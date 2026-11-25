#if canImport(AppKitBackend)
import AppKit
import MediaKit

/// Cached envelope plus a clipped, colored playback pass. Position events drive
/// finite Core Animation interpolation; this view owns no timer or audio work.
@MainActor final class LCDWaveform: NSView {
    private let envelope = CAShapeLayer(), playedEnvelope = CAShapeLayer()
    private let color = CAGradientLayer(), clip = CALayer(), cursor = CALayer()
    private var samples: [Float] = []
    private var pathSize = NSSize.zero
    private var fraction = 0.0
    private var playing = false
    private var needsPath = true

    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        layer?.addSublayer(envelope); layer?.addSublayer(clip); layer?.addSublayer(cursor)
        clip.anchorPoint = .zero; clip.position = .zero; clip.masksToBounds = true
        clip.addSublayer(color); color.mask = playedEnvelope
        color.startPoint = CGPoint(x: 0, y: 0); color.endPoint = CGPoint(x: 1, y: 1)
        cursor.cornerRadius = 0.5
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func update(samples: [Float], fraction: Double, playing: Bool, scrubbing: Bool) {
        if !self.samples.sameStorage(as: samples) { self.samples = samples; needsPath = true; needsLayout = true }
        let next = min(1, max(0, fraction))
        let interpolate = self.playing && playing && !scrubbing && abs(next - self.fraction) < 0.05
        self.playing = playing; self.fraction = next
        renderProgress(animated: interpolate)
    }
    func suspend() { clip.removeAllAnimations(); cursor.removeAllAnimations() }
    override func layout() {
        super.layout()
        if needsPath || pathSize != bounds.size { rebuildPath() }
        renderProgress(animated: false)
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsPath = true; needsLayout = true }
    private func rebuildPath() {
        pathSize = bounds.size; needsPath = false
        let count = min(256, max(2, Int(bounds.width / 2)))
        let usable = max(0, bounds.height - 14), center = 8 + usable / 2
        var amplitudes = [CGFloat](repeating: 0.5, count: count)
        if !samples.isEmpty {
            for index in 0..<count {
                let start = index * samples.count / count
                let end = max(start + 1, (index + 1) * samples.count / count)
                var peak: Float = 0
                for sample in start..<min(end, samples.count) { peak = max(peak, abs(samples[sample])) }
                amplitudes[index] = max(0.6, CGFloat(min(1, peak)) * usable / 2)
            }
        }
        let raw = amplitudes
        for index in 1..<(count - 1) { amplitudes[index] = (raw[index - 1] + raw[index] * 2 + raw[index + 1]) / 4 }
        let points = (0..<count).map { CGPoint(x: CGFloat($0) * bounds.width / CGFloat(count - 1), y: center + amplitudes[$0]) }
            + (0..<count).reversed().map { CGPoint(x: CGFloat($0) * bounds.width / CGFloat(count - 1), y: center - amplitudes[$0]) }
        let path = CGMutablePath()
        if let first = points.first, let last = points.last {
            path.move(to: CGPoint(x: (first.x + last.x) / 2, y: (first.y + last.y) / 2))
            for index in points.indices {
                let next = points[(index + 1) % points.count]
                path.addQuadCurve(to: CGPoint(x: (points[index].x + next.x) / 2, y: (points[index].y + next.y) / 2), control: points[index])
            }
            path.closeSubpath()
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        envelope.path = path; playedEnvelope.path = path
        envelope.fillColor = NSColor.labelColor.withAlphaComponent(0.17).cgColor
        playedEnvelope.fillColor = NSColor.white.cgColor
        color.frame = bounds
        color.colors = [NSColor.controlAccentColor.withAlphaComponent(0.65).cgColor, NSColor.controlAccentColor.cgColor]
        cursor.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.85).cgColor
        CATransaction.commit()
    }
    private func renderProgress(animated: Bool) {
        let width = bounds.width * fraction
        let previous = clip.presentation()?.bounds.width ?? clip.bounds.width
        let previousX = cursor.presentation()?.position.x ?? cursor.position.x
        CATransaction.begin(); CATransaction.setDisableActions(true)
        clip.bounds = CGRect(x: 0, y: 0, width: width, height: bounds.height)
        cursor.frame = CGRect(x: width - 0.5, y: 7, width: 1, height: max(0, bounds.height - 12))
        cursor.isHidden = samples.isEmpty || fraction <= 0 || fraction >= 1
        CATransaction.commit()
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { suspend(); return }
        let linear = CAMediaTimingFunction(name: .linear)
        let reveal = CABasicAnimation(keyPath: "bounds.size.width")
        reveal.fromValue = previous; reveal.toValue = width; reveal.duration = 0.25; reveal.timingFunction = linear
        clip.add(reveal, forKey: "progress")
        let move = CABasicAnimation(keyPath: "position.x")
        move.fromValue = previousX; move.toValue = cursor.position.x; move.duration = 0.25; move.timingFunction = linear
        cursor.add(move, forKey: "progress")
    }
}
#endif
