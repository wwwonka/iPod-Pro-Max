import Foundation
import iPodKit
import MediaKit
import PluginKit

#if canImport(AppKit)
import AppKit
#endif

/// Coordinates playlist subscriptions, launch/open triggers, concurrent sync progress, download folder
/// registration and unsubscribe cleanup (`SUB-1`…`SUB-16`).
@MainActor
final class SubscriptionController {
    static let shared = SubscriptionController()

    private(set) var subscriptions: [SubscriptionEntry] = []
    private(set) var liveStatesBySubID: [UUID: [String: SubscribedTrackState]] = [:]
    private(set) var syncingSubIDs: Set<UUID> = []
    private(set) var activeDownloadStats: [UUID: (active: Int, total: Int)] = [:]
    private(set) var downloadFallbackBanner: String?
    private(set) var corruptSubscriptionsNotice: String?

    /// Bump this whenever headers, row states, or sidebar activity should redraw.
    private(set) var revision = 0

    private var store: PortableLibraryStore?
    private var getTracksSnapshot: () -> [LibraryTrack] = { [] }
    private var getPlaylistsSnapshot: () -> [LibraryPlaylist] = { [] }
    private var applyLibraryMutation: (@escaping @Sendable (inout PortableLibraryCache) -> Void) -> Void = { _ in }
    private var selectPlaylistHandler: (String) -> Void = { _ in }
    private var showPlaylistHandler: (String) -> Void = { _ in }

    private var activeTasks: [UUID: Task<Void, Never>] = [:]
    private var launchSyncTask: Task<Void, Never>?
    private var didScheduleLaunchSync = false
    private var didWarnDownloadFallback = false
    private var syncQueueOrder: [UUID] = []
    private var engine: SubscriptionEngine?
    private var readyTracksByID: [UUID: LibraryTrack] = [:]
    private var saveChain: Task<Void, Never>?

    private var observers: [AnyHashable: () -> Void] = [:]

    func artworkURL(for sub: SubscriptionEntry) -> URL? {
        guard let key = sub.artworkKey, !key.isEmpty, let store else { return nil }
        let url = store.artwork.appendingPathComponent("\(key).jpg")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func observe(_ key: AnyHashable, _ handler: @escaping () -> Void) {
        observers[key] = handler
    }

    private init() {}

    // MARK: - Setup & Persistence

    func attach(
        store: PortableLibraryStore?,
        tracksProvider: @escaping () -> [LibraryTrack],
        playlistsProvider: @escaping () -> [LibraryPlaylist],
        libraryMutator: @escaping (@escaping @Sendable (inout PortableLibraryCache) -> Void) -> Void,
        onSelectPlaylist: @escaping (String) -> Void
    ) {
        self.store = store
        self.getTracksSnapshot = tracksProvider
        self.getPlaylistsSnapshot = playlistsProvider
        self.applyLibraryMutation = libraryMutator
        self.selectPlaylistHandler = onSelectPlaylist
        self.showPlaylistHandler = onSelectPlaylist

        guard let store else {
            subscriptions = []
            liveStatesBySubID = [:]
            syncingSubIDs = []
            activeDownloadStats = [:]
            notify()
            return
        }

        Task { [weak self] in
            guard let self else { return }
            let loadResult = await Task.detached(priority: .utility) {
                let result = SubscriptionsStore.load(from: store.data)
                let downloadFolder = Self.resolveDownloadFolder(for: store).url
                SubscriptionsStore.cleanupOrphanedPartFiles(in: downloadFolder)
                return result
            }.value

            self.subscriptions = loadResult.document.subscriptions
            if loadResult.bothCorrupted {
                self.corruptSubscriptionsNotice = "Subscription list could not be read and has been reset. You can re-subscribe to your playlists at any time."
            }
            for entry in self.subscriptions {
                self.liveStatesBySubID[entry.id] = Self.initialStates(for: entry)
            }
            self.notify()

            if !self.didScheduleLaunchSync && !self.subscriptions.isEmpty {
                self.didScheduleLaunchSync = true
                self.scheduleLaunchSync()
            }
        }
    }

    func dismissCorruptNotice() {
        corruptSubscriptionsNotice = nil
        notify()
    }

    func dismissError(for subscriptionID: UUID) {
        guard let idx = subscriptions.firstIndex(where: { $0.id == subscriptionID }) else { return }
        subscriptions[idx].lastError = nil
        saveSubscriptionsAsync()
        notify()
    }

    func subscription(forPlaylistID id: String) -> SubscriptionEntry? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        return subscriptions.first { $0.playlistID == uuid || $0.id == uuid }
    }

    func subscription(id: UUID) -> SubscriptionEntry? {
        subscriptions.first { $0.id == id }
    }

    func isSyncing(playlistID: String) -> Bool {
        guard let sub = subscription(forPlaylistID: playlistID) else { return false }
        return syncingSubIDs.contains(sub.id)
    }

    /// Global summary shown in Settings › Plug-ins → Downloads card (`SUB-13`).
    var downloadsCardStatus: (text: String, activePlaylistID: String?)? {
        if let firstActiveID = syncingSubIDs.first,
           let sub = subscription(id: firstActiveID) {
            let stats = activeDownloadStats[firstActiveID] ?? (0, 0)
            if stats.total > 0 {
                return ("Downloading \(min(stats.active + 1, stats.total)) of \(stats.total) in “\(sub.title)”…", sub.playlistID.uuidString)
            }
            return ("Syncing “\(sub.title)”…", sub.playlistID.uuidString)
        }
        return nil
    }

    func navigateToPlaylist(_ playlistID: String) {
        showPlaylistHandler(playlistID)
    }

    // MARK: - Triggers (`SUB-8`)

    /// Launch trigger: starts once 10 seconds after library load completes, syncing sequentially at `.utility` priority.
    private func scheduleLaunchSync() {
        launchSyncTask?.cancel()
        launchSyncTask = Task(priority: .utility) { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled, let self else { return }
            let orderedIDs = self.subscriptions.map(\.id)
            for id in orderedIDs {
                guard !Task.isCancelled else { break }
                if self.activeTasks[id] != nil { continue }
                await self.performSync(subscriptionID: id, forceRetryFailed: false, attemptQualityUpgrades: false, singleTrackKey: nil)
            }
        }
    }

    /// Open-playlist trigger (`SUB-8`): refreshes if never synced or synced more than 15 minutes ago.
    func onPlaylistSelected(_ playlistID: String) {
        guard let sub = subscription(forPlaylistID: playlistID) else { return }
        guard !syncingSubIDs.contains(sub.id) else { return }
        if let last = sub.lastSyncedAt, Date().timeIntervalSince(last) < 15 * 60 {
            return
        }
        startSync(subscriptionID: sub.id, forceRetryFailed: false)
    }

    func refresh(playlistID: String) {
        guard let sub = subscription(forPlaylistID: playlistID) else { return }
        startSync(subscriptionID: sub.id, forceRetryFailed: true, attemptQualityUpgrades: true)
    }

    func retryTrack(playlistID: String, trackKey: String) {
        guard let sub = subscription(forPlaylistID: playlistID) else { return }
        startSync(subscriptionID: sub.id, forceRetryFailed: true, attemptQualityUpgrades: false, singleTrackKey: trackKey)
    }

    func stop(playlistID: String) {
        guard let sub = subscription(forPlaylistID: playlistID) else { return }
        activeTasks[sub.id]?.cancel()
        activeTasks[sub.id] = nil
        syncingSubIDs.remove(sub.id)
        activeDownloadStats.removeValue(forKey: sub.id)
        notify()
    }

    func finishAndCheckpointBeforeQuit() async {
        launchSyncTask?.cancel()
        launchSyncTask = nil
        for (_, task) in activeTasks {
            task.cancel()
        }
        for (_, task) in activeTasks {
            await task.value
        }
        activeTasks.removeAll()
        syncingSubIDs.removeAll()
        await saveChain?.value
        if let store {
            let doc = SubscriptionsDocument(version: 1, subscriptions: subscriptions)
            await Task.detached(priority: .utility) {
                try? SubscriptionsStore.save(doc, to: store.data)
                let downloadFolder = Self.resolveDownloadFolder(for: store).url
                SubscriptionsStore.cleanupOrphanedPartFiles(in: downloadFolder)
            }.value
        }
    }

    // MARK: - Subscribe (`SUB-1`)

    enum SubscribeError: LocalizedError {
        case noLibrary
        case unsupportedURL
        case pluginUnavailable(String)
        case pluginDisabled(DiscoveredPlugin)
        case fetchFailed(String)

        var errorDescription: String? {
            switch self {
            case .noLibrary: "Open or configure a library first."
            case .unsupportedURL: "Unsupported URL — install a plug-in for this music service in Settings › Plug-ins."
            case .pluginUnavailable(let name): "\(name) plug-in is unavailable on this computer."
            case .pluginDisabled(let p): "\(p.name) is currently disabled."
            case .fetchFailed(let msg): msg
            }
        }
    }

    func matchSource(for rawURL: String) -> (url: URL, plugin: DiscoveredPlugin?)? {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalized = trimmed.contains("://") || trimmed.contains(":") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: normalized),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" || scheme == "spotify" else {
            return nil
        }
        let plugin = PluginController.shared.registry?.matchPlaylistSource(for: trimmed, includeDisabled: true)
            ?? PluginController.shared.registry?.matchPlaylistSource(for: normalized, includeDisabled: true)
        return (url, plugin)
    }

    func subscribe(urlString: String, plugin: DiscoveredPlugin) async throws -> SubscriptionEntry {
        guard let store, let registry = PluginController.shared.registry else {
            throw SubscribeError.noLibrary
        }
        guard plugin.isEnabledEligible else {
            throw SubscribeError.pluginUnavailable(plugin.name)
        }
        guard PluginController.shared.isEnabled(plugin.id) else {
            throw SubscribeError.pluginDisabled(plugin)
        }
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.contains("://") || trimmed.contains(":") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: trimmed) ?? URL(string: normalized),
              let resolvedURL = (url.scheme != nil ? url : URL(string: normalized)),
              let runtime = registry.runtime(for: plugin.id) else {
            throw SubscribeError.fetchFailed("Could not start \(plugin.name) plug-in.")
        }

        let fetched: PlaylistFetchResult
        do {
            fetched = try await runtime.fetch(url: resolvedURL)
        } catch let pErr as PluginError {
            throw SubscribeError.fetchFailed(pErr.message)
        } catch {
            throw SubscribeError.fetchFailed(error.localizedDescription)
        }

        let subID = UUID()
        let playlistID = UUID()
        let entries = fetched.tracks.enumerated().map { idx, ref in
            SubscribedTrackEntry(
                key: SubscribedTrackEntry.makeKey(for: ref, position: idx),
                trackRef: ref,
                position: idx,
                status: .pending
            )
        }
        let title = fetched.playlist.title.isEmpty ? "Subscribed Playlist" : fetched.playlist.title
        let sub = SubscriptionEntry(
            id: subID,
            playlistID: playlistID,
            sourcePluginID: plugin.id,
            sourceName: plugin.name,
            sourceURL: resolvedURL.absoluteString,
            sourcePlaylistID: fetched.playlist.sourceID,
            title: title,
            owner: fetched.playlist.owner,
            artworkURL: fetched.playlist.artworkURL,
            revision: fetched.playlist.revision,
            lastSyncedAt: Date(),
            lastError: nil,
            dateAdded: Date(),
            tracks: entries
        )

        // Match against both in-memory tracks and any already-downloaded files on disk (`SUB-10`).
        let downloadInfo = Self.resolveDownloadFolder(for: store)
        let currentTracks = await discoverUnindexedDownloads(
            in: downloadInfo.url,
            artworkDir: store.artwork,
            existingTracks: getTracksSnapshot()
        )
        let matcher = LibraryTrackMatcher(tracks: currentTracks, downloadFolderPath: downloadInfo.url.path)
        var linkedEntries = entries
        var initialTrackIDs: [UUID] = []
        for idx in linkedEntries.indices {
            if let matched = matcher.match(for: linkedEntries[idx].trackRef, linkedTrackID: nil) {
                linkedEntries[idx].libraryTrackID = matched.id
                linkedEntries[idx].status = .available
                initialTrackIDs.append(matched.id)
            }
        }
        var finalizedSub = sub
        finalizedSub.tracks = linkedEntries

        subscriptions.append(finalizedSub)
        liveStatesBySubID[subID] = Self.initialStates(for: finalizedSub)
        saveSubscriptionsAsync()

        let playlist = LibraryPlaylist(
            id: playlistID,
            name: finalizedSub.title,
            trackIDs: initialTrackIDs,
            syncEnabled: true,
            dateCreated: Date(),
            isFolder: false,
            parentID: nil,
            subscriptionID: subID
        )
        applyLibraryMutation { cache in
            cache.playlists.append(playlist)
        }

        notify()
        selectPlaylistHandler(playlistID.uuidString)

        if let coverURL = finalizedSub.artworkURL {
            Task { [weak self] in
                await self?.downloadPlaylistCoverIfNeeded(subscriptionID: subID, coverURL: coverURL)
            }
        }

        // Kick off downloads if there are missing tracks
        if linkedEntries.contains(where: { $0.libraryTrackID == nil }) {
            startSync(subscriptionID: subID, forceRetryFailed: true, attemptQualityUpgrades: false)
        }
        return finalizedSub
    }

    // MARK: - Unsubscribe (`SUB-16`)

    func unsubscribeKeepMusic(playlistID: String) {
        guard let sub = subscription(forPlaylistID: playlistID) else { return }
        activeTasks[sub.id]?.cancel()
        activeTasks[sub.id] = nil
        syncingSubIDs.remove(sub.id)
        activeDownloadStats.removeValue(forKey: sub.id)
        liveStatesBySubID.removeValue(forKey: sub.id)
        subscriptions.removeAll { $0.id == sub.id }
        saveSubscriptionsAsync()

        let pUUID = sub.playlistID
        applyLibraryMutation { cache in
            if let idx = cache.playlists.firstIndex(where: { $0.id == pUUID }) {
                cache.playlists[idx].subscriptionID = nil
            }
        }
        notify()
    }

    func unsubscribeRemoveEverything(playlistID: String) {
        guard let sub = subscription(forPlaylistID: playlistID) else { return }
        activeTasks[sub.id]?.cancel()
        activeTasks[sub.id] = nil
        syncingSubIDs.remove(sub.id)
        activeDownloadStats.removeValue(forKey: sub.id)
        liveStatesBySubID.removeValue(forKey: sub.id)
        subscriptions.removeAll { $0.id == sub.id }
        saveSubscriptionsAsync()

        let pUUID = sub.playlistID
        let allTracks = getTracksSnapshot()
        let allPlaylists = getPlaylistsSnapshot()
        let storeRef = store
        let downloadPrefix: String? = storeRef.map {
            let p = Self.resolveDownloadFolder(for: $0).url.standardizedFileURL.path
            return p.hasSuffix("/") ? p : p + "/"
        }

        // Tracks referenced by any other manual or subscribed playlist stay untouched on disk.
        let otherReferencedIDs = Set(
            allPlaylists
                .filter { $0.id != pUUID }
                .flatMap(\.trackIDs)
        )
        let candidateTrackIDs = Set(sub.tracks.compactMap(\.libraryTrackID)).subtracting(otherReferencedIDs)
        let candidateTrackIDStrings = Set(candidateTrackIDs.map(\.uuidString))
        PlaybackController.shared.removeTracks(ids: candidateTrackIDStrings)

        let tracksToTrash = allTracks.filter { track in
            guard candidateTrackIDs.contains(track.id), let downloadPrefix else { return false }
            return URL(fileURLWithPath: track.path).standardizedFileURL.path.hasPrefix(downloadPrefix)
        }

        applyLibraryMutation { cache in
            cache.playlists.removeAll { $0.id == pUUID }
            let trashIDs = Set(tracksToTrash.map(\.id))
            cache.tracks.removeAll { trashIDs.contains($0.id) }
        }

        if let downloadPrefix {
            let rootURL = URL(fileURLWithPath: String(downloadPrefix.dropLast()), isDirectory: true)
            Task.detached(priority: .utility) {
                Self.trashFilesAndPruneEmptyParents(tracksToTrash.map { URL(fileURLWithPath: $0.path) }, stoppingAt: rootURL)
            }
        }
        notify()
    }

    // MARK: - Reorder (Local + Optional Upstream Sync)

    func reorderTracks(playlistID: String, movedIDs: [String], toTargetRow targetRow: Int) {
        guard let subIdx = subscriptions.firstIndex(where: {
            $0.playlistID.uuidString == playlistID || $0.id.uuidString == playlistID
        }) else { return }
        let movedSet = Set(movedIDs)
        guard !movedSet.isEmpty else { return }

        var sub = subscriptions[subIdx]
        let original = sub.tracks
        func isMoved(_ entry: SubscribedTrackEntry) -> Bool {
            movedSet.contains(entry.key) || (entry.libraryTrackID.map { movedSet.contains($0.uuidString) } ?? false)
        }

        guard let firstOriginalIndex = original.firstIndex(where: isMoved) else { return }
        let clamped = max(0, min(original.count, targetRow))
        let beforeCount = original[..<clamped].filter(isMoved).count
        let orderedMoving = original.filter(isMoved)
        guard !orderedMoving.isEmpty else { return }

        var remaining = original.filter { !isMoved($0) }
        let insertAt = max(0, min(remaining.count, clamped - beforeCount))

        let atStart = (insertAt == 0)
        let atEnd = (insertAt == remaining.count)
        let beforeUID = (!atStart && !atEnd) ? remaining[insertAt].trackRef.remoteItemUID : nil
        let afterUID = (insertAt > 0) ? remaining[insertAt - 1].trackRef.remoteItemUID : nil

        remaining.insert(contentsOf: orderedMoving, at: insertAt)
        for idx in remaining.indices {
            remaining[idx].position = idx
        }

        sub.tracks = remaining
        subscriptions[subIdx] = sub
        liveStatesBySubID[sub.id] = Self.initialStates(for: sub)
        saveSubscriptionsAsync()

        let playlistUUID = sub.playlistID
        let newTrackIDs = remaining.compactMap(\.libraryTrackID)
        applyLibraryMutation { cache in
            if let pIdx = cache.playlists.firstIndex(where: { $0.id == playlistUUID }) {
                cache.playlists[pIdx].trackIDs = newTrackIDs
            }
        }
        notify()

        // Push upstream silently when the source plug-in supports `PlaylistReorderable`.
        let subID = sub.id
        let pluginID = sub.sourcePluginID
        let sourcePlaylistID = sub.sourcePlaylistID
        let sourceURLString = sub.sourceURL
        let movedKeys = orderedMoving.map(\.key)
        let beforeKey = (!atStart && !atEnd) ? remaining[insertAt + orderedMoving.count].key : nil
        let afterKey = (!atStart && insertAt > 0) ? remaining[insertAt - 1].key : nil

        var request = PlaylistReorderRequest(
            playlistID: sourcePlaylistID,
            movedItemUIDs: orderedMoving.compactMap(\.trackRef.remoteItemUID),
            beforeItemUID: beforeUID,
            afterItemUID: afterUID,
            atStart: atStart,
            atEnd: atEnd,
            rangeStart: firstOriginalIndex,
            rangeLength: orderedMoving.count,
            insertBefore: clamped
        )

        Task(priority: .utility) { [weak self] in
            await self?.pushReorderUpstream(
                subscriptionID: subID,
                pluginID: pluginID,
                sourceURLString: sourceURLString,
                movedKeys: movedKeys,
                beforeKey: beforeKey,
                afterKey: afterKey,
                request: &request
            )
        }
    }

    private func pushReorderUpstream(
        subscriptionID: UUID,
        pluginID: String,
        sourceURLString: String,
        movedKeys: [String],
        beforeKey: String?,
        afterKey: String?,
        request: inout PlaylistReorderRequest
    ) async {
        guard let runtime = PluginController.shared.registry?.runtime(for: pluginID) else {
            setReorderNotice(
                for: subscriptionID,
                message: "Order changed manually (local only). Only playlists that you own can be modified on Spotify."
            )
            return
        }

        // If the subscription existed before `remoteItemUID` tracking was added, resolve UIDs on demand.
        if request.movedItemUIDs.count != movedKeys.count, let url = URL(string: sourceURLString) {
            if let fetched = try? await runtime.fetch(url: url) {
                var uidByKey: [String: String] = [:]
                for (idx, ref) in fetched.tracks.enumerated() {
                    if let uid = ref.remoteItemUID {
                        uidByKey[SubscribedTrackEntry.makeKey(for: ref, position: idx)] = uid
                    }
                }
                if let subIdx = subscriptions.firstIndex(where: { $0.id == subscriptionID }) {
                    for i in subscriptions[subIdx].tracks.indices {
                        let k = subscriptions[subIdx].tracks[i].key
                        if let uid = uidByKey[k] {
                            subscriptions[subIdx].tracks[i].trackRef.remoteItemUID = uid
                        }
                    }
                    saveSubscriptionsAsync()
                }
                let updatedMoved = movedKeys.compactMap { uidByKey[$0] }
                if updatedMoved.count == movedKeys.count {
                    request.movedItemUIDs = updatedMoved
                    if let beforeKey { request.beforeItemUID = uidByKey[beforeKey] }
                    if let afterKey { request.afterItemUID = uidByKey[afterKey] }
                }
            }
        }

        do {
            try await runtime.reorderPlaylist(request: request)
            clearReorderError(for: subscriptionID)
        } catch let err as PluginError where err.code == .unauthorized {
            if pluginID == "spotify",
               await PluginController.shared.refreshSpotifyWebSessionIfPossible(preferredPlaylistID: request.playlistID) {
                do {
                    try await runtime.reorderPlaylist(request: request)
                    clearReorderError(for: subscriptionID)
                    return
                } catch let retryErr as PluginError {
                    setReorderNotice(for: subscriptionID, message: Self.reorderFailureMessage(retryErr.message))
                    return
                } catch {
                    setReorderNotice(for: subscriptionID, message: Self.reorderFailureMessage(error.localizedDescription))
                    return
                }
            }
            setReorderNotice(
                for: subscriptionID,
                message: "Order changed manually (local only). Sign in to Spotify in Settings › Plug-ins to sync — only playlists that you own can be modified on Spotify."
            )
        } catch let err as PluginError where err.code == .unsupported {
            setReorderNotice(for: subscriptionID, message: Self.reorderFailureMessage(err.message))
        } catch {
            setReorderNotice(for: subscriptionID, message: Self.reorderFailureMessage(error.localizedDescription))
        }
    }

    private static func reorderFailureMessage(_ detail: String) -> String {
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.localizedCaseInsensitiveContains("only playlists") && trimmed.localizedCaseInsensitiveContains("own") {
            return trimmed
        }
        return "Order changed manually (local only) — \(trimmed). Only playlists that you own can be modified on Spotify."
    }

    private func clearReorderError(for subscriptionID: UUID) {
        guard let idx = subscriptions.firstIndex(where: { $0.id == subscriptionID }),
              subscriptions[idx].lastError != nil else { return }
        subscriptions[idx].lastError = nil
        saveSubscriptionsAsync()
        notify()
    }

    private func setReorderNotice(for subscriptionID: UUID, message: String) {
        guard let idx = subscriptions.firstIndex(where: { $0.id == subscriptionID }) else { return }
        subscriptions[idx].lastError = message
        saveSubscriptionsAsync()
        notify()
    }

    // MARK: - Displayed Rows (`SUB-6`)

    func rows(for playlist: Playlist, library: Library) -> [TrackRow] {
        guard let sub = subscription(forPlaylistID: playlist.id) else {
            return library.rowsByPlaylist[playlist.id] ?? []
        }
        let localByID = Dictionary(
            library.allRows.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var out: [TrackRow] = []
        out.reserveCapacity(sub.tracks.count)
        for item in sub.tracks {
            let playlistPosition = "\(out.count + 1)"
            if let tid = item.libraryTrackID {
                if var row = localByID[tid.uuidString] {
                    row.subscriptionKey = item.key
                    row.number = playlistPosition
                    out.append(row)
                    continue
                }
                if var cachedTrackRow = readyTracksByID[tid].map({ Self.trackRow(from: $0, subscriptionKey: item.key) }) {
                    cachedTrackRow.number = playlistPosition
                    out.append(cachedTrackRow)
                    continue
                }
            }
            let ref = item.trackRef
            let durMs = ref.durationMs ?? 0
            let yearStr = ref.releaseDate.flatMap { s -> String? in
                let prefix = String(s.prefix(4))
                return Int(prefix) != nil ? prefix : nil
            } ?? ""
            out.append(TrackRow(
                id: item.key,
                title: ref.title,
                artist: ref.artists.joined(separator: ", "),
                album: ref.album ?? "",
                number: playlistPosition,
                year: yearStr,
                duration: durMs > 0 ? formatDuration(durMs) : "",
                path: nil,
                hasLyrics: false,
                artworkKey: nil,
                dateAdded: nil,
                isFavorite: false,
                subscriptionKey: item.key
            ))
        }
        return out
    }

    // MARK: - Add Personal Library Tracks (Search & Append Upstream)

    func addLibraryTracks(_ trackIDs: [String], toPlaylistID playlistID: String) {
        guard let sub = subscription(forPlaylistID: playlistID) else { return }
        let wantedUUIDs = trackIDs.compactMap(UUID.init(uuidString:))
        guard !wantedUUIDs.isEmpty else { return }

        let allTracks = getTracksSnapshot()
        let trackByID = Dictionary(allTracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let existingLocalIDs = Set(sub.tracks.compactMap(\.libraryTrackID))

        var chosen: [LibraryTrack] = []
        var seen = existingLocalIDs
        for id in wantedUUIDs where seen.insert(id).inserted {
            if let track = trackByID[id] {
                chosen.append(track)
            }
        }
        guard !chosen.isEmpty else { return }

        let subID = sub.id
        let pluginID = sub.sourcePluginID
        let sourcePlaylistID = sub.sourcePlaylistID
        syncingSubIDs.insert(subID)
        notify()

        Task(priority: .utility) { [weak self] in
            await self?.performAddLibraryTracks(
                subscriptionID: subID,
                pluginID: pluginID,
                sourcePlaylistID: sourcePlaylistID,
                tracks: chosen
            )
        }
    }

    private func performAddLibraryTracks(
        subscriptionID: UUID,
        pluginID: String,
        sourcePlaylistID: String,
        tracks: [LibraryTrack]
    ) async {
        defer {
            syncingSubIDs.remove(subscriptionID)
            notify()
        }

        guard let runtime = PluginController.shared.registry?.runtime(for: pluginID) else {
            setReorderNotice(
                for: subscriptionID,
                message: "Cannot add tracks upstream — plug-in '\(pluginID)' is not running. Only playlists that you own can be modified on Spotify."
            )
            return
        }

        let inputs = tracks.map { t in
            PlaylistAddTrackInput(
                title: t.title,
                artist: t.artist ?? "",
                album: t.album,
                durationMs: t.durationMs > 0 ? t.durationMs : nil,
                isrc: nil
            )
        }
        let request = PlaylistAddTracksRequest(playlistID: sourcePlaylistID, tracks: inputs)

        let result: PlaylistAddTracksResult
        do {
            result = try await runtime.addTracksToPlaylist(request: request)
        } catch let err as PluginError where err.code == .unauthorized {
            if pluginID == "spotify",
               await PluginController.shared.refreshSpotifyWebSessionIfPossible(preferredPlaylistID: sourcePlaylistID) {
                do {
                    result = try await runtime.addTracksToPlaylist(request: request)
                } catch let retryErr as PluginError {
                    setReorderNotice(for: subscriptionID, message: Self.addFailureMessage(retryErr.message))
                    return
                } catch {
                    setReorderNotice(for: subscriptionID, message: Self.addFailureMessage(error.localizedDescription))
                    return
                }
            } else {
                setReorderNotice(
                    for: subscriptionID,
                    message: "Sign in to Spotify in Settings › Plug-ins to add songs — only playlists that you own can be modified on Spotify."
                )
                return
            }
        } catch let err as PluginError {
            setReorderNotice(for: subscriptionID, message: Self.addFailureMessage(err.message))
            return
        } catch {
            setReorderNotice(for: subscriptionID, message: Self.addFailureMessage(error.localizedDescription))
            return
        }

        guard let subIdx = subscriptions.firstIndex(where: { $0.id == subscriptionID }) else { return }
        var sub = subscriptions[subIdx]
        var nextPos = sub.tracks.count
        var appendedLocalIDs: [UUID] = []

        for item in result.added {
            guard tracks.indices.contains(item.index) else { continue }
            let localTrack = tracks[item.index]
            let key = SubscribedTrackEntry.makeKey(for: item.matchedTrack, position: nextPos)
            let entry = SubscribedTrackEntry(
                key: key,
                trackRef: item.matchedTrack,
                position: nextPos,
                libraryTrackID: localTrack.id,
                status: .available,
                isYouTubeFallback: false
            )
            sub.tracks.append(entry)
            readyTracksByID[localTrack.id] = localTrack
            appendedLocalIDs.append(localTrack.id)
            nextPos += 1
        }

        if result.notFoundTitles.isEmpty {
            sub.lastError = nil
        } else {
            let listed = result.notFoundTitles.prefix(3).joined(separator: ", ")
            let suffix = result.notFoundTitles.count > 3 ? " (+\(result.notFoundTitles.count - 3) more)" : ""
            sub.lastError = "Added \(result.added.count) track(s); not found on Spotify: \(listed)\(suffix)."
        }

        subscriptions[subIdx] = sub
        liveStatesBySubID[sub.id] = Self.initialStates(for: sub)
        saveSubscriptionsAsync()

        let playlistUUID = sub.playlistID
        let addedIDsSnapshot = appendedLocalIDs
        applyLibraryMutation { cache in
            if let pIdx = cache.playlists.firstIndex(where: { $0.id == playlistUUID }) {
                var existing = Set(cache.playlists[pIdx].trackIDs)
                for tid in addedIDsSnapshot where existing.insert(tid).inserted {
                    cache.playlists[pIdx].trackIDs.append(tid)
                }
            }
        }
    }

    private static func addFailureMessage(_ detail: String) -> String {
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.localizedCaseInsensitiveContains("only playlists") && trimmed.localizedCaseInsensitiveContains("own") {
            return trimmed
        }
        return "Couldn't add song(s) to Spotify — \(trimmed). Only playlists that you own can be modified on Spotify."
    }

    private nonisolated static func trackRow(from track: LibraryTrack, subscriptionKey: String?) -> TrackRow {
        TrackRow(
            id: track.id.uuidString,
            title: track.title,
            artist: track.artist ?? "",
            album: track.album ?? "",
            number: track.trackNumber > 0 ? "\(track.trackNumber)" : "",
            year: track.year > 0 ? "\(track.year)" : "",
            duration: formatDuration(track.durationMs),
            path: track.path,
            hasLyrics: track.hasLyrics,
            artworkKey: track.artworkKey,
            dateAdded: track.dateAdded,
            isFavorite: track.isFavorite == true,
            subscriptionKey: subscriptionKey
        )
    }

    func statusStates(forPlaylistID id: String) -> [String: SubscribedTrackState] {
        guard let sub = subscription(forPlaylistID: id) else { return [:] }
        return liveStatesBySubID[sub.id] ?? Self.initialStates(for: sub)
    }

    // MARK: - Execution

    private func startSync(
        subscriptionID: UUID,
        forceRetryFailed: Bool,
        attemptQualityUpgrades: Bool = false,
        singleTrackKey: String? = nil
    ) {
        if let existing = activeTasks[subscriptionID] {
            existing.cancel()
        }
        activeTasks[subscriptionID] = Task(priority: .utility) { [weak self] in
            await self?.performSync(
                subscriptionID: subscriptionID,
                forceRetryFailed: forceRetryFailed,
                attemptQualityUpgrades: attemptQualityUpgrades,
                singleTrackKey: singleTrackKey
            )
        }
    }

    private func performSync(
        subscriptionID: UUID,
        forceRetryFailed: Bool,
        attemptQualityUpgrades: Bool,
        singleTrackKey: String?
    ) async {
        guard let store,
              let registry = PluginController.shared.registry,
              let currentSub = subscription(id: subscriptionID) else {
            return
        }

        let downloadInfo = Self.resolveDownloadFolder(for: store)
        if downloadInfo.usedIPodFallback && !didWarnDownloadFallback {
            didWarnDownloadFallback = true
            downloadFallbackBanner = "Custom download folder unavailable — using iPod storage."
        }
        ensureDownloadFolderRegisteredIfNeeded(downloadFolder: downloadInfo.url, isCustomFallback: downloadInfo.usedIPodFallback)

        let engine: SubscriptionEngine
        if let existing = self.engine {
            engine = existing
        } else {
            let created = SubscriptionEngine(host: RegistryPluginHost(registry: registry))
            self.engine = created
            engine = created
        }

        let policy = QualityPolicy(
            preferredFormats: PluginController.shared.preferredFormats,
            minimumBitrateKbps: PluginController.shared.minimumBitrateKbps,
            acceptYouTubeFallback: PluginController.shared.acceptYouTubeFallback
        )

        syncingSubIDs.insert(subscriptionID)
        notify()

        // Ensure any files already written in the Download folder (e.g. interrupted prior session)
        // are indexed in memory & library before resolving missing tracks so nothing is downloaded twice.
        let snapshotTracks = await discoverUnindexedDownloads(
            in: downloadInfo.url,
            artworkDir: store.artwork,
            existingTracks: getTracksSnapshot()
        )

        let result = await engine.sync(
            subscription: currentSub,
            existingTracks: snapshotTracks,
            downloadFolder: downloadInfo.url,
            artworkDir: store.artwork,
            qualityPolicy: policy,
            retryFailedCooldownOverride: forceRetryFailed,
            attemptQualityUpgrades: attemptQualityUpgrades,
            singleTrackKey: singleTrackKey,
            onTrackReady: { [weak self] items, readyTrack, replacedTrackID in
                await MainActor.run {
                    self?.applyTrackReady(
                        subscriptionID: subscriptionID,
                        items: items,
                        readyTrack: readyTrack,
                        replacedTrackID: replacedTrackID
                    )
                }
            },
            onCheckpointSave: { [weak self] items, addedTracks in
                await MainActor.run {
                    self?.applyCheckpoint(subscriptionID: subscriptionID, items: items, addedTracks: addedTracks)
                }
            },
            onProgress: { [weak self] progress in
                await MainActor.run {
                    self?.applyProgress(progress)
                }
            }
        )

        let wasCancelled = Task.isCancelled
        if let idx = subscriptions.firstIndex(where: { $0.id == subscriptionID }) {
            subscriptions[idx] = result.updatedEntry
        }
        liveStatesBySubID[subscriptionID] = result.liveStates
        syncingSubIDs.remove(subscriptionID)
        activeDownloadStats.removeValue(forKey: subscriptionID)
        if !wasCancelled {
            activeTasks.removeValue(forKey: subscriptionID)
        }
        saveSubscriptionsAsync()

        let playlistUUID = result.updatedEntry.playlistID
        let newTracks = result.newlyImportedTracks
        for track in newTracks {
            readyTracksByID[track.id] = track
        }
        let replacedSet = Set(result.replacedTrackIDs)
        for oldID in replacedSet {
            readyTracksByID.removeValue(forKey: oldID)
        }
        let finalTrackIDs = result.playlistTrackIDs
        let finalTitle = result.updatedEntry.title
        let allPlaylistsSnapshot = getPlaylistsSnapshot()
        let otherReferencedIDs = Set(
            allPlaylistsSnapshot
                .filter { $0.id != playlistUUID }
                .flatMap(\.trackIDs)
        )
        let tracksToRemove = replacedSet.subtracting(otherReferencedIDs)
        let pathsToTrash = snapshotTracks
            .filter { tracksToRemove.contains($0.id) }
            .map { URL(fileURLWithPath: $0.path) }
            .filter { url in
                let dlPrefix = downloadInfo.url.standardizedFileURL.path
                let normalizedPrefix = dlPrefix.hasSuffix("/") ? dlPrefix : dlPrefix + "/"
                return url.standardizedFileURL.path.hasPrefix(normalizedPrefix)
            }

        applyLibraryMutation { cache in
            let existingIDs = Set(cache.tracks.map(\.id))
            for t in newTracks where !existingIDs.contains(t.id) {
                cache.tracks.append(t)
            }
            if !tracksToRemove.isEmpty {
                cache.tracks.removeAll { tracksToRemove.contains($0.id) }
            }
            if let pIdx = cache.playlists.firstIndex(where: { $0.id == playlistUUID }) {
                cache.playlists[pIdx].name = finalTitle
                cache.playlists[pIdx].trackIDs = finalTrackIDs
            }
        }

        if !pathsToTrash.isEmpty {
            let rootURL = downloadInfo.url
            Task.detached(priority: .utility) {
                Self.trashFilesAndPruneEmptyParents(pathsToTrash, stoppingAt: rootURL)
            }
        }

        notify()
    }

    private func applyProgress(_ progress: SubscriptionSyncProgress) {
        liveStatesBySubID[progress.subscriptionID] = progress.liveStates
        activeDownloadStats[progress.subscriptionID] = (active: progress.downloadStats.active, total: progress.downloadStats.totalToDownload)
        if let idx = subscriptions.firstIndex(where: { $0.id == progress.subscriptionID }) {
            subscriptions[idx].tracks = progress.entries
            subscriptions[idx].lastError = progress.errorBanner
            if let artURL = progress.artworkURL {
                subscriptions[idx].artworkURL = artURL
            }
            if let artKey = progress.artworkKey {
                subscriptions[idx].artworkKey = artKey
            }
        }
        notify()
    }

    private func applyTrackReady(
        subscriptionID: UUID,
        items: [SubscribedTrackEntry],
        readyTrack: LibraryTrack,
        replacedTrackID: UUID?
    ) {
        readyTracksByID[readyTrack.id] = readyTrack
        if let replacedTrackID {
            readyTracksByID.removeValue(forKey: replacedTrackID)
        }
        guard let idx = subscriptions.firstIndex(where: { $0.id == subscriptionID }) else { return }
        subscriptions[idx].tracks = items
        liveStatesBySubID[subscriptionID] = Self.initialStates(for: subscriptions[idx])
        let playlistUUID = subscriptions[idx].playlistID
        let linkedIDs = items.compactMap(\.libraryTrackID)
        saveSubscriptionsAsync()
        applyLibraryMutation { cache in
            if !cache.tracks.contains(where: { $0.id == readyTrack.id }) {
                cache.tracks.append(readyTrack)
            }
            if let pIdx = cache.playlists.firstIndex(where: { $0.id == playlistUUID }) {
                cache.playlists[pIdx].trackIDs = linkedIDs
            }
        }
        notify()
    }

    private func applyCheckpoint(subscriptionID: UUID, items: [SubscribedTrackEntry], addedTracks: [LibraryTrack]) {
        guard let idx = subscriptions.firstIndex(where: { $0.id == subscriptionID }) else { return }
        subscriptions[idx].tracks = items
        let playlistUUID = subscriptions[idx].playlistID
        let linkedIDs = items.compactMap(\.libraryTrackID)
        for track in addedTracks {
            readyTracksByID[track.id] = track
        }
        saveSubscriptionsAsync()
        if !addedTracks.isEmpty {
            applyLibraryMutation { cache in
                let existing = Set(cache.tracks.map(\.id))
                for t in addedTracks where !existing.contains(t.id) {
                    cache.tracks.append(t)
                }
                if let pIdx = cache.playlists.firstIndex(where: { $0.id == playlistUUID }) {
                    cache.playlists[pIdx].trackIDs = linkedIDs
                }
            }
        }
    }

    private func saveSubscriptionsAsync() {
        guard let store else { return }
        let doc = SubscriptionsDocument(version: 1, subscriptions: subscriptions)
        let previous = saveChain
        saveChain = Task.detached(priority: .utility) {
            await previous?.value
            try? SubscriptionsStore.save(doc, to: store.data)
        }
    }

    private func downloadPlaylistCoverIfNeeded(subscriptionID: UUID, coverURL: URL) async {
        guard let store else { return }
        let cache = AlbumArtworkCache(artworkDir: store.artwork)
        guard let cached = await cache.jpegData(for: coverURL, artworkDir: store.artwork) else { return }
        guard let idx = subscriptions.firstIndex(where: { $0.id == subscriptionID }) else { return }
        subscriptions[idx].artworkKey = cached.key
        saveSubscriptionsAsync()
        notify()
    }

    private func discoverUnindexedDownloads(
        in downloadFolder: URL,
        artworkDir: URL,
        existingTracks: [LibraryTrack]
    ) async -> [LibraryTrack] {
        let existingByPath = Set(existingTracks.map { URL(fileURLWithPath: $0.path).standardizedFileURL.path })
        let newlyFound = await Task.detached(priority: .utility) {
            let diskFiles = FolderImporter.mediaFiles(in: downloadFolder)
                .filter { MetadataExtractor.isAudioFile($0) && !["m4b", "aa"].contains($0.pathExtension.lowercased()) }
            let hasNew = diskFiles.contains { !existingByPath.contains($0.standardizedFileURL.path) }
            guard hasNew else { return [LibraryTrack]() }
            let scanResult = await FolderImporter.scan(
                folder: downloadFolder,
                artworkDir: artworkDir,
                cached: existingTracks,
                musicOnly: true
            )
            return scanResult.tracks.filter { !existingByPath.contains(URL(fileURLWithPath: $0.path).standardizedFileURL.path) }
        }.value

        guard !newlyFound.isEmpty else { return existingTracks }
        for track in newlyFound {
            readyTracksByID[track.id] = track
        }
        applyLibraryMutation { cache in
            let knownPaths = Set(cache.tracks.map { URL(fileURLWithPath: $0.path).standardizedFileURL.path })
            let knownIDs = Set(cache.tracks.map(\.id))
            for track in newlyFound {
                let normPath = URL(fileURLWithPath: track.path).standardizedFileURL.path
                if !knownIDs.contains(track.id) && !knownPaths.contains(normPath) {
                    cache.tracks.append(track)
                }
            }
        }
        return existingTracks + newlyFound
    }

    /// Registers the active Download folder as a Music source in `known_hosts.json` if not yet added
    /// and if the user hasn't manually removed it previously (`SUB-14`).
    private func ensureDownloadFolderRegisteredIfNeeded(downloadFolder: URL, isCustomFallback: Bool) {
        guard let store, !isCustomFallback else { return }
        let stdPath = downloadFolder.standardizedFileURL.path
        Task.detached(priority: .utility) { [weak self] in
            var addedNew = false
            try? store.updateCurrentHost { host in
                let alreadySource = host.sources.contains {
                    $0.kind == .music && URL(fileURLWithPath: $0.path).standardizedFileURL.path == stdPath
                }
                let previouslyHandled = host.autoAddedDownloadFolders?.contains(stdPath) ?? false
                guard !alreadySource && !previouslyHandled else { return }
                host.sources.append(KnownSource(id: UUID(), kind: .music, path: stdPath))
                var recorded = host.autoAddedDownloadFolders ?? []
                recorded.append(stdPath)
                host.autoAddedDownloadFolders = recorded
                addedNew = true
            }
            if addedNew {
                await MainActor.run {
                    SettingsController.shared.attach(store)
                    self?.notify()
                }
            }
        }
    }

    // MARK: - Helpers

    nonisolated static func resolveDownloadFolder(for store: PortableLibraryStore) -> (url: URL, usedIPodFallback: Bool) {
        let fm = FileManager.default
        let host = store.currentHost()
        if let custom = host?.downloadFolder?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            let customURL = URL(fileURLWithPath: custom, isDirectory: true)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: customURL.path, isDirectory: &isDir), isDir.boolValue, fm.isWritableFile(atPath: customURL.path) {
                return (customURL, false)
            }
            // Custom folder missing or unwritable -> fallback to iPod `Persistent Data/Downloads`
            let fallback = store.data.url.appendingPathComponent("Downloads", isDirectory: true)
            try? fm.createDirectory(at: fallback, withIntermediateDirectories: true)
            return (fallback, true)
        }

        let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
        let defaultURL = downloads.appendingPathComponent("iPod Pro Max", isDirectory: true)
        do {
            try fm.createDirectory(at: defaultURL, withIntermediateDirectories: true)
            return (defaultURL, false)
        } catch {
            let fallback = store.data.url.appendingPathComponent("Downloads", isDirectory: true)
            try? fm.createDirectory(at: fallback, withIntermediateDirectories: true)
            return (fallback, true)
        }
    }

    private nonisolated static func trashFilesAndPruneEmptyParents(_ urls: [URL], stoppingAt rootURL: URL) {
        let fm = FileManager.default
        let stopPath = rootURL.standardizedFileURL.path
        var dirs = Set<URL>()

        for url in urls {
            guard fm.fileExists(atPath: url.path) else { continue }
            dirs.insert(url.deletingLastPathComponent())
            do {
                #if os(macOS)
                try fm.trashItem(at: url, resultingItemURL: nil)
                #else
                try fm.removeItem(at: url)
                #endif
            } catch {
                try? fm.removeItem(at: url)
            }
        }

        // Remove empty Album and Artist parent folders created by downloads.
        for dir in dirs.sorted(by: { $0.path.count > $1.path.count }) {
            var current = dir.standardizedFileURL
            while current.path.hasPrefix(stopPath) && current.path != stopPath {
                let contents = (try? fm.contentsOfDirectory(atPath: current.path)) ?? ["keep"]
                let nonHidden = contents.filter { !$0.hasPrefix(".") }
                guard nonHidden.isEmpty else { break }
                try? fm.removeItem(at: current)
                current = current.deletingLastPathComponent().standardizedFileURL
            }
        }
    }

    private nonisolated static func initialStates(for sub: SubscriptionEntry) -> [String: SubscribedTrackState] {
        var map: [String: SubscribedTrackState] = [:]
        map.reserveCapacity(sub.tracks.count)
        for item in sub.tracks {
            switch item.status {
            case .available:
                map[item.key] = .available(isYouTubeFallback: item.isYouTubeFallback)
            case .notFound:
                map[item.key] = .notFound
            case .failed:
                map[item.key] = .failed(reason: item.lastFailureReason ?? "Download failed")
            case .pending:
                map[item.key] = .waiting
            }
        }
        return map
    }

    private func notify() {
        revision += 1
        for handler in observers.values { handler() }
    }
}
