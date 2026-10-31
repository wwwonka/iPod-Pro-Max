//
//  PortablePodcasts.swift
//  iPod Pro Max
//
//  Podcast subscriptions of a portable library. They belong to the launching iPod like the rest of the
//  library (`Hosts/<host>/podcasts.json`), and the downloaded episodes sit next to them in
//  `Hosts/<host>/Podcasts/`. Downloads are stored with paths relative to the host folder, because the
//  drive letter or mount point of the iPod changes from one computer to the next.
//

import Foundation

public struct PodcastsDocument: Codable, Equatable, Sendable {
    public var version = 1
    public var shows: [PodcastShow]
    public init(shows: [PodcastShow] = []) { self.shows = shows }
    private enum CodingKeys: String, CodingKey { case version, shows }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        shows = try values.decodeIfPresent([PodcastShow].self, forKey: .shows) ?? []
    }
}

public extension PortableLibraryStore {
    static let podcastsFileName = "podcasts.json"

    /// Where the downloaded episodes of every show live.
    var podcastsDirectory: URL { hostFolder.url.appendingPathComponent("Podcasts", isDirectory: true) }

    /// Where one show's episodes are downloaded.
    func downloadDirectory(for show: PodcastShow) -> URL {
        podcastsDirectory.appendingPathComponent(show.id.uuidString, isDirectory: true)
    }

    /// The subscriptions with their downloads resolved against this connection of the iPod.
    /// A download whose file has disappeared is forgotten, so it is offered again.
    func loadPodcasts() throws -> [PodcastShow] {
        guard let document = try hostFolder.readChecked(PodcastsDocument.self, from: Self.podcastsFileName) else { return [] }
        guard document.version == 1 else { throw IPodDBError.unsupported("Unsupported podcasts.json version") }
        let base = hostFolder.url
        return document.shows.map { show in
            var show = show
            for i in show.episodes.indices {
                guard let relative = show.episodes[i].localPath else { continue }
                let absolute = relative.hasPrefix("/") ? relative : base.appendingPathComponent(relative).path
                show.episodes[i].localPath = FileManager.default.fileExists(atPath: absolute) ? absolute : nil
            }
            return show
        }
    }

    func savePodcasts(_ shows: [PodcastShow]) throws {
        try data.requireAvailableStorage()
        let base = hostFolder.url.path + "/"
        let stored = shows.map { show -> PodcastShow in
            var show = show
            for i in show.episodes.indices {
                guard let path = show.episodes[i].localPath else { continue }
                show.episodes[i].localPath = path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
            }
            return show
        }
        try hostFolder.write(PodcastsDocument(shows: stored), to: Self.podcastsFileName)
    }
}
