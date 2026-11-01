import CoreGraphics
import Foundation

/// A single OCR hit with its on-image location.
///
/// `boundingBox` uses Vision's normalized coordinate space: origin bottom-left,
/// values in 0...1 relative to the image.
struct OCRTextRegion: Sendable, Equatable {
    let text: String
    let boundingBox: CGRect
    let confidence: Float

    var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isUsable: Bool {
        !trimmedText.isEmpty && boundingBox.width > 0.001 && boundingBox.height > 0.001
    }
}

/// Result of an interactive capture that retained OCR geometry.
struct OCRCaptureResult: @unchecked Sendable {
    let image: CGImage
    let regions: [OCRTextRegion]
}

/// One provider's translation for a region (used for multi-source comparison).
struct OCRTranslationVariant: Sendable, Equatable {
    let providerName: String
    let text: String

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// One overlay painted over an original OCR region.
/// Multiple `variants` stack top-to-bottom for side-by-side comparison.
struct OCRTextOverlay: Sendable, Equatable {
    let originalText: String
    let boundingBox: CGRect
    let variants: [OCRTranslationVariant]

    init(region: OCRTextRegion, variants: [OCRTranslationVariant]) {
        self.originalText = region.trimmedText
        self.boundingBox = region.boundingBox
        self.variants = variants.filter { !$0.isEmpty }
    }

    init(region: OCRTextRegion, translation: String) {
        self.init(
            region: region,
            variants: [OCRTranslationVariant(providerName: "", text: translation)]
        )
    }

    var hasTranslation: Bool {
        !variants.isEmpty
    }

    /// Top-to-bottom display lines (labels only when comparing multiple sources).
    var displayLines: [String] {
        guard variants.count > 1 else {
            return variants.map(\.text)
        }
        return variants.map { variant in
            let name = variant.providerName.isEmpty ? "" : "\(variant.providerName): "
            return name + variant.text
        }
    }

    var lineCount: Int {
        max(1, displayLines.count)
    }
}

enum OCRGeometry {
    /// Convert a Vision normalized box into pixel coordinates in a `CGContext`
    /// whose origin is bottom-left (Core Graphics default).
    static func pixelRect(normalizedBox: CGRect, imageWidth: Int, imageHeight: Int) -> CGRect {
        let width = CGFloat(imageWidth)
        let height = CGFloat(imageHeight)
        return CGRect(
            x: normalizedBox.minX * width,
            y: normalizedBox.minY * height,
            width: normalizedBox.width * width,
            height: normalizedBox.height * height
        )
    }

    /// Expand a rect by a fixed inset on every side, clamped to image bounds.
    static func expanded(_ rect: CGRect, inset: CGFloat, bounds: CGRect) -> CGRect {
        let expanded = rect.insetBy(dx: -inset, dy: -inset)
        return expanded.intersection(bounds)
    }
}
