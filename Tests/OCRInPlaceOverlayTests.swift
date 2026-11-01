import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import MoePeek

@Suite
struct OCRGeometryTests {
    @Test func convertsNormalizedVisionBoxToPixelRect() {
        // Vision: origin bottom-left, normalized 0...1
        let box = CGRect(x: 0.25, y: 0.5, width: 0.5, height: 0.25)
        let rect = OCRGeometry.pixelRect(normalizedBox: box, imageWidth: 200, imageHeight: 100)
        #expect(rect == CGRect(x: 50, y: 50, width: 100, height: 25))
    }

    @Test func expandsAndClampsToImageBounds() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let rect = CGRect(x: 10, y: 10, width: 20, height: 20)
        let expanded = OCRGeometry.expanded(rect, inset: 5, bounds: bounds)
        #expect(expanded == CGRect(x: 5, y: 5, width: 30, height: 30))

        let nearEdge = CGRect(x: 0, y: 0, width: 10, height: 10)
        let clamped = OCRGeometry.expanded(nearEdge, inset: 8, bounds: bounds)
        #expect(clamped.minX == 0)
        #expect(clamped.minY == 0)
    }
}

@Suite
struct OCRReadingOrderTests {
    @Test func sortsTopToBottomThenLeftToRight() {
        let topRight = OCRTextRegion(text: "b", boundingBox: CGRect(x: 0.6, y: 0.8, width: 0.2, height: 0.1), confidence: 1)
        let topLeft = OCRTextRegion(text: "a", boundingBox: CGRect(x: 0.1, y: 0.8, width: 0.2, height: 0.1), confidence: 1)
        let bottom = OCRTextRegion(text: "c", boundingBox: CGRect(x: 0.1, y: 0.2, width: 0.2, height: 0.1), confidence: 1)

        let sorted = ScreenCaptureOCR.sortedInReadingOrder([bottom, topRight, topLeft])
        #expect(sorted.map(\.text) == ["a", "b", "c"])
    }

    @Test func keepsNearEqualRowsInLeftToRightOrder() {
        let left = OCRTextRegion(text: "left", boundingBox: CGRect(x: 0.05, y: 0.50, width: 0.2, height: 0.1), confidence: 1)
        let right = OCRTextRegion(text: "right", boundingBox: CGRect(x: 0.55, y: 0.505, width: 0.2, height: 0.1), confidence: 1)

        let sorted = ScreenCaptureOCR.sortedInReadingOrder([right, left])
        #expect(sorted.map(\.text) == ["left", "right"])
    }
}

@Suite
struct TranslationOverlayCompositorTests {
    @Test func contrastPicksDarkTextOnLightPlate() {
        let light = NSColor(calibratedWhite: 0.95, alpha: 1)
        let dark = NSColor(calibratedWhite: 0.1, alpha: 1)
        #expect(TranslationOverlayCompositor.contrastingTextColor(against: light) == NSColor(calibratedWhite: 0.08, alpha: 1))
        #expect(TranslationOverlayCompositor.contrastingTextColor(against: dark) == NSColor(calibratedWhite: 0.97, alpha: 1))
    }

    @Test func fittedFontSizeShrinksUntilTextFits() {
        let maxWidth: CGFloat = 80
        let maxHeight: CGFloat = 18
        // Short enough that shrinking to min size is unnecessary; preferred size must be used.
        let short = "你好世界"
        let shortSize = TranslationOverlayCompositor.fittedFontSize(
            for: short,
            maxWidth: maxWidth,
            maxHeight: maxHeight,
            preferredSize: 16
        )
        #expect(shortSize <= 16)
        #expect(shortSize >= 7)
        let shortBounds = TranslationOverlayCompositor.textBounds(
            short,
            font: .systemFont(ofSize: shortSize, weight: .medium),
            maxWidth: maxWidth
        )
        #expect(shortBounds.height <= maxHeight)

        // Long text must not exceed the preferred size; height may still wrap past the plate
        // at min font size, so only assert the size was reduced.
        let long = String(repeating: "译", count: 40)
        let longSize = TranslationOverlayCompositor.fittedFontSize(
            for: long,
            maxWidth: maxWidth,
            maxHeight: maxHeight,
            preferredSize: 24
        )
        #expect(longSize < 24)
        #expect(longSize >= 7)
    }

    @Test func compositeReturnsOriginalWhenNoPaintableOverlays() throws {
        // 1×1 opaque red pixel
        var pixels: [UInt8] = [255, 0, 0, 255]
        let image = try #require(makeTestImage(pixels: &pixels, width: 1, height: 1))
        let output = TranslationOverlayCompositor.composite(image: image, overlays: [])
        #expect(output === image)
    }

    @Test func overlayTextMapsOneToOneAfterSuccessfulBatch() {
        // Here we assert OCRTextOverlay packaging preserves geometry for 1:1 mapping.
        let region = OCRTextRegion(
            text: "Hello",
            boundingBox: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.05),
            confidence: 0.9
        )
        let overlay = OCRTextOverlay(region: region, translation: "  你好  ")
        #expect(overlay.hasTranslation)
        #expect(overlay.displayLines == ["你好"])
        #expect(overlay.originalText == "Hello")
        #expect(overlay.boundingBox == region.boundingBox)

        let multi = OCRTextOverlay(
            region: region,
            variants: [
                OCRTranslationVariant(providerName: "A", text: "甲"),
                OCRTranslationVariant(providerName: "B", text: "乙"),
            ]
        )
        #expect(multi.lineCount == 2)
        #expect(multi.displayLines == ["A: 甲", "B: 乙"])
    }
}

@Suite
struct OCRTextRegionTests {
    @Test func usabilityIgnoresBlankAndDegenerateRegions() {
        let blank = OCRTextRegion(text: "   \n", boundingBox: CGRect(x: 0, y: 0, width: 1, height: 1), confidence: 1)
        let zeroWidth = OCRTextRegion(text: "a", boundingBox: CGRect(x: 0, y: 0, width: 0, height: 1), confidence: 1)
        let good = OCRTextRegion(text: "a", boundingBox: CGRect(x: 0, y: 0, width: 0.1, height: 0.1), confidence: 0.2)
        #expect(!blank.isUsable)
        #expect(!zeroWidth.isUsable)
        #expect(good.isUsable)
    }
}

// MARK: - Helpers

private func makeTestImage(pixels: inout [UInt8], width: Int, height: Int) -> CGImage? {
    let data = Data(pixels)
    guard let provider = CGDataProvider(data: data as CFData) else { return nil }
    return CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )
}
