import Foundation
import SwiftCrossUI
import MediaKit
import iPodKit

/// Portable presentation state. No drawing, network calls or repeating deadlines.
@MainActor final class PlayerDisplayController {
    static let shared = PlayerDisplayController()
    private(set) var mode: PlayerLCDMode = .title
    private(set) var showsRemaining = true
    private(set) var lyrics: [TimedLyric] = []
    private(set) var chapters: [PlaybackChapter] = []
    private(set) var spectrum: PlayerSpectrum?
    func setSpectrum(_ value: PlayerSpectrum, forTrackID id: String) {
        guard trackID == id, value.frames.count >= (spectrum?.frames.count ?? 0) else { return }
        spectrum = value; onChange()
    }
    private(set) var lyricIndex: Int?
    var idleDetail = "" { didSet { if idleDetail != oldValue { onChange() } } }
    var onChange: () -> Void = {}
    var onReveal: ((String) -> Void)?
    private var sources: [String: (String) -> Void] = [:]
    func clearSources() { sources.removeAll(); onReveal = nil }
    func registerSource(_ ids: [String], action: @escaping (String) -> Void) {
        for id in ids { sources[id] = action }
        onReveal = { [weak self] id in self?.sources[id]?(id) }
    }
    var onFavorite: ((String, Bool) -> Void)?
    var favoriteValue: (String) -> Bool? = { _ in nil }
    var canReveal: (String) -> Bool = { _ in false }
    private var store: PortableLibraryStore?
    private var trackID: String?
    private var detailsTask: Task<Void, Never>?
    private var lyricDeadline: Task<Void, Never>?
    private var lyricDue: Double?
    private var playbackToken: SwiftCrossUI.Cancellable?
    private var activityToken: SwiftCrossUI.Cancellable?
    private var lastPosition = 0.0
    private var lastRate = 1.0
    private(set) var jumpedLastRefresh = false
    private var visible = true
    private var idleDeviceID: String?
    private var idleTask: Task<Void, Never>?
    func setIdleDevices(_ devices: [IPodDevice], selectedID: String?) {
        setIdleDevice(devices.first { $0.id == (selectedID ?? idleDeviceID) } ?? devices.first)
    }
    private func setIdleDevice(_ device: IPodDevice?) {
        guard idleDeviceID != device?.id else { return }
        idleDeviceID = device?.id; idleTask?.cancel()
        idleDetail = ""
        guard let device else { return }
        idleTask = Task { [weak self] in
            let free = await Task.detached(priority: .utility) { device.volumeStats().free }.value
            guard !Task.isCancelled, let self, self.idleDeviceID == device.id else { return }
            self.idleDetail = ByteCountFormatter.string(fromByteCount: free, countStyle: .file) + " free"
        }
    }
    init() {
        playbackToken = PlaybackController.shared.didChange.observe { [weak self] in self?.refresh() }
        activityToken = PlayerActivityController.shared.didChange.observe { [weak self] in self?.onChange() }
    }
    var resolvedMode: PlayerLCDMode { mode.resolved(hasLyrics: !lyrics.isEmpty) }
    func load(_ settings: PortableSettings?, store: PortableLibraryStore) {
        self.store = store
        mode = PlayerLCDMode(rawValue: settings?.playerLCDMode ?? "title") ?? .title
        showsRemaining = settings?.playerShowsRemaining ?? true
        onChange()
    }
    func choose(_ mode: PlayerLCDMode) { self.mode = mode; persist(); refresh() }
    func cycle() { guard PlaybackController.shared.track != nil else { return }; choose(mode.next(hasLyrics: !lyrics.isEmpty)) }
    func toggleTime() { showsRemaining.toggle(); persist(); onChange() }
    private func persist() {
        if let store { PortablePreferences.shared.stagePlayer(mode: mode.rawValue, remaining: showsRemaining, store: store) }
    }
    func setVisible(_ value: Bool) { visible = value; refresh() }
    func refresh() {
        let playback = PlaybackController.shared
        if trackID != playback.track?.id {
            trackID = playback.track?.id; lyrics = []; chapters = []; lyricIndex = nil; spectrum = nil
            detailsTask?.cancel(); lyricDeadline?.cancel(); lyricDue = nil
            if let track = playback.track {
                let id = track.id
                let worker = Task.detached(priority: .utility) { () -> ([TimedLyric], [PlaybackChapter]) in
                    var lines = SynchronizedLyrics.parse(track.lyrics)
                    var chapters: [PlaybackChapter] = []
                    #if os(macOS)
                    if let path = track.path {
                        let details = PlaybackDetails.read(URL(fileURLWithPath: path), needsLyrics: lines.isEmpty)
                        if lines.isEmpty { lines = SynchronizedLyrics.parse(details.lyrics) }
                        chapters = details.chapters
                    }
                    #endif
                    return (lines, chapters)
                }
                detailsTask = Task { [weak self] in
                    let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
                    guard !Task.isCancelled, let self, self.trackID == id else { return }
                    self.lyrics = result.0; self.chapters = result.1; self.refresh()
                }
            }
        }
        lyricIndex = SynchronizedLyrics.index(at: playback.position, in: lyrics)
        let next = (lyricIndex.map { $0 + 1 } ?? 0)
        let due = next < lyrics.count ? lyrics[next].time : nil
        let jumped = abs(playback.position - lastPosition) > 1
        jumpedLastRefresh = jumped
        lastPosition = playback.position
        let rateChanged = lastRate != playback.rate; lastRate = playback.rate
        if rateChanged || due != lyricDue || !playback.playing || !visible || resolvedMode != .lyrics || jumped {
            lyricDeadline?.cancel(); lyricDeadline = nil; lyricDue = nil
            if playback.playing, visible, resolvedMode == .lyrics, let due {
                lyricDue = due
                let delay = max(0.001, (due - playback.position) / playback.rate)
                lyricDeadline = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(min(delay, 86400) * 1_000_000_000))
                    guard !Task.isCancelled, let self else { return }
                    self.lyricIndex = next
                    self.lyricDue = nil
                    self.onChange()
                    // The next engine position event schedules the following line.
                }
            }
        }
        onChange()
    }
}
