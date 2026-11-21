#if canImport(AppKitBackend)
import AppKit

/// A stable content row. Empty space drags the window; child controls keep native tracking.
@MainActor final class PlayerHeaderMac: NSView {
    var onLayout: (() -> Void)?
    private var arranging = false
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        if event.clickCount == 2 {
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
            case "Minimize": window.performMiniaturize(nil)
            case "None": break
            default: window.performZoom(nil)
            }
        } else { window.performDrag(with: event) }
    }
    override func layout() {
        super.layout()
        guard !arranging else { return }
        arranging = true; defer { arranging = false }
        onLayout?()
    }
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        needsLayout = true
    }
}
#endif
