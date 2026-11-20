#if canImport(AppKitBackend)
import AppKit
import AVKit

/// Native route picker on the same 39-by-26 interaction plate as Up Next.
@MainActor final class ToolbarRouteControl: NSView {
    let picker = ToolbarRoutePicker()
    private let plate = ToolbarPlaybackButton()
    override init(frame: NSRect) {
        super.init(frame: frame)
        plate.isBordered = false; plate.title = ""; plate.target = self; plate.action = #selector(openRoutes)
        plate.setAccessibilityElement(false); plate.toolTip = "AirPlay"
        picker.isRoutePickerButtonBordered = false
        addSubview(plate); addSubview(picker)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout(); plate.frame = bounds
        picker.frame = NSRect(x: (bounds.width - 20) / 2, y: (bounds.height - 20) / 2, width: 20, height: 20)
        picker.setBoundsSize(NSSize(width: 24, height: 24))
    }
    private func nativeButton(in view: NSView) -> NSButton? {
        if let result = view as? NSButton { return result }
        return view.subviews.lazy.compactMap { self.nativeButton(in: $0) }.first
    }
    func checkNativeControl() { precondition(nativeButton(in: picker) != nil, "AirPlay plate forwards to the real AVKit button") }
    @objc private func openRoutes() { nativeButton(in: picker)?.performClick(nil) }

}

/// Keep AVKit's route UI and use its public per-state colors for native dimming.
@MainActor final class ToolbarRoutePicker: AVRoutePickerView {
    private var observers: [NSObjectProtocol] = []
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
        if let window {
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateTint() }
                })
            }
            for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateTint() }
                })
            }
        }
        updateTint()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateTint() }
    private func updateTint() {
        let active = playerControlWindow(for: self)?.isKeyWindow == true && NSApp.isActive
        setRoutePickerButtonColor(active ? .secondaryLabelColor : .labelColor, for: .normal)
        setRoutePickerButtonColor(active ? .white : .labelColor, for: .normalHighlighted)
        setRoutePickerButtonColor(active ? .controlAccentColor : .labelColor, for: .active)
        setRoutePickerButtonColor(active ? .white : .labelColor, for: .activeHighlighted)
        alphaValue = active ? 1 : 0.3
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
}
#endif
