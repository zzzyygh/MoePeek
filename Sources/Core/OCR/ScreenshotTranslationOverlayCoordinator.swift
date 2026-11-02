import AppKit
import CoreGraphics
import Defaults
import Foundation

/// Orchestrates Option+S for the in-place overlay path:
/// capture → progressive preferred-provider translate → paint as results arrive.
@MainActor
final class ScreenshotTranslationOverlayCoordinator {
    enum Outcome: Equatable {
        case shown
        case cancelled
        case failed(message: String)
    }

    private let permissionManager: any PermissionChecking
    private let registry: TranslationProviderRegistry
    private let capture: @MainActor () async throws -> OCRCaptureResult

    init(
        permissionManager: any PermissionChecking,
        registry: TranslationProviderRegistry,
        capture: @escaping @MainActor () async throws -> OCRCaptureResult = ScreenCaptureOCR.captureWithTextRegions
    ) {
        self.permissionManager = permissionManager
        self.registry = registry
        self.capture = capture
    }

    /// - `onOriginal`: once, raw screenshot.
    /// - `onTranslated`: repeatedly as regions/stream chunks arrive (progressive replace).
    func run(
        onOriginal: @escaping @MainActor (CGImage) -> Void,
        onTranslated: @escaping @MainActor (CGImage) -> Void,
        onStatus: @escaping @MainActor (String) -> Void
    ) async -> Outcome {
        guard permissionManager.isScreenRecordingGranted else {
            return .failed(message: String(localized: "Screen recording permission not granted. Open Settings to enable it."))
        }

        guard let provider = OCRRegionTranslator.overlayProvider(from: registry) else {
            return .failed(message: String(localized: "No providers enabled. Enable at least one in Settings."))
        }

        let result: OCRCaptureResult
        do {
            result = try await capture()
        } catch OCRError.captureCancelled {
            return .cancelled
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failed(message: String(localized: "OCR failed: \(error.localizedDescription)"))
        }

        onOriginal(result.image)

        let regions = result.regions.filter(\.isUsable)
        guard !regions.isEmpty else {
            return .failed(message: String(localized: "No text was recognized in the captured image"))
        }

        let sourceLanguage = OCRRegionTranslator.resolveSourceLanguage(for: regions)
        let targetLanguage = OCRRegionTranslator.resolveTargetLanguage(detectedSource: sourceLanguage)
        let total = regions.count
        let image = result.image
        let providerName = provider.displayName

        onStatus(String(localized: "Translating with \(providerName)… 0/\(total)"))

        let painter = ProgressiveOverlayPainter(
            image: image,
            regions: regions,
            total: total,
            providerName: providerName,
            onTranslated: { image in onTranslated(image) },
            onStatus: { status in onStatus(status) }
        )

        if Task.isCancelled { return .cancelled }

        do {
            try await OCRRegionTranslator.translateProgressive(
                regions: regions,
                using: provider,
                from: sourceLanguage,
                to: targetLanguage,
                onRegionUpdated: { snapshot in
                    painter.update(translations: snapshot)
                }
            )
        } catch is CancellationError {
            painter.flush()
            return .cancelled
        } catch {
            painter.flush()
            return .failed(message: String(localized: "Translation failed: \(error.localizedDescription)"))
        }

        painter.flush()
        if Task.isCancelled { return .cancelled }
        return painter.didPaint ? .shown : .failed(message: String(localized: "Translation returned empty result"))
    }
}

/// Throttled progressive recomposite so streaming OCR translations appear incrementally.
@MainActor
private final class ProgressiveOverlayPainter {
    let total: Int
    private let image: CGImage
    private let regions: [OCRTextRegion]
    private let providerName: String
    private let onTranslated: (CGImage) -> Void
    private let onStatus: (String) -> Void

    private var lastSnapshot: [String]
    private var lastPaintAt = Date.distantPast
    private var pendingPaint = false
    private var paintTask: Task<Void, Never>?
    private var paintedOnce = false

    var didPaint: Bool { paintedOnce }

    init(
        image: CGImage,
        regions: [OCRTextRegion],
        total: Int,
        providerName: String,
        onTranslated: @escaping (CGImage) -> Void,
        onStatus: @escaping (String) -> Void
    ) {
        self.image = image
        self.regions = regions
        self.total = total
        self.providerName = providerName
        self.onTranslated = onTranslated
        self.onStatus = onStatus
        self.lastSnapshot = [String](repeating: "", count: regions.count)
    }

    func update(translations: [String]) {
        lastSnapshot = translations
        let now = Date()
        if now.timeIntervalSince(lastPaintAt) >= 0.1 {
            lastPaintAt = now
            pendingPaint = false
            paintTask?.cancel()
            paintTask = nil
            paint()
            return
        }
        guard !pendingPaint else { return }
        pendingPaint = true
        paintTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard let self, !Task.isCancelled else { return }
            self.paintTask = nil
            guard self.pendingPaint else { return }
            self.pendingPaint = false
            self.lastPaintAt = Date()
            self.paint()
        }
    }

    func flush() {
        paintTask?.cancel()
        paintTask = nil
        pendingPaint = false
        paint()
    }

    private func paint() {
        let overlays: [OCRTextOverlay] = zip(regions, lastSnapshot).compactMap { region, text in
            let overlay = OCRTextOverlay(region: region, translation: text)
            return overlay.hasTranslation ? overlay : nil
        }
        guard !overlays.isEmpty else { return }

        let composited = TranslationOverlayCompositor.composite(
            image: image,
            overlays: overlays.map(TranslationOverlayCompositor.OverlayItem.init)
        )
        onTranslated(composited)
        paintedOnce = true

        let done = lastSnapshot.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count
        if done >= total {
            onStatus(String(localized: "Done \(done)/\(total) · \(providerName)"))
        } else {
            onStatus(String(localized: "Translating with \(providerName)… \(done)/\(total)"))
        }
    }
}
