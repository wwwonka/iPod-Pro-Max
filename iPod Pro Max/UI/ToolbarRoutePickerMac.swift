#if canImport(AppKitBackend)
import AppKit
import AVKit

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
