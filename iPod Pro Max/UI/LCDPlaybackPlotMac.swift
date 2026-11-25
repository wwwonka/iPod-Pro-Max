#if canImport(AppKitBackend)
import AppKit
import MediaKit

/// Timeline gestures and precomputed visualizations. This view owns no audio clock.
@MainActor final class LCDPlaybackPlot: NSView {
    var onPreview: (Double?) -> Void = { _ in }
    var onHover: (Double?) -> Void = { _ in }
    var onSpectrumReleaseFinished: () -> Void = {}
    var activity: PlayerActivity?
    var isReleasingSpectrum: Bool { mode == .spectrum && (spectrumRelease.isReleasing || peakRelease.isReleasing) }
    private(set) var scrub = PlayerScrub()
    private(set) var hoverX: CGFloat = 0
    private(set) var hoverPoint = NSPoint.zero
    private var trackID: String?
    private var gestureCancelled = false
    var onSeek: (Double) -> Void = { PlaybackController.shared.seek($0) }
    var currentTrackID: () -> String? = { PlaybackController.shared.track?.id }
    private(set) var hoverChapter: String?
    private var duration = 0.0, position = 0.0
    private var mode: PlayerLCDMode = .title
    private let waveform = LCDWaveform()
    private let spectrumIdle = SpectrumIdleBarsView()
    private let spectrumLit = SpectrumLitBarsView()
    private var chapters: [PlaybackChapter] = []
    private var spectrumLink: LCDSpectrumDisplayLink?
    var isSpectrumAnimating: Bool { spectrumLink?.isRunning == true }
    private var spectrumWasPlaying = false
    private var peakRelease = PlayerSpectrumPeakRelease()
    private var spectrumRelease = PlayerSpectrumRelease()
    private var spectrumLevels = [Float](repeating: 0, count: 32)
    private var spectrumPeaks = PlayerSpectrumPeaks()
    private var spectrumAnchor = ProcessInfo.processInfo.systemUptime
    private var spectrumLast = ProcessInfo.processInfo.systemUptime
    private(set) var isScrubbing = false
    func suspendSpectrum() {
        let wasReleasing = spectrumRelease.isReleasing || peakRelease.isReleasing
        spectrumLink?.stop()
        if window?.occlusionState.contains(.visible) != true || !PlaybackController.shared.playing { waveform.suspend() }
        if !PlaybackController.shared.playing {
            spectrumRelease.finish(); spectrumLevels = spectrumRelease.levels
            spectrumPeaks = PlayerSpectrumPeaks(); spectrumWasPlaying = false; peakRelease.finish(); needsDisplay = true
        }
        if wasReleasing { onSpectrumReleaseFinished() }
    }
    private func updateSpectrum() {
        let timeline = PlayerDisplayController.shared.spectrum
        guard mode == .spectrum, activity == nil,
              timeline != nil || spectrumRelease.isReleasing || peakRelease.isReleasing else { suspendSpectrum(); return }
        let visible = window?.isVisible == true && window?.isMiniaturized == false && window?.occlusionState.contains(.visible) == true
        let now = ProcessInfo.processInfo.systemUptime
        let playing = PlaybackController.shared.playing && timeline != nil
        let running = playing && scrub.proposed == nil
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let time = position + (running ? max(0, now - spectrumAnchor) * PlaybackController.shared.rate : 0)
        if playing, let timeline {
            if !spectrumWasPlaying { spectrumRelease.beginRise(at: now, animated: visible && !reduced) }
            spectrumRelease.show(timeline.levels(at: time), at: now)
            peakRelease.show()
        } else if spectrumWasPlaying {
            spectrumRelease.pause(at: now, animated: visible && !reduced)
            peakRelease.pause(at: now, levels: spectrumRelease.levels, animated: visible && !reduced)
        }
        if !visible || reduced, !playing { spectrumRelease.finish(); peakRelease.finish() }
        spectrumRelease.advance(to: now)
        spectrumLevels = spectrumRelease.levels; spectrumWasPlaying = playing
        if playing { spectrumPeaks.update(levels: spectrumLevels, elapsed: now - spectrumLast, reset: reduced) }
        else { peakRelease.advance(to: now) }
        spectrumLast = now
        spectrumLit.levels = spectrumLevels
        spectrumLit.peaks = spectrumPeaks.values
        spectrumLit.peakOpacities = peakRelease.opacities
        spectrumLit.needsDisplay = true
        needsDisplay = true
        if visible && (running || spectrumRelease.isReleasing || peakRelease.isReleasing) {
            if spectrumLink == nil { spectrumLink = LCDSpectrumDisplayLink { [weak self] in self?.updateSpectrum() } }
            spectrumLink?.start(reducedMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        } else { suspendSpectrum() }
    }
    private var hover = false
    private var tracking: NSTrackingArea?
    override var acceptsFirstResponder: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(spectrumIdle); addSubview(spectrumLit); addSubview(waveform)
        spectrumIdle.isHidden = true; spectrumLit.isHidden = true; waveform.isHidden = true
        setAccessibilityElement(true); setAccessibilityRole(.slider); setAccessibilityLabel("Playback position")
    }
    required init?(coder: NSCoder) { fatalError() }
    func update(trackID: String?, position: Double, duration: Double, mode: PlayerLCDMode, samples: [Float], chapters: [PlaybackChapter]) {
        if self.trackID != trackID { if scrub.proposed != nil { gestureCancelled = true }; isScrubbing = false; scrub.cancel(); onHover(nil) }
        if let trackID, self.trackID != trackID { spectrumRelease.finish(); spectrumWasPlaying = false; spectrumPeaks = PlayerSpectrumPeaks(); peakRelease.finish() }
        if abs(self.position - position) > 1 { spectrumPeaks = PlayerSpectrumPeaks() }
        self.trackID = trackID; self.position = position; self.duration = duration; self.mode = mode
        self.chapters = chapters; spectrumAnchor = ProcessInfo.processInfo.systemUptime; updateSpectrum()
        let showSpectrum = mode == .spectrum && activity == nil && (trackID != nil || spectrumRelease.isReleasing || peakRelease.isReleasing)
        spectrumIdle.isHidden = !showSpectrum; spectrumLit.isHidden = !showSpectrum
        waveform.isHidden = mode != .waveform || activity != nil
        waveform.update(samples: samples, fraction: duration > 0 ? (scrub.proposed ?? position) / duration : 0, playing: PlaybackController.shared.playing && !waveform.isHidden, scrubbing: scrub.proposed != nil)
        needsDisplay = true
        setAccessibilityValue(duration > 0 ? position / duration : 0)
    }
    override func layout() {
        super.layout()
        waveform.frame = bounds
        spectrumIdle.frame = bounds
        spectrumLit.frame = bounds
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .activeInKeyWindow], owner: self)
        addTrackingArea(area); tracking = area
    }
    private var allowsPointerInteraction: Bool { window == nil || window?.isKeyWindow == true }
    override func mouseEntered(with event: NSEvent) {
        guard allowsPointerInteraction else { return }
        hover = true; mouseMoved(with: event); needsDisplay = true
    }
    override func mouseExited(with event: NSEvent) {
        hover = false
        guard !isScrubbing else { return }
        onHover(nil); needsDisplay = true
    }
    override func mouseMoved(with event: NSEvent) {
        guard (allowsPointerInteraction || isScrubbing), duration > 0 else { onHover(nil); return }
        hoverPoint = convert(event.locationInWindow, from: nil)
        hoverX = min(max(0, hoverPoint.x), bounds.width)
        let target = min(duration, max(0, Double(hoverX / max(1, bounds.width)) * duration))
        hoverChapter = chapters.first { abs($0.time - target) / duration * bounds.width <= 6 }?.title
        onHover(target)
    }
    private func propose(_ event: NSEvent) {
        guard !gestureCancelled, duration > 0, let trackID, activity == nil else { return }
        if scrub.proposed == nil { scrub.begin(trackID: trackID, position: position) }
        let x = convert(event.locationInWindow, from: nil).x
        scrub.update(fraction: Double(x / max(1, bounds.width)), duration: duration, width: Double(bounds.width), chapters: chapters)
        onPreview(scrub.proposed); needsDisplay = true
    }
    override func mouseDown(with event: NSEvent) {
        guard duration > 0 && activity == nil else {
            superview?.mouseDown(with: event)
            return
        }
        isScrubbing = true
        mouseMoved(with: event); gestureCancelled = false; window?.makeFirstResponder(self); propose(event)
    }
    override func mouseDragged(with event: NSEvent) { mouseMoved(with: event); propose(event) }
    override func mouseUp(with event: NSEvent) {
        isScrubbing = false
        if scrub.proposed != nil {
            if let value = scrub.finish(currentTrackID: currentTrackID()) { onSeek(value) }
            onPreview(nil)
        }
        if let window {
            let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            if bounds.contains(point) {
                hoverPoint = point; hoverX = min(max(0, point.x), bounds.width)
                let target = min(duration, max(0, Double(hoverX / max(1, bounds.width)) * duration))
                onHover(target)
            } else {
                hover = false; onHover(nil)
            }
        }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            isScrubbing = false; gestureCancelled = true; scrub.cancel(); onPreview(nil); needsDisplay = true
        }
        else if event.keyCode == 123 { onSeek(position - 5) }
        else if event.keyCode == 124 { onSeek(position + 5) }
        else { super.keyDown(with: event) }
    }
    override func scrollWheel(with event: NSEvent) {
        // The LCD parent forwards scrolls here. Returning unhandled events to
        // AppKit would send them to that parent again and recurse indefinitely.
        guard allowsPointerInteraction, activity == nil, duration > 0, let trackID, event.scrollingDeltaX != 0 || scrub.proposed != nil else { return }
        if event.phase == .began || event.phase.isEmpty { gestureCancelled = false }
        guard !gestureCancelled else { return }
        if event.phase == .cancelled { scrub.cancel(); onPreview(nil); return }
        if scrub.proposed == nil { scrub.begin(trackID: trackID, position: position) }
        scrub.update(fraction: ((scrub.proposed ?? position) + Double(event.scrollingDeltaX) * 0.25) / duration, duration: duration, width: Double(bounds.width), chapters: chapters)
        onPreview(scrub.proposed)
        if event.phase.isEmpty || event.phase == .ended || event.momentumPhase == .ended {
            if let value = scrub.finish(currentTrackID: currentTrackID()) { onSeek(value) }
            onPreview(nil)
        }
    }
    override func accessibilityPerformIncrement() -> Bool { guard duration > 0 else { return false }; onSeek(position + 5); return true }
    override func accessibilityPerformDecrement() -> Bool { guard duration > 0 else { return false }; onSeek(position - 5); return true }
    override func draw(_ dirtyRect: NSRect) {}
}

/// Idle spectrum bar segments using the same under-window glass + tint shader as the sidebar.
@MainActor private final class SpectrumIdleBarsView: NSView {
    private let glass = NSVisualEffectView()
    private let tint = CALayer()
    private let tintMask = CAShapeLayer()
    private var lastSize = NSSize.zero
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        glass.material = .underWindowBackground
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.wantsLayer = true
        tint.backgroundColor = NSColor.black.withAlphaComponent(railGlassTint).cgColor
        tintMask.fillColor = NSColor.black.cgColor
        tint.mask = tintMask
        glass.layer?.addSublayer(tint)
        addSubview(glass)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() {
        super.layout()
        glass.frame = bounds
        guard bounds.size != lastSize else { return }
        lastSize = bounds.size
        guard bounds.width > 0, bounds.height > 0 else { return }
        let inset: CGFloat = 28
        let channelGap: CGFloat = 24
        let barWidth = max(0, bounds.width - channelGap - 2 * inset) / 32
        let segmentWidth = max(1, barWidth - 2)
        let path = CGMutablePath()
        for block in 0..<2 {
            for band in 0..<16 {
                let index = block * 16 + band
                let x = inset + CGFloat(index) * barWidth + CGFloat(block) * channelGap
                for segment in 0..<6 {
                    path.addRect(CGRect(x: x, y: 9 + CGFloat(segment) * 4, width: segmentWidth, height: 2))
                }
            }
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        tint.frame = bounds
        tintMask.frame = bounds
        tintMask.path = path
        CATransaction.commit()
        let mask = NSImage(size: bounds.size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return true }
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.addPath(path)
            ctx.fillPath()
            return true
        }
        glass.maskImage = mask
    }
}

@MainActor private final class SpectrumLitBarsView: NSView {
    var levels = [Float](repeating: 0, count: 32)
    var peaks = [Float](repeating: 0, count: 32)
    var peakOpacities = [Double](repeating: 0, count: 32)
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 0 else { return }
        let inset: CGFloat = 28
        let channelGap: CGFloat = 24
        let barWidth = max(0, bounds.width - channelGap - 2 * inset) / 32
        let segmentWidth = max(1, barWidth - 2)
        for block in 0..<2 {
            for band in 0..<16 {
                let index = block * 16 + band
                let x = inset + CGFloat(index) * barWidth + CGFloat(block) * channelGap
                NSColor.controlAccentColor.setFill()
                for segment in 0..<6 where Float(segment + 1) / 6 <= levels[index] {
                    NSRect(x: x, y: 9 + CGFloat(segment) * 4, width: segmentWidth, height: 2).fill()
                }
                if peakOpacities[index] > 0 {
                    NSColor.labelColor.withAlphaComponent(0.6).setFill()
                    NSRect(x: x, y: 9 + CGFloat(peaks[index]) * 24, width: segmentWidth, height: 1).fill()
                }
            }
        }
    }
}
#endif
