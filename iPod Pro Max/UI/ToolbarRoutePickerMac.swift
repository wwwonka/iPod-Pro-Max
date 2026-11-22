#if canImport(AppKitBackend)
import AppKit
import AVKit

/// Native route picker on the same 39-by-26 interaction plate as Up Next.
@MainActor final class ToolbarRouteControl: NSView, @preconcurrency AVRoutePickerViewDelegate {
    let picker = ToolbarRoutePicker()
    private let plate = ToolbarPlaybackButton()
    private var routeObservation: NSKeyValueObservation?
    var player: AVPlayer? {
        didSet {
            picker.player = player
            routeObservation = player?.observe(\.isExternalPlaybackActive, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor in self?.plate.usesAccentTint = self?.player?.isExternalPlaybackActive == true }
            }
        }
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        plate.isBordered = false; plate.imageScaling = .scaleNone
        plate.setSymbol("airplay.audio", size: 14, animated: false)
        plate.target = self; plate.action = #selector(openRoutes)
        plate.setAccessibilityLabel("AirPlay"); plate.toolTip = "AirPlay"
        picker.isRoutePickerButtonBordered = false; picker.rendersNativeGlyph = false; picker.delegate = self
        picker.setAccessibilityHidden(true)
        // AVKit owns its popover. The visible plate uses precisely the queue's
        // SF Symbol sizing, hover, press, and inactive treatment.
        addSubview(picker); addSubview(plate)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); plate.frame = bounds; picker.frame = bounds }
    private func nativeButton(in view: NSView) -> NSButton? {
        if let result = view as? NSButton { return result }
        return view.subviews.lazy.compactMap { self.nativeButton(in: $0) }.first
    }
    func checkNativeControl() {
        precondition(nativeButton(in: picker) != nil, "AirPlay plate forwards to the real AVKit button")
        layoutSubtreeIfNeeded()
        precondition(plate.frame == bounds && plate.symbolName == "airplay.audio")
    }
    @objc private func openRoutes() { nativeButton(in: picker)?.performClick(nil) }
    func routePickerViewWillBeginPresentingRoutes(_ routePickerView: AVRoutePickerView) { plate.isLatched = true }
    func routePickerViewDidEndPresentingRoutes(_ routePickerView: AVRoutePickerView) { plate.isLatched = false }
}

/// Keep AVKit's route UI and use its public per-state colors for native dimming.
@MainActor final class ToolbarRoutePicker: AVRoutePickerView {
    private var observers: [NSObjectProtocol] = []
    var rendersNativeGlyph = true { didSet { updateTint() } }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
        if window != nil {
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
        if !rendersNativeGlyph {
            for state: AVRoutePickerView.ButtonState in [.normal, .normalHighlighted, .active, .activeHighlighted] { setRoutePickerButtonColor(.clear, for: state) }
            return
        }
        setRoutePickerButtonColor(active ? .secondaryLabelColor : .labelColor, for: .normal)
        setRoutePickerButtonColor(active ? .white : .labelColor, for: .normalHighlighted)
        setRoutePickerButtonColor(active ? .controlAccentColor : .labelColor, for: .active)
        setRoutePickerButtonColor(active ? .white : .labelColor, for: .activeHighlighted)
        alphaValue = active ? 1 : 0.3
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
}
#endif
