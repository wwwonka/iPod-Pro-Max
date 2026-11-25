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
    private(set) var cachedUserPlaylistsByPlugin: [String: [RemotePlaylistSummary]] = [:]
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
    private var activeActivityCounts: [UUID: Int] = [:]
    private var recentTitleOverrides: [UUID: (value: String, expiresAt: Date)] = [:]
    private var recentCoverOverrides: [UUID: (key: String, expiresAt: Date)] = [:]
    private var verifiedArtworkKeys: Set<String> = []
    private var launchSyncTask: Task<Void, Never>?
    private var didScheduleLaunchSync = false
    private var didWarnDownloadFallback = false
    private var syncQueueOrder: [UUID] = []
    private var engine: SubscriptionEngine?
    private var readyTracksByID: [UUID: LibraryTrack] = [:]
    private var saveChain: Task<Void, Never>?

    var pendingCoverVerificationMessage: String?
    var pendingCoverVerificationURL: URL?

    func dismissCoverVerificationAlert() {
        pendingCoverVerificationMessage = nil
        pendingCoverVerificationURL = nil
        notify()
    }

    private var observers: [AnyHashable: () -> Void] = [:]

    func artworkURL(for sub: SubscriptionEntry) -> URL? {
        guard let key = sub.artworkKey, !key.isEmpty, let store else { return nil }
        let url = store.artwork.appendingPathComponent("\(key).jpg")
        if verifiedArtworkKeys.contains(key) {
            return url
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        verifiedArtworkKeys.insert(key)
        return url
    }

    private func beginActivity(_ subscriptionID: UUID) {
        activeActivityCounts[subscriptionID, default: 0] += 1
        syncingSubIDs.insert(subscriptionID)
        notify()
    }

    private func endActivity(_ subscriptionID: UUID) {
        let remaining = max(0, (activeActivityCounts[subscriptionID] ?? 1) - 1)
        if remaining == 0 {
            activeActivityCounts.removeValue(forKey: subscriptionID)
            syncingSubIDs.remove(subscriptionID)
        } else {
            activeActivityCounts[subscriptionID] = remaining
        }
        notify()
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
        activeActivityCounts.removeValue(forKey: sub.id)
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
        activeActivityCounts.removeAll()
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
        case unauthorized(String)
        case fetchFailed(String)

        var errorDescription: String? {
            switch self {
            case .noLibrary: "Open or configure a library first."
            case .unsupportedURL: "Unsupported URL — install a plug-in for this music service in Settings › Plug-ins."
            case .pluginUnavailable(let name): "\(name) plug-in is unavailable on this computer."
            case .pluginDisabled(let p): "\(p.name) is currently disabled."
            case .unauthorized(let name): "Sign in to \(name) in Settings › Plug-ins to browse your playlists."
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
              scheme == "http" || scheme == "https" || scheme == "spotify" || scheme == "ytmusic" else {
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

        return await registerNewSubscription(
            plugin: plugin,
            resolvedURL: resolvedURL,
            fetched: fetched,
            store: store
        )
    }

    func createUpstreamPlaylist(
        name: String,
        description: String? = nil,
        pluginID: String = "spotify"
    ) async throws -> SubscriptionEntry {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SubscribeError.fetchFailed("Enter a playlist name.")
        }
        guard let store, let registry = PluginController.shared.registry else {
            throw SubscribeError.noLibrary
        }
        guard let plugin = PluginController.shared.plugins.first(where: { $0.id == pluginID && !$0.overriddenByUnpacked }),
              plugin.isEnabledEligible else {
            let serviceLabel = pluginID == "youtube-music" ? "YouTube Music" : pluginID.capitalized
            throw SubscribeError.pluginUnavailable(serviceLabel)
        }
        guard PluginController.shared.isEnabled(plugin.id) else {
            throw SubscribeError.pluginDisabled(plugin)
        }
        guard let runtime = registry.runtime(for: plugin.id) else {
            throw SubscribeError.fetchFailed("Could not start \(plugin.name) plug-in.")
        }

        let created: PlaylistCreateResult
        do {
            created = try await executeWithAuthRetry(
                pluginID: plugin.id,
                preferredPlaylistID: nil,
                runtime: runtime,
                operation: {
                    try await runtime.createPlaylist(request: PlaylistCreateRequest(name: trimmed, description: description))
                }
            )
        } catch let pErr as PluginError {
            throw SubscribeError.fetchFailed(pErr.message)
        } catch {
            throw SubscribeError.fetchFailed(error.localizedDescription)
        }

        return await registerNewSubscription(
            plugin: plugin,
            resolvedURL: created.url,
            fetched: PlaylistFetchResult(playlist: created.playlist, tracks: []),
            store: store
        )
    }

    struct PlaylistImportSummary: Sendable {
        let importedCount: Int
        let skippedExistingCount: Int
        let failed: [(title: String, error: String)]
    }

    func subscribedSourcePlaylistIDs(for pluginID: String) -> Set<String> {
        let existingLibraryIDs = Set(getPlaylistsSnapshot().map(\.id))
        return Set(
            subscriptions
                .filter { $0.sourcePluginID == pluginID && existingLibraryIDs.contains($0.playlistID) }
                .map(\.sourcePlaylistID)
        )
    }

    func clearCachedUserPlaylists(for pluginID: String? = nil) {
        if let pluginID {
            cachedUserPlaylistsByPlugin.removeValue(forKey: pluginID)
        } else {
            cachedUserPlaylistsByPlugin.removeAll()
        }
    }

    func fetchUserPlaylists(pluginID: String) async throws -> [RemotePlaylistSummary] {
        guard let registry = PluginController.shared.registry else {
            throw SubscribeError.noLibrary
        }
        guard let plugin = PluginController.shared.plugins.first(where: { $0.id == pluginID && !$0.overriddenByUnpacked }),
              plugin.isEnabledEligible else {
            let serviceLabel = pluginID == "youtube-music" ? "YouTube Music" : pluginID.capitalized
            throw SubscribeError.pluginUnavailable(serviceLabel)
        }
        guard PluginController.shared.isEnabled(plugin.id) else {
            throw SubscribeError.pluginDisabled(plugin)
        }
        guard let runtime = registry.runtime(for: plugin.id) else {
            throw SubscribeError.fetchFailed("Could not start \(plugin.name) plug-in.")
        }

        let serviceLabel = plugin.manifest?.serviceName ?? plugin.name
        do {
            let raw = try await executeWithAuthRetry(
                pluginID: plugin.id,
                preferredPlaylistID: nil,
                runtime: runtime,
                operation: {
                    try await runtime.listUserPlaylists()
                }
            )
            let sorted = RemotePlaylistSummary.sortedForDisplay(raw)
            cachedUserPlaylistsByPlugin[plugin.id] = sorted
            return sorted
        } catch is CancellationError {
            throw CancellationError()
        } catch let pErr as PluginError where pErr.code == .cancelled {
            throw CancellationError()
        } catch let pErr as PluginError where pErr.code == .unauthorized {
            throw SubscribeError.unauthorized(serviceLabel)
        } catch let pErr as PluginError {
            throw SubscribeError.fetchFailed(pErr.message)
        } catch {
            throw SubscribeError.fetchFailed(error.localizedDescription)
        }
    }

    func importUserPlaylists(
        _ playlists: [RemotePlaylistSummary],
        plugin: DiscoveredPlugin,
        markLikedAsFavorites: Bool = false
    ) async throws -> PlaylistImportSummary {
        guard let store, let registry = PluginController.shared.registry else {
            throw SubscribeError.noLibrary
        }
        guard plugin.isEnabledEligible else {
            throw SubscribeError.pluginUnavailable(plugin.name)
        }
        guard PluginController.shared.isEnabled(plugin.id) else {
            throw SubscribeError.pluginDisabled(plugin)
        }
        guard let runtime = registry.runtime(for: plugin.id) else {
            throw SubscribeError.fetchFailed("Could not start \(plugin.name) plug-in.")
        }

        let alreadySubscribed = subscribedSourcePlaylistIDs(for: plugin.id)
        var skipped = 0
        var imported = 0
        var failures: [(title: String, error: String)] = []
        var didSelectFirst = false

        for item in playlists {
            if alreadySubscribed.contains(item.id) {
                skipped += 1
                continue
            }
            do {
                let fetched = try await executeWithAuthRetry(
                    pluginID: plugin.id,
                    preferredPlaylistID: item.id,
                    runtime: runtime,
                    operation: {
                        try await runtime.fetch(url: item.url)
                    }
                )
                let syncFavs = markLikedAsFavorites && item.isLikedSongs
                _ = await registerNewSubscription(
                    plugin: plugin,
                    resolvedURL: item.url,
                    fetched: fetched,
                    store: store,
                    selectPlaylist: !didSelectFirst,
                    syncFavorites: syncFavs
                )
                didSelectFirst = true
                imported += 1
            } catch let pErr as PluginError {
                failures.append((item.title, pErr.message))
            } catch {
                failures.append((item.title, error.localizedDescription))
            }
        }

        return PlaylistImportSummary(importedCount: imported, skippedExistingCount: skipped, failed: failures)
    }

    private func registerNewSubscription(
        plugin: DiscoveredPlugin,
        resolvedURL: URL,
        fetched: PlaylistFetchResult,
        store: PortableLibraryStore,
        selectPlaylist: Bool = true,
        syncFavorites: Bool = false
    ) async -> SubscriptionEntry {

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
            syncFavorites: syncFavorites ? true : nil,
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
        let syncedTrackIDs = initialTrackIDs
        applyLibraryMutation { cache in
            cache.playlists.append(playlist)
            Self.markTrackIDsFavoriteIfNeeded(syncedTrackIDs, cache: &cache, syncFavorites: syncFavorites)
        }

        notify()
        if selectPlaylist {
            selectPlaylistHandler(playlistID.uuidString)
        }

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

        beginActivity(subID)

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
        // Resolve `remoteItemUID` values on demand if the subscription predates UID tracking.
        if request.movedItemUIDs.count != movedKeys.count,
           let runtime = PluginController.shared.registry?.runtime(for: pluginID),
           let url = URL(string: sourceURLString),
           let fetched = try? await executeWithAuthRetry(
            pluginID: pluginID,
            preferredPlaylistID: request.playlistID,
            runtime: runtime,
            operation: { try await runtime.fetch(url: url) }
           ) {
            var uidByKey: [String: String] = [:]
            for (idx, ref) in fetched.tracks.enumerated() {
                if let uid = ref.remoteItemUID {
                    uidByKey[SubscribedTrackEntry.makeKey(for: ref, position: idx)] = uid
                }
            }
            if let subIdx = subscriptions.firstIndex(where: { $0.id == subscriptionID }) {
                for i in subscriptions[subIdx].tracks.indices {
                    if let uid = uidByKey[subscriptions[subIdx].tracks[i].key] {
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

        let finalRequest = request
        await runSubscriptionMutation(
            subscriptionID: subscriptionID,
            pluginID: pluginID,
            preferredPlaylistID: finalRequest.playlistID,
            failurePrefix: "Order changed manually (local only)",
            unauthAction: "reorder tracks",
            operation: { runtime in
                try await runtime.reorderPlaylist(request: finalRequest)
            }
        )
    }

    private static func reorderFailureMessage(_ detail: String) -> String {
        failureNoticeMessage(detail, prefix: "Order changed manually (local only)")
    }

    private static func failureNoticeMessage(_ detail: String, prefix: String) -> String {
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.localizedCaseInsensitiveContains("only playlists") && trimmed.localizedCaseInsensitiveContains("own") {
            return trimmed
        }
        if trimmed.isEmpty {
            return prefix
        }
        return "\(prefix) — \(trimmed)"
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
        beginActivity(subID)

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
        defer { endActivity(subscriptionID) }

        let serviceName = subscription(id: subscriptionID)?.sourceName ?? "this service"
        guard let runtime = PluginController.shared.registry?.runtime(for: pluginID) else {
            setReorderNotice(
                for: subscriptionID,
                message: "Cannot add tracks upstream — plug-in '\(pluginID)' is not running. Only playlists that you own can be modified on \(serviceName)."
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
            result = try await executeWithAuthRetry(
                pluginID: pluginID,
                preferredPlaylistID: sourcePlaylistID,
                runtime: runtime,
                operation: {
                    try await runtime.addTracksToPlaylist(request: request)
                }
            )
        } catch let err as PluginError where err.code == .unauthorized {
            setReorderNotice(
                for: subscriptionID,
                message: "Sign in to \(serviceName) in Settings › Plug-ins to add songs — only playlists that you own can be modified on \(serviceName)."
            )
            return
        } catch let err as PluginError {
            setReorderNotice(for: subscriptionID, message: Self.addFailureMessage(err.message, serviceName: serviceName))
            return
        } catch {
            setReorderNotice(for: subscriptionID, message: Self.addFailureMessage(error.localizedDescription, serviceName: serviceName))
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
            sub.lastError = "Added \(result.added.count) track(s); not found on \(serviceName): \(listed)\(suffix)."
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
        await refreshAfterMutation(subscriptionID: subscriptionID, pluginID: pluginID, runtime: runtime)
    }

    private static func addFailureMessage(_ detail: String, serviceName: String) -> String {
        failureNoticeMessage(detail, prefix: "Couldn't add song(s) to \(serviceName)")
    }

    // MARK: - Remove Tracks Upstream

    func removeTracks(_ rowIDs: [String], fromPlaylistID playlistID: String) {
        let removeSet = Set(rowIDs)
        guard !removeSet.isEmpty,
              let subIdx = subscriptions.firstIndex(where: { $0.playlistID.uuidString == playlistID }) else { return }

        var sub = subscriptions[subIdx]
        var removedEntries: [SubscribedTrackEntry] = []
        var remaining: [SubscribedTrackEntry] = []
        remaining.reserveCapacity(sub.tracks.count)

        // Match exact occurrence keys first; fall back to `libraryTrackID` only for callers passing UUIDs.
        let matchedAnyExactKey = sub.tracks.contains { removeSet.contains($0.key) }
        for entry in sub.tracks {
            let matches = removeSet.contains(entry.key)
                || (!matchedAnyExactKey && (entry.libraryTrackID.map { removeSet.contains($0.uuidString) } ?? false))
            if matches {
                removedEntries.append(entry)
            } else {
                var updated = entry
                updated.position = remaining.count
                remaining.append(updated)
            }
        }
        guard !removedEntries.isEmpty else { return }

        sub.tracks = remaining
        subscriptions[subIdx] = sub
        liveStatesBySubID[sub.id] = Self.initialStates(for: sub)
        saveSubscriptionsAsync()

        let playlistUUID = sub.playlistID
        let updatedTrackIDs = remaining.compactMap(\.libraryTrackID)
        applyLibraryMutation { cache in
            if let pIdx = cache.playlists.firstIndex(where: { $0.id == playlistUUID }) {
                cache.playlists[pIdx].trackIDs = updatedTrackIDs
            }
        }
        notify()

        let subID = sub.id
        let pluginID = sub.sourcePluginID
        let sourcePlaylistID = sub.sourcePlaylistID
        let trackIDs = removedEntries.map(\.trackRef.sourceID).filter { !$0.isEmpty }
        let removedSourceIDSet = Set(trackIDs)
        let hasRemainingDuplicate = remaining.contains { removedSourceIDSet.contains($0.trackRef.sourceID) }
        let uids = removedEntries.compactMap(\.trackRef.remoteItemUID)
        beginActivity(subID)

        Task(priority: .utility) { [weak self] in
            guard let self else { return }
            guard !trackIDs.isEmpty || !uids.isEmpty else {
                self.endActivity(subID)
                return
            }
            let request = PlaylistRemoveTracksRequest(
                playlistID: sourcePlaylistID,
                trackIDs: trackIDs,
                itemUIDs: uids
            )
            await self.runSubscriptionMutation(
                subscriptionID: subID,
                pluginID: pluginID,
                preferredPlaylistID: sourcePlaylistID,
                failurePrefix: "Removed locally",
                unauthAction: "remove tracks",
                skipPlaylistRefetch: !hasRemainingDuplicate,
                operation: { runtime in
                    try await runtime.removeTracksFromPlaylist(request: request)
                }
            )
        }
    }

    // MARK: - Rename Playlist Upstream

    func renamePlaylist(playlistID: String, to rawName: String) {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let subIdx = subscriptions.firstIndex(where: { $0.playlistID.uuidString == playlistID }) else { return }

        subscriptions[subIdx].title = trimmed
        let subID = subscriptions[subIdx].id
        recentTitleOverrides[subID] = (trimmed, Date().addingTimeInterval(10))
        saveSubscriptionsAsync()

        let playlistUUID = subscriptions[subIdx].playlistID
        applyLibraryMutation { cache in
            if let pIdx = cache.playlists.firstIndex(where: { $0.id == playlistUUID }) {
                cache.playlists[pIdx].name = trimmed
            }
        }

        let pluginID = subscriptions[subIdx].sourcePluginID
        let sourcePlaylistID = subscriptions[subIdx].sourcePlaylistID
        beginActivity(subID)

        Task(priority: .utility) { [weak self] in
            guard let self else { return }
            let request = PlaylistRenameRequest(playlistID: sourcePlaylistID, name: trimmed)
            await self.runSubscriptionMutation(
                subscriptionID: subID,
                pluginID: pluginID,
                preferredPlaylistID: sourcePlaylistID,
                failurePrefix: "Renamed locally",
                unauthAction: "rename playlists",
                expectedTitle: trimmed,
                operation: { runtime in
                    try await runtime.renamePlaylist(request: request)
                }
            )
        }
    }

    // MARK: - Update Playlist Cover Upstream

    func setPlaylistArtwork(playlistID: String, imageURL: URL) {
        guard let sub = subscription(forPlaylistID: playlistID),
              let store else { return }
        let subID = sub.id
        let pluginID = sub.sourcePluginID
        let sourcePlaylistID = sub.sourcePlaylistID
        let previousArtworkKey = sub.artworkKey
        beginActivity(subID)

        Task(priority: .utility) { [weak self] in
            guard let self else { return }
            let prepared: (key: String, jpegData: Data)? = await Task.detached(priority: .utility) {
                guard let jpeg = ImageLoading.spotifyCoverJPEG(from: imageURL) else {
                    return nil
                }
                let key = "subcover-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(16))"
                try? FileManager.default.createDirectory(at: store.artwork, withIntermediateDirectories: true)
                let dest = store.artwork.appendingPathComponent("\(key).jpg")
                try? jpeg.write(to: dest, options: .atomic)
                // Prune the superseded custom playlist cover (never touch shared album track covers).
                if let previousArtworkKey, previousArtworkKey.hasPrefix("subcover-") {
                    let oldFile = store.artwork.appendingPathComponent("\(previousArtworkKey).jpg")
                    try? FileManager.default.removeItem(at: oldFile)
                }
                return (String(key), jpeg)
            }.value

            guard let prepared else {
                await MainActor.run {
                    self.setReorderNotice(for: subID, message: "Could not encode the selected cover image as JPEG.")
                    self.endActivity(subID)
                }
                return
            }

            await MainActor.run {
                if let idx = self.subscriptions.firstIndex(where: { $0.id == subID }) {
                    self.subscriptions[idx].artworkKey = prepared.key
                    self.verifiedArtworkKeys.insert(prepared.key)
                    if let previousArtworkKey, previousArtworkKey.hasPrefix("subcover-") {
                        self.verifiedArtworkKeys.remove(previousArtworkKey)
                    }
                    self.recentCoverOverrides[subID] = (prepared.key, Date().addingTimeInterval(10))
                    self.saveSubscriptionsAsync()
                    self.notify()
                }
            }

            let request = PlaylistArtworkRequest(playlistID: sourcePlaylistID, jpegData: prepared.jpegData)
            await self.runSubscriptionMutation(
                subscriptionID: subID,
                pluginID: pluginID,
                preferredPlaylistID: sourcePlaylistID,
                failurePrefix: "Cover updated locally",
                unauthAction: "update covers",
                expectedArtworkKey: prepared.key,
                operation: { runtime in
                    try await runtime.setPlaylistArtwork(request: request)
                },
                onFailure: { error in
                    let msg = error.localizedDescription
                    let needsPhoneVerification = pluginID == "youtube-music"
                        && (msg.localizedCaseInsensitiveContains("phone")
                            || msg.localizedCaseInsensitiveContains("verify"))
                    guard needsPhoneVerification else { return }
                    await MainActor.run {
                        if let idx = self.subscriptions.firstIndex(where: { $0.id == subID }) {
                            self.subscriptions[idx].artworkKey = previousArtworkKey
                            self.subscriptions[idx].lastError = "YouTube requires verifying your phone number before custom playlist covers can be set."
                        }
                        self.verifiedArtworkKeys.remove(prepared.key)
                        self.recentCoverOverrides.removeValue(forKey: subID)
                        try? FileManager.default.removeItem(at: store.artwork.appendingPathComponent("\(prepared.key).jpg"))
                        self.pendingCoverVerificationMessage = "YouTube Phone Verification Required\n\nYouTube requires verifying your phone number before adding custom playlist thumbnails.\n\nConfirm your number on YouTube first (youtube.com/verify or directly inside YouTube Music), then try changing the cover again."
                        self.pendingCoverVerificationURL = URL(string: "https://www.youtube.com/verify")
                        self.saveSubscriptionsAsync()
                        self.notify()
                    }
                }
            )
        }
    }

    // MARK: - Shared Upstream Runner, Auth Retry & Post-Mutation Refresh

    private func runSubscriptionMutation(
        subscriptionID: UUID,
        pluginID: String,
        preferredPlaylistID: String?,
        failurePrefix: String,
        unauthAction: String,
        expectedTitle: String? = nil,
        expectedArtworkKey: String? = nil,
        skipPlaylistRefetch: Bool = false,
        operation: (ExternalPlugin) async throws -> Void,
        onFailure: (@Sendable (Error) async -> Void)? = nil
    ) async {
        defer { endActivity(subscriptionID) }
        guard let runtime = PluginController.shared.registry?.runtime(for: pluginID) else {
            setReorderNotice(for: subscriptionID, message: "\(failurePrefix) (plug-in '\(pluginID)' is not running).")
            return
        }

        do {
            try await executeWithAuthRetry(
                pluginID: pluginID,
                preferredPlaylistID: preferredPlaylistID,
                runtime: runtime,
                operation: { try await operation(runtime) }
            )
            clearReorderError(for: subscriptionID)
            if skipPlaylistRefetch {
                if let idx = subscriptions.firstIndex(where: { $0.id == subscriptionID }) {
                    subscriptions[idx].revision = Self.safeRevision(
                        title: subscriptions[idx].title,
                        trackIDs: subscriptions[idx].tracks.map(\.trackRef.sourceID)
                    )
                    subscriptions[idx].lastSyncedAt = Date()
                    saveSubscriptionsAsync()
                    notify()
                }
            } else {
                await refreshAfterMutation(
                    subscriptionID: subscriptionID,
                    pluginID: pluginID,
                    runtime: runtime,
                    expectedTitle: expectedTitle,
                    expectedArtworkKey: expectedArtworkKey
                )
            }
        } catch let err as PluginError where err.code == .unauthorized {
            let serviceName = subscription(id: subscriptionID)?.sourceName ?? "this service"
            setReorderNotice(
                for: subscriptionID,
                message: "\(failurePrefix). Sign in to \(serviceName) in Settings › Plug-ins to \(unauthAction) — only playlists that you own can be modified on \(serviceName)."
            )
            await onFailure?(err)
        } catch let err as PluginError {
            setReorderNotice(for: subscriptionID, message: Self.failureNoticeMessage(err.message, prefix: failurePrefix))
            await onFailure?(err)
        } catch {
            setReorderNotice(for: subscriptionID, message: Self.failureNoticeMessage(error.localizedDescription, prefix: failurePrefix))
            await onFailure?(error)
        }
    }

    private func executeWithAuthRetry<T>(
        pluginID: String,
        preferredPlaylistID: String?,
        runtime _: ExternalPlugin,
        operation: () async throws -> T
    ) async throws -> T {
        do {
            return try await operation()
        } catch let err as PluginError where err.code == .unauthorized {
            if await PluginController.shared.refreshWebSessionIfPossible(pluginID: pluginID, preferredPlaylistID: preferredPlaylistID) {
                return try await operation()
            }
            throw err
        }
    }

    /// Refreshes remote playlist metadata / UIDs after an upstream edit so `lastSyncedAt` and UI reflect the sync,
    /// while preserving confirmed local title / cover overrides against short GraphQL cache propagation delays.
    private func refreshAfterMutation(
        subscriptionID: UUID,
        pluginID _: String,
        runtime: ExternalPlugin,
        expectedTitle: String? = nil,
        expectedArtworkKey: String? = nil
    ) async {
        try? await Task.sleep(nanoseconds: 450_000_000)
        guard let idx = subscriptions.firstIndex(where: { $0.id == subscriptionID }),
              let url = URL(string: subscriptions[idx].sourceURL) else { return }

        if let fetched = try? await runtime.fetch(url: url),
           let freshIdx = subscriptions.firstIndex(where: { $0.id == subscriptionID }) {
            var uidByTrackID: [String: [String]] = [:]
            for ref in fetched.tracks {
                if let uid = ref.remoteItemUID, !uid.isEmpty {
                    uidByTrackID[ref.sourceID, default: []].append(uid)
                }
            }
            for i in subscriptions[freshIdx].tracks.indices {
                let sid = subscriptions[freshIdx].tracks[i].trackRef.sourceID
                if var list = uidByTrackID[sid], !list.isEmpty {
                    subscriptions[freshIdx].tracks[i].trackRef.remoteItemUID = list.removeFirst()
                    uidByTrackID[sid] = list
                }
            }
            if let owner = fetched.playlist.owner, !owner.isEmpty {
                subscriptions[freshIdx].owner = owner
            }
            if let expectedTitle, !expectedTitle.isEmpty {
                subscriptions[freshIdx].title = expectedTitle
            } else if !fetched.playlist.title.isEmpty {
                subscriptions[freshIdx].title = fetched.playlist.title
            }
            if let expectedArtworkKey, !expectedArtworkKey.isEmpty {
                subscriptions[freshIdx].artworkKey = expectedArtworkKey
            } else if let remoteArt = fetched.playlist.artworkURL {
                subscriptions[freshIdx].artworkURL = remoteArt
            }
            subscriptions[freshIdx].revision = Self.safeRevision(
                title: subscriptions[freshIdx].title,
                trackIDs: subscriptions[freshIdx].tracks.map(\.trackRef.sourceID)
            )
            subscriptions[freshIdx].lastSyncedAt = Date()
            saveSubscriptionsAsync()
            notify()
        } else if let fallbackIdx = subscriptions.firstIndex(where: { $0.id == subscriptionID }) {
            subscriptions[fallbackIdx].lastSyncedAt = Date()
            saveSubscriptionsAsync()
            notify()
        }
    }

    private static func safeRevision(title: String, trackIDs: [String]) -> String {
        let canonical = ([title] + trackIDs).joined(separator: "\n")
        return SHA256.hex(Data(canonical.utf8))
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
            let created = SubscriptionEngine(host: RegistryPluginHost(
                registry: registry,
                onUnauthorized: { pluginID in
                    await PluginController.shared.refreshWebSessionIfPossible(pluginID: pluginID, preferredPlaylistID: nil)
                }
            ))
            self.engine = created
            engine = created
        }

        let policy = QualityPolicy(
            preferredFormats: PluginController.shared.preferredFormats,
            minimumBitrateKbps: PluginController.shared.minimumBitrateKbps,
            acceptYouTubeFallback: PluginController.shared.acceptYouTubeFallback
        )

        beginActivity(subscriptionID)

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
        var finalEntry = result.updatedEntry
        let now = Date()
        if let titleOverride = recentTitleOverrides[subscriptionID], now < titleOverride.expiresAt {
            finalEntry.title = titleOverride.value
        } else {
            recentTitleOverrides.removeValue(forKey: subscriptionID)
        }
        if let coverOverride = recentCoverOverrides[subscriptionID], now < coverOverride.expiresAt {
            finalEntry.artworkKey = coverOverride.key
        } else {
            recentCoverOverrides.removeValue(forKey: subscriptionID)
        }
        if let key = finalEntry.artworkKey, !key.isEmpty {
            verifiedArtworkKeys.insert(key)
        }
        if let idx = subscriptions.firstIndex(where: { $0.id == subscriptionID }) {
            subscriptions[idx] = finalEntry
        }
        liveStatesBySubID[subscriptionID] = result.liveStates
        activeDownloadStats.removeValue(forKey: subscriptionID)
        if !wasCancelled {
            activeTasks.removeValue(forKey: subscriptionID)
        }
        endActivity(subscriptionID)
        saveSubscriptionsAsync()

        let playlistUUID = finalEntry.playlistID
        let newTracks = result.newlyImportedTracks
        for track in newTracks {
            readyTracksByID[track.id] = track
        }
        let replacedSet = Set(result.replacedTrackIDs)
        for oldID in replacedSet {
            readyTracksByID.removeValue(forKey: oldID)
        }
        let finalTrackIDs = result.playlistTrackIDs
        let finalTitle = finalEntry.title
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

        let syncFavs = (finalEntry.syncFavorites == true)
        applyLibraryMutation { cache in
            let existingIDs = Set(cache.tracks.map(\.id))
            for t in newTracks where !existingIDs.contains(t.id) {
                var copy = t
                if syncFavs { copy.isFavorite = true }
                cache.tracks.append(copy)
            }
            if !tracksToRemove.isEmpty {
                cache.tracks.removeAll { tracksToRemove.contains($0.id) }
            }
            if let pIdx = cache.playlists.firstIndex(where: { $0.id == playlistUUID }) {
                cache.playlists[pIdx].name = finalTitle
                cache.playlists[pIdx].trackIDs = finalTrackIDs
            }
            Self.markTrackIDsFavoriteIfNeeded(finalTrackIDs, cache: &cache, syncFavorites: syncFavs)
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
        let syncFavs = (subscriptions[idx].syncFavorites == true)
        saveSubscriptionsAsync()
        applyLibraryMutation { cache in
            if !cache.tracks.contains(where: { $0.id == readyTrack.id }) {
                var copy = readyTrack
                if syncFavs { copy.isFavorite = true }
                cache.tracks.append(copy)
            } else if syncFavs {
                Self.markTrackIDsFavoriteIfNeeded([readyTrack.id], cache: &cache, syncFavorites: true)
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
        let syncFavs = (subscriptions[idx].syncFavorites == true)
        for track in addedTracks {
            readyTracksByID[track.id] = track
        }
        saveSubscriptionsAsync()
        if !addedTracks.isEmpty {
            applyLibraryMutation { cache in
                let existing = Set(cache.tracks.map(\.id))
                for t in addedTracks where !existing.contains(t.id) {
                    var copy = t
                    if syncFavs { copy.isFavorite = true }
                    cache.tracks.append(copy)
                }
                if let pIdx = cache.playlists.firstIndex(where: { $0.id == playlistUUID }) {
                    cache.playlists[pIdx].trackIDs = linkedIDs
                }
            }
        }
    }

    private nonisolated static func markTrackIDsFavoriteIfNeeded(
        _ trackIDs: [UUID],
        cache: inout PortableLibraryCache,
        syncFavorites: Bool
    ) {
        guard syncFavorites, !trackIDs.isEmpty else { return }
        let wanted = Set(trackIDs)
        for i in cache.tracks.indices where wanted.contains(cache.tracks[i].id) {
            cache.tracks[i].isFavorite = true
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
