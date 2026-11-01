import AppKit
import CoreGraphics
import Defaults
import Foundation

/// Orchestrates Option+S for the in-place overlay path:
/// capture with geometry → primary-provider translate → paint translations onto the shot.
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

    /// Runs the full overlay pipeline. `onOriginal` / `onTranslated` receive CGImages ready to display.
    func run(
        onOriginal: @MainActor (CGImage) -> Void,
        onTranslated: @MainActor (CGImage) -> Void,
        onStatus: @MainActor (String) -> Void
    ) async -> Outcome {
        guard permissionManager.isScreenRecordingGranted else {
            return .failed(message: String(localized: "Screen recording permission not granted. Open Settings to enable it."))
        }

        guard OCRRegionTranslator.primaryProvider(from: registry) != nil else {
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
        onStatus(String(localized: "Translating…"))

        let regions = result.regions.filter(\.isUsable)
        guard !regions.isEmpty else {
            return .failed(message: String(localized: "No text was recognized in the captured image"))
        }

        guard let provider = OCRRegionTranslator.primaryProvider(from: registry) else {
            return .failed(message: String(localized: "No providers enabled. Enable at least one in Settings."))
        }

        let sourceLanguage = OCRRegionTranslator.resolveSourceLanguage(for: regions)
        let targetLanguage = OCRRegionTranslator.resolveTargetLanguage(detectedSource: sourceLanguage)

        let translations: [String]
        do {
            translations = try await OCRRegionTranslator.translate(
                regions: regions,
                using: provider,
                from: sourceLanguage,
                to: targetLanguage
            )
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failed(message: String(localized: "Translation failed: \(error.localizedDescription)"))
        }

        var overlays: [OCRTextOverlay] = []
        for (region, translation) in zip(regions, translations) {
            let overlay = OCRTextOverlay(region: region, translation: translation)
            if overlay.hasTranslation {
                overlays.append(overlay)
            }
        }

        guard !overlays.isEmpty else {
            return .failed(message: String(localized: "Translation returned empty result"))
        }

        let composited = TranslationOverlayCompositor.composite(
            image: result.image,
            overlays: overlays.map(TranslationOverlayCompositor.OverlayItem.init)
        )
        onTranslated(composited)
        return .shown
    }
}
