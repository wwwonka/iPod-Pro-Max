import XCTest
import iPodKit
@testable import MediaKit

final class PortablePodcastTests: XCTestCase {
    private let rss = """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
     <channel>
      <title>Show &amp; Tell</title>
      <itunes:author>Someone</itunes:author>
      <description><![CDATA[<p>About the show</p>]]></description>
      <itunes:image href="https://example.com/cover.jpg"/>
      <item>
       <title>Second</title><guid>g2</guid>
       <pubDate>Tue, 02 Jan 2024 10:00:00 +0000</pubDate>
       <itunes:duration>1:02:03</itunes:duration>
       <enclosure url="https://example.com/2.mp3" length="1234" type="audio/mpeg"/>
      </item>
      <item>
       <title>First</title><guid>g1</guid>
       <pubDate>Mon, 01 Jan 2024 10:00:00 +0000</pubDate>
       <enclosure url="https://example.com/1.mp3" length="99" type="audio/mpeg"/>
      </item>
      <item><title>No audio</title><guid>g0</guid></item>
     </channel>
    </rss>
    """

    func testParsesFeedAndMergeKeepsKnownEpisodes() throws {
        let feed = try PodcastFeedParser.parse(data: Data(rss.utf8))
        XCTAssertEqual(feed.title, "Show & Tell")
        XCTAssertEqual(feed.author, "Someone")
        XCTAssertEqual(feed.summary, "About the show")
        XCTAssertEqual(feed.imageURL?.absoluteString, "https://example.com/cover.jpg")
        XCTAssertEqual(feed.episodes.map(\.guid), ["g2", "g1"])
        XCTAssertEqual(feed.episodes.first?.durationMs, (3600 + 120 + 3) * 1000)
        XCTAssertNotNil(feed.episodes.first?.publishedAt)

        var show = PodcastShow(feedURL: URL(string: "https://example.com/feed")!, title: "")
        show = PodcastSources.merge(feed, into: show)
        XCTAssertEqual(show.episodes.count, 2)
        show.episodes[0].played = true
        let again = PodcastSources.merge(feed, into: show)
        XCTAssertEqual(again.episodes.count, 2)
        XCTAssertTrue(again.episodes[0].played, "a refresh keeps the state of known episodes")
        XCTAssertThrowsError(try PodcastFeedParser.parse(data: Data("<html/>".utf8)))
    }

    func testSourceKindsAndFeedLinks() {
        XCTAssertEqual(PodcastSources.kind(for: URL(string: "https://www.youtube.com/@x")!), .youtube)
        XCTAssertEqual(PodcastSources.kind(for: URL(string: "https://ici.radio-canada.ca/ohdio/balados/123/slug")!), .ohdio)
        XCTAssertEqual(PodcastSources.kind(for: URL(string: "https://example.com/feed.xml")!), .rss)
        XCTAssertEqual(PodcastSources.normalizedFeedURL(" feed://example.com/a ")?.absoluteString, "https://example.com/a")
        XCTAssertNil(PodcastSources.normalizedFeedURL("not a url"))
    }

    func testDownloadsFollowTheIPodAndMissingFilesAreForgotten() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("podcast-store-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try IPodDevice.createSimulatedIPod(at: root)
        let store = PortableLibraryStore(root: root, hostID: "a")
        var show = PodcastShow(feedURL: URL(string: "https://example.com/feed")!, title: "S")
        var kept = PodcastEpisode(guid: "kept", title: "Kept", enclosureURL: URL(string: "https://example.com/k.mp3")!)
        var lost = PodcastEpisode(guid: "lost", title: "Lost", enclosureURL: URL(string: "https://example.com/l.mp3")!)
        let dir = store.downloadDirectory(for: show)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("k.mp3")
        try Data([1]).write(to: file)
        kept.localPath = file.path
        lost.localPath = dir.appendingPathComponent("gone.mp3").path
        show.episodes = [kept, lost]
        try store.savePodcasts([show])

        let raw = try String(contentsOf: store.hostFolder.url.appendingPathComponent("podcasts.json"))
        XCTAssertFalse(raw.contains(root.path), "paths are relative to the iPod, whose mount point changes")
        let loaded = try store.loadPodcasts()
        XCTAssertEqual(loaded.first?.episodes.first { $0.guid == "kept" }?.localPath, file.path)
        XCTAssertNil(loaded.first?.episodes.first { $0.guid == "lost" }?.localPath)
    }

    func testEpisodesAreCopiedOnceAndGetTheirPlaylist() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("podcast-transfer-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try IPodDevice.createSimulatedIPod(at: root)
        let device = try XCTUnwrap(IPodDevice.detect(volume: root, simulated: true))
        let store = PortableLibraryStore(root: root, hostID: "a")
        var show = PodcastShow(feedURL: URL(string: "https://example.com/feed")!, title: "Show")
        let dir = store.downloadDirectory(for: show)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var episodes: [PodcastEpisode] = []
        for n in 1...2 {
            var e = PodcastEpisode(guid: "g\(n)", title: "Episode \(n)", publishedAt: Date(timeIntervalSince1970: Double(n) * 86_400),
                                   enclosureURL: URL(string: "https://example.com/\(n).mp3")!)
            let file = dir.appendingPathComponent("\(e.id.uuidString).mp3")
            try Data(repeating: UInt8(n), count: 2048).write(to: file)
            e.localPath = file.path
            episodes.append(e)
        }
        show.episodes = episodes

        let first = try PortablePodcastTransfer.prepare(shows: [show], device: device, store: store)
        XCTAssertEqual(first.request.shows.first?.episodes.count, 2)
        let result = try await SyncEngine(request: first.request, progress: { _ in }).run()
        XCTAssertEqual(result.added, 2)
        let db = try device.readDatabase()
        XCTAssertEqual(db.tracks.filter(\.isPodcast).count, 2)
        let playlist = try XCTUnwrap(db.playlists.first { $0.isPodcasts })
        XCTAssertEqual(playlist.memberDBIDs.count, 2)
        XCTAssertEqual(db.tracks.first { $0.isPodcast }?.podcastRSS, "https://example.com/feed")

        // Same episodes, a second computer subscribed to the same feed: nothing is copied again.
        let other = PortableLibraryStore(root: root, hostID: "b")
        var copy = show
        copy.id = UUID()
        copy.episodes = copy.episodes.map { var e = $0; e.id = UUID(); return e }
        let again = try PortablePodcastTransfer.prepare(shows: [copy], device: device, store: other)
        XCTAssertTrue(again.request.shows.isEmpty || again.request.shows.allSatisfy { show in
            let ids = Set(show.episodes.map(\.id))
            return again.request.record.episodeDBIDs.keys.filter(ids.contains).count == show.episodes.count
        })
        XCTAssertEqual(again.reused, 2)
        let second = try await SyncEngine(request: again.request, progress: { _ in }).run()
        XCTAssertEqual(second.added, 0)
        XCTAssertEqual(try device.readDatabase().tracks.filter(\.isPodcast).count, 2)
    }

    func testFetchesFeedAndDownloadsEpisodeWithProgress() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("podcast-net-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let audio = dir.appendingPathComponent("1.mp3")
        try Data(repeating: 7, count: 300_000).write(to: audio)
        let xml = rss.replacingOccurrences(of: "https://example.com/1.mp3", with: audio.absoluteString)
        let feedFile = dir.appendingPathComponent("feed.xml")
        try Data(xml.utf8).write(to: feedFile)

        let feed = try await PodcastSources.fetchFeed(feedFile, kind: .rss)
        XCTAssertEqual(feed.episodes.count, 2)
        var show = PodcastSources.merge(feed, into: PodcastShow(feedURL: feedFile, title: ""))
        let episode = try XCTUnwrap(show.episodes.first { $0.guid == "g1" })
        let target = dir.appendingPathComponent("downloads")
        let file = try await PodcastSources.download(episode, of: show, into: target) { _ in }
        XCTAssertEqual(try Data(contentsOf: file).count, 300_000)
        XCTAssertEqual(file.pathExtension, "mp3")
        show.episodes = []
    }
}
