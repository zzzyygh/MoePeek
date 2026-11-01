import AppKit
import CoreGraphics
import Defaults
import Foundation

/// Orchestrates Option+S for the in-place overlay path:
/// capture with geometry → multi-provider translate → paint stacked translations onto the shot.
@MainActor
final class ScreenshotTranslationOverlayCoordinator {
    enum Outcome: Equatable {
        case shown
        case cancelled
        case failed(message: String)
    }

    /// Maximum sources stacked per OCR box (keeps plates readable).
    private static let maxOverlayProviders = 3

    private let permissionManager: any PermissionChecking
    private let registry: TranslationProviderRegistry
    private let capture: @escaping @MainActor () async throws -> OCRCaptureResult

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

        let providers = OCRRegionTranslator.overlayProviders(
            from: registry,
            maxCount: Self.maxOverlayProviders
        )
        guard !providers.isEmpty else {
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

        let sourceNames = providers.map(\.displayName).joined(separator: " · ")
        if providers.count > 1 {
            onStatus(String(localized: "Translating with \(sourceNames)…"))
        } else {
            onStatus(String(localized: "Translating…"))
        }

        let regions = result.regions.filter(\.isUsable)
        guard !regions.isEmpty else {
            return .failed(message: String(localized: "No text was recognized in the captured image"))
        }

        let sourceLanguage = OCRRegionTranslator.resolveSourceLanguage(for: regions)
        let targetLanguage = OCRRegionTranslator.resolveTargetLanguage(detectedSource: sourceLanguage)

        let providerResults: [OCRRegionTranslator.ProviderTranslateResult]
        do {
            try Task.checkCancellation()
            providerResults = await OCRRegionTranslator.translateOrdered(
                regions: regions,
                providers: providers,
                from: sourceLanguage,
                to: targetLanguage
            )
        }
        if Task.isCancelled { return .cancelled }

        guard !providerResults.isEmpty else {
            return .failed(message: String(localized: "Translation failed"))
        }

        var overlays: [OCRTextOverlay] = []
        for (index, region) in regions.enumerated() {
            var variants: [OCRTranslationVariant] = []
            for result in providerResults {
                guard index < result.translations.count else { continue }
                let text = result.translations[index]
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    variants.append(OCRTranslationVariant(providerName: result.providerName, text: text))
                }
            }
            let overlay = OCRTextOverlay(region: region, variants: variants)
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
