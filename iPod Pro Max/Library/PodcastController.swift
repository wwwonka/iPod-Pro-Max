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

    private var store: PortableLibraryStore?
    private var downloads: [UUID: Task<Void, Never>] = [:]
    private var saveTask: Task<Void, Never>?
    private var saveChain: Task<Void, Error>?
    private var dirty = false
    private var lastProgressPublish = Date.distantPast

    /// The cover file of a show, nil until it has been downloaded.
    func artworkURL(for show: PodcastShow) -> URL? {
        guard let key = show.artworkKey, let store else { return nil }
        let url = store.artwork.appendingPathComponent("\(key).jpg")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func show(id: UUID) -> PodcastShow? { shows.first { $0.id == id } }
    func isDownloading(_ episodeID: UUID) -> Bool { downloads[episodeID] != nil }

    /// Episodes the sync rules want that aren't on this computer yet.
    var pendingDownloads: [(show: PodcastShow, episode: PodcastEpisode)] {
        shows.flatMap { show in show.episodesToSync().filter { !$0.isDownloaded && downloads[$0.id] == nil }.map { (show, $0) } }
    }

    func load(store: PortableLibraryStore) async {
        self.store = store
        do {
            let loaded = try await Task.detached(priority: .userInitiated) { try store.loadPodcasts() }.value
            shows = loaded
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
                let file = try await PodcastSources.download(episode, of: show, into: directory) { fraction in
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

    func downloadPending() async {
        let pending = pendingDownloads
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

    func cancelDownload(episodeID: UUID) { downloads[episodeID]?.cancel() }

    func deleteDownload(showID: UUID, episodeID: UUID) {
        guard let path = show(id: showID)?.episodes.first(where: { $0.id == episodeID })?.localPath else { return }
        Task.detached(priority: .utility) { try? FileManager.default.removeItem(atPath: path) }
        mutate(showID, episodeID) { $0.localPath = nil; $0.fileSize = nil }
    }

    private func publishProgress(_ id: UUID, _ fraction: Double) {
        guard downloads[id] != nil else { return }
        progress[id] = fraction
        let now = Date()
        guard now.timeIntervalSince(lastProgressPublish) >= 0.25 else { return }
        lastProgressPublish = now
        onChange()
    }

    // MARK: Saving

    private func changed() {
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
        guard dirty, let store else { return }
        dirty = false
        let snapshot = shows
        let previous = saveChain
        let write = Task.detached(priority: .utility) { () -> Void in
            _ = try? await previous?.value
            try store.savePodcasts(snapshot)
        }
        saveChain = write
        do { try await write.value } catch { dirty = true; throw error }
    }
}
