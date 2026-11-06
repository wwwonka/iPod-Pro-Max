#if canImport(AppKitBackend)
import AppKit
import AppKitBackend
import AVFoundation
import SwiftCrossUI

struct NativePlayerDock: NSViewRepresentable {
    func makeNSView(context: Context) -> GlassPlayerView { GlassPlayerView() }
    func updateNSView(_ view: GlassPlayerView, context: Context) {}
}

final class GlassPlayerView: NSVisualEffectView {
    private let controller = PlaybackController.shared
    private var subscription: SwiftCrossUI.Cancellable?
    private let artwork = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let artist = NSTextField(labelWithString: "")
    private let error = NSTextField(labelWithString: "")
    private let elapsed = NSTextField(labelWithString: "0:00")
    private let waveform = WaveformView()
    private let volume = NSSlider(value: 0.8, minValue: 0, maxValue: 1, target: nil, action: nil)
    private var buttons: [NSButton] = []
    private var trackID: String?
    private var artTask: Task<Void, Never>?
    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .popover; blendingMode = .withinWindow; state = .followsWindowActiveState
        wantsLayer = true
        layer?.cornerRadius = 22
        layer?.borderWidth = 0.5
        layer?.masksToBounds = true
        artwork.wantsLayer = true; artwork.layer?.cornerRadius = 10; artwork.layer?.masksToBounds = true
        artwork.imageScaling = .scaleProportionallyUpOrDown
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        artist.font = .systemFont(ofSize: 13); artist.textColor = .secondaryLabelColor
        for field in [title, artist, error] { field.lineBreakMode = .byTruncatingTail }
        error.font = .systemFont(ofSize: 11); error.textColor = .systemRed
        elapsed.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular); elapsed.textColor = .secondaryLabelColor
        let definitions: [(String, String, Selector)] = [
            ("shuffle", "Shuffle", #selector(shuffle)), ("backward.end.fill", "Previous", #selector(previous)),
            ("play.fill", "Play or pause", #selector(toggle)), ("forward.end.fill", "Next", #selector(next)),
            ("repeat", "Repeat", #selector(repeatPlayback)), ("xmark", "Close player", #selector(closePlayer))]
        for (symbol, label, action) in definitions {
            let button = NSButton(title: "", target: self, action: action)
            button.image = systemSymbol(symbol, pointSize: symbol == "play.fill" ? 27 : 19)
            if button.image == nil { button.title = label }
            button.isBordered = false; button.toolTip = label; button.setAccessibilityLabel(label)
            buttons.append(button); addSubview(button)
        }
        volume.target = self; volume.action = #selector(changeVolume)
        volume.setAccessibilityLabel("Volume")
        waveform.onSeek = { [weak self] fraction in
            guard let self else { return }; self.controller.seek(fraction * self.controller.duration)
        }
        for view in [artwork, title, artist, error, elapsed, waveform, volume] { addSubview(view) }
        subscription = controller.didChange.observe { [weak self] in self?.refresh() }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let movement = CABasicAnimation(keyPath: "transform.translation.y")
        movement.fromValue = -12; movement.toValue = 0; movement.duration = 0.2
        movement.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
        layer?.add(movement, forKey: "playerEntrance")
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0; fade.toValue = 1; fade.duration = 0.16
        layer?.add(fade, forKey: "playerFade")
    }
    private func refresh() {
        if controller.track == nil {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.18
                animator().alphaValue = 0
            }
            return
        }
        alphaValue = 1
        title.stringValue = controller.track?.title ?? ""
        artist.stringValue = controller.track?.artist ?? ""
        error.stringValue = controller.error
        waveform.isHidden = !controller.error.isEmpty
        elapsed.stringValue = String(format: "%d:%02d", Int(controller.position) / 60, Int(controller.position) % 60)
        waveform.progress = controller.duration > 0 ? controller.position / controller.duration : 0
        if !waveform.samples.sameStorage(as: controller.samples) { waveform.samples = controller.samples }
        buttons[2].image = systemSymbol(controller.playing ? "pause.fill" : "play.fill", pointSize: 27)
        buttons[2].setAccessibilityLabel(controller.playing ? "Pause" : "Play")
        buttons[0].setAccessibilityValue(controller.shuffled ? "On" : "Off")
        buttons[4].setAccessibilityValue(controller.repeatMode == .off ? "Off" : controller.repeatMode == .one ? "One track" : "All tracks")
        buttons[0].contentTintColor = controller.shuffled ? .controlAccentColor : .labelColor
        buttons[4].image = systemSymbol(controller.repeatMode == .one ? "repeat.1" : "repeat", pointSize: 19)
        buttons[4].contentTintColor = controller.repeatMode == .off ? .labelColor : .controlAccentColor
        volume.doubleValue = controller.volume
        layer?.borderColor = NSColor.separatorColor.cgColor
        guard trackID != controller.track?.id else { return }
        trackID = controller.track?.id
        artTask?.cancel(); artwork.image = systemSymbol("music.note", pointSize: 32)
        let id = trackID
        if let key = controller.track?.artworkKey, let folder = PlayerArtwork.folder {
            artTask = Task { [weak self] in
                let image = await ThumbnailStore.shared.image(folder.appendingPathComponent(key + ".jpg"), pixels: 144)
                guard !Task.isCancelled, self?.trackID == id else { return }
                if let image { self?.artwork.image = image }
            }
        }
    }
    override func layout() {
        super.layout()
        let w = bounds.width
        let compact = w < 760
        artwork.frame = NSRect(x: 16, y: 16, width: 68, height: 68)
        let textWidth = compact ? max(64, min(120, w * 0.22)) : max(80, min(240, w * 0.24))
        title.frame = NSRect(x: 100, y: 56, width: textWidth, height: 21)
        artist.frame = NSRect(x: 100, y: 34, width: textWidth, height: 18)
        error.frame = NSRect(x: 100, y: 14, width: max(0, w - 150), height: 16)
        let controlsX = compact ? max(230, w - 250) : max(200, (w - 216) / 2)
        for i in 0..<5 { buttons[i].frame = NSRect(x: controlsX + CGFloat(i) * 42, y: 36, width: 38, height: 40) }
        buttons[5].frame = NSRect(x: w - 30, y: 68, width: 22, height: 22)
        waveform.isHidden = !controller.error.isEmpty
        volume.isHidden = compact
        elapsed.isHidden = compact
        waveform.frame = compact
            ? NSRect(x: 100, y: 8, width: max(0, w - 140), height: 16)
            : NSRect(x: controlsX + 226, y: 40, width: max(0, w - controlsX - 380), height: 36)
        volume.frame = NSRect(x: w - 130, y: 47, width: 100, height: 20)
        elapsed.frame = NSRect(x: controlsX + 226, y: 23, width: 60, height: 13)
    }
    @objc private func toggle() { controller.toggle() }
    @objc private func next() { controller.next() }
    @objc private func previous() { controller.previous() }
    @objc private func shuffle() { controller.toggleShuffle() }
    @objc private func repeatPlayback() { controller.cycleRepeat() }
    @objc private func changeVolume() { controller.setVolume(volume.doubleValue) }
    @objc private func closePlayer() { controller.close() }
}


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
