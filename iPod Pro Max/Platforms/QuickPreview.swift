import Foundation

#if canImport(AppKit)
import AppKit

/// A small Quick Look–style panel for one tall image (a game's instruction page): no title bar,
/// fades in, opens fitted to its width at the top of the page, scrolls, zooms in (never out
/// past the fitted width) with a trackpad pinch, and fades out on Esc or a click elsewhere.
@MainActor final class QuickPreview {
    static let shared = QuickPreview()
    private var panel: PreviewPanel?

    func show(_ url: URL, title: String? = nil) {
        guard let image = NSImage(contentsOf: url), let rep = image.representations.first else { return }
        // Pixel size, so a 72-dpi JPEG and a Retina PNG open at the same width.
        let size = NSSize(width: max(1, rep.pixelsWide), height: max(1, rep.pixelsHigh))
        image.size = size
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = min(560, size.width, visible.width * 0.6)
        let height = min(visible.height * 0.85, size.height * width / size.width)
        let panel = self.panel ?? PreviewPanel()
        self.panel = panel
        panel.setAccessibilityTitle(title ?? url.deletingPathExtension().lastPathComponent)
        panel.display(image)
        if !panel.isVisible {
            panel.setContentSize(NSSize(width: width, height: height))
            panel.center()
        }
        panel.fit()
        panel.fadeIn()
    }
}

private final class FlippedImageView: NSImageView {
    override var isFlipped: Bool { true }
}

private final class PreviewPanel: NSPanel, NSWindowDelegate {
    private let scroll = NSScrollView()
    private let imageView = FlippedImageView()
    private var closing = false

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 560, height: 700),
                   styleMask: [.borderless, .resizable, .fullSizeContentView],
                   backing: .buffered, defer: true)
        isReleasedWhenClosed = false
        isFloatingPanel = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        delegate = self
        let frame = NSView()
        frame.wantsLayer = true
        frame.layer?.cornerRadius = 12
        frame.layer?.masksToBounds = true
        frame.layer?.backgroundColor = NSColor.black.cgColor
        imageView.imageScaling = .scaleAxesIndependently
        scroll.documentView = imageView
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.allowsMagnification = true
        scroll.maxMagnification = 4
        scroll.autoresizingMask = [.width, .height]
        frame.addSubview(scroll)
        contentView = frame
    }

    func display(_ image: NSImage) {
        imageView.image = image
        imageView.frame = NSRect(origin: .zero, size: image.size)
    }

    /// Fits the page's width to the window, makes that the smallest zoom, and goes back to the top.
    func fit() {
        guard let size = imageView.image?.size, size.width > 0, let content = contentView else { return }
        scroll.frame = content.bounds
        let fitted = scroll.contentSize.width / size.width
        scroll.minMagnification = fitted
        scroll.maxMagnification = max(4, fitted * 4)
        scroll.magnification = fitted
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    func fadeIn() {
        closing = false
        if !isVisible { alphaValue = 0 }
        makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.18; animator().alphaValue = 1 }
    }

    func fadeOut() {
        guard isVisible, !closing else { return }
        closing = true
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.18; animator().alphaValue = 0 }) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.closing else { return }
                self.orderOut(nil)
                self.closing = false
            }
        }
    }

    func windowDidResignKey(_ notification: Notification) { fadeOut() }
    func windowDidResize(_ notification: Notification) {
        // Keep the fitted width as the zoom floor when the panel is resized.
        guard let size = imageView.image?.size, size.width > 0 else { return }
        let fitted = scroll.contentSize.width / size.width
        scroll.minMagnification = fitted
        if scroll.magnification < fitted { scroll.magnification = fitted }
    }
    override func cancelOperation(_ sender: Any?) { fadeOut() }
    override var canBecomeKey: Bool { true }
}
#else
/// Opens the file in the system's image viewer, the closest equivalent of Quick Look.
@MainActor final class QuickPreview {
    static let shared = QuickPreview()
    func show(_ url: URL, title: String? = nil) {
        let process = Process()
        #if os(Windows)
        process.executableURL = URL(fileURLWithPath: "C:\\Windows\\System32\\cmd.exe")
        process.arguments = ["/c", "start", "", url.path]
        #else
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xdg-open")
        process.arguments = [url.path]
        #endif
        try? process.run()
    }
}
#endif
