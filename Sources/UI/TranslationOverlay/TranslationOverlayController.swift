import AppKit
import Defaults
import SwiftUI

/// Floating panel that shows a screenshot with translations painted over the original text.
final class TranslationOverlayPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: true
        )

        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { true }
}

/// Content view: the translated screenshot plus an optional status strip while loading.
private struct TranslationOverlayContentView: View {
    let image: NSImage
    var isLoading: Bool
    var statusText: String?

    var body: some View {
        VStack(spacing: 0, content: {
            ZStack {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)

                if isLoading {
                    ProgressView()
                        .controlSize(.large)
                        .padding(12)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
            }

            if let statusText, !statusText.isEmpty {
                HStack(spacing: 6) {
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(statusText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.bar)
            }
        })
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.separator, lineWidth: 1)
        )
    }
}

/// Manages the in-place screenshot translation overlay lifecycle.
@MainActor
final class TranslationOverlayController {
    var onDismiss: (() -> Void)?

    private var panel: TranslationOverlayPanel?
    private var hostView: NSHostingView<TranslationOverlayContentView>?
    private var dismissMonitor: PopupDismissMonitor?
    private var currentImage: NSImage?
    private var isLoading = false
    private var statusText: String?

    func showOriginal(image: CGImage, statusText: String?) {
        let nsImage = NSImage(cgImage: image, size: pixelSize(for: image))
        currentImage = nsImage
        isLoading = true
        self.statusText = statusText
        render()
    }

    func showTranslated(image: CGImage, statusText: String?) {
        let nsImage = NSImage(cgImage: image, size: pixelSize(for: image))
        currentImage = nsImage
        isLoading = false
        self.statusText = statusText
        render()
    }

    /// Updates the footer without touching the image. No-op before the first frame.
    func updateStatus(_ text: String?) {
        guard currentImage != nil else { return }
        statusText = text
        render()
    }

    func dismiss() {
        dismissMonitor?.stop()
        dismissMonitor = nil
        hostView = nil
        currentImage = nil
        isLoading = false
        statusText = nil
        panel?.contentView = nil
        panel?.close()
        panel = nil
    }

    var isVisible: Bool {
        panel?.isVisible ?? false
    }

    // MARK: - Private

    private func render() {
        guard let image = currentImage else { return }
        let contentSize = fittedContentSize(for: image)
        let panel = self.panel ?? TranslationOverlayPanel(contentRect: NSRect(origin: .zero, size: contentSize))
        self.panel = panel

        let rootView = TranslationOverlayContentView(image: image, isLoading: isLoading, statusText: statusText)
        if let hostView {
            hostView.rootView = rootView
            hostView.setFrameSize(contentSize)
        } else {
            let host = NSHostingView(rootView: rootView)
            host.setFrameSize(contentSize)
            panel.contentView = host
            hostView = host
        }

        panel.setContentSize(contentSize)
        place(panel, contentSize: contentSize)
        panel.orderFrontRegardless()

        if dismissMonitor == nil {
            let monitor = PopupDismissMonitor(panel: panel) { [weak self] in
                self?.dismiss()
                self?.onDismiss?()
            }
            monitor.start()
            dismissMonitor = monitor
        }
    }

    private func fittedContentSize(for image: NSImage) -> CGSize {
        let imageSize = image.size
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGSize(width: 480, height: 320)
        }

        let screen = NSScreen.main?.visibleFrame
            ?? NSScreen.screens.first?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)

        let maxWidth = max(320, screen.width * 0.86)
        let maxHeight = max(240, screen.height * 0.82)
        let scale = min(maxWidth / imageSize.width, maxHeight / imageSize.height, 1)

        var size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        if let statusText, !statusText.isEmpty {
            size.height += 36
        }
        size.width = max(240, size.width)
        size.height = max(160, size.height)
        return size
    }

    private func place(_ panel: NSPanel, contentSize: CGSize) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        else { return }

        let visible = screen.visibleFrame
        let cursor = NSEvent.mouseLocation
        var origin = NSPoint(
            x: cursor.x - contentSize.width / 2,
            y: cursor.y - contentSize.height / 2
        )
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - contentSize.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - contentSize.height - 8)
        panel.setFrame(NSRect(origin: origin, size: contentSize), display: true)
    }

    private func pixelSize(for image: CGImage) -> NSSize {
        // Backing pixels → points so Retina captures are not shown at 2× logical size.
        let scale = max(NSScreen.main?.backingScaleFactor ?? 2, 1)
        return NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
    }
}
