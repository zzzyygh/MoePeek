import AppKit
import CoreGraphics
import Foundation

/// Paints OCR translations over the original text so the screenshot itself reads as translated.
enum TranslationOverlayCompositor {
    struct OverlayItem: Sendable, Equatable {
        /// Top-to-bottom lines to paint (provider-labeled when comparing sources).
        let lines: [String]
        let boundingBox: CGRect

        init(_ overlay: OCRTextOverlay) {
            self.lines = overlay.displayLines.filter { !$0.isEmpty }
            self.boundingBox = overlay.boundingBox
        }

        init(lines: [String], boundingBox: CGRect) {
            self.lines = lines.filter { !$0.isEmpty }
            self.boundingBox = boundingBox
        }

        init(translation: String, boundingBox: CGRect) {
            self.init(lines: [translation], boundingBox: boundingBox)
        }
    }

    /// Renders a new image with each overlay covering its source region.
    /// Returns the original image when there is nothing to paint.
    static func composite(image: CGImage, overlays: [OverlayItem]) -> CGImage {
        let paintable = overlays.filter { !$0.lines.isEmpty }
        guard !paintable.isEmpty else { return image }

        let width = image.width
        let height = image.height
        guard width > 0, height > 0,
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return image }

        let imageBounds = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        context.draw(image, in: imageBounds)
        context.clip(to: imageBounds)

        for overlay in paintable {
            let pixelRect = OCRGeometry.pixelRect(
                normalizedBox: overlay.boundingBox,
                imageWidth: width,
                imageHeight: height
            ).intersection(imageBounds)
            guard !pixelRect.isNull, pixelRect.width >= 2, pixelRect.height >= 2 else { continue }

            let padding = max(4, pixelRect.height * 0.18)
            var coverRect = OCRGeometry.expanded(pixelRect, inset: padding, bounds: imageBounds)
            guard !coverRect.isNull, coverRect.width >= 2, coverRect.height >= 2 else { continue }

            let lineCount = max(1, overlay.lines.count)
            coverRect = growPlateToFit(
                coverRect: coverRect,
                lines: overlay.lines,
                imageBounds: imageBounds,
                padding: padding
            )
            guard coverRect.width >= 2, coverRect.height >= 2 else { continue }

            let background = sampleBackgroundColor(in: image, around: coverRect)
            let textColor = contrastingTextColor(against: background)

            let plateRect = coverRect.insetBy(dx: -1, dy: -1)
            let path = CGPath(roundedRect: plateRect, cornerWidth: 4, cornerHeight: 4, transform: nil)
            context.setFillColor(background.cgColor)
            context.addPath(path)
            context.fillPath()

            drawFittedLines(
                overlay.lines,
                in: coverRect,
                context: context,
                textColor: textColor
            )
            _ = lineCount
        }

        return context.makeImage() ?? image
    }

    /// Expands the plate vertically until every line can render at a readable size.
    private static func growPlateToFit(
        coverRect: CGRect,
        lines: [String],
        imageBounds: CGRect,
        padding: CGFloat
    ) -> CGRect {
        guard !lines.isEmpty else { return coverRect }
        var rect = coverRect
        let minFont: CGFloat = readableMinFontSize
        let maxWidth = max(20, rect.width - 10)

        // Estimate height needed at min font (worst-case wrap).
        for _ in 0..<6 {
            var needed: CGFloat = 0
            for line in lines {
                let font = NSFont.systemFont(ofSize: minFont, weight: .medium)
                let bounds = textBounds(line, font: font, maxWidth: maxWidth)
                needed += max(bounds.height, minFont * 1.25)
            }
            needed += padding * 0.5 + 4
            if needed <= rect.height { break }
            let grow = (needed - rect.height) / 2 + 2
            let expanded = rect.insetBy(dx: 0, dy: -grow).intersection(imageBounds)
            if expanded.height <= rect.height { break } // hit image edge
            rect = expanded
        }
        return rect
    }

    /// Average of a 1px ring just outside the cover rect; falls back to a light plate.
    static func sampleBackgroundColor(in image: CGImage, around rect: CGRect) -> NSColor {
        let fallback = NSColor(calibratedWhite: 0.96, alpha: 1)
        var samples: [NSColor] = []
        samples.append(contentsOf: horizontalEdgeSamples(image: image, y: rect.minY - 2, from: rect.minX, to: rect.maxX))
        samples.append(contentsOf: horizontalEdgeSamples(image: image, y: rect.maxY + 2, from: rect.minX, to: rect.maxX))
        samples.append(contentsOf: verticalEdgeSamples(image: image, x: rect.minX - 2, from: rect.minY, to: rect.maxY))
        samples.append(contentsOf: verticalEdgeSamples(image: image, x: rect.maxX + 2, from: rect.minY, to: rect.maxY))
        guard !samples.isEmpty else { return fallback }

        // Median-per-channel is more robust than the mean against one dark UI border pixel.
        let r = median(samples.map(\.redComponent))
        let g = median(samples.map(\.greenComponent))
        let b = median(samples.map(\.blueComponent))
        return NSColor(calibratedRed: r, green: g, blue: b, alpha: 1)
    }

    /// Picks near-black or near-white text from the relative luminance of the plate.
    static func contrastingTextColor(against background: NSColor) -> NSColor {
        let rgb = background.usingColorSpace(.deviceRGB) ?? background
        let luminance = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
        return luminance > 0.55
            ? NSColor(calibratedWhite: 0.08, alpha: 1)
            : NSColor(calibratedWhite: 0.97, alpha: 1)
    }

    /// Absolute floor for painted translation type (pixels in the screenshot bitmap).
    /// Kept high enough that CJK remains readable after Retina downscale in the panel.
    static let readableMinFontSize: CGFloat = 13

    /// Returns the font size that lets `text` fit `maxSize` (width × height), shrinking as needed.
    static func fittedFontSize(
        for text: String,
        maxWidth: CGFloat,
        maxHeight: CGFloat,
        preferredSize: CGFloat,
        minSize: CGFloat = TranslationOverlayCompositor.readableMinFontSize
    ) -> CGFloat {
        guard !text.isEmpty, maxWidth > 4, maxHeight > 4 else { return minSize }
        var fontSize = max(minSize, min(preferredSize, maxHeight))
        while fontSize >= minSize {
            let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
            let bounds = Self.textBounds(text, font: font, maxWidth: maxWidth)
            if bounds.height <= maxHeight, bounds.width <= maxWidth + 0.5 {
                return fontSize
            }
            fontSize *= 0.94
        }
        return minSize
    }

    /// Measures wrapped text size for fitting decisions.
    static func textBounds(_ text: String, font: NSFont, maxWidth: CGFloat) -> CGSize {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineHeightMultiple = 1.1
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font,
            .paragraphStyle: paragraph,
        ])
        let bounds = attributed.boundingRect(
            with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        return CGSize(width: ceil(bounds.width), height: ceil(bounds.height))
    }

    /// Paints one or more translation lines stacked top-to-bottom inside `rect`.
    /// When `lines.count > 1`, each slot gets an equal horizontal band and a
    /// slightly smaller font so sources can be compared in place.
    static func drawFittedLines(
        _ lines: [String],
        in rect: CGRect,
        context: CGContext,
        textColor: NSColor
    ) {
        guard !lines.isEmpty, rect.width > 4, rect.height > 4 else { return }

        let count = lines.count
        let slotHeight = rect.height / CGFloat(count)
        let topY = rect.maxY // CGContext: larger y is higher

        for (index, line) in lines.enumerated() {
            guard !line.isEmpty else { continue }
            // Slot 0 at the top of the plate (highest y).
            let slotTop = topY - CGFloat(index) * slotHeight
            let slotRect = CGRect(
                x: rect.minX,
                y: slotTop - slotHeight,
                width: rect.width,
                height: slotHeight
            )
            drawFittedText(line, in: slotRect, context: context, textColor: textColor)
        }
    }

    /// Shrinks (then wraps) a single line until it fits the slot, then draws it upright.
    static func drawFittedText(
        _ text: String,
        in rect: CGRect,
        context: CGContext,
        textColor: NSColor
    ) {
        guard !text.isEmpty, rect.width > 4, rect.height > 4 else { return }

        let horizontalPadding: CGFloat = 6
        let verticalPadding: CGFloat = 3
        let maxTextWidth = max(4, rect.width - horizontalPadding * 2)
        let maxTextHeight = max(4, rect.height - verticalPadding * 2)
        // Prefer a large size first; fittedFontSize only shrinks down to readableMinFontSize.
        let preferredSize = max(readableMinFontSize, min(rect.height * 0.9, maxTextHeight))

        let fontSize = fittedFontSize(
            for: text,
            maxWidth: maxTextWidth,
            maxHeight: maxTextHeight,
            preferredSize: preferredSize
        )
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineHeightMultiple = 1.1

        let attributed = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraph,
        ])

        let measured = Self.textBounds(text, font: font, maxWidth: maxTextWidth)
        let textHeight = min(maxTextHeight, measured.height)
        let drawWidth = min(maxTextWidth, max(4, measured.width))
        guard let textImage = renderTextImage(attributed, width: drawWidth, height: textHeight) else {
            return
        }

        // coverRect is in CGContext space (origin bottom-left). CGContext.draw preserves
        // CGImage orientation, so an upright text bitmap stays upright here.
        let cgDrawRect = CGRect(
            x: rect.midX - drawWidth / 2,
            y: rect.midY - textHeight / 2,
            width: drawWidth,
            height: textHeight
        )
        context.saveGState()
        context.draw(textImage, in: cgDrawRect)
        context.restoreGState()
    }

    /// Renders attributed text into an opaque-free bitmap using AppKit's top-left
    /// graphics context (correct glyph orientation), then returns it as a CGImage.
    private static func renderTextImage(_ attributed: NSAttributedString, width: CGFloat, height: CGFloat) -> CGImage? {
        let pixelWidth = max(1, Int(ceil(width)))
        let pixelHeight = max(1, Int(ceil(height)))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }

        rep.size = NSSize(width: CGFloat(pixelWidth), height: CGFloat(pixelHeight))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        attributed.draw(in: CGRect(x: 0, y: 0, width: CGFloat(pixelWidth), height: CGFloat(pixelHeight)))
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }

    // MARK: - Pixel sampling

    private static func horizontalEdgeSamples(
        image: CGImage,
        y: CGFloat,
        from minX: CGFloat,
        to maxX: CGFloat
    ) -> [NSColor] {
        let pixelY = Int(y.rounded())
        guard pixelY >= 0, pixelY < image.height else { return [] }
        let start = max(0, Int(minX.rounded()))
        let end = min(image.width - 1, Int(maxX.rounded()))
        guard start <= end else { return [] }

        var colors: [NSColor] = []
        let step = max(1, (end - start) / 24)
        var x = start
        while x <= end {
            if let color = pixelColor(in: image, x: x, y: pixelY) {
                colors.append(color)
            }
            x += step
        }
        return colors
    }

    private static func verticalEdgeSamples(
        image: CGImage,
        x: CGFloat,
        from minY: CGFloat,
        to maxY: CGFloat
    ) -> [NSColor] {
        let pixelX = Int(x.rounded())
        guard pixelX >= 0, pixelX < image.width else { return [] }
        let start = max(0, Int(minY.rounded()))
        let end = min(image.height - 1, Int(maxY.rounded()))
        guard start <= end else { return [] }

        var colors: [NSColor] = []
        let step = max(1, (end - start) / 24)
        var y = start
        while y <= end {
            if let color = pixelColor(in: image, x: pixelX, y: y) {
                colors.append(color)
            }
            y += step
        }
        return colors
    }

    /// Reads one sRGB pixel. Coordinates are Core Graphics bottom-left based.
    private static func pixelColor(in image: CGImage, x: Int, y: Int) -> NSColor? {
        guard x >= 0, y >= 0, x < image.width, y < image.height else { return nil }

        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { return nil }

        // Draw a 1×1 window of the source image into the sample context.
        context.draw(
            image,
            in: CGRect(x: -CGFloat(x), y: -CGFloat(y), width: 1, height: 1)
        )

        let alpha = CGFloat(pixel[3]) / 255
        guard alpha > 0.01 else { return nil }
        return NSColor(
            calibratedRed: CGFloat(pixel[0]) / 255 / max(alpha, 0.01),
            green: CGFloat(pixel[1]) / 255 / max(alpha, 0.01),
            blue: CGFloat(pixel[2]) / 255 / max(alpha, 0.01),
            alpha: 1
        )
    }

    private static func median(_ values: [CGFloat]) -> CGFloat {
        guard !values.isEmpty else { return 0.5 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }
}
