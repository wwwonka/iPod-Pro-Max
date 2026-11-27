#if canImport(AppKitBackend)
import AppKit
import AVKit
import SwiftCrossUI
import iPodKit

@MainActor final class ToolbarControlGroup: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { superview?.mouseDown(with: event) }
    func centerControls() {
        for control in subviews {
            control.setFrameOrigin(NSPoint(x: control.frame.minX, y: (bounds.height - control.frame.height) / 2))
        }
    }
    override func layout() { super.layout(); centerControls() }
    override func resizeSubviews(withOldSize oldSize: NSSize) { super.resizeSubviews(withOldSize: oldSize); centerControls() }
}

/// All player controls stay in the primary content window, including full screen.
@MainActor func playerControlWindow(for view: NSView) -> NSWindow? { view.window }

/// Native toolbar drawing only; playback and session volume belong to the shared controller.
@MainActor final class ToolbarPlayerMac: NSObject, NSPopoverDelegate {
    let transport = ToolbarControlGroup(frame: NSRect(x: 0, y: 0, width: 90, height: 32))
    let volumeView = ToolbarControlGroup(frame: NSRect(x: 0, y: 0, width: 100, height: 32))
    let route = ToolbarRouteControl(frame: NSRect(x: 0, y: 0, width: 39, height: 26))
    let lcd = PlayerLCD(frame: NSRect(x: 0, y: 0, width: 280, height: 44))
    var selectionRows: [TrackRow] = [] { didSet { refresh() } }
    var selectedIDs: [String] = [] { didSet { refresh() } }
    var canPlaySelection: Bool { selection != nil }
    var onStart: ((TrackRow, [TrackRow]) -> Void)?
    private let controller: PlaybackController
    private let previous = HoldTransportButton()
    private let play = ToolbarPlaybackButton()
    private let next = HoldTransportButton()
    private let mute = ToolbarPlaybackButton()
    private let slider = PlayerVolumeSlider(value: 0.8, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let popover = NSPopover()
    private var subscription: SwiftCrossUI.Cancellable?
    private var keyMonitor: Any?
    private var speakerLevel = -1
    private var headerHovered = false
    private var optionHeld = false
    private var lastShowsStop = false
    private var lastAnimationNonce = 0
    private var pendingTransportAnimation: (trackID: String?, playing: Bool)?
    /// The play button's state and action (shared rules).
    private var transportState: PlayerHeaderRules.Transport {
        .init(hasTrack: controller.track != nil, playing: controller.playing, hasSelection: selection != nil, optionHovered: headerHovered && optionHeld)
    }
    private var showsStop: Bool { transportState.stopArmed }
    var trailingControlsWidth: CGFloat = 194
    static let maximumVolumeSliderWidth: CGFloat = 117
    private(set) var volumeSliderWidth: CGFloat = maximumVolumeSliderWidth
    private var compact = false
    private(set) var fullScreenLayout = false
    private(set) var trafficLightsRevealed = false
    private(set) var transportLeadingSpace: CGFloat = 0
    private(set) var volumeTargetGap: CGFloat = 28
    private var selection: TrackRow? { selectionRows.first { selectedIDs.contains($0.id) && $0.path != nil } }

    init(controller: PlaybackController) {
        self.controller = controller
        super.init()
        transport.identifier = NSUserInterfaceItemIdentifier("playerTransport")
        transport.wantsLayer = true; transport.layer?.masksToBounds = false
        volumeView.identifier = NSUserInterfaceItemIdentifier("playerVolume")
        volumeView.wantsLayer = true; volumeView.clipsToBounds = false
        lcd.identifier = NSUserInterfaceItemIdentifier("playerLCD")
        slider.controlSize = .small
        for (button, symbol, label, action, x) in [
            (previous as NSButton, "backward.fill", "Previous", #selector(goPrevious), CGFloat(0)),
            (play, "play.fill", "Play", #selector(activateTransport), CGFloat(27)),
            (next as NSButton, "forward.fill", "Next", #selector(goNext), CGFloat(54))] {
            configure(button, symbol: symbol, label: label, action: action)
            button.toolTip = nil
            button.frame = NSRect(x: x, y: 2, width: 28, height: 28)
            transport.addSubview(button)
        }
        previous.onSeek = { [weak self] in guard let self else { return }; self.controller.seek(self.controller.position - 5) }
        next.onSeek = { [weak self] in guard let self else { return }; self.controller.seek(self.controller.position + 5) }
        for button in [previous, play, next] {
            (button.cell as? NSButtonCell)?.imageDimsWhenDisabled = false
            button.animatesPress = true; button.usesElevation = true
            (button.cell as? NSButtonCell)?.highlightsBy = []
        }
        play.symbolTransition = .pinned
        play.drawsSymbolTransition = true
        configure(mute, symbol: "speaker.wave.2.fill", label: "Mute", action: #selector(volumeButton))
        mute.symbolTransition = .crossfade; mute.drawsSymbolTransition = true
        mute.glyphOnlyHover = true
        mute.frame = NSRect(x: 0, y: 0, width: 28, height: 32)
        volumeView.addSubview(mute)
        slider.target = self; slider.action = #selector(changeVolume)
        slider.isContinuous = true; slider.setAccessibilityLabel("App volume")
        volumeView.addSubview(slider)
        let content = NSViewController()
        content.view = NSView(frame: NSRect(x: 0, y: 0, width: 112, height: 40))
        popover.contentViewController = content; popover.behavior = .transient; popover.delegate = self
        subscription = controller.didChange.observe { [weak self] in self?.refresh() }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self else { return false }
                if event.type == .flagsChanged {
                    self.optionHeld = event.modifierFlags.contains(.option)
                    self.refresh()
                    return false
                }
                guard event.window === self.transport.window, event.keyCode == 49, !event.isARepeat,
                      event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                      !(event.window?.firstResponder is NSTextView), !(event.window?.firstResponder is NSTextField),
                      self.controller.track != nil || self.selection != nil else { return false }
                self.toggleWithSymbolAnimation(); return true
            }
            return handled ? nil : event
        }
        transport.centerControls(); volumeView.centerControls()
        lastAnimationNonce = controller.transportAnimationNonce
        refresh(); updateWidth()
    }
    deinit { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) } }
    func checkInteractions() {
        precondition(!play.isEnabled && !previous.isEnabled && !next.isEnabled)
        let row = TrackRow(id: "toolbar-check", title: "Toolbar", artist: "", album: "", number: "", year: "", duration: "", path: "/missing")
        selectionRows = [row]; selectedIDs = [row.id]
        precondition(play.isEnabled && play.matchesDisabledTint && play.contentTintColor == previous.contentTintColor)
        let beforeClick = play.animatedSymbolChanges
        play.performClick(nil)
        refresh()
        precondition(play.animatedSymbolChanges == beforeClick + 1, "Only a transport click requests the SF transition")
        precondition(controller.playing && previous.isEnabled && next.isEnabled)
        play.performClick(nil)
        precondition(!controller.playing)
        let beforeSpace = play.animatedSymbolChanges
        toggleWithSymbolAnimation(); toggleWithSymbolAnimation()
        precondition(play.animatedSymbolChanges == beforeSpace + 2, "Space shares the explicit Play/Pause transition")
        let afterClicks = play.animatedSymbolChanges
        controller.toggle(); controller.toggle(); refresh()
        precondition(play.animatedSymbolChanges == afterClicks, "External playback updates must never animate the transport symbol")
        let changedTrack = TrackRow(id: "toolbar-check-next", title: "Next", artist: "", album: "", number: "", year: "", duration: "", path: "/missing-next")
        controller.start(changedTrack, in: [row, changedTrack]); refresh()
        precondition(play.animatedSymbolChanges == afterClicks, "Changing tracks must not animate Pause")
        controller.setPlaying(false)
        setHeaderHovered(true, modifiers: [.option])
        precondition(play.symbolName == "stop.fill")
        setHeaderHovered(false, modifiers: [.option])
        precondition(play.symbolName == "play.fill")
        setHeaderHovered(true, modifiers: [.option]); play.performClick(nil)
        precondition(controller.track == nil && !controller.playing, "Option-click stops and unloads playback")
        setHeaderHovered(false, modifiers: [])
        precondition([previous, play, next].allSatisfy { $0.toolTip == nil })
        controller.setVolume(0.42); mute.performClick(nil)
        precondition(controller.volume == 0)
        mute.performClick(nil); precondition(controller.volume == 0.42)
        controller.close(); refresh()
        precondition(!previous.isEnabled && !next.isEnabled)
        PlayerLCDContent().checkScrollRouting()
        log("PASS: toolbar selection playback, transport state and mute restore")
    }
    private func configure(_ button: NSButton, symbol: String, label: String, action: Selector) {
        button.bezelStyle = .texturedRounded; button.isBordered = false
        button.controlSize = .small; button.imageScaling = .scaleNone
        if let button = button as? ToolbarPlaybackButton { button.setSymbol(symbol, size: button === play ? 20 : button === mute ? 10 : 13) }
        else { button.image = systemSymbol(symbol, pointSize: 13) }
        button.target = self; button.action = action; button.toolTip = label; button.setAccessibilityLabel(label)
    }
    func updateWidth() {
        let windowWidth = playerControlWindow(for: transport)?.frame.width ?? 1240
        transportLeadingSpace = fullScreenLayout ? 0 : min(8, max(0, (windowWidth - 900) / 340 * 8))
        for (index, button) in transport.subviews.enumerated() {
            button.setFrameOrigin(NSPoint(x: transportLeadingSpace + CGFloat(index) * 27, y: button.frame.minY))
        }
        let transportWidth = 96 + transportLeadingSpace
        transport.setFrameSize(NSSize(width: transportWidth, height: transport.frame.height))
        transport.centerControls()
    }
    func setFullScreenLayout(_ enabled: Bool, animated: Bool = true) {
        guard fullScreenLayout != enabled else { return }
        animateTransportPlacement(duration: animated ? 0.25 : 0, timing: .easeInEaseOut) { self.fullScreenLayout = enabled; if !enabled { self.trafficLightsRevealed = false } }
    }
    func setTrafficLightsRevealed(_ revealed: Bool) {
        guard trafficLightsRevealed != revealed else { return }
        animateTransportPlacement(duration: 0.14, timing: .easeOut) { self.trafficLightsRevealed = revealed }
    }
    private func animateTransportPlacement(duration: TimeInterval, timing: CAMediaTimingFunctionName, _ change: () -> Void) {
        let controls = [transport, volumeView]
        let origins = controls.map { $0.frame.minX + ($0.layer?.presentation()?.transform.m41 ?? 0) }
        let oldTransportInset = transport.subviews.first?.frame.minX ?? 0
        change()
        if let header = transport.superview { layout(in: header) }
        let transportInset = transport.subviews.first?.frame.minX ?? 0
        for (index, view) in controls.enumerated() {
            view.layer?.removeAnimation(forKey: "fullScreenSpacing")
            let insetDelta = view === transport ? oldTransportInset - transportInset : 0
            let offset = origins[index] - view.frame.minX + insetDelta
            guard duration > 0, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, abs(offset) > 0.5 else { continue }
            let movement = CABasicAnimation(keyPath: "transform.translation.x")
            movement.fromValue = offset; movement.toValue = 0; movement.duration = duration
            movement.timingFunction = CAMediaTimingFunction(name: timing)
            view.layer?.add(movement, forKey: "fullScreenSpacing")
        }
    }
    /// Geometry is owned by the content header; AppKit never reparents these views.
    func layout(in header: NSView) {
        updateWidth()
        transport.frame.origin = NSPoint(x: fullScreenLayout ? (trafficLightsRevealed ? 82 : CGFloat(mediaRailWidth) + 8) : 74, y: 6)
        let gap = (fullScreenLayout ? 18 : trafficToBackGap(in: header)) + 3
        volumeTargetGap = gap
        let nextInk = next.cell?.imageRect(forBounds: next.bounds) ?? next.bounds
        let nextRight = next.convert(nextInk, to: header).maxX
        let muteInk = mute.cell?.imageRect(forBounds: mute.bounds) ?? mute.bounds
        volumeView.frame.origin = NSPoint(x: nextRight + gap - muteInk.minX, y: 6)
        // Share the available width with the LCD, rather than dropping the slider
        // at a fixed window-width threshold. Reserve the actual search control.
        let sliderX: CGFloat = 18
        let budget = header.bounds.width - trailingControlsWidth - 47 - 59 - volumeView.frame.minX - sliderX
        compact = budget < 280 + 44
        // Native NSSliderCell rounds its travel metrics. Integral point widths
        // keep the drawn endpoints and native drag fractions identical.
        volumeSliderWidth = compact ? 0 : floor(min(Self.maximumVolumeSliderWidth, max(44, Self.maximumVolumeSliderWidth - max(0, 460 + Self.maximumVolumeSliderWidth - budget) * 0.4)))
        volumeView.setFrameSize(NSSize(width: sliderX + volumeSliderWidth, height: 32))
        if !popover.isShown {
            if compact { slider.removeFromSuperview() }
            else {
                if slider.superview !== volumeView { slider.removeFromSuperview(); volumeView.addSubview(slider) }
                slider.frame = NSRect(x: sliderX, y: 6, width: volumeSliderWidth, height: 20)
            }
        }
        mute.customTrackingRect = compact ? nil : NSRect(x: 0, y: 4, width: 17.5, height: 24)
        volumeView.centerControls()
        let lcdWidth = min(460, max(280, budget - volumeSliderWidth))
        let lcdX = max((header.bounds.width - lcdWidth) / 2, volumeView.frame.maxX + 59)
        lcd.frame = NSRect(x: lcdX, y: 3, width: lcdWidth, height: 41)
        route.frame = NSRect(x: lcdX - 47, y: 9, width: 39, height: 26)
    }
    func nextToVolumeGap(in root: NSView) -> CGFloat {
        let nextInk = next.cell?.imageRect(forBounds: next.bounds) ?? next.bounds
        let muteInk = mute.cell?.imageRect(forBounds: mute.bounds) ?? mute.bounds
        return mute.convert(muteInk, to: root).minX - next.convert(nextInk, to: root).maxX
    }
    func checkVolumeSlider() {
        slider.checkThumbInteraction(); route.checkNativeControl()
        TransportSymbolView.checkSpeakerAlignment()
        if let content = popover.contentViewController?.view, !compact {
            slider.removeFromSuperview(); content.addSubview(slider)
            popoverDidClose(Notification(name: NSPopover.didCloseNotification, object: popover))
            precondition(slider.superview === volumeView, "Closing the volume popover restores the inline slider")
        }
        precondition(mute.symbolTransition == .crossfade, "Speaker waves crossfade on a fixed leading canvas")
    }
    func trafficToBackGap(in root: NSView) -> CGFloat {
        guard playerControlWindow(for: transport) != nil, let zoom = MacChrome.shared.windowControl(.zoomButton) else { return 10 + transportLeadingSpace }
        let symbolRect = previous.cell?.imageRect(forBounds: previous.bounds) ?? previous.bounds
        let backLeft = previous.convert(symbolRect, to: root).minX
        let lightsRight = zoom.convert(zoom.bounds, to: root).maxX
        return max(8, min(80, backLeft - lightsRight))
    }
    func volumeRightEdge(in root: NSView) -> CGFloat {
        if compact { return mute.convert(mute.bounds, to: root).maxX }
        let track = slider.visibleTrackRect
        return slider.convert(track, to: root).maxX
    }
    private func refresh() {
        let routePlayer = (controller.activeEngine as? PlatformAudioEngine)?.routePlayer
        if route.player !== routePlayer { route.player = routePlayer }
        let state = transportState
        previous.isEnabled = state.skipEnabled; next.isEnabled = state.skipEnabled
        play.isEnabled = state.playEnabled
        play.matchesDisabledTint = !state.hasTrack
        if controller.transportAnimationNonce != lastAnimationNonce {
            lastAnimationNonce = controller.transportAnimationNonce
            pendingTransportAnimation = (controller.track?.id, controller.playing)
        }
        let stopChanged = state.stopArmed != lastShowsStop
        lastShowsStop = state.stopArmed
        let playPauseAnimated = !state.stopArmed && pendingTransportAnimation?.trackID == controller.track?.id && pendingTransportAnimation?.playing == controller.playing
        let animate = stopChanged || playPauseAnimated
        play.setSymbol(state.symbol, size: 20, animated: animate)
        play.setAccessibilityLabel(state.label)
        if playPauseAnimated || pendingTransportAnimation?.trackID != controller.track?.id { pendingTransportAnimation = nil }
        if slider.doubleValue != controller.volume { slider.setVolume(controller.volume, animated: true) }
        let level = PlayerHeaderRules.speakerLevel(volume: controller.volume)
        if level != speakerLevel {
            let oldLevel = speakerLevel
            speakerLevel = level
            mute.setSpeakerSymbols(from: oldLevel, to: level, size: 10, animated: oldLevel >= 0 && mute.window != nil)
        }
        mute.setAccessibilityLabel(controller.volume == 0 ? "Unmute" : "Mute")
        // LCD refreshes once through PlayerDisplayController.didChange.
    }
    func setHeaderHovered(_ value: Bool, modifiers: NSEvent.ModifierFlags = NSEvent.modifierFlags) {
        headerHovered = value; optionHeld = modifiers.contains(.option)
        refresh()
    }
    @objc private func activateTransport() {
        if showsStop { pendingTransportAnimation = nil; controller.close(); return }
        toggleWithSymbolAnimation()
    }
    private func toggleWithSymbolAnimation() {
        pendingTransportAnimation = (controller.track?.id ?? selection?.id, !controller.playing)
        toggle()
    }
    @objc func toggle() {
        switch transportState.action {
        case .toggle, .stop: controller.toggle()
        case .startSelection:
            guard let selection else { return }
            if let onStart { onStart(selection, selectionRows) } else { controller.start(selection, in: selectionRows) }
        case .none: break
        }
    }
    @objc private func goPrevious() { controller.previous() }
    @objc private func goNext() { controller.next() }
    @objc private func changeVolume() { slider.syncTrackingPosition(); controller.setVolume(slider.doubleValue) }
    func popoverDidClose(_ notification: Notification) {
        if let header = transport.superview { layout(in: header) }
    }
    @objc private func volumeButton() {
        controller.toggleMute()
        guard compact, !popover.isShown, let view = popover.contentViewController?.view else { return }
        slider.removeFromSuperview(); view.addSubview(slider)
        slider.frame = NSRect(x: 12, y: 10, width: 88, height: 20)
        popover.show(relativeTo: mute.bounds, of: mute, preferredEdge: .minY)
    }
}

#endif
