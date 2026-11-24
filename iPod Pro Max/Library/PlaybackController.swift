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
    private(set) var queueRows: [TrackRow] = []
    var onQueueReset: (() -> Void)?
    var onEnqueue: (([TrackRow]) -> Void)?
    var startSelection: ((TrackRow, [TrackRow]) -> Void)?
    var libraryRowsProvider: ([String]) -> [TrackRow] = { _ in [] }
    var onPresenceChanged: ((Bool) -> Void)?
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
    private var pendingSeek: Double?
    private var anchorTime = ProcessInfo.processInfo.systemUptime
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
    private func configureSessionCommands() {
        session?.onCommand = { [weak self] command in
            guard let self, self.track != nil else { return }
            if ProcessInfo.processInfo.environment["IPPM_PLAYER_QA"] != nil { log("[media QA] command: \(command)") }
            switch command {
            case .play: self.setPlaying(true)
            case .pause: self.setPlaying(false)
            case .toggle: self.toggle()
            case .next: self.next()
            case .previous: self.previous()
            case .seek(let value): self.seek(value)
            case .skip(let amount): self.seek(self.exactPosition + amount)
            }
        }
    }
    var exactPosition: Double {
        if let pendingSeek { return min(duration, pendingSeek + (playing ? (ProcessInfo.processInfo.systemUptime - anchorTime) * rate : 0)) }
        if let current = engineStorage?.currentPosition, current.isFinite { return max(0, current) }
        return min(duration, position + (playing ? (ProcessInfo.processInfo.systemUptime - anchorTime) * rate : 0))
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
        if track == nil { if let startSelection { startSelection(first, valid) } else { start(first, in: valid) }; return }
        onEnqueue?(valid)
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
        guard let track, track.playbackKind != .music, [0.75, 1, 1.25, 1.5, 2].contains(value) else { return }
        position = exactPosition; anchorTime = ProcessInfo.processInfo.systemUptime
        rate = value; spokenRates[track.playbackKind] = value; engineStorage?.setRate(value); publishSession()
    }
    private func configure(_ engine: AudioEngine) {
        engineStorage = engine
        engine.onProgress = { [weak self] position, duration in
            guard let self, self.track != nil else { return }
            let oldDuration = self.duration
            if self.pendingSeek == nil {
                self.position = max(0, position.isFinite ? position : 0)
                self.anchorTime = ProcessInfo.processInfo.systemUptime
            }
            self.duration = max(0, duration.isFinite ? duration : 0)
            if oldDuration == 0, self.duration > 0 { self.publishSession() }
        }
        engine.onPlaybackState = { [weak self] playing in
            guard let self, self.track != nil, self.playing != playing else { return }
            self.position = self.exactPosition; self.anchorTime = ProcessInfo.processInfo.systemUptime
            self.playing = playing; self.publishSession()
        }
        engine.onEnd = { [weak self] in self?.next(automatic: true) }
        engine.onError = { [weak self] message in
            guard let self else { return }
            self.engine.stop(); self.playing = false; self.error = message; self.publishSession()
        }
        engine.setVolume(volume)
    }
    func start(_ track: TrackRow, in displayed: [TrackRow]) {
        onQueueReset?(); onEnqueue?(displayed)
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
        pendingSeek = nil
        track = row; position = 0; duration = 0; error = ""; samples = []; playing = true
        anchorTime = ProcessInfo.processInfo.systemUptime
        rate = row.playbackKind == .music ? 1 : (spokenRates[row.playbackKind] ?? 1)
        refreshQueue()
        onPresenceChanged?(true)
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
        if !playing, duration > 0, position >= duration { seek(0) }
        setPlaying(!playing)
    }
    func setPlaying(_ value: Bool) {
        guard track != nil else { return }
        if value && !error.isEmpty, let track { load(track); return }
        guard playing != value else { return }
        position = exactPosition; anchorTime = ProcessInfo.processInfo.systemUptime; playing = value
        if playing { engine.play() } else { engine.pause() }
        publishSession()
    }
    func next(automatic: Bool = false) {
        guard let id = queue.next(automatic: automatic), let row = rows[id] else {
            #if canImport(AppKitBackend)
            close()
            #else
            engine.pause(); playing = false
            if automatic { position = duration }
            #endif
            return
        }
        load(row)
    }
    func previous() {
        if exactPosition > 3 { seek(0); return }
        if let id = queue.previous(), let row = rows[id] { load(row) }
    }
    func seek(_ seconds: Double) {
        guard seconds.isFinite, track != nil else { return }
        let value = min(max(0, seconds), duration)
        pendingSeek = value; position = value; anchorTime = ProcessInfo.processInfo.systemUptime
        let revision = generation
        publishSession(positionOverride: value)
        engine.seek(value) { [weak self] in
            guard let self, self.generation == revision, self.pendingSeek == value else { return }
            self.pendingSeek = nil; self.position = value; self.anchorTime = ProcessInfo.processInfo.systemUptime
            self.publishSession(positionOverride: value)
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
        onQueueReset?()
        pendingSeek = nil
        generation += 1; analysis?.cancel(); analysis = nil
        engineStorage?.stop(); engineStorage = nil; queue.clear(); rows = [:]
        track = nil; playing = false; samples = []; position = 0; duration = 0; error = ""
        refreshQueue(); publishSession()
        onPresenceChanged?(false)
    }
}
