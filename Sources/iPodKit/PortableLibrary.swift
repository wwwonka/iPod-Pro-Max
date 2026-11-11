import Foundation

public enum SourceKind: String, Codable, Sendable {
    case music, audiobooks, videos, photos
    /// Folders dedicated to one kind of video (Settings → General → Videos).
    case movies, tvShows, musicVideos, webVideos
}

public struct KnownSource: Codable, Equatable, Sendable {
    public var id: UUID
    public var kind: SourceKind
    public var path: String
    public init(id: UUID = UUID(), kind: SourceKind = .music, path: String) {
        self.id = id; self.kind = kind; self.path = path
    }
}

public struct KnownHost: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var sources: [KnownSource]
    public init(id: String, name: String, sources: [KnownSource] = []) {
        self.id = id; self.name = name; self.sources = sources
    }
    private enum CodingKeys: String, CodingKey { case id, name, sources }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? id
        sources = try values.decodeIfPresent([KnownSource].self, forKey: .sources) ?? []
    }
}

public struct KnownHosts: Codable, Sendable {
    public var version = 1
    public var hosts: [KnownHost] = []
    public init() {}
    private enum CodingKeys: String, CodingKey { case version, hosts }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        hosts = try values.decodeIfPresent([KnownHost].self, forKey: .hosts) ?? []
    }
}

/// Minimal identity for a favorite whose source is temporarily unavailable.
public struct PortableFavoriteReference: Codable, Equatable, Sendable {
    public var id: UUID
    public var path: String
    public init(id: UUID, path: String) { self.id = id; self.path = path }
}

public struct PortableLibraryCache: Codable, Equatable, Sendable {
    public var version = 1
    public var tracks: [LibraryTrack]
    public var playlists: [LibraryPlaylist]
    public var videoPlaylists: [LibraryPlaylist]
    public var sourcePaths: [String: String]?
    /// Unresolved historical roots per registered Music source; dropped once all tracks resolve.
    public var sourcePathHistory: [String: [String]]?
    /// Kept separately so unavailable favorites can regain their identity on a later scan.
    public var favoriteReferences: [PortableFavoriteReference]?
    /// Unavailable media is never displayed; retain identity and user metadata until its source returns.
    public var offlineTracks: [LibraryTrack]?
    public init(tracks: [LibraryTrack] = [], playlists: [LibraryPlaylist] = [], videoPlaylists: [LibraryPlaylist] = []) {
        self.tracks = tracks; self.playlists = playlists; self.videoPlaylists = videoPlaylists
    }
    private enum CodingKeys: String, CodingKey { case version, tracks, playlists, videoPlaylists, sourcePaths, sourcePathHistory, favoriteReferences, offlineTracks }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        tracks = try values.decodeIfPresent([LibraryTrack].self, forKey: .tracks) ?? []
        playlists = try values.decodeIfPresent([LibraryPlaylist].self, forKey: .playlists) ?? []
        videoPlaylists = try values.decodeIfPresent([LibraryPlaylist].self, forKey: .videoPlaylists) ?? []
        sourcePaths = try values.decodeIfPresent([String: String].self, forKey: .sourcePaths)
        sourcePathHistory = try values.decodeIfPresent([String: [String]].self, forKey: .sourcePathHistory)
        favoriteReferences = try values.decodeIfPresent([PortableFavoriteReference].self, forKey: .favoriteReferences)
        offlineTracks = try values.decodeIfPresent([LibraryTrack].self, forKey: .offlineTracks)
    }

    /// Merge visible choices without discarding favorites whose media is unavailable.
    public mutating func reconcileFavoriteReferences() {
        var references = Dictionary((favoriteReferences ?? []).map { ($0.id, $0) }, uniquingKeysWith: { _, newer in newer })
        let favorites = Set(tracks.lazy.filter { $0.isFavorite == true }.map(\.id))
        for track in tracks {
            if favorites.contains(track.id) { references[track.id] = PortableFavoriteReference(id: track.id, path: track.path) }
            else { references.removeValue(forKey: track.id) }
        }
        favoriteReferences = references.values.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    /// Keep offline references in step when a remembered source changes location.
    public mutating func relocateFavoriteReferences(from previousRoot: String, to newRoot: String, keeping remainingRoots: [String] = [], relocatingCoveredPaths: Set<String> = []) {
        let old = URL(fileURLWithPath: previousRoot).standardizedFileURL.path
        let new = URL(fileURLWithPath: newRoot).standardizedFileURL.path
        guard old != new else { return }
        let oldPrefix = old.hasSuffix("/") ? old : old + "/"
        let retained = remainingRoots.map { root -> String in
            let path = URL(fileURLWithPath: root).standardizedFileURL.path
            return path.hasSuffix("/") ? path : path + "/"
        }
        func relocated(_ value: String) -> String? {
            let path = URL(fileURLWithPath: value).standardizedFileURL.path
            guard path.hasPrefix(oldPrefix),
                  !retained.contains(where: { path.hasPrefix($0) }) || relocatingCoveredPaths.contains(path) else { return nil }
            return new + "/" + path.dropFirst(oldPrefix.count)
        }
        for index in (favoriteReferences ?? []).indices {
            if let path = relocated(favoriteReferences![index].path) { favoriteReferences![index].path = path }
        }
        for index in (offlineTracks ?? []).indices {
            if let path = relocated(offlineTracks![index].path) { offlineTracks![index].path = path }
        }
    }

    /// Explicit removal of a source forgets its unavailable favorite references too.
    public mutating func forgetFavoriteReferences(under root: String, keeping remainingRoots: [String] = []) {
        func prefix(_ path: String) -> String {
            let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
            return normalized.hasSuffix("/") ? normalized : normalized + "/"
        }
        let removed = prefix(root)
        let retained = remainingRoots.map(prefix)
        func shouldForget(_ path: String) -> Bool {
            let path = URL(fileURLWithPath: path).standardizedFileURL.path
            return path.hasPrefix(removed) && !retained.contains { path.hasPrefix($0) }
        }
        favoriteReferences?.removeAll { shouldForget($0.path) }
        offlineTracks?.removeAll { shouldForget($0.path) }
    }

    /// Collapse already-imported overlapping Music sources while preserving playlist references.
    /// The caller supplies a canonical key computed from source-root aliases, not per-track I/O.
    public mutating func coalesceMusicTracks(pathKey: (String) -> String) {
        let playlistIDs = Set(playlists.flatMap(\.trackIDs))
        var groups: [String: [Int]] = [:]
        for index in tracks.indices where tracks[index].mediaKind == .song {
            groups[pathKey(tracks[index].path), default: []].append(index)
        }
        var removed = Set<Int>()
        var remap: [UUID: UUID] = [:]
        for indices in groups.values where indices.count > 1 {
            let preferred = indices.first(where: { playlistIDs.contains(tracks[$0].id) }) ?? indices[0]
            let keep = indices[0]
            var merged = tracks[keep]
            let preferredTrack = tracks[preferred]
            merged.id = preferredTrack.id
            merged.isFavorite = indices.contains(where: { tracks[$0].isFavorite == true }) ? true : preferredTrack.isFavorite
            merged.rating = preferredTrack.rating != 0 ? preferredTrack.rating : indices.map { tracks[$0].rating }.first(where: { $0 != 0 }) ?? 0
            merged.playCount = indices.map { tracks[$0].playCount }.max() ?? 0
            merged.dateAdded = indices.map { tracks[$0].dateAdded }.min() ?? merged.dateAdded
            for index in indices {
                if tracks[index].id != merged.id { remap[tracks[index].id] = merged.id }
                if index != keep { removed.insert(index) }
            }
            tracks[keep] = merged
        }
        guard !removed.isEmpty else { return }
        tracks = tracks.enumerated().compactMap { removed.contains($0.offset) ? nil : $0.element }
        for index in playlists.indices {
            playlists[index].trackIDs = playlists[index].trackIDs.map { remap[$0] ?? $0 }
        }
        for index in (favoriteReferences ?? []).indices {
            if let replacement = remap[favoriteReferences![index].id] { favoriteReferences![index].id = replacement }
        }
    }

    /// Move previously visible but unavailable tracks out of the UI while retaining IDs and choices.
    public mutating func reconcileOfflineTracks(previous: [LibraryTrack], keeping roots: [String]) {
        let prefixes = roots.map { root -> String in
            let path = URL(fileURLWithPath: root).standardizedFileURL.path
            return path.hasSuffix("/") ? path : path + "/"
        }
        let visible = Set(tracks.map(\.id))
        var saved: [UUID: LibraryTrack] = [:]
        for track in (offlineTracks ?? []) + previous where !visible.contains(track.id) && track.mediaKind == .song {
            let path = URL(fileURLWithPath: track.path).standardizedFileURL.path
            if prefixes.contains(where: { path.hasPrefix($0) }) { saved[track.id] = track }
        }
        offlineTracks = saved.values.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    /// Synthetic cache entries are used only as scan identity hints, never as visible media.
    public func cachedTracksIncludingFavorites() -> [LibraryTrack] {
        let visibleIDs = Set(tracks.map(\.id))
        let offline = (offlineTracks ?? []).filter { !visibleIDs.contains($0.id) }
        let known = visibleIDs.union(offline.map(\.id))
        let missing = (favoriteReferences ?? []).filter { !known.contains($0.id) }.map { reference in
            LibraryTrack(id: reference.id, path: reference.path, title: "", fileSize: -1,
                         fileExtension: URL(fileURLWithPath: reference.path).pathExtension, isFavorite: true)
        }
        return tracks + offline + missing
    }
}

public struct PortableSettings: Codable, Sendable {
    public var version = 1
    public var syncArtwork = true
    public var musicViewMode = "All Songs"
    /// The sidebar's width in points, and the page last shown in it.
    public var sidebarWidth: Double?
    public var lastTab: String?
    public var sectionTabs: [String: String] = [:]
    public var sidebarOpen = true
    public var albumArtworkSize: Double = 172
    public init() {}
    private enum CodingKeys: String, CodingKey { case version, syncArtwork, musicViewMode, sidebarWidth, lastTab, sectionTabs, sidebarOpen, albumArtworkSize }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        syncArtwork = try values.decodeIfPresent(Bool.self, forKey: .syncArtwork) ?? true
        musicViewMode = try values.decodeIfPresent(String.self, forKey: .musicViewMode) ?? "All Songs"
        sidebarWidth = try values.decodeIfPresent(Double.self, forKey: .sidebarWidth)
        lastTab = try values.decodeIfPresent(String.self, forKey: .lastTab)
        sectionTabs = try values.decodeIfPresent([String: String].self, forKey: .sectionTabs) ?? [:]
        sidebarOpen = try values.decodeIfPresent(Bool.self, forKey: .sidebarOpen) ?? true
        albumArtworkSize = try values.decodeIfPresent(Double.self, forKey: .albumArtworkSize) ?? 172
    }
}

/// All library, artwork and conversion data belongs to the launching iPod.
public struct PortableLibraryStore: Sendable {
    public let data: DeviceDataFolder
    public let hostID: String
    public var hostFolder: DeviceDataFolder {
        DeviceDataFolder(url: data.url.appendingPathComponent("Hosts/\(hostID)", isDirectory: true))
    }
    public var artwork: URL { hostFolder.url.appendingPathComponent("Artwork", isDirectory: true) }
    public var transcodes: URL { hostFolder.url.appendingPathComponent("Transcodes", isDirectory: true) }
    public init(root: URL, hostID: String) {
        data = DeviceDataFolder(mountPoint: root); self.hostID = hostID
    }
    public func register(name: String, musicFolder: URL? = nil, audiobooksFolder: URL? = nil) throws -> KnownHost {
        try data.requireAvailableStorage()
        var registry = try data.readChecked(KnownHosts.self, from: "known_hosts.json") ?? KnownHosts()
        guard registry.version == 1 else { throw IPodDBError.unsupported("Unsupported known_hosts.json version") }
        var host = registry.hosts.first { $0.id == hostID } ?? KnownHost(id: hostID, name: name)
        host.name = name
        if let musicFolder {
            if let i = host.sources.firstIndex(where: { $0.kind == .music }) { host.sources[i].path = musicFolder.path }
            else { host.sources.append(KnownSource(path: musicFolder.path)) }
        }
        if let audiobooksFolder {
            if let i = host.sources.firstIndex(where: { $0.kind == .audiobooks }) { host.sources[i].path = audiobooksFolder.path }
            else { host.sources.append(KnownSource(kind: .audiobooks, path: audiobooksFolder.path)) }
        }
        registry.hosts.removeAll { $0.id == hostID }; registry.hosts.append(host)
        let previous = data.read(KnownHosts.self, from: "known_hosts.json")
        if previous?.hosts != registry.hosts { try data.write(registry, to: "known_hosts.json") }
        return host
    }
    public func cache() throws -> PortableLibraryCache { try cacheChecked() }
    public func cacheChecked() throws -> PortableLibraryCache {
        try data.requireAvailableStorage()
        let cache = try hostFolder.readChecked(PortableLibraryCache.self, from: "library.json") ?? PortableLibraryCache()
        guard cache.version == 1 else { throw IPodDBError.unsupported("Unsupported library.json version") }
        return cache
    }
    public func save(_ cache: PortableLibraryCache) throws { try data.requireAvailableStorage(); try hostFolder.write(cache, to: "library.json") }
}
