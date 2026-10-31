import Foundation
import iPodKit
import MediaKit

/// The podcast subscriptions of the launching iPod: subscribing, refreshing, downloading, and saving
/// `podcasts.json`. Event-driven only; work runs off the main actor and results are published in
/// batches (the view re-renders on `onChange`, so download progress is throttled).
@MainActor
final class PodcastController {
    static let shared = PodcastController()

    private(set) var shows: [PodcastShow] = []
    private(set) var refreshing: Set<UUID> = []
    private(set) var progress: [UUID: Double] = [:]
    var onChange: () -> Void = {}
    var onError: (String) -> Void = { _ in }
    var onStatus: (String) -> Void = { _ in }

    private var store: PortableLibraryStore?
    private var downloads: [UUID: Task<Void, Never>] = [:]
    private var saveTask: Task<Void, Never>?
    private var saveChain: Task<Void, Error>?
    private var dirty = false
    /// Bumped by changes to the shows' content, not by download progress: the episode list rebuilds on this.
    private(set) var contentRevision = 0

    /// The cover file of a show, nil until it has been downloaded.
    func artworkURL(for show: PodcastShow) -> URL? {
        guard let key = show.artworkKey, let store else { return nil }
        return store.artwork.appendingPathComponent("\(key).jpg")
    }

    func show(id: UUID) -> PodcastShow? { shows.first { $0.id == id } }
    func isDownloading(_ episodeID: UUID) -> Bool { downloads[episodeID] != nil }

    private var countRevision = -1
    private var downloadedCounts: [UUID: Int] = [:]
    private var wantedEpisodes: [UUID: [PodcastEpisode]] = [:]

    private func validateCounts() {
        guard countRevision != contentRevision else { return }
        countRevision = contentRevision
        downloadedCounts.removeAll(keepingCapacity: true)
        wantedEpisodes.removeAll(keepingCapacity: true)
    }
    func downloadedCount(for show: PodcastShow) -> Int {
        validateCounts()
        if let count = downloadedCounts[show.id] { return count }
        let count = show.episodes.reduce(0) { $0 + ($1.isDownloaded ? 1 : 0) }
        downloadedCounts[show.id] = count
        return count
    }
    func pendingDownloadCount(for show: PodcastShow) -> Int {
        validateCounts()
        let episodes: [PodcastEpisode]
        if let cached = wantedEpisodes[show.id] { episodes = cached }
        else { episodes = show.episodesToSync(); wantedEpisodes[show.id] = episodes }
        return episodes.reduce(0) { $0 + (!$1.isDownloaded && downloads[$1.id] == nil ? 1 : 0) }
    }

    /// Episodes the sync rules want that aren't on this computer yet.
    var pendingDownloads: [(show: PodcastShow, episode: PodcastEpisode)] {
        shows.flatMap { show in show.episodesToSync().filter { !$0.isDownloaded && downloads[$0.id] == nil }.map { (show, $0) } }
    }

    func load(store: PortableLibraryStore) async {
        self.store = store
        do {
            let loaded = try await Task.detached(priority: .userInitiated) { try store.loadPodcasts() }.value
            shows = loaded
            contentRevision &+= 1
            onChange()
        } catch { onError("Couldn't read the podcasts: \(error.localizedDescription)") }
    }

    // MARK: Subscriptions

    @discardableResult
    func subscribe(feedURL: URL) async throws -> PodcastShow {
        guard let store else { throw IPodDBError.io("Launch the app from the iPod to subscribe to podcasts.") }
        if let existing = shows.first(where: { $0.feedURL == feedURL }) { return existing }
        let kind = PodcastSources.kind(for: feedURL)
        let feed = try await PodcastSources.fetchFeed(feedURL, kind: kind)
        var show = PodcastShow(feedURL: feedURL, title: feed.title, author: feed.author, summary: feed.summary, imageURL: feed.imageURL)
        show.sourceKind = kind
        show = PodcastSources.merge(feed, into: show)
        if let image = feed.imageURL { show.artworkKey = await PodcastSources.downloadArtwork(image, into: store.artwork) }
        guard !shows.contains(where: { $0.feedURL == feedURL }) else { return show }
        shows.append(show)
        changed()
        return show
    }

    func unsubscribe(showID: UUID) {
        guard let show = show(id: showID), let store else { return }
        for episode in show.episodes { downloads[episode.id]?.cancel() }
        let folder = store.downloadDirectory(for: show)
        Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: folder) }
        shows.removeAll { $0.id == showID }
        changed()
    }

    func update(_ show: PodcastShow) {
        guard let i = shows.firstIndex(where: { $0.id == show.id }) else { return }
        shows[i] = show
        changed()
    }

    func refresh(showID: UUID) async {
        guard let show = show(id: showID), let store, !refreshing.contains(showID) else { return }
        refreshing.insert(showID); onChange()
        defer { refreshing.remove(showID); onChange() }
        do {
            let feed = try await PodcastSources.fetchFeed(show.feedURL, kind: show.sourceKind)
            var merged = PodcastSources.merge(feed, into: self.show(id: showID) ?? show)
            if merged.artworkKey == nil, let image = merged.imageURL { merged.artworkKey = await PodcastSources.downloadArtwork(image, into: store.artwork) }
            update(merged)
        } catch { onError("Couldn't refresh \(show.title): \(error.localizedDescription)") }
    }

    func refreshAll() async {
        let ids = shows.map(\.id)
        await withTaskGroup(of: Void.self) { group in
            var next = 0
            let width = min(4, max(1, ProcessInfo.processInfo.activeProcessorCount))
            func add() { guard next < ids.count else { return }; let id = ids[next]; next += 1; group.addTask { await self.refresh(showID: id) } }
            for _ in 0..<width { add() }
            while await group.next() != nil { add() }
        }
    }

    // MARK: Episodes

    func setEpisodeSync(showID: UUID, episodeID: UUID, override: Bool?) {
        mutate(showID, episodeID) { $0.syncOverride = override }
    }

    func setPlayed(showID: UUID, episodeID: UUID, played: Bool) {
        mutate(showID, episodeID) { $0.played = played; if played { $0.playbackPositionMs = 0 } }
    }

    private func mutate(_ showID: UUID, _ episodeID: UUID, _ body: (inout PodcastEpisode) -> Void) {
        guard let s = shows.firstIndex(where: { $0.id == showID }), let e = shows[s].episodes.firstIndex(where: { $0.id == episodeID }) else { return }
        body(&shows[s].episodes[e])
        changed()
    }

    /// Played state and resume position read back from the iPod during a sync.
    func apply(_ result: SyncResult) {
        guard !result.episodeStats.isEmpty else { return }
        for s in shows.indices {
            for e in shows[s].episodes.indices {
                guard let stats = result.episodeStats[shows[s].episodes[e].id] else { continue }
                shows[s].episodes[e].played = stats.played
                shows[s].episodes[e].playbackPositionMs = stats.played ? 0 : stats.positionMs
            }
        }
        changed()
    }

    // MARK: Downloads

    func download(showID: UUID, episodeID: UUID) async {
        guard let show = show(id: showID), let episode = show.episodes.first(where: { $0.id == episodeID }),
              let store, !episode.isDownloaded, downloads[episodeID] == nil else { return }
        let directory = store.downloadDirectory(for: show)
        progress[episodeID] = 0
        let task = Task { [weak self] in
            do {
                // Throttled where the callbacks arrive: thousands per download would each wake the main actor.
                let gate = ProgressGate(interval: 0.25)
                let file = try await PodcastSources.download(episode, of: show, into: directory) { fraction in
                    guard gate.shouldPublish() else { return }
                    Task { @MainActor in self?.publishProgress(episodeID, fraction) }
                }
                let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) }
                self?.mutate(showID, episodeID) { $0.localPath = file.path; $0.fileSize = size }
            } catch {
                if !(error is CancellationError), (error as? URLError)?.code != .cancelled {
                    self?.onError("Download failed for “\(episode.title)”: \(error.localizedDescription)")
                }
            }
            self?.downloads[episodeID] = nil
            self?.progress[episodeID] = nil
            self?.onChange()
        }
        downloads[episodeID] = task
        onChange()
        await task.value
    }

    func downloadPending(showID: UUID? = nil) async {
        let pending = pendingDownloads.filter { showID == nil || $0.show.id == showID }
        await withTaskGroup(of: Void.self) { group in
            var next = 0
            func add() {
                guard next < pending.count else { return }
                let item = pending[next]; next += 1
                group.addTask { await self.download(showID: item.show.id, episodeID: item.episode.id) }
            }
            for _ in 0..<3 { add() }
            while await group.next() != nil { add() }
        }
    }

    /// What a drag of `episodeIDs` onto an iPod sends: those episodes, downloaded first when they aren't
    /// yet (the show's "keep the latest" rule is for the Sync button, not for episodes picked by hand).
    func shows(forDropped episodeIDs: Set<UUID>) async -> [PodcastShow] {
        let wanted = shows.flatMap { show in show.episodes.filter { episodeIDs.contains($0.id) && !$0.isDownloaded }.map { (show.id, $0.id) } }
        if !wanted.isEmpty {
            onStatus("Downloading \(wanted.count) episode\(wanted.count == 1 ? "" : "s")…")
            await withTaskGroup(of: Void.self) { group in
                var next = 0
                func add() {
                    guard next < wanted.count else { return }
                    let (show, episode) = wanted[next]; next += 1
                    group.addTask { await self.download(showID: show, episodeID: episode) }
                }
                for _ in 0..<3 { add() }
                while await group.next() != nil { add() }
            }
        }
        return shows.compactMap { show in
            var copy = show
            copy.episodes = show.episodes.filter { episodeIDs.contains($0.id) && $0.isDownloaded }
            // Picked by hand: the show's "keep the latest N" rule and any "never sync" mark don't apply.
            for i in copy.episodes.indices { copy.episodes[i].syncOverride = true }
            copy.syncEnabled = true
            return copy.episodes.isEmpty ? nil : copy
        }
    }

    var episodeIDs: Set<UUID> { Set(shows.flatMap { $0.episodes.map(\.id) }) }

    func cancelDownload(episodeID: UUID) { downloads[episodeID]?.cancel() }

    func deleteDownload(showID: UUID, episodeID: UUID) {
        guard let path = show(id: showID)?.episodes.first(where: { $0.id == episodeID })?.localPath else { return }
        Task.detached(priority: .utility) { try? FileManager.default.removeItem(atPath: path) }
        mutate(showID, episodeID) { $0.localPath = nil; $0.fileSize = nil }
    }

    /// Already throttled where the callbacks arrive (`ProgressGate`).
    private func publishProgress(_ id: UUID, _ fraction: Double) {
        guard downloads[id] != nil else { return }
        progress[id] = fraction
        onChange()
    }

    // MARK: Saving

    private func changed() {
        contentRevision &+= 1
        dirty = true
        onChange()
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            do { try await flush() } catch { onError("Couldn't save the podcasts: \(error.localizedDescription)") }
        }
    }

    /// Before a transfer and on exit: the file on the iPod matches what the screen shows.
    func flush() async throws {
        saveTask?.cancel()
        if dirty, let store {
            dirty = false
            let snapshot = shows
            let previous = saveChain
            saveChain = Task.detached(priority: .utility) { () -> Void in
                _ = try? await previous?.value
                try store.savePodcasts(snapshot)
            }
        }
        // Also waits for a debounced save that already started: its `dirty` is false but the file isn't written yet.
        // A finished chain is forgotten, so a failure is reported once and a later flush starts clean.
        guard let chain = saveChain else { return }
        defer { if saveChain == chain { saveChain = nil } }
        do { try await chain.value } catch { dirty = true; throw error }
    }
}

private final class ProgressGate: @unchecked Sendable {
    private let lock = NSLock()
    private let interval: TimeInterval
    private var last = Date.distantPast
    init(interval: TimeInterval) { self.interval = interval }
    func shouldPublish() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        guard now.timeIntervalSince(last) >= interval else { return false }
        last = now
        return true
    }
}
