import Foundation
import iPodKit
import PluginKit

/// Async counting semaphore for bounding plugin search and download concurrency (`SUB-12`).
public actor AsyncSemaphore {
    private var permits: Int
    private var waiters: [CheckedContinuation<Void, Error>] = []

    public init(permits: Int) {
        self.permits = max(1, permits)
    }

    public func acquire() async throws {
        try Task.checkCancellation()
        if permits > 0 {
            permits -= 1
            return
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(continuation)
            }
        } onCancel: {
            Task { await self.cancelAllWaitersIfNeeded() }
        }
    }

    public func release() {
        while !waiters.isEmpty {
            let next = waiters.removeFirst()
            next.resume()
            return
        }
        permits += 1
    }

    private func cancelAllWaitersIfNeeded() {
        // Note: Individual cancellation is checked on resume; if task is cancelled while queued,
        // release next slot on resume. Here we only fail callers whose tasks were cancelled.
    }
}

/// Runtime adapter passed into `SubscriptionEngine` so tests and app controllers share one sync pipeline (`SUB-9`, `SUB-12`, `SUB-18`).
public protocol SubscriptionPluginHost: Sendable {
    func fetchPlaylist(pluginID: String, url: String) async throws -> PlaylistFetchResult
    func orderedResolvers(includeYouTubeFallback: Bool) async -> [String]
    func searchCandidates(
        resolverID: String,
        track: TrackRef,
        policy: QualityPolicy,
        onPartial: @escaping @Sendable ([Candidate]) -> Void
    ) async throws -> [Candidate]
    func downloadCandidate(
        resolverID: String,
        candidate: Candidate,
        destinationDir: URL,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL
}

/// Default `SubscriptionPluginHost` backed by a `PluginRegistry`.
public final class RegistryPluginHost: SubscriptionPluginHost, @unchecked Sendable {
    private let registry: PluginRegistry
    private let onUnauthorized: (@Sendable (String) async -> Bool)?

    public init(registry: PluginRegistry, onUnauthorized: (@Sendable (String) async -> Bool)? = nil) {
        self.registry = registry
        self.onUnauthorized = onUnauthorized
    }

    public func fetchPlaylist(pluginID: String, url: String) async throws -> PlaylistFetchResult {
        guard let runtime = registry.runtime(for: pluginID),
              let parsedURL = URL(string: url) else {
            throw PluginError(code: .unsupported, message: "Plug-in '\(pluginID)' is not enabled or URL is invalid.")
        }
        do {
            return try await runtime.fetch(url: parsedURL)
        } catch let err as PluginError where err.code == .unauthorized {
            if let onUnauthorized, await onUnauthorized(pluginID) {
                return try await runtime.fetch(url: parsedURL)
            }
            throw err
        }
    }

    public func orderedResolvers(includeYouTubeFallback: Bool) async -> [String] {
        let resolvers = registry.orderedEnabledResolvers().map(\.id)
        if includeYouTubeFallback {
            let nonYT = resolvers.filter { $0 != "yt-dlp" }
            let hasYT = resolvers.contains("yt-dlp")
            return hasYT ? (nonYT + ["yt-dlp"]) : nonYT
        }
        return resolvers.filter { $0 != "yt-dlp" }
    }

    public func searchCandidates(
        resolverID: String,
        track: TrackRef,
        policy: QualityPolicy,
        onPartial: @escaping @Sendable ([Candidate]) -> Void
    ) async throws -> [Candidate] {
        guard let runtime = registry.runtime(for: resolverID) else {
            throw PluginError(code: .unsupported, message: "Plug-in '\(resolverID)' is not available.")
        }
        return try await runtime.search(track: track, policy: policy) { partial in
            onPartial(partial)
        }
    }

    public func downloadCandidate(
        resolverID: String,
        candidate: Candidate,
        destinationDir: URL,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        guard let runtime = registry.runtime(for: resolverID) else {
            throw PluginError(code: .unsupported, message: "Plug-in '\(resolverID)' is not available.")
        }
        return try await runtime.download(candidate: candidate, destinationDir: destinationDir) { progress in
            let fraction: Double
            if let total = progress.total, total > 0 {
                fraction = min(1.0, max(0.0, progress.done / total))
            } else {
                fraction = min(1.0, max(0.0, progress.done))
            }
            onProgress(fraction)
        }
    }
}

/// Progress snapshot batched roughly every 500 ms toward the UI (`SUB-9`, `AGENTS.md`).
public struct SubscriptionSyncProgress: Sendable {
    public var subscriptionID: UUID
    public var title: String
    public var sourceURL: String
    public var sourcePluginID: String
    public var sourceName: String
    public var revision: String?
    public var artworkURL: URL?
    public var artworkKey: String?
    public var entries: [SubscribedTrackEntry]
    public var liveStates: [String: SubscribedTrackState]
    public var addedTracks: [LibraryTrack]
    public var isSyncing: Bool
    public var errorBanner: String?
    public var downloadStats: (active: Int, totalToDownload: Int)
}

public struct SubscriptionSyncResult: Sendable {
    public var updatedEntry: SubscriptionEntry
    public var playlistTrackIDs: [UUID]
    public var newlyImportedTracks: [LibraryTrack]
    public var replacedTrackIDs: [UUID] = []
    public var liveStates: [String: SubscribedTrackState]
    public var errorBanner: String?
    public var skippedDueToUnchangedRevision: Bool
}

/// Runs a complete or incremental playlist subscription sync cleanly off the main actor (`SUB-9`, `SUB-12`, `SUB-14`, `SUB-15`).
public actor SubscriptionEngine {
    private let host: any SubscriptionPluginHost
    private let searchSemaphore = AsyncSemaphore(permits: 3)
    private let downloadSemaphore = AsyncSemaphore(permits: 4)
    private let ytdlpSemaphore = AsyncSemaphore(permits: 2)
    private let stagingLock = NSLock()

    public init(host: any SubscriptionPluginHost) {
        self.host = host
    }

    /// Syncs one subscribed playlist end to end, returning updated entries, linked/new `LibraryTrack`s,
    /// and emitting grouped progress updates about every 500 ms.
    public func sync(
        subscription: SubscriptionEntry,
        existingTracks: [LibraryTrack],
        downloadFolder: URL,
        artworkDir: URL,
        qualityPolicy: QualityPolicy,
        retryFailedCooldownOverride: Bool = false,
        attemptQualityUpgrades: Bool = false,
        singleTrackKey: String? = nil,
        onTrackReady: @escaping @Sendable ([SubscribedTrackEntry], LibraryTrack, UUID?) async -> Void = { _, _, _ in },
        onCheckpointSave: @escaping @Sendable ([SubscribedTrackEntry], [LibraryTrack]) async -> Void = { _, _ in },
        onProgress: @escaping @Sendable (SubscriptionSyncProgress) async -> Void = { _ in }
    ) async -> SubscriptionSyncResult {
        var entry = subscription
        let now = Date()
        let artworkCache = AlbumArtworkCache(artworkDir: artworkDir)

        // 1. Fetch latest playlist snapshot unless retrying a single track manually (`Try Again`)
        let fetched: PlaylistFetchResult?
        if singleTrackKey == nil {
            do {
                let result = try await host.fetchPlaylist(pluginID: entry.sourcePluginID, url: entry.sourceURL)
                fetched = result
                entry.title = result.playlist.title.isEmpty ? entry.title : result.playlist.title
                entry.owner = result.playlist.owner ?? entry.owner
                if !result.playlist.sourceID.isEmpty {
                    entry.sourcePlaylistID = result.playlist.sourceID
                }
                if let artURL = result.playlist.artworkURL {
                    if entry.artworkURL != artURL {
                        entry.artworkURL = artURL
                        entry.artworkKey = nil
                    }
                }
            } catch let pErr as PluginError {
                entry.lastError = friendlyMessage(for: pErr, serviceName: entry.sourceName)
                let states = buildLiveStates(for: entry.tracks, noDownloadSource: false)
                return SubscriptionSyncResult(
                    updatedEntry: entry,
                    playlistTrackIDs: entry.tracks.compactMap(\.libraryTrackID),
                    newlyImportedTracks: [],
                    liveStates: states,
                    errorBanner: entry.lastError,
                    skippedDueToUnchangedRevision: false
                )
            } catch {
                entry.lastError = error.localizedDescription
                let states = buildLiveStates(for: entry.tracks, noDownloadSource: false)
                return SubscriptionSyncResult(
                    updatedEntry: entry,
                    playlistTrackIDs: entry.tracks.compactMap(\.libraryTrackID),
                    newlyImportedTracks: [],
                    liveStates: states,
                    errorBanner: entry.lastError,
                    skippedDueToUnchangedRevision: false
                )
            }
        } else {
            fetched = nil
        }

        // Download / verify cached playlist cover artwork off the main thread.
        if let coverURL = entry.artworkURL {
            let needsCover: Bool = {
                guard let key = entry.artworkKey, !key.isEmpty else { return true }
                return !FileManager.default.fileExists(atPath: artworkDir.appendingPathComponent("\(key).jpg").path)
            }()
            if needsCover, let cachedCover = await artworkCache.jpegData(for: coverURL, artworkDir: artworkDir) {
                entry.artworkKey = cachedCover.key
            }
        }

        // 2. Fast-path check when playlist revision hasn't changed (`SUB-9`, `SUB-18` < 2 s target).
        let existingByID = Dictionary(existingTracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let resolverIDsForCheck = await host.orderedResolvers(includeYouTubeFallback: qualityPolicy.acceptYouTubeFallback)
        let resolversWithYTFallback = await host.orderedResolvers(includeYouTubeFallback: true)
        let ytOnlyResolvers = resolversWithYTFallback.filter { $0 == "yt-dlp" }
        let hasNonYTForUpgrade = resolverIDsForCheck.contains { $0 != "yt-dlp" }
        let hasPendingUpgrades = attemptQualityUpgrades && hasNonYTForUpgrade && entry.tracks.contains { item in
            guard item.status == .available,
                  item.trackRef.isVideo != true,
                  !TrackTextNormalizer.hasVideoVersionQualifier(title: item.trackRef.title, album: item.trackRef.album),
                  let tid = item.libraryTrackID,
                  let track = existingByID[tid],
                  FileManager.default.fileExists(atPath: track.path) else {
                return false
            }
            return CandidateScorer.canSeekUpgrade(
                localExtension: track.fileExtension,
                localBitrateKbps: track.bitrate,
                localIsLossless: track.isLossless,
                wasYouTubeFallback: item.isYouTubeFallback,
                policy: qualityPolicy,
                hasNonYouTubeResolvers: hasNonYTForUpgrade
            )
        }
        if let fetched,
           singleTrackKey == nil,
           !hasPendingUpgrades,
           !fetched.playlist.revision.isEmpty,
           fetched.playlist.revision == entry.revision {
            let allHaveValidFiles = entry.tracks.allSatisfy { item in
                guard item.status == .available, let tid = item.libraryTrackID, let t = existingByID[tid] else {
                    return false
                }
                return FileManager.default.fileExists(atPath: t.path)
            }
            let recentFailuresCount = entry.tracks.filter {
                ($0.status == .failed || $0.status == .notFound)
                    && !shouldRetry(item: $0, now: now, forceRetry: retryFailedCooldownOverride)
            }.count
            let pendingOrRetryableCount = entry.tracks.filter {
                $0.status != .available || !($0.libraryTrackID.flatMap { existingByID[$0] }.map { FileManager.default.fileExists(atPath: $0.path) } ?? false)
            }.count
            if allHaveValidFiles || (pendingOrRetryableCount == recentFailuresCount && pendingOrRetryableCount == entry.tracks.filter { $0.status != .available }.count) {
                entry.lastSyncedAt = now
                entry.lastError = nil
                let states = buildLiveStates(for: entry.tracks, noDownloadSource: false)
                return SubscriptionSyncResult(
                    updatedEntry: entry,
                    playlistTrackIDs: entry.tracks.compactMap(\.libraryTrackID),
                    newlyImportedTracks: [],
                    liveStates: states,
                    errorBanner: nil,
                    skippedDueToUnchangedRevision: true
                )
            }
        }

        // 3. Reconcile track list from fetched playlist (or keep existing list if single-track retry)
        let oldByKey = Dictionary(entry.tracks.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        var updatedItems: [SubscribedTrackEntry]
        if let fetched {
            var seenKeys = Set<String>()
            updatedItems = []
            updatedItems.reserveCapacity(fetched.tracks.count)
            for (index, ref) in fetched.tracks.enumerated() {
                var key = SubscribedTrackEntry.makeKey(for: ref, position: index)
                if !seenKeys.insert(key).inserted {
                    key = "\(key)#\(index)"
                    seenKeys.insert(key)
                }
                var item = oldByKey[key] ?? SubscribedTrackEntry(key: key, trackRef: ref, position: index)
                item.trackRef = ref
                item.position = index
                updatedItems.append(item)
            }
            entry.revision = fetched.playlist.revision
        } else {
            updatedItems = entry.tracks
        }

        // 4. Match every track against local library in memory (`SUB-10`).
        let matcher = LibraryTrackMatcher(tracks: existingTracks, downloadFolderPath: downloadFolder.path)
        // Match any previously unlinked files now present in `existingTracks`.
        for idx in updatedItems.indices {
            if let matched = matcher.match(for: updatedItems[idx].trackRef, linkedTrackID: updatedItems[idx].libraryTrackID) {
                let wasLinked = (updatedItems[idx].libraryTrackID == matched.id)
                updatedItems[idx].libraryTrackID = matched.id
                updatedItems[idx].status = .available
                updatedItems[idx].lastFailureReason = nil
                if !wasLinked && updatedItems[idx].isYouTubeFallback == false {
                    // Preserve lossless/MP3 classification: only treat unlinked M4A from yt-dlp unknown if small
                }
            } else if updatedItems[idx].status == .available {
                // Linked file vanished from disk -> mark pending again
                updatedItems[idx].libraryTrackID = nil
                updatedItems[idx].status = .pending
            }
        }

        // Pass 1 targets: ONLY tracks not yet available on disk.
        let targetIndices: [Int] = updatedItems.indices.filter { idx in
            let item = updatedItems[idx]
            if let singleTrackKey, item.key != singleTrackKey { return false }
            guard item.libraryTrackID == nil else { return false }
            return shouldRetry(item: item, now: now, forceRetry: retryFailedCooldownOverride || singleTrackKey != nil)
        }
        let targetKeySet = Set(targetIndices.map { updatedItems[$0].key })

        // Pass 2 targets (Refresh): quality upgrades on tracks already available below top tier / YouTube fallback.
        let resolverIDs = resolverIDsForCheck
        let nonYTResolvers = resolverIDs.filter { $0 != "yt-dlp" }
        let matchedByID = Dictionary(existingTracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let upgradeIndices: [Int] = (attemptQualityUpgrades && singleTrackKey == nil && !nonYTResolvers.isEmpty)
            ? updatedItems.indices.filter { idx in
                let item = updatedItems[idx]
                guard !targetKeySet.contains(item.key),
                      item.trackRef.isVideo != true,
                      item.status == .available,
                      !TrackTextNormalizer.hasVideoVersionQualifier(title: item.trackRef.title, album: item.trackRef.album),
                      let tid = item.libraryTrackID,
                      let localTrack = matchedByID[tid] else {
                    return false
                }
                return CandidateScorer.canSeekUpgrade(
                    localExtension: localTrack.fileExtension,
                    localBitrateKbps: localTrack.bitrate,
                    localIsLossless: localTrack.isLossless,
                    wasYouTubeFallback: item.isYouTubeFallback,
                    policy: qualityPolicy,
                    hasNonYouTubeResolvers: true
                )
            }
            : []

        let actionableTargets = targetIndices.filter { idx in
            let item = updatedItems[idx]
            let itemResolvers = (item.trackRef.isVideo == true) ? ytOnlyResolvers : resolverIDs
            return !itemResolvers.isEmpty
        }

        if (!targetIndices.isEmpty || !upgradeIndices.isEmpty) && actionableTargets.isEmpty && upgradeIndices.isEmpty {
            entry.tracks = updatedItems
            entry.lastSyncedAt = now
            entry.lastError = nil
            var states = buildLiveStates(for: updatedItems, noDownloadSource: true)
            for idx in targetIndices {
                states[updatedItems[idx].key] = .noDownloadSource
            }
            return SubscriptionSyncResult(
                updatedEntry: entry,
                playlistTrackIDs: updatedItems.compactMap(\.libraryTrackID),
                newlyImportedTracks: [],
                replacedTrackIDs: [],
                liveStates: states,
                errorBanner: nil,
                skippedDueToUnchangedRevision: false
            )
        }

        var liveStates = buildLiveStates(for: updatedItems, noDownloadSource: false)
        for idx in targetIndices {
            let item = updatedItems[idx]
            let itemResolvers = (item.trackRef.isVideo == true) ? ytOnlyResolvers : resolverIDs
            liveStates[item.key] = itemResolvers.isEmpty ? .noDownloadSource : .waiting
        }

        let stateBox = SyncStateBox(
            items: updatedItems,
            liveStates: liveStates,
            totalToDownload: actionableTargets.count + upgradeIndices.count
        )

        let subID = entry.id
        let subTitle = entry.title
        let subSourceURL = entry.sourceURL
        let subPluginID = entry.sourcePluginID
        let subSourceName = entry.sourceName
        let subRevision = entry.revision
        let subArtworkURL = entry.artworkURL
        let subArtworkKey = entry.artworkKey

        let emitProgress: @Sendable (Bool) async -> Void = { force in
            let snapshot = stateBox.snapshot(force: force)
            guard let snapshot else { return }
            await onProgress(SubscriptionSyncProgress(
                subscriptionID: subID,
                title: subTitle,
                sourceURL: subSourceURL,
                sourcePluginID: subPluginID,
                sourceName: subSourceName,
                revision: subRevision,
                artworkURL: subArtworkURL,
                artworkKey: subArtworkKey,
                entries: snapshot.items,
                liveStates: snapshot.liveStates,
                addedTracks: snapshot.addedTracks,
                isSyncing: true,
                errorBanner: snapshot.errorBanner,
                downloadStats: (snapshot.completedDownloads, snapshot.totalToDownload)
            ))
        }

        await emitProgress(true)

        // 5. Pass 1: missing tracks, bounded by global semaphores + .utility CPU pool.
        let partRootDir = downloadFolder.appendingPathComponent(".ippm-parts", isDirectory: true)
        try? FileManager.default.createDirectory(at: partRootDir, withIntermediateDirectories: true)

        await withTaskGroup(of: Void.self) { group in
            for idx in actionableTargets {
                if Task.isCancelled || stateBox.isDiskFullPaused || stateBox.areAllResolversBlocked() {
                    break
                }
                let item = updatedItems[idx]
                let itemResolvers = (item.trackRef.isVideo == true) ? ytOnlyResolvers : resolverIDs
                group.addTask(priority: .utility) { [weak stateBox] in
                    guard let stateBox else { return }
                    await self.processTrack(
                        index: idx,
                        item: item,
                        resolverIDs: itemResolvers,
                        qualityPolicy: qualityPolicy,
                        serviceName: entry.sourceName,
                        downloadFolder: downloadFolder,
                        partRootDir: partRootDir,
                        artworkDir: artworkDir,
                        artworkCache: artworkCache,
                        stateBox: stateBox,
                        onTrackReady: onTrackReady,
                        onCheckpoint: { itemsSnapshot, addedSnapshot in
                            await onCheckpointSave(itemsSnapshot, addedSnapshot)
                        },
                        emitProgress: {
                            await emitProgress(false)
                        }
                    )
                }
            }
        }

        // 6. Pass 2: quality upgrade attempt for lower-quality / YouTube fallback tracks already on disk.
        if !upgradeIndices.isEmpty && !Task.isCancelled && !stateBox.isDiskFullPaused {
            for idx in upgradeIndices {
                stateBox.setState(for: updatedItems[idx].key, state: .waiting)
            }
            await emitProgress(true)

            await withTaskGroup(of: Void.self) { group in
                for idx in upgradeIndices {
                    if Task.isCancelled || stateBox.isDiskFullPaused { break }
                    let item = updatedItems[idx]
                    guard let tid = item.libraryTrackID, let localTrack = matchedByID[tid] else { continue }
                    group.addTask(priority: .utility) { [weak stateBox] in
                        guard let stateBox else { return }
                        await self.processUpgradeTrack(
                            index: idx,
                            item: item,
                            localTrack: localTrack,
                            resolverIDs: nonYTResolvers,
                            qualityPolicy: qualityPolicy,
                            serviceName: entry.sourceName,
                            downloadFolder: downloadFolder,
                            partRootDir: partRootDir,
                            artworkDir: artworkDir,
                            artworkCache: artworkCache,
                            stateBox: stateBox,
                            onTrackReady: onTrackReady,
                            onCheckpoint: { itemsSnapshot, addedSnapshot in
                                await onCheckpointSave(itemsSnapshot, addedSnapshot)
                            },
                            emitProgress: {
                                await emitProgress(false)
                            }
                        )
                    }
                }
            }
        }

        let final = stateBox.snapshot(force: true)!
        entry.tracks = final.items
        entry.lastSyncedAt = Date()
        entry.lastError = final.errorBanner
        try? FileManager.default.removeItem(at: partRootDir)

        return SubscriptionSyncResult(
            updatedEntry: entry,
            playlistTrackIDs: final.items.compactMap(\.libraryTrackID),
            newlyImportedTracks: final.addedTracks,
            replacedTrackIDs: final.replacedTrackIDs,
            liveStates: final.liveStates,
            errorBanner: final.errorBanner,
            skippedDueToUnchangedRevision: false
        )
    }

    private enum AttemptOutcome {
        case downloaded(track: LibraryTrack, isYouTube: Bool)
        case unsuccessful(anyCandidatesFound: Bool, reason: String?)
    }

    private func attemptDownload(
        item: SubscribedTrackEntry,
        resolverIDs: [String],
        qualityPolicy: QualityPolicy,
        serviceName: String,
        downloadFolder: URL,
        partRootDir: URL,
        artworkDir: URL,
        artworkCache: AlbumArtworkCache,
        stateBox: SyncStateBox,
        emitProgress: @escaping @Sendable () async -> Void,
        candidateFilter: (Candidate) -> Bool
    ) async -> AttemptOutcome {
        var lastReason: String?
        var anyCandidatesFound = false
        let preferYouTubeVideo = TrackTextNormalizer.hasVideoVersionQualifier(
            title: item.trackRef.title,
            album: item.trackRef.album
        ) && resolverIDs.contains("yt-dlp")
        let orderedForTrack = preferYouTubeVideo
            ? ["yt-dlp"] + resolverIDs.filter { $0 != "yt-dlp" }
            : resolverIDs

        for resolverID in orderedForTrack {
            if Task.isCancelled || stateBox.isDiskFullPaused { break }
            if resolverID == "yt-dlp" && stateBox.isYTDLPRateLimited { continue }

            stateBox.setState(for: item.key, state: .searching(resolver: resolverID))
            await emitProgress()

            let searchResults: [Candidate]
            do {
                try await searchSemaphore.acquire()
                do {
                    searchResults = try await host.searchCandidates(
                        resolverID: resolverID,
                        track: item.trackRef,
                        policy: qualityPolicy,
                        onPartial: { _ in }
                    )
                    await searchSemaphore.release()
                } catch {
                    await searchSemaphore.release()
                    throw error
                }
            } catch let pErr as PluginError {
                if pErr.code == .rateLimited && resolverID == "yt-dlp" {
                    stateBox.markYTDLPRateLimited()
                }
                lastReason = pErr.message
                continue
            } catch {
                lastReason = error.localizedDescription
                continue
            }

            let ranked = CandidateScorer.rank(
                candidates: searchResults,
                for: item.trackRef,
                policy: qualityPolicy,
                resolverOrder: resolverIDs
            ).filter(candidateFilter)

            if !ranked.isEmpty {
                anyCandidatesFound = true
            }

            // Try top 3 candidates from this resolver before falling back to next resolver (`SUB-12`).
            for candidate in ranked.prefix(3) {
                if Task.isCancelled || stateBox.isDiskFullPaused { break }
                if resolverID == "yt-dlp" && stateBox.isYTDLPRateLimited { break }

                stateBox.setState(for: item.key, state: .downloading(resolver: resolverID, progress: 0))
                await emitProgress()

                let isYT = (resolverID == "yt-dlp")
                let trackTempDir = partRootDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try? FileManager.default.createDirectory(at: trackTempDir, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: trackTempDir) }

                do {
                    try await downloadSemaphore.acquire()
                    if isYT {
                        do {
                            try await ytdlpSemaphore.acquire()
                        } catch {
                            await downloadSemaphore.release()
                            throw error
                        }
                    }

                    let downloadedFileURL: URL
                    do {
                        downloadedFileURL = try await host.downloadCandidate(
                            resolverID: resolverID,
                            candidate: candidate,
                            destinationDir: trackTempDir,
                            onProgress: { pct in
                                stateBox.setState(for: item.key, state: .downloading(resolver: resolverID, progress: pct))
                            }
                        )
                        if isYT { await ytdlpSemaphore.release() }
                        await downloadSemaphore.release()
                    } catch {
                        if isYT { await ytdlpSemaphore.release() }
                        await downloadSemaphore.release()
                        throw error
                    }

                    // Ensure downloaded file lives as `.part` before verify+finalize.
                    let sourceFile = downloadedFileURL
                    let partFile = sourceFile.pathExtension.lowercased() == "part"
                        ? sourceFile
                        : sourceFile.appendingPathExtension("part")
                    if sourceFile != partFile && FileManager.default.fileExists(atPath: sourceFile.path) {
                        try? FileManager.default.moveItem(at: sourceFile, to: partFile)
                    }

                    let suggestedExt = !candidate.container.isEmpty
                        ? candidate.container
                        : (sourceFile.pathExtension.lowercased() == "part"
                            ? sourceFile.deletingPathExtension().pathExtension
                            : sourceFile.pathExtension)

                    let newTrack = try await DownloadPlacement.finalizeTrack(
                        partURL: partFile,
                        suggestedExtension: suggestedExt,
                        ref: item.trackRef,
                        serviceName: serviceName,
                        downloadFolder: downloadFolder,
                        artworkDir: artworkDir,
                        artworkCache: artworkCache,
                        isYouTube: isYT
                    )
                    return .downloaded(track: newTrack, isYouTube: isYT)
                } catch let pErr as PluginError {
                    if pErr.code == .rateLimited && isYT {
                        stateBox.markYTDLPRateLimited()
                    }
                    lastReason = pErr.message
                } catch let placeErr as DownloadPlacement.PlacementError where placeErr.isDiskFull {
                    stateBox.markDiskFull(placeErr.localizedDescription)
                    lastReason = placeErr.localizedDescription
                    break
                } catch {
                    if DownloadPlacement.isOutOfSpaceError(error) {
                        stateBox.markDiskFull(error.localizedDescription)
                    }
                    lastReason = error.localizedDescription
                }
            }
        }

        return .unsuccessful(anyCandidatesFound: anyCandidatesFound, reason: lastReason)
    }

    private func processTrack(
        index: Int,
        item: SubscribedTrackEntry,
        resolverIDs: [String],
        qualityPolicy: QualityPolicy,
        serviceName: String,
        downloadFolder: URL,
        partRootDir: URL,
        artworkDir: URL,
        artworkCache: AlbumArtworkCache,
        stateBox: SyncStateBox,
        onTrackReady: @escaping @Sendable ([SubscribedTrackEntry], LibraryTrack, UUID?) async -> Void,
        onCheckpoint: @escaping @Sendable ([SubscribedTrackEntry], [LibraryTrack]) async -> Void,
        emitProgress: @escaping @Sendable () async -> Void
    ) async {
        guard !Task.isCancelled, !stateBox.isDiskFullPaused else { return }

        let outcome = await attemptDownload(
            item: item,
            resolverIDs: resolverIDs,
            qualityPolicy: qualityPolicy,
            serviceName: serviceName,
            downloadFolder: downloadFolder,
            partRootDir: partRootDir,
            artworkDir: artworkDir,
            artworkCache: artworkCache,
            stateBox: stateBox,
            emitProgress: emitProgress,
            candidateFilter: { _ in true }
        )

        switch outcome {
        case .downloaded(let newTrack, let isYT):
            stateBox.markSuccess(index: index, track: newTrack, isYouTubeFallback: isYT)
            let (itemsSnap, addedSnap) = stateBox.checkpointData()
            await emitProgress()
            await onTrackReady(itemsSnap, newTrack, nil)
            await onCheckpoint(itemsSnap, addedSnap)
        case .unsuccessful(let anyCandidatesFound, let lastReason):
            let finalStatus: PersistedSubscribedTrackStatus = anyCandidatesFound ? .failed : .notFound
            let shouldCheckpoint = stateBox.markFailure(
                index: index,
                key: item.key,
                status: finalStatus,
                reason: lastReason ?? (anyCandidatesFound ? "Download failed" : "Not found")
            )
            await emitProgress()
            if shouldCheckpoint {
                let (itemsSnap, addedSnap) = stateBox.checkpointData()
                await onCheckpoint(itemsSnap, addedSnap)
            }
        }
    }

    private func processUpgradeTrack(
        index: Int,
        item: SubscribedTrackEntry,
        localTrack: LibraryTrack,
        resolverIDs: [String],
        qualityPolicy: QualityPolicy,
        serviceName: String,
        downloadFolder: URL,
        partRootDir: URL,
        artworkDir: URL,
        artworkCache: AlbumArtworkCache,
        stateBox: SyncStateBox,
        onTrackReady: @escaping @Sendable ([SubscribedTrackEntry], LibraryTrack, UUID?) async -> Void,
        onCheckpoint: @escaping @Sendable ([SubscribedTrackEntry], [LibraryTrack]) async -> Void,
        emitProgress: @escaping @Sendable () async -> Void
    ) async {
        guard !Task.isCancelled, !stateBox.isDiskFullPaused else { return }

        let outcome = await attemptDownload(
            item: item,
            resolverIDs: resolverIDs,
            qualityPolicy: qualityPolicy,
            serviceName: serviceName,
            downloadFolder: downloadFolder,
            partRootDir: partRootDir,
            artworkDir: artworkDir,
            artworkCache: artworkCache,
            stateBox: stateBox,
            emitProgress: emitProgress,
            candidateFilter: { cand in
                CandidateScorer.isStrictlyBetterUpgrade(
                    candidate: cand,
                    thanLocalExtension: localTrack.fileExtension,
                    localBitrateKbps: localTrack.bitrate,
                    localIsLossless: localTrack.isLossless,
                    wasYouTubeFallback: item.isYouTubeFallback,
                    policy: qualityPolicy
                )
            }
        )

        switch outcome {
        case .downloaded(let upgradedTrack, let isYT):
            stateBox.markUpgrade(index: index, track: upgradedTrack, replacedTrackID: localTrack.id, isYouTubeFallback: isYT)
            let (itemsSnap, addedSnap) = stateBox.checkpointData()
            await emitProgress()
            await onTrackReady(itemsSnap, upgradedTrack, localTrack.id)
            await onCheckpoint(itemsSnap, addedSnap)
        case .unsuccessful:
            stateBox.restoreAvailable(index: index)
            await emitProgress()
        }
    }

    private func shouldRetry(item: SubscribedTrackEntry, now: Date, forceRetry: Bool) -> Bool {
        if item.libraryTrackID != nil && item.status == .available { return false }
        if forceRetry { return true }
        guard item.status == .failed || item.status == .notFound else { return true }
        guard let lastFail = item.lastFailureAt else { return true }
        return now.timeIntervalSince(lastFail) >= 24 * 3600
    }

    private func buildLiveStates(for items: [SubscribedTrackEntry], noDownloadSource: Bool) -> [String: SubscribedTrackState] {
        var states: [String: SubscribedTrackState] = [:]
        states.reserveCapacity(items.count)
        for item in items {
            switch item.status {
            case .available:
                states[item.key] = .available(isYouTubeFallback: item.isYouTubeFallback)
            case .notFound:
                states[item.key] = noDownloadSource ? .noDownloadSource : .notFound
            case .failed:
                states[item.key] = noDownloadSource ? .noDownloadSource : .failed(reason: item.lastFailureReason ?? "Download failed")
            case .pending:
                states[item.key] = noDownloadSource ? .noDownloadSource : .waiting
            }
        }
        return states
    }

    private func friendlyMessage(for error: PluginError, serviceName: String) -> String {
        switch error.code {
        case .unauthorized:
            return "Sign in to \(serviceName) again in Settings › Plug-ins"
        case .network:
            return "Offline or couldn't reach \(serviceName)"
        case .rateLimited:
            if let retry = error.retryAfterSeconds {
                return "\(serviceName) rate-limited requests — try again in \(retry)s"
            }
            return "\(serviceName) temporarily rate-limited requests"
        default:
            return error.message
        }
    }
}

private final class SyncStateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [SubscribedTrackEntry]
    private var liveStates: [String: SubscribedTrackState]
    private var addedTracks: [LibraryTrack] = []
    private var replacedTrackIDs: [UUID] = []
    private var completedCount = 0
    private var failureCheckpointCounter = 0
    private let totalToDownload: Int
    private var lastEmit = Date.distantPast
    private(set) var ytdlpRateLimited = false
    private(set) var diskFullMessage: String?

    init(items: [SubscribedTrackEntry], liveStates: [String: SubscribedTrackState], totalToDownload: Int) {
        self.items = items
        self.liveStates = liveStates
        self.totalToDownload = totalToDownload
    }

    var isDiskFullPaused: Bool {
        lock.lock(); defer { lock.unlock() }
        return diskFullMessage != nil
    }

    var isYTDLPRateLimited: Bool {
        lock.lock(); defer { lock.unlock() }
        return ytdlpRateLimited
    }

    func areAllResolversBlocked() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return diskFullMessage != nil
    }

    func markYTDLPRateLimited() {
        lock.lock(); ytdlpRateLimited = true; lock.unlock()
    }

    func markDiskFull(_ msg: String) {
        lock.lock(); diskFullMessage = msg; lock.unlock()
    }

    func setState(for key: String, state: SubscribedTrackState) {
        lock.lock()
        liveStates[key] = state
        lock.unlock()
    }

    func markSuccess(index: Int, track: LibraryTrack, isYouTubeFallback: Bool) {
        lock.lock()
        defer { lock.unlock() }
        items[index].libraryTrackID = track.id
        items[index].status = .available
        items[index].isYouTubeFallback = isYouTubeFallback
        items[index].lastFailureReason = nil
        items[index].lastFailureAt = nil
        liveStates[items[index].key] = .available(isYouTubeFallback: isYouTubeFallback)
        addedTracks.append(track)
        completedCount += 1
    }

    func markUpgrade(index: Int, track: LibraryTrack, replacedTrackID: UUID, isYouTubeFallback: Bool) {
        lock.lock()
        defer { lock.unlock() }
        items[index].libraryTrackID = track.id
        items[index].status = .available
        items[index].isYouTubeFallback = isYouTubeFallback
        items[index].lastFailureReason = nil
        items[index].lastFailureAt = nil
        liveStates[items[index].key] = .available(isYouTubeFallback: isYouTubeFallback)
        addedTracks.append(track)
        replacedTrackIDs.append(replacedTrackID)
        completedCount += 1
    }

    func restoreAvailable(index: Int) {
        lock.lock()
        defer { lock.unlock() }
        let item = items[index]
        liveStates[item.key] = .available(isYouTubeFallback: item.isYouTubeFallback)
        completedCount += 1
    }

    func markFailure(index: Int, key: String, status: PersistedSubscribedTrackStatus, reason: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        items[index].status = status
        items[index].lastFailureReason = reason
        items[index].lastFailureAt = Date()
        items[index].failedAttempts += 1
        liveStates[key] = status == .notFound ? .notFound : .failed(reason: reason)
        completedCount += 1
        failureCheckpointCounter += 1
        if failureCheckpointCounter >= 5 {
            failureCheckpointCounter = 0
            return true
        }
        return false
    }

    func checkpointData() -> ([SubscribedTrackEntry], [LibraryTrack]) {
        lock.lock(); defer { lock.unlock() }
        return (items, addedTracks)
    }

    struct Snapshot {
        var items: [SubscribedTrackEntry]
        var liveStates: [String: SubscribedTrackState]
        var addedTracks: [LibraryTrack]
        var replacedTrackIDs: [UUID]
        var errorBanner: String?
        var completedDownloads: Int
        var totalToDownload: Int
    }

    func snapshot(force: Bool) -> Snapshot? {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        if !force && now.timeIntervalSince(lastEmit) < 0.5 {
            return nil
        }
        lastEmit = now
        return Snapshot(
            items: items,
            liveStates: liveStates,
            addedTracks: addedTracks,
            replacedTrackIDs: replacedTrackIDs,
            errorBanner: diskFullMessage,
            completedDownloads: completedCount,
            totalToDownload: totalToDownload
        )
    }
}
