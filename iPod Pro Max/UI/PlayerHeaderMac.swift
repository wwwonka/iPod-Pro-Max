#if canImport(AppKitBackend)
import AppKit

/// A stable content row. Empty space drags the window; child controls keep native tracking.
@MainActor final class PlayerHeaderMac: NSView {
    var onPointerPresence: (Bool) -> Void = { _ in }
    var trafficLights: [NSButton] = []
    var trafficLightsGroupRect: NSRect = .zero {
        didSet { if oldValue != trafficLightsGroupRect { updateTrafficLightTracking() } }
    }
    private var pointerArea: NSTrackingArea?
    private var trafficLightTracking: NSTrackingArea?
    private var trafficLightHovered = false
    private var activationObserver: NSObjectProtocol?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerArea { removeTrackingArea(pointerArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .inVisibleRect, .activeInKeyWindow], owner: self)
        addTrackingArea(area); pointerArea = area
        updateTrafficLightTracking()
    }
    private func updateTrafficLightTracking() {
        if let trafficLightTracking { removeTrackingArea(trafficLightTracking); self.trafficLightTracking = nil }
        guard !trafficLightsGroupRect.isEmpty else {
            setTrafficLightHovered(false)
            return
        }
        let area = NSTrackingArea(rect: trafficLightsGroupRect, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: ["trafficLights": true])
        addTrackingArea(area); trafficLightTracking = area
        if let window {
            let local = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            setTrafficLightHovered(trafficLightsGroupRect.contains(local))
        }
    }
    private func setTrafficLightHovered(_ hovered: Bool) {
        guard trafficLightHovered != hovered else { return }
        trafficLightHovered = hovered
        for button in trafficLights { button.needsDisplay = true }
    }
    @objc func _mouseInGroup(_ widget: Any?) -> Bool { trafficLightHovered }
    override func mouseEntered(with event: NSEvent) {
        if (event.trackingArea?.userInfo as? [String: Bool])?["trafficLights"] == true {
            setTrafficLightHovered(true)
            return
        }
        onPointerPresence(true)
    }
    override func mouseExited(with event: NSEvent) {
        if (event.trackingArea?.userInfo as? [String: Bool])?["trafficLights"] == true {
            setTrafficLightHovered(false)
            return
        }
        onPointerPresence(false)
    }
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
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func shouldDelayWindowOrdering(for event: NSEvent) -> Bool { event.modifierFlags.contains(.command) }
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let allowActivate = !event.modifierFlags.contains(.command)
        if !allowActivate {
            NSApp.preventWindowOrdering()
        } else if !NSApp.isActive || !window.isKeyWindow {
            if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
            if !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }
        }
        guard !window.styleMask.contains(.fullScreen) else { return }
        if event.clickCount == 2 {
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
            case "Minimize": window.performMiniaturize(nil)
            case "None": break
            default: window.performZoom(nil)
            }
        } else {
            window.performDrag(with: event)
        }
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
