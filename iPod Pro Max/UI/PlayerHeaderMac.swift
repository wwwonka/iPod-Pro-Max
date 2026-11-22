#if canImport(AppKitBackend)
import AppKit

/// A stable content row. Empty space drags the window; child controls keep native tracking.
@MainActor final class PlayerHeaderMac: NSView {
    var onPointerPresence: (Bool) -> Void = { _ in }
    private var pointerArea: NSTrackingArea?
    private var activationObserver: NSObjectProtocol?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerArea { removeTrackingArea(pointerArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .inVisibleRect, .activeInKeyWindow], owner: self)
        addTrackingArea(area); pointerArea = area
    }
    override func mouseEntered(with event: NSEvent) { onPointerPresence(true) }
    override func mouseExited(with event: NSEvent) { onPointerPresence(false) }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = window.map { window in
            NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onPointerPresence(false) }
            }
        }
    }
    deinit { if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) } }
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
