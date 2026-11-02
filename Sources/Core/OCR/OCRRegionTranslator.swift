import Defaults
import Foundation

/// Translates OCR regions for the in-place overlay.
///
/// Regions are translated independently so the overlay can paint each result
/// as soon as it arrives (progressive “translate a little, replace a little”).
@MainActor
enum OCRRegionTranslator {
    enum TranslatorError: LocalizedError {
        case noProvider

        var errorDescription: String? {
            switch self {
            case .noProvider:
                String(localized: "No providers enabled. Enable at least one in Settings.")
            }
        }
    }

    /// Concurrent region requests (responsive without hammering free APIs).
    private static let maxParallelRegionRequests = 3

    /// Thread-safe accumulator shared by concurrent region streams.
    private final class RegionSink: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String]
        let count: Int

        init(count: Int) {
            self.count = count
            self.values = [String](repeating: "", count: count)
        }

        func set(_ index: Int, _ value: String) {
            lock.lock()
            defer { lock.unlock() }
            guard values.indices.contains(index) else { return }
            values[index] = value
        }

        func snapshot() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }

    /// Translates each region independently, publishing partial results as streams advance.
    /// - Parameter onRegionUpdated: Main-actor callback with the full `[translation]` array
    ///   aligned to `regions.filter(\.isUsable)`.
    static func translateProgressive(
        regions: [OCRTextRegion],
        using provider: any TranslationProvider,
        from sourceLanguage: String?,
        to targetLanguage: String?,
        onRegionUpdated: @escaping @MainActor ([String]) -> Void
    ) async throws -> [String] {
        let usable = regions.filter(\.isUsable)
        guard !usable.isEmpty else {
            onRegionUpdated([])
            return []
        }

        let sink = RegionSink(count: usable.count)
        onRegionUpdated(sink.snapshot())

        try await withThrowingTaskGroup(of: Void.self) { group in
            var nextIndex = 0
            var inFlight = 0

            func publish() {
                let snap = sink.snapshot()
                Task { @MainActor in
                    onRegionUpdated(snap)
                }
            }

            func launchNext() {
                guard nextIndex < usable.count else { return }
                let index = nextIndex
                let source = usable[index].trimmedText
                nextIndex += 1
                inFlight += 1

                group.addTask { [provider] in
                    var accumulated = ""
                    let stream = provider.translateStream(
                        source,
                        from: sourceLanguage,
                        to: targetLanguage
                    )
                    for try await chunk in stream {
                        accumulated += chunk
                        let partial = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !partial.isEmpty else { continue }
                        sink.set(index, partial)
                        publish()
                    }
                    let final = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
                    sink.set(index, final)
                    publish()
                }
            }

            while nextIndex < usable.count, inFlight < maxParallelRegionRequests {
                launchNext()
            }

            do {
                for try await _ in group {
                    inFlight -= 1
                    launchNext()
                }
            } catch {
                group.cancelAll()
                throw error
            }
        }

        let final = sink.snapshot()
        onRegionUpdated(final)
        return final
    }

    /// Convenience wrapper without progressive updates (tests / one-shot callers).
    static func translate(
        regions: [OCRTextRegion],
        using provider: any TranslationProvider,
        from sourceLanguage: String?,
        to targetLanguage: String?
    ) async throws -> [String] {
        try await translateProgressive(
            regions: regions,
            using: provider,
            from: sourceLanguage,
            to: targetLanguage,
            onRegionUpdated: { _ in }
        )
    }

    /// Detects the source language for the combined OCR text, respecting the forced-source setting.
    static func resolveSourceLanguage(for regions: [OCRTextRegion]) -> String? {
        let forced = Defaults[.sourceLanguage]
        if forced != "auto" {
            return forced
        }

        let combined = regions
            .map(\.trimmedText)
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        guard !combined.isEmpty else { return nil }

        let threshold = Defaults[.detectionConfidenceThreshold]
        return LanguageDetector.detectWithConfidence(combined, threshold: threshold, preferredSourceHints: nil).language
    }

    static func resolveTargetLanguage(detectedSource: String?) -> String {
        SupportedLanguages.resolvedTarget(
            Defaults[.targetLanguage],
            detectedLanguage: detectedSource,
            favoriteCodes: Defaults[.favoriteTargetLanguages]
        )
    }

    /// Provider used for in-place overlay: preferred slot when enabled + automatic;
    /// otherwise the first automatically-enabled slot.
    static func overlayProvider(from registry: TranslationProviderRegistry) -> (any TranslationProvider)? {
        let automatic = registry.enabledSlots.filter { registry.translatesAutomatically($0) }
        let preferredID = Defaults[.ocrOverlayPreferredProvider]
        if !preferredID.isEmpty,
           let preferred = automatic.first(where: { $0.id == preferredID }) {
            return preferred
        }
        return automatic.first
    }

    static func primaryProvider(from registry: TranslationProviderRegistry) -> (any TranslationProvider)? {
        overlayProvider(from: registry)
    }
}
