#if canImport(AppKitBackend)
import AppKit
import MediaKit

/// Separate from the visualizer's opacity, and above the fading track labels.
@MainActor final class LCDProgressOverlay: NSView {
    private let track = CALayer(), fill = CALayer(), markers = CAShapeLayer(), thumb = CALayer()
    private var fraction = 0.0
    private var chapters: [PlaybackChapter] = []
    private var duration = 0.0
    private var scrubbing = false
    private(set) var thickness: CGFloat = 2
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        for item in [track, fill, markers, thumb] { layer?.addSublayer(item) }
        thumb.cornerRadius = 3
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func update(position: Double, duration: Double, activity: PlayerActivity?, proposed: Double?, chapters: [PlaybackChapter], hovered: Bool) {
        self.duration = duration; self.chapters = activity == nil ? chapters : []
        fraction = min(1, max(0, activity?.fraction ?? (duration > 0 ? (proposed ?? position) / duration : 0)))
        scrubbing = proposed != nil
        let next: CGFloat = hovered || scrubbing ? 4 : 2
        let changed = next != thickness; thickness = next
        render(animated: changed)
    }
    func checkHoverRendering() {
        update(position: 30, duration: 60, activity: nil, proposed: nil, chapters: [], hovered: true)
        precondition(thickness == 4 && track.bounds.height == 4 && fill.bounds.height == 4)
        precondition(alphaValue == 1 && track.opacity == 1 && fill.opacity == 1, "Progress must stay opaque above metadata")
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            precondition(track.animation(forKey: "hoverHeight") != nil, "Hover thickness must animate")
        }
        update(position: 30, duration: 60, activity: nil, proposed: nil, chapters: [], hovered: false)
        precondition(thickness == 2 && track.bounds.height == 2)
        log("PASS: progress overlay stays opaque and animates hover thickness 2–4 pt")
    }
    override func layout() { super.layout(); render(animated: false) }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); render(animated: false) }
    private func render(animated: Bool) {
        let oldTrackHeight = track.presentation()?.bounds.height ?? track.bounds.height
        let oldTrackY = track.presentation()?.position.y ?? track.position.y
        CATransaction.begin(); CATransaction.setDisableActions(true)
        track.backgroundColor = NSColor.tertiaryLabelColor.withAlphaComponent(0.5).cgColor
        fill.backgroundColor = NSColor.controlAccentColor.cgColor
        markers.fillColor = NSColor.labelColor.withAlphaComponent(0.55).cgColor
        thumb.backgroundColor = NSColor.controlAccentColor.cgColor
        track.frame = NSRect(x: 0, y: 0, width: bounds.width, height: thickness)
        fill.frame = NSRect(x: 0, y: 0, width: bounds.width * fraction, height: thickness)
        track.cornerRadius = 0; fill.cornerRadius = 0
        let path = CGMutablePath()
        if duration > 0 { for chapter in chapters { path.addRect(CGRect(x: bounds.width * chapter.time / duration, y: 0, width: 1, height: thickness + 2)) } }
        markers.path = path
        thumb.frame = NSRect(x: bounds.width * fraction - 3, y: 0, width: 6, height: 6)
        thumb.isHidden = !scrubbing
        CATransaction.commit()
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
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
}
#endif
