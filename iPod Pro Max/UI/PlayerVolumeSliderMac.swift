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
    private let channelTintMask = CAShapeLayer()
    private let thumb = CALayer()
    private let volumeFillGroup = CALayer()
    private let volumeFillMask = CAShapeLayer()
    private let volumeFill = CALayer()
    private let maskGap: CGFloat = 1
    private var lastMaskSize = NSSize.zero
    private var lastMaskCenterX = CGFloat.nan
    private var lastMaskCutoutRadius = CGFloat.nan
    private var maskRestoreWork: DispatchWorkItem?
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
        channelGlass.wantsLayer = true
        channelGlass.layer?.cornerRadius = 2; channelGlass.layer?.masksToBounds = true
        channelTint.cornerRadius = 2; channelTint.masksToBounds = true
        channelTintMask.fillRule = .evenOdd; channelTintMask.fillColor = NSColor.black.cgColor
        channelTint.mask = channelTintMask
        channelGlass.layer?.addSublayer(channelTint)
        channelGlass.setAccessibilityHidden(true); addSubview(channelGlass)
        controlOverlay.wantsLayer = true; controlOverlay.clipsToBounds = false
        controlOverlay.setAccessibilityHidden(true); addSubview(controlOverlay, positioned: .above, relativeTo: channelGlass)
        volumeFillGroup.zPosition = 1; thumb.zPosition = 2
        volumeFillMask.fillRule = .evenOdd; volumeFillMask.fillColor = NSColor.black.cgColor
        volumeFillMask.bounds = CGRect(x: -1000, y: -50, width: 2000, height: 100)
        volumeFillMask.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        volumeFillGroup.mask = volumeFillMask
        volumeFill.anchorPoint = CGPoint(x: 0, y: 0.5); volumeFill.cornerRadius = 2
        volumeFillGroup.addSublayer(volumeFill)
        controlOverlay.layer?.addSublayer(volumeFillGroup); controlOverlay.layer?.addSublayer(thumb)
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
    private func cutoutPath(radius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.addRect(volumeFillMask.bounds)
        if radius > 0 {
            path.addEllipse(in: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2))
        }
        return path
    }
    private func tintCutoutPath(size: NSSize, centerX: CGFloat?, cutoutRadius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.addRect(CGRect(origin: .zero, size: size))
        if let centerX, cutoutRadius > 0 {
            path.addEllipse(in: CGRect(x: centerX - cutoutRadius, y: size.height / 2 - cutoutRadius,
                                       width: cutoutRadius * 2, height: cutoutRadius * 2))
        }
        return path
    }
    private func updateChannelGlassMask(size: NSSize, centerX: CGFloat?, cutoutRadius: CGFloat) {
        guard size.width > 0, size.height > 0 else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        channelTintMask.frame = CGRect(origin: .zero, size: size)
        channelTintMask.path = tintCutoutPath(size: size, centerX: centerX, cutoutRadius: cutoutRadius)
        CATransaction.commit()
        let targetX = centerX ?? -1
        let targetR = centerX == nil ? -1 : cutoutRadius
        guard size != lastMaskSize || abs(targetX - lastMaskCenterX) > 0.05 || abs(targetR - lastMaskCutoutRadius) > 0.05 else { return }
        lastMaskSize = size; lastMaskCenterX = targetX; lastMaskCutoutRadius = targetR
        let mask = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            rect.fill()
            if let centerX, cutoutRadius > 0 {
                NSGraphicsContext.current?.cgContext.setBlendMode(.clear)
                let hole = NSRect(x: centerX - cutoutRadius, y: rect.midY - cutoutRadius,
                                  width: cutoutRadius * 2, height: cutoutRadius * 2)
                NSBezierPath(ovalIn: hole).fill()
            }
            return true
        }
        channelGlass.maskImage = mask
    }
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
        let cutoutRadius = (PlayerVolumeCell.thumbDiameter / 2) * targetScale + maskGap
        CATransaction.begin(); CATransaction.setDisableActions(true)
        volumeFillGroup.frame = bounds
        thumb.bounds = NSRect(x: 0, y: 0, width: PlayerVolumeCell.thumbDiameter, height: PlayerVolumeCell.thumbDiameter)
        thumb.position = NSPoint(x: rect.midX, y: rect.midY)
        thumb.shadowPath = CGPath(ellipseIn: thumb.bounds, transform: nil)
        volumeFillMask.position = thumb.position
        volumeFillMask.path = cutoutPath(radius: cutoutRadius)
        volumeFill.bounds = NSRect(x: 0, y: 0, width: max(0, rect.midX - bar.minX), height: bar.height)
        volumeFill.position = NSPoint(x: bar.minX, y: bar.midY)
        CATransaction.commit()
        if changed {
            animateNextValueChange = false; lastDrawnValue = doubleValue
            thumb.removeAnimation(forKey: "volumeClick"); volumeFill.removeAnimation(forKey: "volumeClick"); volumeFillMask.removeAnimation(forKey: "volumeClick")
            maskRestoreWork?.cancel(); maskRestoreWork = nil
            if animate {
                let knob = CABasicAnimation(keyPath: "position"); knob.fromValue = NSValue(point: oldPosition); knob.toValue = NSValue(point: thumb.position)
                let maskMove = CABasicAnimation(keyPath: "position"); maskMove.fromValue = NSValue(point: oldPosition); maskMove.toValue = NSValue(point: thumb.position)
                let fill = CABasicAnimation(keyPath: "bounds.size.width"); fill.fromValue = oldWidth; fill.toValue = volumeFill.bounds.width
                for animation in [knob, maskMove, fill] { animation.duration = 0.14; animation.timingFunction = CAMediaTimingFunction(name: .easeOut) }
                thumb.add(knob, forKey: "volumeClick"); volumeFillMask.add(maskMove, forKey: "volumeClick"); volumeFill.add(fill, forKey: "volumeClick")
                updateChannelGlassMask(size: bar.size, centerX: nil, cutoutRadius: cutoutRadius)
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    let currentBar = self.visibleTrackRect
                    let currentCutout = (PlayerVolumeCell.thumbDiameter / 2) * self.targetScale + self.maskGap
                    self.updateChannelGlassMask(size: currentBar.size, centerX: self.thumb.position.x - currentBar.minX, cutoutRadius: currentCutout)
                }
                maskRestoreWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: work)
            } else {
                updateChannelGlassMask(size: bar.size, centerX: thumb.position.x - bar.minX, cutoutRadius: cutoutRadius)
            }
        } else if maskRestoreWork == nil {
            updateChannelGlassMask(size: bar.size, centerX: thumb.position.x - bar.minX, cutoutRadius: cutoutRadius)
        }
        updateThumbArea()
        if hovering && !pressing, let window, !thumbHitRect.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) { setHovering(false) }
        updateThumb(animated: false)
    }
    private func fillColor(active: Bool, dark: Bool) -> NSColor {
        NSColor(white: dark ? 0.7 : 0.46, alpha: active ? 1 : 0.35)
    }
    private func updateThumb(animated: Bool = true) {
        let active = MacWindowLifecycle.shared.isWindowVisuallyActive(playerControlWindow(for: self)) && isEnabled
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let gray: CGFloat = dark ? 0.85 : 0.97
        let base = NSColor(white: gray, alpha: 1)
        let color = active && (accented || pressing) ? (NSColor.controlAccentColor.blended(withFraction: 0.65, of: base) ?? base).withAlphaComponent(1) : base
        let saved = NSAppearance.current; NSAppearance.current = effectiveAppearance
        let target = color.cgColor; NSAppearance.current = saved
        CATransaction.begin(); CATransaction.setDisableActions(true)
        thumb.opacity = active ? 1 : 0.35
        thumb.borderColor = NSColor.white.withAlphaComponent(dark ? 0.28 : 0.8).cgColor
        thumb.shadowOpacity = active ? 0.28 : 0.06
        CATransaction.commit()
        let motion = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let fill = fillColor(active: active, dark: dark)
        if volumeFill.backgroundColor != fill.cgColor {
            if motion {
                let fade = CABasicAnimation(keyPath: "backgroundColor")
                fade.fromValue = volumeFill.presentation()?.backgroundColor ?? volumeFill.backgroundColor; fade.toValue = fill.cgColor
                fade.duration = RailButton.hoverFadeOut; fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                volumeFill.add(fade, forKey: "fillTint")
            } else { volumeFill.removeAnimation(forKey: "fillTint") }
            CATransaction.begin(); CATransaction.setDisableActions(true); volumeFill.backgroundColor = fill.cgColor; CATransaction.commit()
        }
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
            let oldMaskPath = volumeFillMask.presentation()?.path ?? volumeFillMask.path
            targetScale = scale
            let nextCutout = (PlayerVolumeCell.thumbDiameter / 2) * scale + maskGap
            let nextMaskPath = cutoutPath(radius: nextCutout)
            CATransaction.begin(); CATransaction.setDisableActions(true)
            thumb.transform = CATransform3DMakeScale(scale, scale, 1)
            volumeFillMask.path = nextMaskPath
            CATransaction.commit()
            let bar = visibleTrackRect
            if maskRestoreWork == nil {
                updateChannelGlassMask(size: bar.size, centerX: thumb.position.x - bar.minX, cutoutRadius: nextCutout)
            }
            if motion {
                let duration = hovering ? 0.1 : 0.09
                let animation = CABasicAnimation(keyPath: "transform.scale")
                animation.fromValue = previous; animation.toValue = scale
                animation.duration = duration
                animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
                thumb.add(animation, forKey: "thumbScale")
                if let oldMaskPath {
                    let maskAnim = CABasicAnimation(keyPath: "path")
                    maskAnim.fromValue = oldMaskPath; maskAnim.toValue = nextMaskPath
                    maskAnim.duration = duration; maskAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    volumeFillMask.add(maskAnim, forKey: "thumbScale")
                }
            } else { thumb.removeAnimation(forKey: "thumbScale"); volumeFillMask.removeAnimation(forKey: "thumbScale") }
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
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, MacWindowLifecycle.visualActivationDidChange] {
                activationObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        if playerControlWindow(for: self)?.isKeyWindow != true {
                            self.hoverWork?.cancel(); self.hovering = false; self.accented = false; self.pressing = false
                        }
                        self.updateThumb(animated: false)
                    }
                })
            }
        }
        updateThumb(animated: false)
    }
    override func scrollWheel(with event: NSEvent) {
        guard window == nil || playerControlWindow(for: self)?.isKeyWindow == true else { return }
        applyScroll(event)
    }
    private func applyScroll(_ event: NSEvent) {
        awaitingPointerMove = true; setHovering(false)
        animateNextValueChange = true
        let sensitivity = event.hasPreciseScrollingDeltas ? 0.0015 : 0.004
        doubleValue = min(1, max(0, doubleValue + Double(event.scrollingDeltaY) * sensitivity))
        sendAction(action, to: target)
    }
    func checkThumbInteraction() {
        precondition(thumb.sublayers?.isEmpty != false && volumeFillGroup.mask === volumeFillMask && volumeFillMask.fillRule == .evenOdd && volumeFillMask.path != nil, "The 1 px mask acts on the volume track, not around the thumb")
        precondition(channelGlass.maskImage != nil, "The glass channel carries the 1 px thumb cutout")
        for dark in [true, false] {
            let active = fillColor(active: true, dark: dark), inactive = fillColor(active: false, dark: dark)
            precondition(active.alphaComponent == 1 && inactive.alphaComponent < 0.5, "Inactive volume fill must dim")
        }
        guard let cell = cell as? NSSliderCell else { preconditionFailure("Volume cell missing") }
        let previousValue = doubleValue
        defer { doubleValue = previousValue; sendAction(action, to: target); setHovering(false); positionThumb() }
        let bar = visibleTrackRect
        let active = isEnabled && playerControlWindow(for: self)?.isKeyWindow == true
        let expectedOpacity: Float = active ? 1 : 0.35
        for fraction in [0.0, 0.25, 0.5, 0.75, 1] {
            doubleValue = fraction; positionThumb()
            precondition(abs(thumb.position.x - (bar.minX + bar.width * fraction)) < 0.01 && abs(thumb.position.y - bar.midY) < 0.01)
            precondition(abs(thumb.opacity - expectedOpacity) < 0.01 && thumb.backgroundColor?.alpha == 1, "Volume thumb opacity tracks activation")
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
        let expectedDiameter: CGFloat = active ? PlayerVolumeCell.hoverDiameter : PlayerVolumeCell.thumbDiameter
        precondition(abs(targetScale * PlayerVolumeCell.thumbDiameter - expectedDiameter) < 0.001, "Hover follows the actual window activation state")
        if active, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { precondition(thumb.animation(forKey: "thumbScale")?.duration == 0.1) }
        if !active { log("NOTE: volume active-hover check unavailable without key window; inactive thumb scale verified instead") }
        setHovering(false)
        precondition(targetScale == 1 && !accented, "Hover-out restores the size and cancels delayed tint")
        let scroll = NSEvent(cgEvent: CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 10, wheel2: 0, wheel3: 0)!)!
        doubleValue = 0.5
        if active {
            scrollWheel(with: scroll)
        } else {
            scrollWheel(with: scroll)
            precondition(doubleValue == 0.5, "Background window ignores volume trackpad scroll")
            applyScroll(scroll)
        }
        precondition(doubleValue > 0.5 && doubleValue < 0.55, "Scroll volume changes remain restrained")
        mouseEntered(with: scroll)
        precondition(awaitingPointerMove && !hovering && targetScale == 1, "A wheel-moved thumb must not grow underneath a stationary cursor")
        let move = NSEvent.mouseEvent(with: .mouseMoved, location: convert(NSPoint(x: thumbHitRect.midX, y: thumbHitRect.midY), to: nil), modifierFlags: [], timestamp: 0, windowNumber: window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
        mouseMoved(with: move)
        precondition(!awaitingPointerMove && hovering, "A real pointer move restores direct thumb interaction")
        setHovering(false)
        log("PASS: volume endpoints and native quarter-step drags agree; track-masked thumb; hover scale follows activation (active=\(active))")
    }
    func checkInactiveFill() {
        guard let window, !window.isKeyWindow else {
            log("NOTE: inactive volume fill check needs a background window"); return
        }
        precondition((volumeFill.backgroundColor?.alpha ?? 1) < 0.5, "Inactive volume fill must dim with the rest of the interface")
        precondition(volumeFill.backgroundColor != nil && thumb.opacity < 0.5, "Inactive volume thumb dims like the rest of the interface")
        precondition(volumeFill.animation(forKey: "fillTint") == nil && thumb.animation(forKey: "hoverTint") == nil, "Inactive volume dimming is instantaneous")
        log("PASS: inactive volume fill and thumb dim instantaneously to \(volumeFill.backgroundColor?.alpha ?? 1) / \(thumb.opacity)")
    }
    deinit { maskRestoreWork?.cancel(); hoverWork?.cancel(); activationObservers.forEach(NotificationCenter.default.removeObserver) }
}

#endif
