import XCTest
import iPodKit
@testable import MediaKit

final class ReviewRegressionTests: XCTestCase {
    func testClassicRSSImageIsUsedWhenThereIsNoItunesImage() throws {
        let xml = """
        <?xml version="1.0"?><rss version="2.0"><channel><title>Old School</title>
        <image><url>https://example.com/logo.png</url><title>Logo</title></image>
        <item><title>One</title><guid>1</guid><enclosure url="https://example.com/1.mp3" length="1" type="audio/mpeg"/></item>
        </channel></rss>
        """
        let feed = try PodcastFeedParser.parse(data: Data(xml.utf8))
        XCTAssertEqual(feed.title, "Old School", "the image's own title must not replace the show's")
        XCTAssertEqual(feed.imageURL?.absoluteString, "https://example.com/logo.png")
    }

    func testChapterNumbersFollowTheFilesThatAreThereNow() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("renumber-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let book = root.appendingPathComponent("Book")
        try FileManager.default.createDirectory(at: book, withIntermediateDirectories: true)
        for name in ["01.mp3", "02.mp3", "04.mp3"] { try AudioFixtures.twoSecondMP3.write(to: book.appendingPathComponent(name)) }
        let art = root.appendingPathComponent("art")
        let first = await AudiobookScanner.scan(folder: root, artworkDir: art, namespace: "s")
        XCTAssertEqual(first.tracks.map(\.trackNumber), [1, 2, 3])
        // A chapter appears in the middle; the others come from the cache.
        try AudioFixtures.threeSecondMP3.write(to: book.appendingPathComponent("03.mp3"))
        let second = await AudiobookScanner.scan(folder: root, artworkDir: art, cached: first.tracks, namespace: "s")
        XCTAssertEqual(second.tracks.map(\.trackNumber), [1, 2, 3, 4])
        XCTAssertEqual(Set(second.tracks.map(\.trackCount)), [4])
        XCTAssertEqual(AudiobookScanner.bookGroups(second.tracks)[0].map { $0.url.lastPathComponent }, ["01.mp3", "02.mp3", "03.mp3", "04.mp3"])
    }

    #if !os(Windows)
    func testLargeYtDlpListingDoesNotBlock() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ytdlp-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // A stand-in yt-dlp whose listing (about 600 KB) is far beyond a pipe buffer, with noise on stderr too.
        let script = dir.appendingPathComponent("yt-dlp")
        try """
        #!/bin/sh
        i=0
        while [ $i -lt 3000 ]; do
          echo "{\\"id\\": \\"v$i\\", \\"title\\": \\"Video number $i with a reasonably long title to fill the pipe up quickly, as real listings do\\", \\"duration\\": 60, \\"upload_date\\": \\"20240102\\", \\"playlist_title\\": \\"Big Channel\\"}"
          echo "warning $i" >&2
          i=$((i+1))
        done
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        setenv("IPODPROMAX_YTDLP", script.path, 1)
        defer { unsetenv("IPODPROMAX_YTDLP") }
        let feed = try await withTimeout(seconds: 20) { try await PodcastSources.fetchFeed(URL(string: "https://www.youtube.com/@big")!, kind: .youtube) }
        XCTAssertEqual(feed.title, "Big Channel")
        XCTAssertEqual(feed.episodes.count, 3000)
        XCTAssertNotNil(feed.episodes.first?.publishedAt)
    }

    private func withTimeout<T: Sendable>(seconds: Double, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)); throw IPodDBError.io("timed out: the listing blocked") }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
    #endif
}
