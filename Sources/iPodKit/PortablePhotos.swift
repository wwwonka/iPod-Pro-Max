//
//  PortablePhotos.swift
//  iPod Pro Max
//
//  What a computer sends to the iPod's Photos menu, kept with the rest of its library on the iPod:
//  the folders it picked (sources of kind `.photos` in known_hosts.json) and, on a Mac, which Photos-app
//  albums (`Hosts/<host>/photos.json`; album identifiers only mean something on the Mac that made them).
//

import Foundation

public struct PhotosDocument: Codable, Equatable, Sendable {
    public var version = 1
    public var selection = PhotoSelection()
    public init(selection: PhotoSelection = PhotoSelection()) { self.selection = selection }
    private enum CodingKeys: String, CodingKey { case version, selection }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        selection = try values.decodeIfPresent(PhotoSelection.self, forKey: .selection) ?? PhotoSelection()
    }
}

public extension PortableLibraryStore {
    static let photosFileName = "photos.json"

    var photoCache: URL { hostFolder.url.appendingPathComponent("PhotoCache", isDirectory: true) }

    func loadPhotoSelection() -> PhotoSelection {
        hostFolder.read(PhotosDocument.self, from: Self.photosFileName)?.selection ?? PhotoSelection()
    }

    func savePhotoSelection(_ selection: PhotoSelection) throws {
        try data.requireAvailableStorage()
        guard loadPhotoSelection() != selection else { return }
        try hostFolder.write(PhotosDocument(selection: selection), to: Self.photosFileName)
    }

    /// This computer's sources of one kind.
    func sources(of kind: SourceKind) -> [KnownSource] {
        data.read(KnownHosts.self, from: "known_hosts.json")?.hosts.first { $0.id == hostID }?.sources.filter { $0.kind == kind } ?? []
    }

    @discardableResult
    func addSource(kind: SourceKind, path: String) throws -> KnownSource {
        try data.requireAvailableStorage()
        var registry = try data.readChecked(KnownHosts.self, from: "known_hosts.json") ?? KnownHosts()
        guard registry.version == 1 else { throw IPodDBError.unsupported("Unsupported known_hosts.json version") }
        var host = registry.hosts.first { $0.id == hostID } ?? KnownHost(id: hostID, name: hostID)
        if let existing = host.sources.first(where: { $0.kind == kind && $0.path == path }) { return existing }
        let source = KnownSource(kind: kind, path: path)
        host.sources.append(source)
        registry.hosts.removeAll { $0.id == hostID }
        registry.hosts.append(host)
        try data.write(registry, to: "known_hosts.json")
        return source
    }

    func removeSource(id: UUID) throws {
        try data.requireAvailableStorage()
        guard var registry = try data.readChecked(KnownHosts.self, from: "known_hosts.json"),
              var host = registry.hosts.first(where: { $0.id == hostID }) else { return }
        host.sources.removeAll { $0.id == id }
        registry.hosts.removeAll { $0.id == hostID }
        registry.hosts.append(host)
        try data.write(registry, to: "known_hosts.json")
    }
}
