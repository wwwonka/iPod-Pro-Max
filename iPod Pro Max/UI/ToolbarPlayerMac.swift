#if canImport(AppKitBackend)
import AppKit
import AVKit
import SwiftCrossUI

@MainActor final class ToolbarControlGroup: NSView {
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
@MainActor final class ToolbarPlayerMac: NSObject {
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
    private var speakerImages: [Int: NSImage] = [:]
    private var speakerLevel = -1
    var trailingControlsWidth: CGFloat = 194
    private(set) var volumeSliderWidth: CGFloat = 132
    private var compact = false
    private(set) var fullScreenLayout = false
    private(set) var trafficLightsRevealed = false
    private(set) var transportLeadingSpace: CGFloat = 0
    private(set) var volumeTargetGap: CGFloat = 28
    private var selection: TrackRow? { selectionRows.first { selectedIDs.contains($0.id) && $0.path != nil } }

    init(controller: PlaybackController = .shared) {
        self.controller = controller
        super.init()
        transport.identifier = NSUserInterfaceItemIdentifier("playerTransport")
        transport.wantsLayer = true; transport.layer?.masksToBounds = false
        volumeView.identifier = NSUserInterfaceItemIdentifier("playerVolume")
        volumeView.clipsToBounds = false
        lcd.identifier = NSUserInterfaceItemIdentifier("playerLCD")
        slider.controlSize = .small
        for (button, symbol, label, action, x) in [
            (previous as NSButton, "backward.fill", "Previous", #selector(goPrevious), CGFloat(0)),
            (play, "play.fill", "Play", #selector(toggle), CGFloat(30)),
            (next as NSButton, "forward.fill", "Next", #selector(goNext), CGFloat(60))] {
            configure(button, symbol: symbol, label: label, action: action)
            button.frame = NSRect(x: x, y: 2, width: 28, height: 28)
            transport.addSubview(button)
        }
        previous.onSeek = { [weak self] in guard let self else { return }; self.controller.seek(self.controller.position - 5) }
        next.onSeek = { [weak self] in guard let self else { return }; self.controller.seek(self.controller.position + 5) }
        for button in [previous, play, next] {
            button.animatesPress = true; button.usesElevation = true
            (button.cell as? NSButtonCell)?.highlightsBy = []
        }
        play.drawsSymbolTransition = true
        configure(mute, symbol: "speaker.wave.2.fill", label: "Mute", action: #selector(volumeButton))
        mute.frame = NSRect(x: 0, y: 0, width: 28, height: 32)
        volumeView.addSubview(mute)
        slider.target = self; slider.action = #selector(changeVolume)
        slider.isContinuous = true; slider.setAccessibilityLabel("App volume")
        volumeView.addSubview(slider)
        let content = NSViewController()
        content.view = NSView(frame: NSRect(x: 0, y: 0, width: 160, height: 40))
        popover.contentViewController = content; popover.behavior = .transient
        subscription = controller.didChange.observe { [weak self] in self?.refresh() }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, (event.window === self.transport.window || event.window === playerControlWindow(for: self.transport)),
                      event.keyCode == 49, !event.isARepeat,
                      event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                      !(event.window?.firstResponder is NSTextView), !(event.window?.firstResponder is NSTextField),
                      self.controller.track != nil || self.selection != nil else { return event }
                self.toggle(); return nil
            }
        }
        transport.centerControls(); volumeView.centerControls()
        refresh(); updateWidth()
    }
    func checkInteractions() {
        precondition(!play.isEnabled && !previous.isEnabled && !next.isEnabled)
        let row = TrackRow(id: "toolbar-check", title: "Toolbar", artist: "", album: "", number: "", year: "", duration: "", path: "/missing")
        selectionRows = [row]; selectedIDs = [row.id]
        precondition(play.isEnabled)
        play.performClick(nil)
        refresh()
        precondition(controller.playing && previous.isEnabled && next.isEnabled)
        play.performClick(nil)
        precondition(!controller.playing)
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
        if let button = button as? ToolbarPlaybackButton { button.setSymbol(symbol, size: button === play ? 19 : 13) }
        else { button.image = systemSymbol(symbol, pointSize: 13) }
        button.target = self; button.action = action; button.toolTip = label; button.setAccessibilityLabel(label)
    }
    func updateWidth() {
        let windowWidth = playerControlWindow(for: transport)?.frame.width ?? 1240
        transportLeadingSpace = fullScreenLayout ? 0 : min(8, max(0, (windowWidth - 900) / 340 * 8))
        for (index, button) in transport.subviews.enumerated() {
            button.setFrameOrigin(NSPoint(x: transportLeadingSpace + CGFloat(index) * 30, y: button.frame.minY))
        }
        let transportWidth = 102 + transportLeadingSpace
        transport.setFrameSize(NSSize(width: transportWidth, height: transport.frame.height))
        transport.centerControls()
    }
    func setFullScreenLayout(_ enabled: Bool) {
        guard fullScreenLayout != enabled else { return }
        animateTransportPlacement { self.fullScreenLayout = enabled; if !enabled { self.trafficLightsRevealed = false } }
    }
    func setTrafficLightsRevealed(_ revealed: Bool) {
        guard trafficLightsRevealed != revealed else { return }
        animateTransportPlacement { self.trafficLightsRevealed = revealed }
    }
    private func animateTransportPlacement(_ change: () -> Void) {
        let presentationOffset = transport.layer?.presentation()?.transform.m41 ?? 0
        let oldX = transport.frame.minX + (transport.subviews.first?.frame.minX ?? 0) + presentationOffset
        change()
        if let header = transport.superview { layout(in: header) }
        let newX = transport.frame.minX + (transport.subviews.first?.frame.minX ?? 0)
        transport.layer?.removeAnimation(forKey: "fullScreenSpacing")
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, abs(oldX - newX) > 0.5 else { return }
        let movement = CABasicAnimation(keyPath: "transform.translation.x")
        movement.fromValue = oldX - newX; movement.toValue = 0; movement.duration = 0.25
        movement.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        transport.layer?.add(movement, forKey: "fullScreenSpacing")
    }
    /// Geometry is owned by the content header; AppKit never reparents these views.
    func layout(in header: NSView) {
        updateWidth()
        transport.frame.origin = NSPoint(x: fullScreenLayout ? (trafficLightsRevealed ? 82 : CGFloat(mediaRailWidth) + 12) : 74, y: 6)
        let gap = fullScreenLayout ? 18 : trafficToBackGap(in: header)
        volumeTargetGap = gap
        let nextInk = next.cell?.imageRect(forBounds: next.bounds) ?? next.bounds
        let nextRight = next.convert(nextInk, to: header).maxX
        let muteInk = mute.cell?.imageRect(forBounds: mute.bounds) ?? mute.bounds
        volumeView.frame.origin = NSPoint(x: nextRight + gap - muteInk.minX, y: 6)
        // Share the available width with the LCD, rather than dropping the slider
        // at a fixed window-width threshold. Reserve the actual search control.
        let budget = header.bounds.width - trailingControlsWidth - 47 - 59 - volumeView.frame.minX - 28
        compact = budget < 280 + 52
        volumeSliderWidth = compact ? 0 : min(132, max(52, 132 - max(0, 460 + 132 - budget) * 0.4))
        volumeView.setFrameSize(NSSize(width: 28 + volumeSliderWidth, height: 32))
        if !popover.isShown {
            if compact { slider.removeFromSuperview() }
            else {
                if slider.superview !== volumeView { slider.removeFromSuperview(); volumeView.addSubview(slider) }
                slider.frame = NSRect(x: 28, y: 6, width: volumeSliderWidth, height: 20)
            }
        }
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
        for level in 0...3 { precondition(speakerImage(level).size == NSSize(width: 20, height: 16), "Speaker horn canvas stays fixed at all volumes") }
    }
    func trafficToBackGap(in root: NSView) -> CGFloat {
        guard let window = playerControlWindow(for: transport), let zoom = window.standardWindowButton(.zoomButton) else { return 10 + transportLeadingSpace }
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
        route.picker.player = (controller.activeEngine as? PlatformAudioEngine)?.routePlayer
        previous.isEnabled = controller.track != nil; next.isEnabled = controller.track != nil
        play.isEnabled = controller.track != nil || selection != nil
        play.setSymbol(controller.playing ? "pause.fill" : "play.fill", size: 19)
        play.setAccessibilityLabel(controller.playing ? "Pause" : "Play")
        slider.doubleValue = controller.volume
        let level = controller.volume == 0 ? 0 : controller.volume < 0.33 ? 1 : controller.volume < 0.67 ? 2 : 3
        if level != speakerLevel { speakerLevel = level; mute.image = speakerImage(level) }
        mute.setAccessibilityLabel(controller.volume == 0 ? "Unmute" : "Mute")
        lcd.refresh()
    }
    private func speakerImage(_ level: Int) -> NSImage {
        if let cached = speakerImages[level] { return cached }
        let horn = systemSymbol("speaker.fill", pointSize: 12)
        let result = NSImage(size: NSSize(width: 20, height: 16), flipped: false) { _ in
            horn?.draw(in: NSRect(x: 0, y: 3, width: 9, height: 10))
            NSColor.black.setStroke()
            if level == 0 {
                let cross = NSBezierPath(); cross.lineWidth = 1.1; cross.lineCapStyle = .round
                cross.move(to: NSPoint(x: 12, y: 6)); cross.line(to: NSPoint(x: 16, y: 10))
                cross.move(to: NSPoint(x: 12, y: 10)); cross.line(to: NSPoint(x: 16, y: 6)); cross.stroke()
            } else {
                for wave in 0..<level {
                    let path = NSBezierPath(); path.lineWidth = 1.15; path.lineCapStyle = .round
                    path.appendArc(withCenter: NSPoint(x: 7, y: 8), radius: CGFloat(4 + wave * 3), startAngle: -42, endAngle: 42)
                    path.stroke()
                }
            }
            return true
        }
        result.isTemplate = true; speakerImages[level] = result; return result
    }
    @objc func toggle() {
        if controller.track != nil { controller.toggle() }
        else if let selection { if let onStart { onStart(selection, selectionRows) } else { controller.start(selection, in: selectionRows) } }
    }
    @objc private func goPrevious() { controller.previous() }
    @objc private func goNext() { controller.next() }
    @objc private func changeVolume() { controller.setVolume(slider.doubleValue) }
    @objc private func volumeButton() {
        controller.toggleMute()
        guard compact, !popover.isShown, let view = popover.contentViewController?.view else { return }
        slider.removeFromSuperview(); view.addSubview(slider)
        slider.frame = NSRect(x: 12, y: 10, width: 136, height: 20)
        popover.show(relativeTo: mute.bounds, of: mute, preferredEdge: .minY)
    }
}

@MainActor final class PlayerLCD: NSVisualEffectView {
    private let content = PlayerLCDContent()
    private let innerShade = CAGradientLayer()
    private let leftShade = CAGradientLayer()
    private let rightShade = CAGradientLayer()
    private let lowerGlow = CAGradientLayer()
    private let rim = CAShapeLayer()
    private let bottomLight = CAShapeLayer()
    // Toolbar viewers normally impose an 8 pt vertical inset on custom views.
    // This glass insert fills its viewer, while the other toolbar controls keep that inset.
    override var frame: NSRect {
        get { super.frame }
        set {
            var fitted = newValue
            if let parent = superview, parent.bounds.height > 0 {
                fitted.origin.y = 3
                fitted.size.height = max(0, parent.bounds.height - 3)
            }
            super.frame = fitted
        }
    }
    override var mouseDownCanMoveWindow: Bool { false }
    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .underWindowBackground; blendingMode = .behindWindow; state = .active
        wantsLayer = true
        layer?.cornerRadius = 3
        layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        layer?.masksToBounds = true
        // Shade falls inside the glass; no outer shadow or bright upper bevel.
        innerShade.colors = [NSColor.black.withAlphaComponent(0.035).cgColor,
                             NSColor.black.withAlphaComponent(0.07).cgColor,
                             NSColor.black.withAlphaComponent(0.22).cgColor]
        innerShade.locations = [0, 0.85, 1]
        innerShade.startPoint = CGPoint(x: 0.5, y: 0)
        innerShade.endPoint = CGPoint(x: 0.5, y: 1)
        for shade in [leftShade, rightShade] {
            shade.colors = [NSColor.black.withAlphaComponent(0.14).cgColor, NSColor.clear.cgColor]
            shade.startPoint = CGPoint(x: 0, y: 0.5); shade.endPoint = CGPoint(x: 1, y: 0.5)
        }
        rightShade.startPoint = CGPoint(x: 1, y: 0.5); rightShade.endPoint = CGPoint(x: 0, y: 0.5)
        lowerGlow.colors = [NSColor.white.withAlphaComponent(0.075).cgColor, NSColor.clear.cgColor]
        lowerGlow.startPoint = CGPoint(x: 0.5, y: 0); lowerGlow.endPoint = CGPoint(x: 0.5, y: 1)
        rim.fillColor = nil; rim.strokeColor = NSColor.black.withAlphaComponent(0.16).cgColor
        rim.lineWidth = 0.5
        bottomLight.fillColor = nil
        bottomLight.strokeColor = NSColor.white.withAlphaComponent(0.15).cgColor
        bottomLight.lineWidth = 0.5
        for decoration in [innerShade, leftShade, rightShade, lowerGlow, rim, bottomLight] { layer?.addSublayer(decoration) }
        addSubview(content)
    }
    func refresh() { content.refresh() }
    func checkComposition() { content.checkComposition() }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        innerShade.frame = bounds
        leftShade.frame = CGRect(x: 0, y: 0, width: 8, height: bounds.height)
        rightShade.frame = CGRect(x: bounds.width - 8, y: 0, width: 8, height: bounds.height)
        lowerGlow.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 6)
        rim.frame = bounds; bottomLight.frame = bounds
        let edges = CGMutablePath()
        edges.move(to: CGPoint(x: 0.25, y: bounds.height))
        edges.addLine(to: CGPoint(x: 0.25, y: 3))
        edges.move(to: CGPoint(x: bounds.width - 0.25, y: bounds.height))
        edges.addLine(to: CGPoint(x: bounds.width - 0.25, y: 3))
        rim.path = edges
        let light = CGMutablePath()
        light.move(to: CGPoint(x: 3, y: 0.25))
        light.addLine(to: CGPoint(x: bounds.width - 3, y: 0.25))
        bottomLight.path = light
        CATransaction.commit()
        content.frame = bounds
        content.needsLayout = true

    }
}

@MainActor private final class PlayerVolumeCell: NSSliderCell {
    static let thumbDiameter: CGFloat = 7
    override var knobThickness: CGFloat { Self.thumbDiameter }
    var visibleTrackRect: NSRect {
        let bounds = controlView?.bounds ?? .zero
        return NSRect(x: bounds.minX + Self.thumbDiameter / 2, y: bounds.midY - 2,
                      width: max(0, bounds.width - Self.thumbDiameter), height: 4)
    }
    override func knobRect(flipped: Bool) -> NSRect {
        let bar = visibleTrackRect
        let fraction = CGFloat(min(1, max(0, (doubleValue - minValue) / max(0.001, maxValue - minValue))))
        return NSRect(x: bar.minX + bar.width * fraction - Self.thumbDiameter / 2,
                      y: bar.midY - Self.thumbDiameter / 2, width: Self.thumbDiameter, height: Self.thumbDiameter)
    }
    override func drawKnob(_ knobRect: NSRect) {} // Opaque layer, native cell tracking.
    override func drawBar(inside rect: NSRect, flipped: Bool) {
        // Keep barRect native: its metrics also drive AppKit's drag calculation.
        let bar = visibleTrackRect
        let dark = controlView?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        NSColor(white: dark ? 0.06 : 0.55, alpha: dark ? 0.8 : 0.3).setFill()
        NSBezierPath(roundedRect: bar, xRadius: 2, yRadius: 2).fill()

    }
}

@MainActor final class PlayerVolumeSlider: NSSlider {
    private let thumb = CALayer()
    private let volumeFill = CALayer()
    private var animateNextValueChange = false
    private var lastDrawnValue = Double.nan
    private var thumbArea: NSTrackingArea?
    private var hoverWork: DispatchWorkItem?
    private var hovering = false
    private var accented = false
    private var pressing = false
    private var targetScale: CGFloat = 1
    private var activationObservers: [NSObjectProtocol] = []
    var visibleTrackRect: NSRect { (cell as? PlayerVolumeCell)?.visibleTrackRect ?? .zero }
    private var thumbHitRect: NSRect { (cell as? NSSliderCell)?.knobRect(flipped: isFlipped).insetBy(dx: -3, dy: -3) ?? .zero }
    override init(frame: NSRect) {
        super.init(frame: frame)
        let volumeCell = PlayerVolumeCell(); volumeCell.minValue = 0; volumeCell.maxValue = 1
        cell = volumeCell; wantsLayer = true; clipsToBounds = false
        layer?.masksToBounds = false
        volumeFill.anchorPoint = CGPoint(x: 0, y: 0.5); volumeFill.cornerRadius = 2
        layer?.addSublayer(volumeFill); layer?.addSublayer(thumb)
        thumb.cornerRadius = PlayerVolumeCell.thumbDiameter / 2
        thumb.opacity = 1
        thumb.shadowColor = NSColor.black.cgColor; thumb.shadowOffset = CGSize(width: 0, height: -1)
        thumb.shadowRadius = 1.5; thumb.borderWidth = 0.5
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) { super.draw(dirtyRect); positionThumb() }
    override func layout() { super.layout(); positionThumb() }
    private func positionThumb() {
        guard let cell = cell as? NSSliderCell else { return }
        let rect = cell.knobRect(flipped: isFlipped)
        let changed = doubleValue != lastDrawnValue
        let animate = changed && animateNextValueChange && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let oldPosition = thumb.presentation()?.position ?? thumb.position
        let oldWidth = volumeFill.presentation()?.bounds.width ?? volumeFill.bounds.width
        let bar = visibleTrackRect
        CATransaction.begin(); CATransaction.setDisableActions(true)
        thumb.bounds = NSRect(x: 0, y: 0, width: PlayerVolumeCell.thumbDiameter, height: PlayerVolumeCell.thumbDiameter)
        thumb.position = NSPoint(x: rect.midX, y: rect.midY)
        thumb.shadowPath = CGPath(ellipseIn: thumb.bounds, transform: nil)
        volumeFill.bounds = NSRect(x: 0, y: 0, width: max(0, rect.midX - bar.minX), height: bar.height)
        volumeFill.position = NSPoint(x: bar.minX, y: bar.midY)
        volumeFill.backgroundColor = NSColor(white: effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 0.7 : 0.46, alpha: 1).cgColor
        CATransaction.commit()
        if changed {
            animateNextValueChange = false; lastDrawnValue = doubleValue
            thumb.removeAnimation(forKey: "volumeClick"); volumeFill.removeAnimation(forKey: "volumeClick")
            if animate {
                let knob = CABasicAnimation(keyPath: "position"); knob.fromValue = NSValue(point: oldPosition); knob.toValue = NSValue(point: thumb.position)
                let fill = CABasicAnimation(keyPath: "bounds.size.width"); fill.fromValue = oldWidth; fill.toValue = volumeFill.bounds.width
                for animation in [knob, fill] { animation.duration = 0.14; animation.timingFunction = CAMediaTimingFunction(name: .easeOut) }
                thumb.add(knob, forKey: "volumeClick"); volumeFill.add(fill, forKey: "volumeClick")
            }
        }
        updateThumbArea()
        if hovering && !pressing, let window, !thumbHitRect.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) { setHovering(false) }
        updateThumb(animated: false)
    }
    private func updateThumb(animated: Bool = true) {
        let active = playerControlWindow(for: self)?.isKeyWindow == true && isEnabled
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let gray: CGFloat = dark ? (active ? 0.85 : 0.64) : (active ? 0.97 : 0.9)
        let base = NSColor(white: gray, alpha: 1)
        let color = active && (accented || pressing) ? (NSColor.controlAccentColor.blended(withFraction: 0.65, of: base) ?? base).withAlphaComponent(1) : base
        let saved = NSAppearance.current; NSAppearance.current = effectiveAppearance
        let target = color.cgColor; NSAppearance.current = saved
        CATransaction.begin(); CATransaction.setDisableActions(true)
        thumb.borderColor = NSColor.white.withAlphaComponent(dark ? 0.28 : 0.8).cgColor
        thumb.shadowOpacity = active ? 0.28 : 0.12
        CATransaction.commit()
        let motion = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if thumb.backgroundColor != target {
            if motion {
                let fade = CABasicAnimation(keyPath: "backgroundColor")
                fade.fromValue = thumb.presentation()?.backgroundColor ?? thumb.backgroundColor; fade.toValue = target
                fade.duration = RailButton.hoverFadeIn; fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                thumb.add(fade, forKey: "hoverTint")
            } else { thumb.removeAnimation(forKey: "hoverTint") }
            CATransaction.begin(); CATransaction.setDisableActions(true); thumb.backgroundColor = target; CATransaction.commit()
        }
        let scale: CGFloat = active ? (pressing ? 1.45 : hovering ? 12 / PlayerVolumeCell.thumbDiameter : 1) : 1
        if scale != targetScale {
            let previous = thumb.presentation()?.transform.m11 ?? thumb.transform.m11
            targetScale = scale
            CATransaction.begin(); CATransaction.setDisableActions(true)
            thumb.transform = CATransform3DMakeScale(scale, scale, 1)
            CATransaction.commit()
            if motion {
                let animation = CABasicAnimation(keyPath: "transform.scale")
                animation.fromValue = previous; animation.toValue = scale
                animation.duration = hovering ? 0.1 : 0.09
                animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
                thumb.add(animation, forKey: "thumbScale")
            } else { thumb.removeAnimation(forKey: "thumbScale") }
        }
    }
    private func updateThumbArea() {
        let rect = thumbHitRect
        guard thumbArea?.rect != rect else { return }
        if let thumbArea { removeTrackingArea(thumbArea) }
        let area = NSTrackingArea(rect: rect, options: [.activeInKeyWindow, .mouseEnteredAndExited, .mouseMoved, .enabledDuringMouseDrag], owner: self)
        thumbArea = area; addTrackingArea(area)
    }
    override func updateTrackingAreas() { super.updateTrackingAreas(); updateThumbArea() }
    private func setHovering(_ value: Bool) {
        guard hovering != value else { return }
        hovering = value; hoverWork?.cancel()
        if value {
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.hovering, playerControlWindow(for: self)?.isKeyWindow == true else { return }
                self.accented = true; self.updateThumb()
            }
            hoverWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + RailButton.hoverDelay, execute: work)
        } else { accented = false }
        updateThumb()
    }
    override func mouseEntered(with event: NSEvent) { setHovering(true) }
    override func mouseMoved(with event: NSEvent) { setHovering(thumbHitRect.contains(convert(event.locationInWindow, from: nil))) }
    override func mouseExited(with event: NSEvent) { setHovering(false) }
    override func mouseDown(with event: NSEvent) {
        animateNextValueChange = !thumbHitRect.contains(convert(event.locationInWindow, from: nil))
        hoverWork?.cancel(); pressing = true; updateThumb()
        super.mouseDown(with: event)
        positionThumb(); animateNextValueChange = false
        pressing = false
        if let window { setHovering(thumbHitRect.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))) }
        updateThumb()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateThumb(animated: false) }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        activationObservers.forEach(NotificationCenter.default.removeObserver); activationObservers.removeAll()
        if window != nil {
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                activationObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        if playerControlWindow(for: self)?.isKeyWindow != true {
                            self.hoverWork?.cancel(); self.hovering = false; self.accented = false; self.pressing = false
                        }
                        self.updateThumb()
                    }
                })
            }
        }
        updateThumb(animated: false)
    }
    override func scrollWheel(with event: NSEvent) {
        doubleValue = min(1, max(0, doubleValue + Double(event.scrollingDeltaY) * 0.01))
        sendAction(action, to: target)
    }
    func checkThumbInteraction() {
        guard let cell = cell as? NSSliderCell else { preconditionFailure("Volume cell missing") }
        let previousValue = doubleValue
        defer { doubleValue = previousValue; setHovering(false); positionThumb() }
        let bar = visibleTrackRect
        for fraction in [0.0, 0.25, 0.5, 0.75, 1] {
            doubleValue = fraction; positionThumb()
            precondition(abs(thumb.position.x - (bar.minX + bar.width * fraction)) < 0.01 && abs(thumb.position.y - bar.midY) < 0.01)
            precondition(thumb.opacity == 1 && thumb.backgroundColor?.alpha == 1, "Volume thumb must occlude the track")
            doubleValue = 0
            let start = NSPoint(x: bar.minX, y: bar.midY), end = NSPoint(x: bar.minX + bar.width * fraction, y: bar.midY)
            _ = cell.startTracking(at: start, in: self)
            _ = cell.continueTracking(last: start, current: end, in: self)
            cell.stopTracking(last: start, current: end, in: self, mouseIsUp: true)
            precondition(abs(doubleValue - fraction) < 0.001, "Native drag and visible track must use the same travel")
        }
        doubleValue = 0; positionThumb()
        animateNextValueChange = true; doubleValue = 1; positionThumb()
        precondition(volumeFill.animation(forKey: "volumeClick")?.duration == 0.14 || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        setHovering(true)
        precondition(abs(targetScale * PlayerVolumeCell.thumbDiameter - 12) < 0.001, "Knob grows from 7 to 12 pt")
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { precondition(thumb.animation(forKey: "thumbScale")?.duration == 0.1) }
        setHovering(false)
        precondition(targetScale == 1 && !accented, "Hover-out restores the size and cancels delayed tint")
        log("PASS: volume endpoints and native quarter-step drags agree; opaque thumb; immediate 100/90 ms reversible hover scale")
    }
    deinit { hoverWork?.cancel(); activationObservers.forEach(NotificationCenter.default.removeObserver) }
}

/// Custom toolbar views do not inherit NSToolbarItem's automatic inactive tint.
/// Follow window activation notifications, keeping the glass independent of control tint.
@MainActor class ToolbarPlaybackButton: NSButton {
    private var activationObservers: [NSObjectProtocol] = []
    private let hoverLayer: CALayer = { let layer = CALayer(); layer.opacity = 0; return layer }()
    private var hoverArea: NSTrackingArea?
    private var hovered = false
    private var pointerInside = false
    private var hoverWork: DispatchWorkItem?
    var isLatched = false { didSet { updateInteraction() } }
    private var pressed = false
    private var currentSymbol = ""
    private lazy var transportSymbol = TransportSymbolView()
    var usesElevation = false { didSet { if usesElevation { (cell as? NSButtonCell)?.highlightsBy = [] } } }
    var usesAccentTint = false
    var usesLightGlyph = false
    var animatesPress = false
    var drawsSymbolTransition = false {
        didSet {
            guard drawsSymbolTransition else { return }
            addSubview(transportSymbol); transportSymbol.frame = bounds
            transportSymbol.setSymbol(currentSymbol, image: image, animated: false)
            image = nil
        }
    }
    func setSymbol(_ name: String, size: Double) {
        guard name != currentSymbol else { return }
        let replacing = !currentSymbol.isEmpty
        currentSymbol = name
        title = ""; imagePosition = .imageOnly
        let symbolImage = systemSymbol(name, pointSize: size)
        if drawsSymbolTransition {
            transportSymbol.setSymbol(name, image: symbolImage, animated: replacing)
            image = nil
        } else { image = symbolImage }
        if replacing, !drawsSymbolTransition, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let fade = CATransition(); fade.type = .fade; fade.duration = 0.18
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer?.add(fade, forKey: "symbolReplace")
        }
    }
    override func layout() {
        super.layout()
        if hoverLayer.superlayer == nil { wantsLayer = true; layer?.insertSublayer(hoverLayer, at: 0) }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if drawsSymbolTransition { transportSymbol.frame = bounds }
        hoverLayer.frame = bounds; hoverLayer.cornerRadius = 6
        hoverLayer.backgroundColor = RailButton.overlay(1).cgColor
        CATransaction.commit()
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) {
        guard isEnabled, playerControlWindow(for: self)?.isKeyWindow == true else { return }
        pointerInside = true; hoverWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.pointerInside, self.isEnabled, playerControlWindow(for: self)?.isKeyWindow == true else { return }
            self.hovered = true; self.updateInteraction()
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + RailButton.hoverDelay, execute: work)
    }
    override func mouseExited(with event: NSEvent) {
        hoverWork?.cancel(); pointerInside = false; hovered = false; updateInteraction()
    }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        pressed = true; updateInteraction()
        defer { pressed = false; updateInteraction() }
        super.mouseDown(with: event)
    }
    static func checkHoverFeedback() async {
        let previous = NSApp.keyWindow
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // Synthetic enter/exit events must not race AppKit's tracking of the
        // real pointer, which remains untouched during this check.
        final class FeedbackProbe: ToolbarPlaybackButton {
            override func updateTrackingAreas() {}
        }
        let button = FeedbackProbe(frame: NSRect(x: 20, y: 20, width: 28, height: 28))
        button.isBordered = false; button.setSymbol("play.fill", size: 19)
        window.contentView?.addSubview(button); window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); previous?.makeKeyAndOrderFront(nil) }
        button.layoutSubtreeIfNeeded()
        // Let AppKit finish its initial tracking-area/key-window notifications
        // before injecting the synthetic hover (without moving the user's pointer).
        try? await Task.sleep(nanoseconds: 150_000_000)
        let event = NSEvent(cgEvent: CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: .zero, mouseButton: .left)!)!
        button.mouseEntered(with: event)
        precondition(button.hoverLayer.opacity == 0)
        try? await Task.sleep(nanoseconds: 200_000_000)
        precondition(button.hoverLayer.opacity == 0, "No immediate hover plate")
        try? await Task.sleep(nanoseconds: 300_000_000)
        precondition(abs(button.hoverLayer.opacity - 0.065) < 0.001, "Delayed native hover plate")
        button.mouseExited(with: event)
        precondition(button.hoverLayer.opacity == 0)
        button.mouseEntered(with: event); button.mouseExited(with: event)
        try? await Task.sleep(nanoseconds: 450_000_000)
        precondition(button.hoverLayer.opacity == 0, "Leaving cancels delayed highlight")
        window.makeKeyAndOrderFront(nil)
        button.usesElevation = true; button.updateInteraction()
        precondition(button.hoverLayer.opacity == 0 && abs((button.layer?.shadowOpacity ?? 0) - 0.4) < 0.001, "Elevation base: key=\(window.isKeyWindow), enabled=\(button.isEnabled), shadow=\(button.layer?.shadowOpacity ?? -1), plate=\(button.hoverLayer.opacity)")
        button.mouseEntered(with: event)
        try? await Task.sleep(nanoseconds: 450_000_000)
        precondition(button.hoverLayer.opacity == 0 && abs((button.layer?.shadowOpacity ?? 0) - 0.78) < 0.001)
        button.animatesPress = true; button.drawsSymbolTransition = true
        button.pressed = true; button.updateInteraction()
        precondition(button.contentTintColor != NSColor.white && (button.cell as? NSButtonCell)?.highlightsBy == [], "Press keeps the transport tint and disables native white highlighting")
        precondition((button.layer?.shadowOpacity ?? 1) < 0.02, "Press flattens the elevated symbol")
        precondition(abs((button.layer?.transform.m11 ?? 0) - 0.86) < 0.001, "Transport shrinks while held")
        button.pressed = false; button.updateInteraction()
        precondition(abs((button.layer?.transform.m11 ?? 0) - 1) < 0.001, "Transport restores on release")
        button.setSymbol("pause.fill", size: 19)
        button.setSymbol("play.fill", size: 19)
        try? await Task.sleep(nanoseconds: 450_000_000)
        precondition(button.transportSymbol.symbol == "play.fill" && button.transportSymbol.hasImage, "Rapid Play/Pause changes must settle on the latest symbol")
        log("PASS: transport uses delayed elevation without a hover plate, flattens on press, and settles on the latest symbol")
        let route = ToolbarRoutePicker(frame: NSRect(x: 55, y: 20, width: 24, height: 24))
        window.contentView?.addSubview(route)
        window.resignKey(); precondition(button.hoverLayer.opacity == 0)
        precondition(abs(route.alphaValue - 0.3) < 0.001, "AirPlay must dim with the inactive window")
        log("PASS: native AirPlay picker dims to the same inactive gray")
        log("PASS: toolbar hover waits 400 ms, uses 6.5% neutral plate, cancels on leave and dims when inactive")
    }
    private func updateInteraction() {
        let active = isEnabled && playerControlWindow(for: self)?.isKeyWindow == true
        let lit = active && (hovered || pressed || isLatched)
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : lit ? RailButton.hoverFadeIn : RailButton.hoverFadeOut
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        CATransaction.begin(); CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        hoverLayer.backgroundColor = (dark ? NSColor.white : NSColor.black).cgColor
        hoverLayer.opacity = usesElevation ? 0 : lit ? (pressed ? 0.13 : 0.065) : 0
        CATransaction.commit()
        contentTintColor = !isEnabled ? .disabledControlTextColor : !active ? NSColor.labelColor.withAlphaComponent(0.3) : (pressed || isLatched) && !usesElevation ? .white : .secondaryLabelColor
        if usesAccentTint && active { contentTintColor = .controlAccentColor }
        if usesLightGlyph && active { contentTintColor = .white }
        if drawsSymbolTransition { transportSymbol.tint = contentTintColor }
        if usesElevation, let layer {
            // Shadow follows the symbol alpha, never a rounded hover plate.
            layer.masksToBounds = false
            let nextOpacity: Float = !active ? 0.12 : pressed ? 0.015 : hovered ? 0.78 : 0.4
            let nextRadius: CGFloat = pressed ? 0.2 : hovered ? 3.6 : 1.7
            let nextOffset = CGSize(width: 0, height: pressed ? 0 : hovered ? -2.5 : -1)
            let oldOpacity = layer.presentation()?.shadowOpacity ?? layer.shadowOpacity
            let oldRadius = layer.presentation()?.shadowRadius ?? layer.shadowRadius
            let oldOffset = layer.presentation()?.shadowOffset ?? layer.shadowOffset
            CATransaction.begin(); CATransaction.setDisableActions(true)
            layer.shadowColor = NSColor.black.cgColor
            layer.shadowOpacity = nextOpacity; layer.shadowRadius = nextRadius; layer.shadowOffset = nextOffset
            CATransaction.commit()
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                for (key, from, to) in [("shadowOpacity", NSNumber(value: oldOpacity), NSNumber(value: nextOpacity)),
                                        ("shadowRadius", NSNumber(value: Double(oldRadius)), NSNumber(value: Double(nextRadius)))] {
                    let animation = CABasicAnimation(keyPath: key); animation.fromValue = from; animation.toValue = to
                    animation.duration = pressed ? 0.06 : 0.12; animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    layer.add(animation, forKey: key)
                }
                let offset = CABasicAnimation(keyPath: "shadowOffset")
                offset.fromValue = NSValue(size: oldOffset); offset.toValue = NSValue(size: nextOffset)
                offset.duration = pressed ? 0.06 : 0.12; layer.add(offset, forKey: "shadowOffset")
            }
        }
        if animatesPress, let layer {
            let scale: CGFloat = active && pressed ? 0.86 : 1
            let pivot = CGPoint(x: bounds.midX - bounds.width * layer.anchorPoint.x, y: bounds.midY - bounds.height * layer.anchorPoint.y)
            let target = CATransform3DMakeAffineTransform(CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: pivot.x * (1 - scale), ty: pivot.y * (1 - scale)))
            if !CATransform3DEqualToTransform(layer.transform, target) {
                let old = layer.presentation()?.transform ?? layer.transform
                CATransaction.begin(); CATransaction.setDisableActions(true); layer.transform = target; CATransaction.commit()
                if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    let animation = CABasicAnimation(keyPath: "transform")
                    animation.fromValue = NSValue(caTransform3D: old); animation.toValue = NSValue(caTransform3D: target)
                    animation.duration = pressed ? 0.06 : 0.10
                    animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    layer.add(animation, forKey: "transportPress")
                }
            }
        }
    }
    override var isEnabled: Bool { didSet { if isEnabled != oldValue { updateTint() } } }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        activationObservers.forEach(NotificationCenter.default.removeObserver)
        activationObservers.removeAll()
        if let window {
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                activationObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateTint() }
                })
            }
        }
        updateTint()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateTint() }
    private func updateTint() {
        if !isEnabled || playerControlWindow(for: self)?.isKeyWindow != true {
            hoverWork?.cancel(); pointerInside = false; hovered = false; pressed = false
        }
        updateInteraction()
    }
    deinit { hoverWork?.cancel(); activationObservers.forEach(NotificationCenter.default.removeObserver) }
}

/// A wait exists only during a mouse press. Releasing outside or deactivating cancels it.
@MainActor final class HoldTransportButton: ToolbarPlaybackButton {
    var onSeek: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        var held = false
        var repeats: Timer?
        let delay = Timer(timeInterval: 0.4, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                held = true
                self?.onSeek?()
                let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, playerControlWindow(for: self)?.isKeyWindow == true else { return }
                        self.onSeek?()
                    }
                }
                repeats = timer
                RunLoop.main.add(timer, forMode: .eventTracking)
            }
        }
        RunLoop.main.add(delay, forMode: .eventTracking)
        let savedAction = action
        action = nil
        super.mouseDown(with: event)
        delay.invalidate(); repeats?.invalidate(); action = savedAction
        if !held, bounds.contains(convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)) {
            sendAction(action, to: target)
        }
    }
}
#endif
