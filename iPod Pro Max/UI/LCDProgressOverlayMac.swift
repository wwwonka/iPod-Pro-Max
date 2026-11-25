#if canImport(AppKitBackend)
import AppKit
import MediaKit

/// Separate from the visualizer's opacity, and above the fading track labels.
@MainActor final class LCDProgressOverlay: NSView {
    private let barGroup = CALayer()
    private let barMask = CALayer()
    private let barMaskOuter = CAShapeLayer()
    private let barMaskInner = CAShapeLayer()
    private let track = CALayer(), fill = CALayer(), markers = CAShapeLayer()
    private let knobGroup = CALayer()
    private let knob = CAShapeLayer()
    private var fraction = 0.0
    private var chapters: [PlaybackChapter] = []
    private var duration = 0.0
    private var scrubbing = false
    private var wasPlaying = false
    private var isPlaying = false
    private var hovered = false
    private var knobHovered = false
    private var knobVisible = false
    private var accented = false
    private var pointerX: CGFloat?
    private var hoverWork: DispatchWorkItem?
    private var activationObservers: [NSObjectProtocol] = []
    /// A discreet capsule: rounded on top, flat on the track, ~1/3 taller than
    /// the hovered 4 pt timeline, with a 1 pt cutout mask acting on the timeline.
    private let knobWidth: CGFloat = 3
    private let knobHeight: CGFloat = 5.5
    private let maskGap: CGFloat = 1
    private(set) var thickness: CGFloat = 2
    /// The knob marks the playback position, never the pointer: it stays on the
    /// current time while the hover label still previews the hovered time.
    var handleRect: NSRect { knobRect(center: knobCenter) }
    var hoverHandleRect: NSRect { knobRect(center: pointerX.map(clampedPointerCenter) ?? knobCenter) }
    private var knobCenter: CGFloat {
        let inset = knobWidth / 2
        return min(max(inset, bounds.width * fraction), max(inset, bounds.width - inset))
    }
    private func clampedPointerCenter(_ x: CGFloat) -> CGFloat {
        let inset = knobWidth / 2
        return min(max(inset, x), max(inset, bounds.width - inset))
    }
    private func knobRect(center: CGFloat) -> NSRect {
        NSRect(x: center - knobWidth / 2, y: 0, width: knobWidth, height: knobHeight)
    }
    private func pillPath(in rect: NSRect) -> CGPath {
        let radius = rect.width / 2
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: rect.maxY), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY - radius), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
    /// Centered at x = 0 inside `barMask` so shifting `barMask.position.x` keeps
    /// the 1 pt cutout pixel-locked to the smoothly gliding gizmo.
    private var localCutoutRect: CGRect {
        let halfWidth = knobWidth / 2 + maskGap
        return CGRect(x: -halfWidth, y: -2, width: halfWidth * 2, height: knobHeight + maskGap + 2)
    }
    private func outerMaskPath() -> CGPath {
        let path = CGMutablePath()
        path.addRect(CGRect(x: -2000, y: -2, width: 4000, height: max(12, bounds.height + 6)))
        path.addPath(pillPath(in: localCutoutRect))
        return path
    }
    private func innerMaskPath() -> CGPath {
        pillPath(in: localCutoutRect.insetBy(dx: -0.5, dy: -0.5))
    }
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true; clipsToBounds = false
        layer?.addSublayer(barGroup)
        barMask.bounds = CGRect(x: -2000, y: 0, width: 4000, height: 10)
        barMask.anchorPoint = CGPoint(x: 0.5, y: 0)
        barMaskOuter.fillRule = .evenOdd
        barMaskOuter.fillColor = NSColor.black.cgColor
        barMaskInner.fillColor = NSColor.black.cgColor
        barMaskInner.opacity = 1
        barMask.addSublayer(barMaskOuter)
        barMask.addSublayer(barMaskInner)
        barGroup.mask = barMask
        track.anchorPoint = CGPoint(x: 1, y: 0.5)
        fill.anchorPoint = CGPoint(x: 0, y: 0.5)
        for item in [track, fill, markers] { barGroup.addSublayer(item) }
        layer?.addSublayer(knobGroup)
        knobGroup.addSublayer(knob)
        knob.shadowColor = NSColor.black.cgColor
        knob.shadowOffset = CGSize(width: 0, height: -0.5)
        knob.shadowRadius = 1
        knob.shadowOpacity = 0.22
        knobGroup.opacity = 0
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { hoverWork?.cancel(); activationObservers.forEach(NotificationCenter.default.removeObserver) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func update(position: Double, duration: Double, activity: PlayerActivity?, proposed: Double?, chapters: [PlaybackChapter], playing: Bool = false) {
        self.duration = duration; self.chapters = activity == nil ? chapters : []
        let nextFraction = min(1, max(0, activity?.fraction ?? (duration > 0 ? (proposed ?? position) / duration : 0)))
        let nextScrubbing = proposed != nil
        let interpolate = wasPlaying && playing && !nextScrubbing && duration > 0 && abs(nextFraction - fraction) < 0.05 && nextFraction > fraction
        wasPlaying = playing
        isPlaying = playing
        fraction = nextFraction
        scrubbing = nextScrubbing
        let next: CGFloat = (hovered || scrubbing) ? 4 : 2
        let changed = next != thickness; thickness = next
        let tintChanged = updateKnobHoverState()
        render(animated: changed || tintChanged, interpolateProgress: interpolate)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        activationObservers.forEach(NotificationCenter.default.removeObserver); activationObservers.removeAll()
        guard window != nil else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, MacWindowLifecycle.visualActivationDidChange] {
            activationObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if !MacWindowLifecycle.shared.isWindowVisuallyActive(playerControlWindow(for: self)) {
                        self.hoverWork?.cancel(); self.hoverWork = nil; self.accented = false
                    }
                    self.render(animated: false)
                }
            })
        }
        render(animated: false)
    }
    func setPointerX(_ value: CGFloat?) {
        pointerX = value
        let hoverChanged = setHovered(value != nil)
        let tintChanged = updateKnobHoverState()
        render(animated: hoverChanged || tintChanged)
    }
    @discardableResult
    private func setHovered(_ value: Bool) -> Bool {
        let nextHovered = value
        let nextThickness: CGFloat = (nextHovered || scrubbing) ? 4 : 2
        let changed = hovered != nextHovered || thickness != nextThickness
        hovered = nextHovered; thickness = nextThickness
        return changed
    }
    @discardableResult
    private func updateKnobHoverState() -> Bool {
        let overKnob = pointerX.map { abs($0 - knobCenter) <= knobWidth / 2 + 3 } ?? false
        guard overKnob != knobHovered else { return false }
        knobHovered = overKnob
        hoverWork?.cancel(); hoverWork = nil
        if overKnob {
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.knobHovered, MacWindowLifecycle.shared.isWindowVisuallyActive(playerControlWindow(for: self)) else { return }
                self.accented = true; self.render(animated: true)
            }
            hoverWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + RailButton.hoverDelay, execute: work)
            return false
        } else if accented {
            accented = false
            return true
        }
        return false
    }
    func checkHoverRendering() {
        let savedFrame = frame
        if bounds.width < 40 { frame = NSRect(x: savedFrame.minX, y: savedFrame.minY, width: 240, height: 7) }
        defer { frame = savedFrame; layoutSubtreeIfNeeded() }
        update(position: 30, duration: 60, activity: nil, proposed: nil, chapters: [])
        let playbackCenter = knobCenter
        precondition(abs(knobGroup.opacity) < 0.01 && abs(knob.position.x - playbackCenter) < 0.01)
        let pillSize = knob.path?.boundingBox.size ?? .zero
        precondition(abs(pillSize.width - knobWidth) < 0.01 && abs(pillSize.height - knobHeight) < 0.01, "The timeline gizmo stays a small flat-bottom capsule")
        precondition(knobGroup.sublayers?.count == 1 && barGroup.mask === barMask, "The 1 px mask acts on the timeline bar, not around the gizmo")
        setPointerX(bounds.width - 8)
        precondition(abs(knobGroup.opacity - 1) < 0.01)
        precondition(knob.fillColor?.alpha == 1, "The timeline gizmo stays opaque")
        precondition(abs(knob.position.x - playbackCenter) < 0.01, "Hover must not move the gizmo away from playback: knob=\(knob.position.x) playback=\(playbackCenter) width=\(bounds.width) fraction=\(fraction) hovered=\(hovered) scrubbing=\(scrubbing)")
        precondition(abs(hoverHandleRect.midX - (bounds.width - 8)) < 0.01, "The hover label keeps following the pointer")
        precondition(thickness == 4 && track.bounds.height == 4 && fill.bounds.height == 4)
        precondition(alphaValue == 1 && track.opacity == 1 && fill.opacity == 1, "Progress must stay opaque above metadata")
        let baseWidth = knob.bounds.width
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            precondition(track.animation(forKey: "hoverHeight") != nil, "Hover thickness must animate")
            precondition(knobGroup.animation(forKey: "knobFade") != nil, "The gizmo fades in on hover")
        }
        accented = true; render(animated: true)
        precondition(abs(knob.bounds.width - baseWidth) < 0.01, "The gizmo never grows on hover")
        precondition(knob.animation(forKey: "knobTint") != nil || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, "The hover tint fades like the volume thumb")
        setPointerX(playbackCenter)
        precondition(knobHovered && accented, "Hovering the gizmo itself preserves its hover state")
        setPointerX(bounds.width - 8)
        precondition(!knobHovered && !accented, "Leaving the gizmo clears its color tint even while still hovering the timeline")
        update(position: 45, duration: 60, activity: nil, proposed: nil, chapters: [])
        precondition(abs(knob.position.x - knobCenter) < 0.01 && knob.position.x > playbackCenter + 1, "The gizmo follows playback, not the pointer")
        setPointerX(nil)
        precondition(abs(knobGroup.opacity) < 0.01)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            precondition(knobGroup.animation(forKey: "knobFade") != nil, "The gizmo fades out on leave")
        }
        precondition(thickness == 2 && track.bounds.height == 2)
        log("PASS: timeline gizmo stays discreet, flat-bottomed, masks the timeline bar and clears tint off-hover")
    }
    override func layout() { super.layout(); render(animated: false) }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); render(animated: false) }
    private func render(animated: Bool, interpolateProgress: Bool = false) {
        let active = window == nil || MacWindowLifecycle.shared.isWindowVisuallyActive(playerControlWindow(for: self))
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let oldTrackHeight = track.presentation()?.bounds.height ?? track.bounds.height
        let oldTrackY = track.presentation()?.position.y ?? track.position.y
        let oldKnobOpacity = knobGroup.presentation()?.opacity ?? knobGroup.opacity
        let oldInnerOpacity = barMaskInner.presentation()?.opacity ?? barMaskInner.opacity
        let oldFill = knob.presentation()?.fillColor ?? knob.fillColor
        let oldFillWidth = fill.presentation()?.bounds.width ?? fill.bounds.width
        let oldKnobX = knob.presentation()?.position.x ?? knob.position.x
        let oldMaskX = barMask.presentation()?.position.x ?? barMask.position.x
        let oldTrackWidth = track.presentation()?.bounds.width ?? track.bounds.width
        let visible = scrubbing || hovered
        let visibilityChanged = visible != knobVisible
        knobVisible = visible
        let base = NSColor(white: dark ? 0.86 : 0.97, alpha: 1)
        let tint = accented ? (NSColor.controlAccentColor.blended(withFraction: 0.65, of: base) ?? base).withAlphaComponent(1) : base
        let tintChanged = knob.fillColor != tint.cgColor
        let targetCenter = knobCenter
        let targetFillWidth = bounds.width * fraction
        let targetTrackWidth = max(0, bounds.width - targetFillWidth)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        barGroup.frame = bounds
        barMask.bounds = CGRect(x: -2000, y: 0, width: 4000, height: max(10, bounds.height))
        barMask.position = CGPoint(x: targetCenter, y: 0)
        barMaskOuter.frame = barMask.bounds
        barMaskInner.frame = barMask.bounds
        barMaskOuter.path = outerMaskPath()
        barMaskInner.path = innerMaskPath()
        barMaskInner.opacity = visible ? 0 : 1
        track.backgroundColor = NSColor.tertiaryLabelColor.withAlphaComponent(active ? 0.5 : 0.22).cgColor
        fill.backgroundColor = (active ? NSColor.controlAccentColor : NSColor.labelColor.withAlphaComponent(0.3)).cgColor
        markers.fillColor = NSColor.labelColor.withAlphaComponent(active ? 0.55 : 0.25).cgColor
        track.bounds = NSRect(x: 0, y: 0, width: targetTrackWidth, height: thickness)
        track.position = CGPoint(x: bounds.width, y: thickness / 2)
        fill.bounds = NSRect(x: 0, y: 0, width: targetFillWidth, height: thickness)
        fill.position = CGPoint(x: 0, y: thickness / 2)
        track.cornerRadius = 0; fill.cornerRadius = 0
        let path = CGMutablePath()
        if duration > 0 { for chapter in chapters { path.addRect(CGRect(x: bounds.width * chapter.time / duration, y: 0, width: 1, height: thickness + 2)) } }
        markers.path = path
        knobGroup.frame = bounds
        let rect = knobRect(center: targetCenter)
        knob.frame = rect
        let pill = pillPath(in: NSRect(origin: .zero, size: rect.size))
        knob.path = pill
        knob.fillColor = tint.cgColor
        knob.shadowPath = pill
        knobGroup.opacity = visible ? 1 : 0
        CATransaction.commit()
        if !interpolateProgress || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            track.removeAnimation(forKey: "progress")
            fill.removeAnimation(forKey: "progress")
            knob.removeAnimation(forKey: "progress")
            barMask.removeAnimation(forKey: "progress")
        }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        if interpolateProgress {
            let linear = CAMediaTimingFunction(name: .linear)
            let trackAnim = CABasicAnimation(keyPath: "bounds.size.width")
            trackAnim.fromValue = oldTrackWidth; trackAnim.toValue = targetTrackWidth
            trackAnim.duration = 0.25; trackAnim.timingFunction = linear
            track.add(trackAnim, forKey: "progress")
            let fillAnim = CABasicAnimation(keyPath: "bounds.size.width")
            fillAnim.fromValue = oldFillWidth; fillAnim.toValue = targetFillWidth
            fillAnim.duration = 0.25; fillAnim.timingFunction = linear
            fill.add(fillAnim, forKey: "progress")
            let knobAnim = CABasicAnimation(keyPath: "position.x")
            knobAnim.fromValue = oldKnobX; knobAnim.toValue = knob.position.x
            knobAnim.duration = 0.25; knobAnim.timingFunction = linear
            knob.add(knobAnim, forKey: "progress")
            let maskAnim = CABasicAnimation(keyPath: "position.x")
            maskAnim.fromValue = oldMaskX; maskAnim.toValue = barMask.position.x
            maskAnim.duration = 0.25; maskAnim.timingFunction = linear
            barMask.add(maskAnim, forKey: "progress")
        }
        let motion = animated || visibilityChanged
        guard motion else { return }
        if abs(oldTrackHeight - thickness) > 0.01 {
            for bar in [track, fill] {
                let height = CABasicAnimation(keyPath: "bounds.size.height")
                height.fromValue = oldTrackHeight; height.toValue = thickness; height.duration = 0.18
                height.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                bar.add(height, forKey: "hoverHeight")
                let position = CABasicAnimation(keyPath: "position.y")
                position.fromValue = oldTrackY; position.toValue = thickness / 2; position.duration = 0.18
                position.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                bar.add(position, forKey: "hoverPosition")
            }
        }
        if visibilityChanged, abs(oldKnobOpacity - knobGroup.opacity) > 0.01 {
            let duration = visible ? RailButton.hoverFadeIn : RailButton.hoverFadeOut
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = oldKnobOpacity; fade.toValue = knobGroup.opacity
            fade.duration = duration
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            knobGroup.add(fade, forKey: "knobFade")
            let maskFade = CABasicAnimation(keyPath: "opacity")
            maskFade.fromValue = oldInnerOpacity; maskFade.toValue = barMaskInner.opacity
            maskFade.duration = duration
            maskFade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            barMaskInner.add(maskFade, forKey: "maskFade")
        }
        if tintChanged, let oldFill {
            let fade = CABasicAnimation(keyPath: "fillColor")
            fade.fromValue = oldFill; fade.toValue = tint.cgColor
            fade.duration = RailButton.hoverFadeIn
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            knob.add(fade, forKey: "knobTint")
        }
    }
}
#endif
