import Foundation
import iPodKit
import MediaKit
import DeviceKit

struct LoadedPortableLibrary {
    var store: PortableLibraryStore
    var cache: PortableLibraryCache
    var configured: Bool
    var audiobooksConfigured = false
}

enum PortableLoading {
    static func load(folder: URL? = nil, audiobooksFolder: URL? = nil, refresh: Bool = false, removedKind: SourceKind? = nil, removedSourcePath: String? = nil, root overrideRoot: URL? = nil, legacyLibraryURL: URL? = nil) async throws -> LoadedPortableLibrary {
        try await Task.detached(priority: .userInitiated) {
            guard let root = overrideRoot ?? PortableRoot.url else { throw LoadingError.noRoot }
            guard let hostID = HostIdentity.current() else { throw LoadingError.noIdentity }
            let store = PortableLibraryStore(root: root, hostID: hostID)
            try store.data.requireAvailableStorage()
            var selectedFolder = folder
            var cache = try store.cacheChecked()
            let originalCache = cache
            // One-time, read-only migration of this Mac's legacy library; never write back to it.
            #if os(macOS)
            if cache.tracks.isEmpty, store.data.read(KnownHosts.self, from: "known_hosts.json")?.hosts.contains(where: { $0.id == hostID }) != true {
                let legacy = legacyLibraryURL ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/iPod Pro Max/library.json")
                if let bytes = try? Data(contentsOf: legacy), let doc = try? JSONDecoder().decode(iPodKit.LibraryDocument.self, from: bytes) {
                    cache = PortableLibraryCache(tracks: doc.tracks, playlists: doc.playlists, videoPlaylists: doc.videoPlaylists)
                    if selectedFolder == nil, let path = doc.musicFolderPath { selectedFolder = URL(fileURLWithPath: path) }
                    let oldArt = legacy.deletingLastPathComponent().appendingPathComponent("Artwork")
                    if FileManager.default.fileExists(atPath: oldArt.path), !FileManager.default.fileExists(atPath: store.artwork.path) {
                        try FileManager.default.createDirectory(at: store.hostFolder.url, withIntermediateDirectories: true)
                        try FileManager.default.copyItem(at: oldArt, to: store.artwork)
                    }
                }
            }
            #endif
            let host = try store.register(name: ProcessInfo.processInfo.hostName, musicFolder: selectedFolder, audiobooksFolder: audiobooksFolder)
            // A source removal can have committed before a previous scan failed. Reconcile those
            // removals on retry without treating a temporarily unavailable registered source as removed.
            let currentSourceIDs = Set(host.sources.map { $0.id.uuidString })
            let remainingMusicSources = host.sources.filter { $0.kind == .music }
            let remainingMusicRoots = remainingMusicSources.map(\.path)
            var sourceHistory = cache.sourcePathHistory ?? [:]
            for source in remainingMusicSources {
                let id = source.id.uuidString
                if let previous = cache.sourcePaths?[id], previous != source.path,
                   !(sourceHistory[id] ?? []).contains(previous) {
                    sourceHistory[id, default: []].append(previous)
                }
            }
            let activeHistory = remainingMusicSources.flatMap { sourceHistory[$0.id.uuidString] ?? [] }
            let retainedRoots = remainingMusicRoots + activeHistory
            // Resolve each source root once. Canonical keys avoid per-track filesystem lookups and
            // keep overlapping or symlinked sources from importing the same audio more than once.
            let roots = retainedRoots + Array(cache.sourcePaths?.values ?? Dictionary<String, String>().values)
            let aliases: [(path: String, canonical: String)] = roots.map { root in
                let url = URL(fileURLWithPath: root).standardizedFileURL
                return (url.path, FileOps.canonicalPath(url))
            }.sorted { $0.path.count > $1.path.count }
            func musicPathKey(_ path: String) -> String {
                let path = URL(fileURLWithPath: path).standardizedFileURL.path
                for alias in aliases where path == alias.path || path.hasPrefix(alias.path.hasSuffix("/") ? alias.path : alias.path + "/") {
                    return alias.canonical + path.dropFirst(alias.path.count)
                }
                return path
            }
            cache.coalesceMusicTracks(pathKey: musicPathKey)
            cache.reconcileFavoriteReferences()
            var previousTracks = cache.tracks
            if let removedSourcePath, removedKind == .music {
                cache.forgetFavoriteReferences(under: removedSourcePath, keeping: retainedRoots)
            }
            for (id, oldRoot) in cache.sourcePaths ?? [:] where !currentSourceIDs.contains(id) {
                cache.forgetFavoriteReferences(under: oldRoot, keeping: retainedRoots)
            }
            for (id, oldRoots) in sourceHistory where !currentSourceIDs.contains(id) {
                for oldRoot in oldRoots { cache.forgetFavoriteReferences(under: oldRoot, keeping: retainedRoots) }
            }
            sourceHistory = sourceHistory.filter { currentSourceIDs.contains($0.key) }
            if try store.data.readChecked(PortableSettings.self, from: "settings.json") == nil { try store.data.write(PortableSettings(), to: "settings.json") }
            let scanBooks = refresh || audiobooksFolder != nil
            if scanBooks, host.sources.contains(where: { $0.kind == .audiobooks }) {
                var books: [LibraryTrack] = []
                for source in host.sources where source.kind == .audiobooks {
                    let scanned = await AudiobookScanner.scan(folder: URL(fileURLWithPath: source.path), artworkDir: store.artwork,
                        cached: cache.tracks.filter(\.isAudiobook), namespace: source.id.uuidString)
                    books.append(contentsOf: scanned.tracks)
                }
                cache.tracks = cache.tracks.filter { !$0.isAudiobook } + books
            }
            if (refresh || folder != nil), host.sources.contains(where: { $0.kind == .music }) {
                let books = cache.tracks.filter(\.isAudiobook)
                var tracks: [LibraryTrack] = []
                let musicSources = host.sources.filter { $0.kind == .music }.sorted {
                    let a = musicPathKey($0.path), b = musicPathKey($1.path)
                    return a.count == b.count ? a < b : a.count < b.count
                }
                for source in musicSources {
                    let previousRoots = (sourceHistory[source.id.uuidString] ?? []).sorted { $0.count > $1.count }
                    let otherRoots = musicSources.filter { $0.id != source.id }.map(\.path)
                    let otherPrefixes = otherRoots.map { root -> String in
                        let path = URL(fileURLWithPath: root).standardizedFileURL.path
                        return path.hasSuffix("/") ? path : path + "/"
                    }
                    var relocationRules: [(old: String, movedCovered: Set<String>)] = []
                    for previousRoot in previousRoots {
                        let old = URL(fileURLWithPath: previousRoot).standardizedFileURL.path
                        let new = URL(fileURLWithPath: source.path).standardizedFileURL.path
                        let prefix = old.hasSuffix("/") ? old : old + "/"
                        var relocatingCoveredPaths = Set<String>()
                        if old != new {
                            // A track also covered by another source stays there while the old file
                            // exists. If it has actually moved, preserve its ID at the new location.
                            let paths = Set((previousTracks.map(\.path) + (cache.offlineTracks ?? []).map(\.path) +
                                             (cache.favoriteReferences ?? []).map(\.path)).map { URL(fileURLWithPath: $0).standardizedFileURL.path })
                            let covered = paths.filter { path in path.hasPrefix(prefix) && otherPrefixes.contains(where: { path.hasPrefix($0) }) }
                            let candidatesArray = Array(covered)
                            let relocation = await withTaskGroup(of: (String, Bool, Bool).self) { group in
                                var next = 0
                                func addNext() {
                                    guard next < candidatesArray.count else { return }
                                    let path = candidatesArray[next]; next += 1
                                    let replacement = new + "/" + path.dropFirst(prefix.count)
                                    group.addTask {
                                        let fm = FileManager.default
                                        let existsOld = fm.fileExists(atPath: path)
                                        let existsNew = fm.fileExists(atPath: replacement)
                                        return (path, !existsOld && existsNew, !existsOld && !existsNew)
                                    }
                                }
                                for _ in 0..<min(max(1, ProcessInfo.processInfo.activeProcessorCount), candidatesArray.count) { addNext() }
                                var moved = Set<String>()
                                var unresolved = false
                                for await (path, didMove, isUnresolved) in group {
                                    if didMove { moved.insert(path) }
                                    if isUnresolved { unresolved = true }
                                    addNext()
                                }
                                return (moved, unresolved)
                            }
                            relocatingCoveredPaths = relocation.0
                            for index in previousTracks.indices {
                                let path = URL(fileURLWithPath: previousTracks[index].path).standardizedFileURL.path
                                if path.hasPrefix(prefix) && (!otherPrefixes.contains(where: { path.hasPrefix($0) }) || relocatingCoveredPaths.contains(path)) {
                                    previousTracks[index].path = new + "/" + path.dropFirst(prefix.count)
                                }
                            }
                        }
                        cache.relocateFavoriteReferences(from: previousRoot, to: source.path, keeping: otherRoots,
                                                         relocatingCoveredPaths: relocatingCoveredPaths)
                        relocationRules.append((old, relocatingCoveredPaths))
                    }
                    let canonicalRoot = musicPathKey(source.path)
                    let sourceRoot = URL(fileURLWithPath: source.path).standardizedFileURL.path
                    // Previously scanned tracks are valid cache hits for nested sources, avoiding
                    // repeated tag/artwork work while still visiting explicit hidden or restricted roots.
                    let relocated = (cache.cachedTracksIncludingFavorites() + tracks).map { track -> LibraryTrack in
                        var track = track
                        for rule in relocationRules {
                            let new = URL(fileURLWithPath: source.path).standardizedFileURL.path
                            let prefix = rule.old.hasSuffix("/") ? rule.old : rule.old + "/"
                            let path = URL(fileURLWithPath: track.path).standardizedFileURL.path
                            if rule.old != new && path.hasPrefix(prefix) && (!otherPrefixes.contains(where: { path.hasPrefix($0) }) || rule.movedCovered.contains(path)) {
                                track.path = new + "/" + path.dropFirst(prefix.count)
                                break
                            }
                        }
                        let key = musicPathKey(track.path)
                        if key.hasPrefix(canonicalRoot.hasSuffix("/") ? canonicalRoot : canonicalRoot + "/") {
                            track.path = sourceRoot + key.dropFirst(canonicalRoot.count)
                        }
                        return track
                    }
                    let scanned = await FolderImporter.scan(folder: URL(fileURLWithPath: source.path), artworkDir: store.artwork,
                        cached: relocated, namespace: source.id.uuidString, musicOnly: true,
                        excluding: host.sources.filter { $0.kind == .audiobooks }.map { URL(fileURLWithPath: $0.path) })
                    tracks.append(contentsOf: scanned.tracks)
                }
                cache.tracks = tracks + books
                cache.coalesceMusicTracks(pathKey: musicPathKey)
                cache.sourcePaths = Dictionary(host.sources.map { ($0.id.uuidString, $0.path) }, uniquingKeysWith: { a, _ in a })
            } else {
                cache.tracks.removeAll { !FileManager.default.isReadableFile(atPath: $0.path) }
            }
            // The library only holds what the folders in Settings hold: the last folder of a kind was
            // removed (its tracks go), or a folder left known_hosts.json while the app was closed.
            let musicRoots = host.sources.filter { $0.kind == .music || $0.kind == .audiobooks }.map { $0.path.hasSuffix("/") ? $0.path : $0.path + "/" }
            if removedKind == .music, !host.sources.contains(where: { $0.kind == .music }) {
                cache.tracks = cache.tracks.filter(\.isAudiobook)
            }
            if removedKind == .audiobooks, !host.sources.contains(where: { $0.kind == .audiobooks }) {
                cache.tracks = cache.tracks.filter { !$0.isAudiobook }
            }
            if !musicRoots.isEmpty {
                cache.tracks.removeAll { track in !musicRoots.contains { track.path.hasPrefix($0) } }
            } else if cache.sourcePaths != nil {
                // Previously registered sources were removed, even if an earlier refresh failed.
                cache.tracks.removeAll()
            }
            if let paths = cache.sourcePaths {
                cache.sourcePaths = paths.filter { currentSourceIDs.contains($0.key) }
            }
            // The scan only displays accessible tracks; offline entries retain identities and user choices.
            cache.reconcileOfflineTracks(previous: previousTracks, keeping: retainedRoots)
            cache.reconcileFavoriteReferences()
            // Histories are bounded by genuinely unresolved offline identities, and removed when
            // sources disappear or their tracks reappear at either location.
            let visibleIDs = Set(cache.tracks.map(\.id))
            let unresolvedPaths = (cache.offlineTracks ?? []).map(\.path) + (cache.favoriteReferences ?? []).filter { !visibleIDs.contains($0.id) }.map(\.path)
            sourceHistory = sourceHistory.compactMapValues { roots in
                let pending = roots.filter { root in
                    let normalized = URL(fileURLWithPath: root).standardizedFileURL.path
                    let prefix = normalized.hasSuffix("/") ? normalized : normalized + "/"
                    return unresolvedPaths.contains { URL(fileURLWithPath: $0).standardizedFileURL.path.hasPrefix(prefix) }
                }
                return pending.isEmpty ? nil : Array(Set(pending)).sorted()
            }
            cache.sourcePathHistory = sourceHistory.isEmpty ? nil : sourceHistory
            // Playlist membership is a saved choice. Missing tracks have no visible rows,
            // but keep their IDs so a reconnected source can populate the playlist again.
            if cache != originalCache { try store.save(cache) }
            return LoadedPortableLibrary(store: store, cache: cache, configured: host.sources.contains { $0.kind == .music },
                                         audiobooksConfigured: host.sources.contains { $0.kind == .audiobooks })
        }.value
    }
    enum LoadingError: LocalizedError {
        case noRoot, noIdentity
        var errorDescription: String? {
            switch self {
            case .noRoot: return "Launch the app from the iPod to use its portable library."
            case .noIdentity: return "This computer could not be identified. No local data was created."
            }
        }
    }
}
