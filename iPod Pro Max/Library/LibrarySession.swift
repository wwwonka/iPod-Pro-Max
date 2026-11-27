import Foundation
import SwiftCrossUI
import iPodKit

/// The user's library and every edit made to it: playlist tree, track order, favorites, metadata,
/// and the portable save behind them. Platform-neutral; the views only call it and read `library`.
///
/// Performance:
/// - Edits queued while a save runs are coalesced: one pass off the main actor, one disk write and
///   one reindex for the whole burst (a drag-reorder or several quick edits).
/// - An edit that only touches playlists reindexes playlists only (`Library.reindexingPlaylists`),
///   not the full sort plus artwork checks a track change needs.
/// - Only `library` is observed, so a save re-renders once, when its result lands.
@MainActor
final class LibrarySession: SwiftCrossUI.ObservableObject {
    /// What a write can change, so the reindex after it does no more than needed.
    enum Scope { case playlists, full }

    /// The library as displayed. Playlist edits update it at once; the save confirms it.
    @SwiftCrossUI.Published var library: Library?
    /// The loaded portable library (store + saved cache). Changes together with `library`.
    private(set) var loaded: LoadedPortableLibrary?
    /// True while edits are queued or being saved.
    var saving: Bool { drain != nil }

    /// After a full reindex (tracks changed): artist photos, sharing, metadata editor.
    var onReindexed: (@MainActor () -> Void)?
    /// A save failed; the message is for the player LCD.
    var onError: (@MainActor (String) -> Void)?

    private struct Edit {
        var label: String
        var scope: Scope
        var apply: @Sendable (inout PortableLibraryCache, URL) -> Void
        var completion: (@MainActor (Result<Void, Error>) -> Void)?
    }

    private let gate = PortableLibraryGate()
    private let writer = PortableLibraryWriter()
    private var queued: [Edit] = []
    private var drain: Task<Void, Never>?
    /// Saved, or staged after a failed write, but not yet indexed into `library`.
    private var pendingSave: (library: LoadedPortableLibrary, scope: Scope)?

    // MARK: Loading and exclusive access

    /// Runs `body` alone against the library (scans, source changes), after any staged save.
    func exclusive<T>(_ body: () async throws -> T) async throws -> T {
        await gate.acquire()
        do {
            try await retryLocked()
            let value = try await body()
            await gate.release()
            return value
        } catch {
            await gate.release()
            throw error
        }
    }

    /// A freshly loaded library; call from inside `exclusive`.
    func install(_ loaded: LoadedPortableLibrary, indexed: Library) {
        self.loaded = loaded
        library = indexed
        if ProcessInfo.processInfo.environment["IPPM_BENCH_REINDEX"] != nil { benchReindex(loaded, indexed) }
    }

    /// `IPPM_BENCH_REINDEX=1`: times a full reindex against a playlist-only one on this library.
    private func benchReindex(_ loaded: LoadedPortableLibrary, _ indexed: Library) {
        Task.detached(priority: .utility) {
            func ms(_ body: () -> Void) -> Int { let t = Date(); for _ in 0..<5 { body() }; return Int(Date().timeIntervalSince(t) * 200) }
            let full = ms { _ = Library.portable(loaded.cache, source: loaded.store.hostFolder.url.path, artworkFolder: loaded.store.artwork) }
            let playlists = ms { _ = indexed.reindexingPlaylists(from: loaded.cache) }
            log("[bench] reindex on \(loaded.cache.tracks.count) tracks, \(loaded.cache.playlists.count) playlists: full \(full) ms, playlists only \(playlists) ms")
        }
    }

    /// Waits for every queued edit, then retries a staged save (exit, eject).
    func flush() async throws {
        while let drain { await drain.value }
        try await exclusive {}
    }

    // MARK: Writes

    /// Queues an edit of the saved library. `apply` runs off the main actor with the artwork folder.
    func write(
        _ label: String,
        scope: Scope = .full,
        completion: (@MainActor (Result<Void, Error>) -> Void)? = nil,
        apply: @escaping @Sendable (inout PortableLibraryCache, URL) -> Void
    ) {
        queued.append(Edit(label: label, scope: scope, apply: apply, completion: completion))
        guard drain == nil else { return }
        drain = Task { [self] in
            await drainQueue()
            drain = nil
        }
    }

    func write(_ label: String, scope: Scope = .full, apply: @escaping @Sendable (inout PortableLibraryCache) -> Void) {
        write(label, scope: scope) { cache, _ in apply(&cache) }
    }

    private func drainQueue() async {
        while !queued.isEmpty {
            let batch = queued
            queued = []
            let scope: Scope = batch.contains { $0.scope == .full } ? .full : .playlists
            var result: Result<Void, Error> = .success(())
            await gate.acquire()
            do {
                try await retryLocked()
                guard let base = loaded else { throw PortableLoading.LoadingError.noRoot }
                let edits = batch.map(\.apply)
                let saved = await Task.detached(priority: .utility) {
                    var value = base
                    for edit in edits { edit(&value.cache, base.store.artwork) }
                    value.cache.reconcileFavoriteReferences()
                    return value
                }.value
                pendingSave = (saved, scope)
                try await writer.save(saved.cache, to: saved.store)
                try await retryLocked()
            } catch {
                let labels = Array(NSOrderedSet(array: batch.map(\.label))) as? [String] ?? []
                onError?("Couldn't save \(labels.joined(separator: ", ")): \(error.localizedDescription)")
                result = .failure(error)
            }
            await gate.release()
            for edit in batch { edit.completion?(result) }
        }
    }

    /// Writes a staged save, then indexes it into `library`. Call with the gate held.
    private func retryLocked() async throws {
        try await writer.flush()
        guard let (saved, scope) = pendingSave else { return }
        let current = library
        let start = Date()
        let indexed = await Task.detached(priority: .utility) {
            if scope == .playlists, let current { return current.reindexingPlaylists(from: saved.cache) }
            return Library.portable(saved.cache, source: saved.store.hostFolder.url.path, artworkFolder: saved.store.artwork)
        }.value
        log("[library] saved and reindexed (\(scope == .playlists ? "playlists" : "full")) in \(Int(Date().timeIntervalSince(start) * 1000)) ms")
        loaded = saved
        pendingSave = nil
        library = indexed
        if scope == .full { onReindexed?() }
    }

    // MARK: Playlists

    /// Creates a playlist or folder with a free name based on `base`, shown at once. Returns its id.
    @discardableResult
    func createPlaylist(base: String, isFolder: Bool = false, uniqueName: Bool = true) -> String {
        let name = uniqueName ? PlaylistEdits.uniqueName(base, among: (library?.playlists ?? []).map(\.name)) : base
        let created = LibraryPlaylist(name: name, isFolder: isFolder)
        library?.playlists.append(Playlist(id: created.id.uuidString, name: name, trackIDs: [], isFolder: isFolder))
        updatePlaylists { $0.append(created) }
        return created.id.uuidString
    }

    func renamePlaylist(_ id: String, to name: String) {
        guard let uuid = UUID(uuidString: id) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Shown at once, subscription playlists too: their rename lands with the service.
        if let index = library?.playlists.firstIndex(where: { $0.id == id }) { library?.playlists[index].name = trimmed }
        if isSubscribed(id) { return SubscriptionController.shared.renamePlaylist(playlistID: id, to: trimmed) }
        updatePlaylists { PlaylistEdits.rename(uuid, to: trimmed, in: &$0) }
    }

    func movePlaylist(_ id: String, toFolder folderID: String?, atIndex index: Int?) {
        guard let uuid = UUID(uuidString: id) else { return }
        if library != nil { PlaylistEdits.move(id, toFolder: folderID, atIndex: index, in: &library!.playlists) }
        let parent = folderID.flatMap(UUID.init(uuidString:))
        updatePlaylists { PlaylistEdits.move(uuid, toFolder: parent, atIndex: index, in: &$0) }
    }

    /// Sidebar order of the playlists section.
    func reorderPlaylists(_ orderedIDs: [String]) {
        let ids = orderedIDs.compactMap(UUID.init(uuidString:))
        updatePlaylists { PlaylistEdits.reorder(ids, in: &$0) }
    }

    /// Not for subscription playlists, which are unsubscribed instead.
    func deletePlaylist(_ id: String) {
        guard let uuid = UUID(uuidString: id), !isSubscribed(id) else { return }
        library?.playlists.removeAll { $0.id == id }
        updatePlaylists { $0.removeAll { $0.id == uuid } }
    }

    func addTracks(_ ids: [String], toPlaylist playlistID: String) {
        if isSubscribed(playlistID) { return SubscriptionController.shared.addLibraryTracks(ids, toPlaylistID: playlistID) }
        guard let uuid = UUID(uuidString: playlistID) else { return }
        let tracks = ids.compactMap(UUID.init(uuidString:))
        updatePlaylists { PlaylistEdits.addTracks(tracks, toPlaylist: uuid, of: &$0) }
    }

    func removeTracks(_ ids: [String], fromPlaylist playlistID: String) {
        if isSubscribed(playlistID) { return SubscriptionController.shared.removeTracks(ids, fromPlaylistID: playlistID) }
        guard let uuid = UUID(uuidString: playlistID) else { return }
        let tracks = ids.compactMap(UUID.init(uuidString:))
        updatePlaylists { PlaylistEdits.removeTracks(tracks, fromPlaylist: uuid, of: &$0) }
    }

    /// Drag-reorder in a playlist: `ids` land before `targetRow` of the displayed order.
    func reorderTracks(_ ids: [String], to targetRow: Int, inPlaylist playlistID: String) {
        if isSubscribed(playlistID) {
            return SubscriptionController.shared.reorderTracks(playlistID: playlistID, movedIDs: ids, toTargetRow: targetRow)
        }
        guard let uuid = UUID(uuidString: playlistID) else { return }
        let moving = ids.compactMap(UUID.init(uuidString:))
        updatePlaylists { PlaylistEdits.reorderTracks(moving, to: targetRow, inPlaylist: uuid, of: &$0) }
    }

    /// Tracks to send for a playlist; a folder sends its playlists' tracks.
    func trackIDs(forPlaylist id: String) -> [String] {
        guard let playlists = library?.playlists, let target = playlists.first(where: { $0.id == id }) else { return [] }
        return target.isFolder ? playlists.filter { $0.parentID == id }.flatMap(\.trackIDs) : target.trackIDs
    }

    // MARK: Video playlists

    func createVideoPlaylist(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        updateVideoPlaylists { $0.append(LibraryPlaylist(name: trimmed)) }
    }

    func renameVideoPlaylist(_ id: String, to name: String) {
        guard let uuid = UUID(uuidString: id) else { return }
        updateVideoPlaylists { PlaylistEdits.rename(uuid, to: name, in: &$0) }
    }

    func deleteVideoPlaylist(_ id: String) {
        guard let uuid = UUID(uuidString: id) else { return }
        updateVideoPlaylists { $0.removeAll { $0.id == uuid } }
    }

    func reorderVideoPlaylists(_ orderedIDs: [String]) {
        let ids = orderedIDs.compactMap(UUID.init(uuidString:))
        updateVideoPlaylists { PlaylistEdits.reorder(ids, in: &$0) }
    }

    func addVideos(_ ids: [String], toPlaylist playlistID: String) {
        guard let uuid = UUID(uuidString: playlistID) else { return }
        let videos = ids.compactMap(UUID.init(uuidString:))
        updateVideoPlaylists { PlaylistEdits.addTracks(videos, toPlaylist: uuid, of: &$0) }
    }

    func removeVideos(_ ids: [String], fromPlaylist playlistID: String) {
        guard let uuid = UUID(uuidString: playlistID) else { return }
        let videos = ids.compactMap(UUID.init(uuidString:))
        updateVideoPlaylists { PlaylistEdits.removeTracks(videos, fromPlaylist: uuid, of: &$0) }
    }

    // MARK: Favorites

    /// The icon changes at once (`ListAppearance`); the library is saved and reindexed behind it.
    func setFavorite(_ favorite: Bool, ids: [String]) {
        guard !ids.isEmpty else { return }
        let selected = Set(ids)
        ListAppearance.shared.beginFavoriteWrite(ids, favorite: favorite)
        write("favorites", completion: { result in
            if case .success = result { ListAppearance.shared.endFavoriteWrite(saved: true) }
            else { ListAppearance.shared.endFavoriteWrite(saved: false) }
        }) { cache, _ in
            var pathsByID: [UUID: String] = [:]
            for index in cache.tracks.indices where selected.contains(cache.tracks[index].id.uuidString) && cache.tracks[index].mediaKind == .song {
                cache.tracks[index].isFavorite = favorite
                pathsByID[cache.tracks[index].id] = cache.tracks[index].path
            }
            guard favorite else { return }
            var refs = cache.favoriteReferences ?? []
            var existing = Set(refs.map(\.id))
            for idString in ids {
                guard let uuid = UUID(uuidString: idString), let path = pathsByID[uuid], existing.insert(uuid).inserted else { continue }
                refs.append(PortableFavoriteReference(id: uuid, path: path))
            }
            cache.favoriteReferences = refs
        }
    }

    // MARK: Private

    private func isSubscribed(_ playlistID: String) -> Bool {
        SubscriptionController.shared.subscription(forPlaylistID: playlistID) != nil
    }

    private func updatePlaylists(_ change: @escaping @Sendable (inout [LibraryPlaylist]) -> Void) {
        write("playlist", scope: .playlists) { change(&$0.playlists) }
    }

    private func updateVideoPlaylists(_ change: @escaping @Sendable (inout [LibraryPlaylist]) -> Void) {
        write("video playlist", scope: .playlists) { change(&$0.videoPlaylists) }
    }
}
