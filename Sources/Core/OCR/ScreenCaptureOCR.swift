import AppKit
import Vision
import os

enum ScreenCaptureOCR {
    /// Atomically claim a one-shot flag. Returns `true` on first call, `false` thereafter.
    private static func claimOnce(_ lock: OSAllocatedUnfairLock<Bool>) -> Bool {
        lock.withLock { val in
            if val { return false }
            val = true
            return true
        }
    }

    /// Launch interactive screen capture, OCR the captured image, and return recognized text.
    static func captureAndRecognize() async throws -> String {
        let result = try await captureWithTextRegions()
        let text = result.regions
            .map(\.trimmedText)
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        if text.isEmpty {
            throw OCRError.noTextRecognized
        }
        return text
    }

    /// Launch interactive screen capture and OCR with bounding boxes retained.
    ///
    /// Used by the in-place overlay flow, which paints each translation back onto the
    /// original region instead of showing a separate result popup.
    static func captureWithTextRegions() async throws -> OCRCaptureResult {
        // Generate a unique temp file path to avoid concurrency conflicts
        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("moepeek_ocr_\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        // Run screencapture -i <tmpPath> (interactive selection → temp file, clipboard untouched)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", tmpURL.path]

        let status = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                let resumed = OSAllocatedUnfairLock(initialState: false)

                process.terminationHandler = { proc in
                    guard claimOnce(resumed) else { return }
                    continuation.resume(returning: proc.terminationStatus)
                }
                do {
                    try process.run()
                } catch {
                    guard claimOnce(resumed) else { return }
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            process.terminate()
        }

        guard status == 0 else {
            throw OCRError.captureCancelled
        }

        // Read image from temp file and perform OCR inside autoreleasepool
        // to ensure large screenshot images are freed promptly.
        let cgImage: CGImage = try autoreleasepool {
            guard let image = NSImage(contentsOf: tmpURL),
                  let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            else {
                throw OCRError.captureReadFailed
            }
            return cg
        }

        let regions = try await recognizeTextRegions(in: cgImage)
        guard regions.contains(where: \.isUsable) else {
            throw OCRError.noTextRecognized
        }
        return OCRCaptureResult(image: cgImage, regions: regions.filter(\.isUsable))
    }

    /// OCR with line-level geometry. Returns observations sorted in reading order
    /// (top → bottom, then left → right) so batch translation maps predictably.
    static func recognizeTextRegions(in image: CGImage) async throws -> [OCRTextRegion] {
        try await withCheckedThrowingContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)

            let request = VNRecognizeTextRequest { request, error in
                guard claimOnce(resumed) else { return }

                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let regions = observations.compactMap { observation -> OCRTextRegion? in
                    guard let candidate = observation.topCandidates(1).first else { return nil }
                    let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return nil }
                    return OCRTextRegion(
                        text: text,
                        boundingBox: observation.boundingBox,
                        confidence: candidate.confidence
                    )
                }
                continuation.resume(returning: Self.sortedInReadingOrder(regions))
            }

            request.recognitionLevel = .accurate
            request.automaticallyDetectsLanguage = true
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US", "ja-JP", "ko-KR"]
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                guard claimOnce(resumed) else { return }
                continuation.resume(throwing: error)
            }
        }
    }

    /// Sort by Vision's top edge (maxY desc), then left edge. Ties keep x order stable.
    static func sortedInReadingOrder(_ regions: [OCRTextRegion]) -> [OCRTextRegion] {
        regions.sorted { lhs, rhs in
            let lhsTop = lhs.boundingBox.maxY
            let rhsTop = rhs.boundingBox.maxY
            // Snap near-equal rows so multi-column lines still read left → right as a group.
            if abs(lhsTop - rhsTop) > 0.012 {
                return lhsTop > rhsTop
            }
            return lhs.boundingBox.minX < rhs.boundingBox.minX
        }
    }
}

enum OCRError: LocalizedError {
    case captureCancelled
    case captureReadFailed
    case noTextRecognized

    var errorDescription: String? {
        switch self {
        case .captureCancelled:  String(localized: "Screen capture was cancelled")
        case .captureReadFailed: String(localized: "Failed to read the captured image")
        case .noTextRecognized:  String(localized: "No text was recognized in the captured image")
        }
    }
}
