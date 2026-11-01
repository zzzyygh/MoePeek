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

/// One translation painted over an original OCR region.
struct OCRTextOverlay: Sendable, Equatable {
    let originalText: String
    let translation: String
    let boundingBox: CGRect

    init(region: OCRTextRegion, translation: String) {
        self.originalText = region.trimmedText
        self.translation = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        self.boundingBox = region.boundingBox
    }

    var hasTranslation: Bool {
        !translation.isEmpty
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
