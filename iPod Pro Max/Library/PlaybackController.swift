import Foundation
import SwiftCrossUI
import MediaKit

@MainActor protocol AudioEngine: AnyObject {
    var onProgress: ((Double, Double) -> Void)? { get set }
    var onEnd: (() -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }
    func load(_ url: URL)
    func play()
    func pause()
    func seek(_ seconds: Double)
    func setVolume(_ volume: Double)
    func setVisible(_ visible: Bool)
    func stop()
}

/// Only the player subtree observes this object. Time updates never invalidate library state.
@MainActor final class PlaybackController: SwiftCrossUI.ObservableObject {
    static let shared = PlaybackController()
    @SwiftCrossUI.Published private(set) var track: TrackRow?
    @SwiftCrossUI.Published private(set) var playing = false
    @SwiftCrossUI.Published private(set) var position = 0.0
    @SwiftCrossUI.Published private(set) var duration = 0.0
    @SwiftCrossUI.Published private(set) var volume = 0.8
    @SwiftCrossUI.Published private(set) var shuffled = false
    @SwiftCrossUI.Published private(set) var repeatMode: PlaybackQueue.RepeatMode = .off
    @SwiftCrossUI.Published private(set) var error = ""
    @SwiftCrossUI.Published private(set) var samples: [Float] = []
    var onPresenceChanged: ((Bool) -> Void)?
    private var engineStorage: AudioEngine?
    private var visible = true
    private var engine: AudioEngine {
        if let engineStorage { return engineStorage }
        let created = PlatformAudioEngine()
        configure(created)
        created.setVisible(visible)
        return created
    }
    private var queue = PlaybackQueue()
    private var rows: [String: TrackRow] = [:]
    private var generation = 0
    private var analysis: Task<Void, Never>?

    private init() {}
    init(engine: AudioEngine) { configure(engine) }
    private func configure(_ engine: AudioEngine) {
        engineStorage = engine
        engine.onProgress = { [weak self] position, duration in
            guard let self, self.track != nil else { return }
            self.position = max(0, position.isFinite ? position : 0)
            self.duration = max(0, duration.isFinite ? duration : 0)
        }
        engine.onEnd = { [weak self] in self?.next(automatic: true) }
        engine.onError = { [weak self] message in
            guard let self else { return }
            self.engine.stop(); self.playing = false; self.error = message
        }
        engine.setVolume(volume)
    }
    func start(_ track: TrackRow, in displayed: [TrackRow]) {
        rows = Dictionary(displayed.filter { $0.path != nil }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard rows[track.id] != nil else { return }
        queue.start(ids: displayed.filter { $0.path != nil }.map(\.id), at: track.id)
        load(track)
    }
    private func load(_ row: TrackRow) {
        guard let path = row.path else { return }
        generation += 1
        let revision = generation
        analysis?.cancel()
        engine.stop()
        track = row; position = 0; duration = 0; error = ""; samples = []; playing = true
        onPresenceChanged?(true)
        engine.load(URL(fileURLWithPath: path))
        guard error.isEmpty else { return }
        engine.setVolume(volume)
        engine.play()
        analysis = Task { [weak self] in
            let peaks = await AudioWaveform.samples(URL(fileURLWithPath: path))
            guard !Task.isCancelled, let self, revision == self.generation else { return }
            self.samples = peaks
        }
    }
    func toggle() {
        guard track != nil else { return }
        if !error.isEmpty, let track { load(track); return }
        if !playing, duration > 0, position >= duration { seek(0) }
        playing.toggle()
        if playing { engine.play() } else { engine.pause() }
    }
    func next(automatic: Bool = false) {
        guard let id = queue.next(automatic: automatic), let row = rows[id] else {
            engine.pause(); playing = false
            if automatic { position = duration }
            return
        }
        load(row)
    }
    func previous() {
        if position > 3 { seek(0); return }
        if let id = queue.previous(), let row = rows[id] { load(row) }
    }
    func seek(_ seconds: Double) {
        let value = min(max(0, seconds), duration)
        position = value; engine.seek(value)
    }
    func setVolume(_ value: Double) { volume = min(1, max(0, value)); engine.setVolume(volume) }
    func toggleShuffle() { shuffled.toggle(); queue.setShuffled(shuffled) }
    func cycleRepeat() {
        repeatMode = PlaybackQueue.RepeatMode(rawValue: (repeatMode.rawValue + 1) % 3)!
        queue.repeatMode = repeatMode
    }
    func setVisible(_ visible: Bool) { self.visible = visible; engineStorage?.setVisible(visible) }
    func close() {
        generation += 1; analysis?.cancel(); analysis = nil
        engineStorage?.stop(); engineStorage = nil; queue.clear(); rows = [:]
        track = nil; playing = false; samples = []; position = 0; duration = 0; error = ""
        onPresenceChanged?(false)
    }
}
