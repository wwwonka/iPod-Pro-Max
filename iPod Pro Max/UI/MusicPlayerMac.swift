#if canImport(AppKitBackend)
import AppKit
import AppKitBackend
import AVFoundation
import SwiftCrossUI

final class WaveformView: NSView {
    var samples: [Float] = [] { didSet { needsDisplay = true } }
    var progress: Double = 0 { didSet { needsDisplay = true; setAccessibilityValue(progress) } }
    var onSeek: (Double) -> Void = { _ in }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true); setAccessibilityRole(.slider); setAccessibilityLabel("Playback position")
    }
    required init?(coder: NSCoder) { fatalError() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 123 { onSeek(max(0, progress - 0.02)) }
        else if event.keyCode == 124 { onSeek(min(1, progress + 0.02)) }
        else { super.keyDown(with: event) }
    }
    override func accessibilityPerformIncrement() -> Bool { onSeek(min(1, progress + 0.02)); return true }
    override func accessibilityPerformDecrement() -> Bool { onSeek(max(0, progress - 0.02)); return true }
    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 0 else { return }
        let count = max(1, Int(bounds.width / 4))
        for i in 0..<count {
            let value = samples.isEmpty ? 0.08 : CGFloat(samples[min(samples.count - 1, i * samples.count / count)])
            let h = max(3, min(bounds.height, value * bounds.height))
            (Double(i) / Double(count) <= progress ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).setFill()
            NSBezierPath(roundedRect: NSRect(x: CGFloat(i) * 4, y: (bounds.height - h) / 2, width: 2, height: h), xRadius: 1, yRadius: 1).fill()
        }
    }
    override func mouseDown(with event: NSEvent) { seek(event) }
    override func mouseDragged(with event: NSEvent) { seek(event) }
    private func seek(_ event: NSEvent) { if bounds.width > 0 { onSeek(max(0, min(1, convert(event.locationInWindow, from: nil).x / bounds.width))) } }
}

#endif
