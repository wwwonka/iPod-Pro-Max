#if canImport(AppKitBackend)
import AppKit

@MainActor private final class PlayerVolumeCell: NSSliderCell {
    static let thumbDiameter: CGFloat = 7
    static let hoverDiameter: CGFloat = 9
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
        // The inactive channel is a native glass view below the fill layer.

    }
}

@MainActor final class PlayerVolumeSlider: NSSlider {
    private let channelGlass = NSVisualEffectView()
    private let controlOverlay = NSView()
    private let channelTint = CALayer()
    private let thumb = CALayer()
    private let volumeFill = CALayer()
    private var animateNextValueChange = false
    private var lastDrawnValue = Double.nan
    private var thumbArea: NSTrackingArea?
    private var hoverWork: DispatchWorkItem?
    private var awaitingPointerMove = false
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
        channelGlass.material = .underWindowBackground
        channelGlass.blendingMode = .behindWindow; channelGlass.state = .active
        channelGlass.wantsLayer = true; channelGlass.layer?.cornerRadius = 2; channelGlass.layer?.masksToBounds = true
        channelGlass.layer?.addSublayer(channelTint)
        channelGlass.setAccessibilityHidden(true); addSubview(channelGlass)
        controlOverlay.wantsLayer = true; controlOverlay.clipsToBounds = false
        controlOverlay.setAccessibilityHidden(true); addSubview(controlOverlay, positioned: .above, relativeTo: channelGlass)
        volumeFill.anchorPoint = CGPoint(x: 0, y: 0.5); volumeFill.cornerRadius = 2
        volumeFill.zPosition = 1; thumb.zPosition = 2
        controlOverlay.layer?.addSublayer(volumeFill); controlOverlay.layer?.addSublayer(thumb)
        thumb.cornerRadius = PlayerVolumeCell.thumbDiameter / 2
        thumb.opacity = 1
        thumb.shadowColor = NSColor.black.cgColor; thumb.shadowOffset = CGSize(width: 0, height: -1)
        thumb.shadowRadius = 1.5; thumb.borderWidth = 0.5
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point, from: superview)) ? self : nil }
    override func draw(_ dirtyRect: NSRect) { super.draw(dirtyRect); positionThumb() }
    override func layout() { super.layout(); positionThumb() }
    func setVolume(_ value: Double, animated: Bool) {
        animateNextValueChange = animated
        doubleValue = value
        positionThumb()
    }
    func syncTrackingPosition() { positionThumb() }
    private func positionThumb() {
        guard let cell = cell as? NSSliderCell else { return }
        let rect = cell.knobRect(flipped: isFlipped)
        let changed = doubleValue != lastDrawnValue
        let animate = changed && animateNextValueChange && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let oldPosition = thumb.presentation()?.position ?? thumb.position
        let oldWidth = volumeFill.presentation()?.bounds.width ?? volumeFill.bounds.width
        let bar = visibleTrackRect
        controlOverlay.frame = bounds
        channelGlass.frame = bar
        channelTint.frame = channelGlass.bounds
        channelTint.backgroundColor = NSColor.black.withAlphaComponent(railGlassTint).cgColor
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
        let scale: CGFloat = active ? (pressing ? 1.1 : hovering ? PlayerVolumeCell.hoverDiameter / PlayerVolumeCell.thumbDiameter : 1) : 1
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
    override func mouseEntered(with event: NSEvent) { if !awaitingPointerMove { setHovering(true) } }
    override func mouseMoved(with event: NSEvent) { awaitingPointerMove = false; setHovering(thumbHitRect.contains(convert(event.locationInWindow, from: nil))) }
    override func mouseExited(with event: NSEvent) { setHovering(false) }
    override func mouseDown(with event: NSEvent) {
        awaitingPointerMove = false
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
        awaitingPointerMove = true; setHovering(false)
        animateNextValueChange = true
        let sensitivity = event.hasPreciseScrollingDeltas ? 0.0015 : 0.004
        doubleValue = min(1, max(0, doubleValue + Double(event.scrollingDeltaY) * sensitivity))
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
        let active = isEnabled && playerControlWindow(for: self)?.isKeyWindow == true
        setHovering(true)
        let expectedDiameter: CGFloat = active ? PlayerVolumeCell.hoverDiameter : PlayerVolumeCell.thumbDiameter
        precondition(abs(targetScale * PlayerVolumeCell.thumbDiameter - expectedDiameter) < 0.001, "Hover follows the actual window activation state")
        if active, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { precondition(thumb.animation(forKey: "thumbScale")?.duration == 0.1) }
        if !active { log("NOTE: volume active-hover check unavailable without key window; inactive thumb scale verified instead") }
        setHovering(false)
        precondition(targetScale == 1 && !accented, "Hover-out restores the size and cancels delayed tint")
        let scroll = NSEvent(cgEvent: CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 10, wheel2: 0, wheel3: 0)!)!
        doubleValue = 0.5; scrollWheel(with: scroll)
        precondition(doubleValue > 0.5 && doubleValue < 0.55, "Scroll volume changes remain restrained")
        mouseEntered(with: scroll)
        precondition(awaitingPointerMove && !hovering && targetScale == 1, "A wheel-moved thumb must not grow underneath a stationary cursor")
        let move = NSEvent.mouseEvent(with: .mouseMoved, location: convert(NSPoint(x: thumbHitRect.midX, y: thumbHitRect.midY), to: nil), modifierFlags: [], timestamp: 0, windowNumber: window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
        mouseMoved(with: move)
        precondition(!awaitingPointerMove && hovering, "A real pointer move restores direct thumb interaction")
        setHovering(false)
        log("PASS: volume endpoints and native quarter-step drags agree; opaque thumb; hover scale follows activation (active=\(active))")
    }
    deinit { hoverWork?.cancel(); activationObservers.forEach(NotificationCenter.default.removeObserver) }
}

#endif
