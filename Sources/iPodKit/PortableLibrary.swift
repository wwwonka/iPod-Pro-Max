import Foundation

public enum SourceKind: String, Codable, Sendable { case music, audiobooks, videos, photos }

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

public struct PortableLibraryCache: Codable, Equatable, Sendable {
    public var version = 1
    public var tracks: [LibraryTrack]
    public var playlists: [LibraryPlaylist]
    public var sourcePaths: [String: String]?
    public init(tracks: [LibraryTrack] = [], playlists: [LibraryPlaylist] = []) {
        self.tracks = tracks; self.playlists = playlists
    }
    private enum CodingKeys: String, CodingKey { case version, tracks, playlists, sourcePaths }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        tracks = try values.decodeIfPresent([LibraryTrack].self, forKey: .tracks) ?? []
        playlists = try values.decodeIfPresent([LibraryPlaylist].self, forKey: .playlists) ?? []
        sourcePaths = try values.decodeIfPresent([String: String].self, forKey: .sourcePaths)
    }
}

public struct PortableSettings: Codable, Sendable {
    public var version = 1
    public var syncArtwork = true
    public var musicViewMode = "All Songs"
    public init() {}
    private enum CodingKeys: String, CodingKey { case version, syncArtwork, musicViewMode }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        syncArtwork = try values.decodeIfPresent(Bool.self, forKey: .syncArtwork) ?? true
        musicViewMode = try values.decodeIfPresent(String.self, forKey: .musicViewMode) ?? "All Songs"
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
    public func cache() -> PortableLibraryCache {
        hostFolder.read(PortableLibraryCache.self, from: "library.json") ?? PortableLibraryCache()
    }
    public func save(_ cache: PortableLibraryCache) throws { try data.requireAvailableStorage(); try hostFolder.write(cache, to: "library.json") }
}
