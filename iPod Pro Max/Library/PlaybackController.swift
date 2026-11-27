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
    func seek(_ seconds: Double, completion: @escaping () -> Void)
    func setVolume(_ volume: Double)
    func setVisible(_ visible: Bool)
    func stop()
    func setRate(_ rate: Double)
    var currentPosition: Double? { get }
    var onPlaybackState: ((Bool) -> Void)? { get set }
}
extension AudioEngine {
    func seek(_ seconds: Double, completion: @escaping () -> Void) { seek(seconds); completion() }
    func setRate(_ rate: Double) {}
    var currentPosition: Double? { nil }
    var onPlaybackState: ((Bool) -> Void)? { get { nil } set {} }
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
    @SwiftCrossUI.Published private(set) var rate = 1.0
    @SwiftCrossUI.Published private(set) var queueRevision = 0
    private(set) var transportAnimationNonce = 0
    private(set) var queueRows: [TrackRow] = []
    /// What the controller needs from the app, set once at launch: the only seam to the rest of it.
    struct Host {
        /// The queue was replaced or emptied.
        var didReset: () -> Void = {}
        /// Rows entered the queue (to remember where playback came from).
        var didEnqueue: ([TrackRow]) -> Void = { _ in }
        /// Starts playback from a selection the way the app does (nil: `start(_:in:)`).
        var startSelection: ((TrackRow, [TrackRow]) -> Void)?
        /// Library rows for track IDs dropped on the queue.
        var rows: ([String]) -> [TrackRow] = { _ in [] }
        /// A track started (true) or playback closed (false).
        var presenceChanged: (Bool) -> Void = { _ in }
    }
    var host = Host()
    private var engineStorage: AudioEngine?
    var activeEngine: AudioEngine? { engineStorage }
    private var session: (any MediaSession)?
    private var sessionFactory: @MainActor () -> any MediaSession = {
        #if os(macOS)
        if ProcessInfo.processInfo.environment["IPPM_PLAYER_QA"] != nil || (ProcessInfo.processInfo.environment["IPPM_PLAYER_PREVIEW"] == nil && ProcessInfo.processInfo.environment["IPPM_CHECK_PLAYER"] == nil) { return MacMediaSession() }
        #endif
        return SimulatedMediaSession()
    }
    private var spokenRates: [PlaybackContentKind: Double] = [:]
    private var replacingTrack = false
    /// Position, duration, rate and pending seek (shared, tested in MediaKit); the published
    /// fields above mirror it for the views.
    private var clock = PlaybackClock()
    private var now: Double { ProcessInfo.processInfo.systemUptime }
    private func publishClock() {
        if position != clock.position { position = clock.position }
        if duration != clock.duration { duration = clock.duration }
        if rate != clock.rate { rate = clock.rate }
        if playing != clock.playing { playing = clock.playing }
    }
    private var visible = true
    private var unmutedVolume = 0.8
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
    init(engine: AudioEngine, session: (any MediaSession)? = nil) {
        self.session = session; sessionFactory = { SimulatedMediaSession() }
        configure(engine); configureSessionCommands()
    }
    func requestTransportAnimation() { transportAnimationNonce += 1 }
    private func configureSessionCommands() {
        session?.onCommand = { [weak self] command in
            guard let self, self.track != nil else { return }
            if ProcessInfo.processInfo.environment["IPPM_PLAYER_QA"] != nil { log("[media QA] command: \(command)") }
            switch command {
            case .play: self.requestTransportAnimation(); self.setPlaying(true)
            case .pause: self.requestTransportAnimation(); self.setPlaying(false)
            case .toggle: self.requestTransportAnimation(); self.toggle()
            case .next: self.next()
            case .previous: self.previous()
            case .seek(let value): self.seek(value)
            case .skip(let amount): self.seek(self.exactPosition + amount)
            }
        }
    }
    var exactPosition: Double {
        clock.current(at: now, enginePosition: engineStorage?.currentPosition)
    }
    private func publishSession(positionOverride: Double? = nil) {
        if session == nil, track != nil { session = sessionFactory(); configureSessionCommands() }
        guard let session else { return }
        guard let track else { session.publish(MediaSessionState()); return }
        let artwork = track.artworkKey.flatMap { key in PlayerArtwork.folder?.appendingPathComponent(key + ".jpg") }
        session.publish(MediaSessionState(title: track.playbackTitle ?? track.title, artist: track.artist, album: track.album,
            artworkURL: artwork, duration: duration, position: positionOverride ?? exactPosition, rate: rate,
            status: playing ? .playing : .paused, canPrevious: true, canNext: queue.canGoNext, spoken: track.playbackKind != .music))
    }
    private func refreshQueue() {
        queueRows = queue.currentAndUpcoming.compactMap { rows[$0] }
        queueRevision += 1
    }
    func enqueue(_ incoming: [TrackRow], next: Bool = false, at insertion: Int? = nil) {
        let valid = incoming.filter { $0.path != nil }
        guard let first = valid.first else { return }
        if track == nil { if let start = host.startSelection { start(first, valid) } else { start(first, in: valid) }; return }
        host.didEnqueue(valid)
        for row in valid { rows[row.id] = row }
        if let insertion { queue.insert(valid.map(\.id), at: insertion) }
        else if next { queue.insert(valid.map(\.id), at: 0) }
        else { queue.append(valid.map(\.id)) }
        refreshQueue(); publishSession()
    }
    func jump(to id: String) { guard queue.jump(to: id), let row = rows[id] else { return }; load(row) }
    func removeFromQueue(_ ids: Set<String>) { queue.remove(ids); refreshQueue(); publishSession() }
    func moveInQueue(_ ids: [String], to index: Int) { queue.move(ids, to: index); refreshQueue(); publishSession() }
    func moveInQueue(_ id: String, to index: Int) { moveInQueue([id], to: index) }
    func clearUpcoming() { queue.clearUpcoming(); refreshQueue(); publishSession() }
    func setRepeat(_ mode: PlaybackQueue.RepeatMode) { repeatMode = mode; queue.repeatMode = mode; publishSession() }
    func setRate(_ value: Double) {
        guard let track, PlaybackRules.canSetRate(value, spoken: track.playbackKind != .music) else { return }
        clock.setRate(value, at: now, enginePosition: engineStorage?.currentPosition); publishClock()
        spokenRates[track.playbackKind] = value; engineStorage?.setRate(value); publishSession()
    }
    private func configure(_ engine: AudioEngine) {
        engineStorage = engine
        engine.onProgress = { [weak self] position, duration in
            guard let self, self.track != nil else { return }
            let durationKnown = self.clock.progress(position: position, duration: duration, at: self.now)
            self.publishClock()
            if durationKnown { self.publishSession() }
        }
        engine.onPlaybackState = { [weak self] playing in
            guard let self, !self.replacingTrack, self.track != nil, self.playing != playing else { return }
            self.clock.setPlaying(playing, at: self.now, enginePosition: self.engineStorage?.currentPosition)
            self.publishClock(); self.publishSession()
        }
        engine.onEnd = { [weak self] in self?.next(automatic: true) }
        engine.onError = { [weak self] message in
            guard let self else { return }
            self.engine.stop(); self.clock.stop(); self.publishClock(); self.error = message; self.publishSession()
        }
        engine.setVolume(volume)
    }
    func start(_ track: TrackRow, in displayed: [TrackRow]) {
        host.didReset(); host.didEnqueue(displayed)
        rows = Dictionary(displayed.filter { $0.path != nil }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard rows[track.id] != nil else { return }
        queue.start(ids: displayed.filter { $0.path != nil }.map(\.id), at: track.id)
        load(track)
    }
    private func load(_ row: TrackRow) {
        guard let path = row.path else { return }
        replacingTrack = true
        defer { replacingTrack = false }
        generation += 1
        let revision = generation
        analysis?.cancel()
        engine.stop()
        clock.load(rate: row.playbackKind == .music ? 1 : (spokenRates[row.playbackKind] ?? 1), at: now)
        track = row; error = ""; samples = []; publishClock()
        refreshQueue()
        host.presenceChanged(true)
        engine.load(URL(fileURLWithPath: path))
        guard error.isEmpty else { return }
        engine.setVolume(volume)
        engine.setRate(rate); engine.play(); publishSession()
        analysis = Task { [weak self] in
            #if os(macOS)
            let result = await AudioAnalysis.read(URL(fileURLWithPath: path), onSpectrum: { [weak self] spectrum in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == revision else { return }
                    PlayerDisplayController.shared.setSpectrum(spectrum, forTrackID: row.id)
                }
            })
            guard !Task.isCancelled, let self, revision == self.generation else { return }
            self.samples = result.samples
            if let spectrum = result.spectrum { PlayerDisplayController.shared.setSpectrum(spectrum, forTrackID: row.id) }
            #else
            let peaks = await AudioWaveform.samples(URL(fileURLWithPath: path))
            guard !Task.isCancelled, let self, revision == self.generation else { return }
            self.samples = peaks
            #endif
        }
    }
    func toggle() {
        guard track != nil else { return }
        if !error.isEmpty, let track { load(track); return }
        if !playing, clock.atEnd { seek(0) }
        setPlaying(!playing)
    }
    func setPlaying(_ value: Bool) {
        guard track != nil else { return }
        if value && !error.isEmpty, let track { load(track); return }
        guard playing != value else { return }
        clock.setPlaying(value, at: now, enginePosition: engineStorage?.currentPosition); publishClock()
        if playing { engine.play() } else { engine.pause() }
        publishSession()
    }
    func next(automatic: Bool = false) {
        guard let id = queue.next(automatic: automatic), let row = rows[id] else {
            #if canImport(AppKitBackend)
            close()
            #else
            engine.pause()
            if automatic { clock.finish() } else { clock.stop() }
            publishClock()
            #endif
            return
        }
        load(row)
    }
    func previous() {
        if PlaybackRules.previousRestarts(position: exactPosition) { seek(0); return }
        if let id = queue.previous(), let row = rows[id] { load(row) }
    }
    func seek(_ seconds: Double) {
        guard seconds.isFinite, track != nil else { return }
        let value = clock.beginSeek(to: seconds, at: now); publishClock()
        let revision = generation
        publishSession(positionOverride: value)
        engine.seek(value) { [weak self] in
            guard let self, self.generation == revision, self.clock.completeSeek(value, at: self.now) else { return }
            self.publishClock(); self.publishSession(positionOverride: value)
        }
    }
    func setVolume(_ value: Double) {
        guard value.isFinite else { return }
        volume = min(1, max(0, value))
        if volume > 0 { unmutedVolume = volume }
        engineStorage?.setVolume(volume)
    }
    func toggleMute() { setVolume(volume > 0 ? 0 : unmutedVolume) }
    func toggleShuffle() { shuffled.toggle(); queue.setShuffled(shuffled); refreshQueue(); publishSession() }
    func cycleRepeat() {
        repeatMode = PlaybackQueue.RepeatMode(rawValue: (repeatMode.rawValue + 1) % 3)!
        queue.repeatMode = repeatMode; publishSession()
    }
    func setVisible(_ visible: Bool) { self.visible = visible; engineStorage?.setVisible(visible) }
    func removeTracks(ids removed: Set<String>) {
        guard !removed.isEmpty else { return }
        for id in removed { rows.removeValue(forKey: id) }
        let removedCurrent = track.map { removed.contains($0.id) } ?? false
        queue.remove(ids: removed)
        if removedCurrent {
            if let nextID = queue.current, let nextRow = rows[nextID] {
                load(nextRow)
                return
            } else {
                close()
                return
            }
        }
        refreshQueue(); publishSession()
    }
    /// Also lets controlled checks wait for the current derived data without stopping playback.
    func waitForAnalysis() async { await analysis?.value }

    func prepareForExit() async {
        let pending = analysis; close(); await pending?.value
    }
    func close() {
        host.didReset()
        clock.reset()
        generation += 1; analysis?.cancel(); analysis = nil
        engineStorage?.stop(); engineStorage = nil; queue.clear(); rows = [:]
        track = nil; samples = []; publishClock(); error = ""
        refreshQueue(); publishSession()
        host.presenceChanged(false)
    }
}
