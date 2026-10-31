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
}

public struct KnownHosts: Codable, Sendable {
    public var version = 1
    public var hosts: [KnownHost] = []
    public init() {}
}

public struct PortableLibraryCache: Codable, Equatable, Sendable {
    public var version = 1
    public var tracks: [LibraryTrack]
    public var playlists: [LibraryPlaylist]
    public var sourcePaths: [String: String]?
    public init(tracks: [LibraryTrack] = [], playlists: [LibraryPlaylist] = []) {
        self.tracks = tracks; self.playlists = playlists
    }
}

public struct PortableSettings: Codable, Sendable {
    public var version = 1
    public var syncArtwork = true
    public var musicViewMode = "All Songs"
    public init() {}
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
    public func register(name: String, musicFolder: URL? = nil) throws -> KnownHost {
        var registry = try data.readChecked(KnownHosts.self, from: "known_hosts.json") ?? KnownHosts()
        guard registry.version == 1 else { throw IPodDBError.unsupported("Unsupported known_hosts.json version") }
        var host = registry.hosts.first { $0.id == hostID } ?? KnownHost(id: hostID, name: name)
        host.name = name
        if let musicFolder {
            if let i = host.sources.firstIndex(where: { $0.kind == .music }) { host.sources[i].path = musicFolder.path }
            else { host.sources.append(KnownSource(path: musicFolder.path)) }
        }
        registry.hosts.removeAll { $0.id == hostID }; registry.hosts.append(host)
        let previous = data.read(KnownHosts.self, from: "known_hosts.json")
        if previous?.hosts != registry.hosts { try data.write(registry, to: "known_hosts.json") }
        return host
    }
    public func cache() -> PortableLibraryCache {
        hostFolder.read(PortableLibraryCache.self, from: "library.json") ?? PortableLibraryCache()
    }
    public func save(_ cache: PortableLibraryCache) throws { try hostFolder.write(cache, to: "library.json") }
}
