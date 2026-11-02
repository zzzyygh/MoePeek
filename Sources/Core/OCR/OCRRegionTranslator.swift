import Defaults
import Foundation

/// Translates OCR regions for the in-place overlay.
///
/// Overlay mode only needs one readable result per region, so it uses the first
/// automatically-enabled provider slot instead of fanning out to every provider.
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

    /// How many individual region requests may share the network at once when the
    /// single batched request cannot be mapped back 1:1.
    private static let maxParallelRegionRequests = 3

    /// Translates each region's text, preserving input order in the output.
    static func translate(
        regions: [OCRTextRegion],
        using provider: any TranslationProvider,
        from sourceLanguage: String?,
        to targetLanguage: String
    ) async throws -> [String] {
        let usable = regions.filter(\.isUsable)
        guard !usable.isEmpty else { return [] }

        let texts = usable.map(\.trimmedText)

        if let mapped = try? await translateBatched(
            texts,
            using: provider,
            from: sourceLanguage,
            to: targetLanguage
        ) {
            return mapped
        }

        return try await translateIndividually(
            texts,
            using: provider,
            from: sourceLanguage,
            to: targetLanguage
        )
    }

    /// Joins every line with `\n`, asks the provider once, then splits the answer.
    /// Returns nil when the split does not line up with the inputs.
    static func translateBatched(
        _ texts: [String],
        using provider: any TranslationProvider,
        from sourceLanguage: String?,
        to targetLanguage: String
    ) async throws -> [String]? {
        guard texts.count > 1 else {
            let single = try await collect(provider.translateStream(
                texts[0],
                from: sourceLanguage,
                to: targetLanguage
            ))
            let trimmed = single.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : [trimmed]
        }

        let joined = texts.joined(separator: "\n")
        let raw = try await collect(provider.translateStream(
            joined,
            from: sourceLanguage,
            to: targetLanguage
        ))
        let lines = raw
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        guard lines.count == texts.count, lines.allSatisfy({ !$0.isEmpty }) else {
            return nil
        }
        return lines
    }

    /// Per-region requests with a small concurrency cap. Used when batching fails to map.
    static func translateIndividually(
        _ texts: [String],
        using provider: any TranslationProvider,
        from sourceLanguage: String?,
        to targetLanguage: String
    ) async throws -> [String] {
        try await withThrowingTaskGroup(of: (Int, String).self) { group in
            var results = [String](repeating: "", count: texts.count)
            var nextIndex = 0
            var inFlight = 0

            func launchNext() {
                guard nextIndex < texts.count else { return }
                let index = nextIndex
                let text = texts[index]
                nextIndex += 1
                inFlight += 1
                group.addTask { [provider] in
                    let output = try await self.collect(provider.translateStream(
                        text,
                        from: sourceLanguage,
                        to: targetLanguage
                    ))
                    return (index, output.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }

            while nextIndex < texts.count, inFlight < maxParallelRegionRequests {
                launchNext()
            }

            for try await (index, value) in group {
                results[index] = value
                inFlight -= 1
                launchNext()
            }

            // Preserve blanks rather than failing the whole overlay for one empty box.
            return results
        }
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

    /// Provider used for in-place overlay: the configured preferred slot when it is
    /// enabled and automatic; otherwise the first automatically-enabled slot.
    static func overlayProvider(from registry: TranslationProviderRegistry) -> (any TranslationProvider)? {
        let automatic = registry.enabledSlots.filter { registry.translatesAutomatically($0) }
        let preferredID = Defaults[.ocrOverlayPreferredProvider]
        if !preferredID.isEmpty,
           let preferred = automatic.first(where: { $0.id == preferredID }) {
            return preferred
        }
        return automatic.first
    }

    /// First automatically-enabled slot in user order — single-source fallback.
    static func primaryProvider(from registry: TranslationProviderRegistry) -> (any TranslationProvider)? {
        overlayProvider(from: registry)
    }

    private static func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> String {
        var accumulated = ""
        for try await chunk in stream {
            accumulated += chunk
        }
        return accumulated
    }
}
