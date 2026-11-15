import XCTest
import iPodKit
@testable import MediaKit

final class MetadataEditorTests: XCTestCase {
    func testTagWriterRoundTripOnMP3() async throws {
        TestFFmpeg.prepare()
        guard FFmpeg.binaryPath() != nil else {
            throw XCTSkip("FFmpeg binary not available")
        }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ippm-tagwriter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let mp3URL = dir.appendingPathComponent("sample.mp3")
        try AudioFixtures.threeSecondMP3.write(to: mp3URL)

        var track = LibraryTrack(
            path: mp3URL.path,
            title: "Edited Title",
            artist: "Edited Artist",
            album: "Edited Album",
            albumArtist: "Edited Album Artist",
            genre: "Electronic",
            composer: "Edited Composer",
            comment: "Edited Comment",
            grouping: "Edited Grouping",
            year: 2024,
            trackNumber: 3,
            trackCount: 12,
            discNumber: 1,
            discCount: 2,
            fileExtension: "mp3",
            compilation: true,
            bpm: 128,
            lyrics: "Line one\nLine two",
            customLyrics: true
        )
        track.sortTitle = "Sort Title"

        try await TagWriter.writeTags(for: track, customArtworkData: nil)

        let extracted = try await MetadataExtractor.extract(from: mp3URL)
        XCTAssertEqual(extracted.title, "Edited Title")
        XCTAssertEqual(extracted.artist, "Edited Artist")
        XCTAssertEqual(extracted.album, "Edited Album")
        XCTAssertEqual(extracted.albumArtist, "Edited Album Artist")
        XCTAssertEqual(extracted.genre, "Electronic")
        XCTAssertEqual(extracted.composer, "Edited Composer")
        XCTAssertEqual(extracted.grouping, "Edited Grouping")
        XCTAssertEqual(extracted.year, 2024)
        XCTAssertEqual(extracted.trackNumber, 3)
        XCTAssertEqual(extracted.trackCount, 12)
        XCTAssertEqual(extracted.discNumber, 1)
        XCTAssertEqual(extracted.discCount, 2)
        XCTAssertEqual(extracted.bpm, 128)
        XCTAssertTrue(extracted.compilation)
        XCTAssertTrue(extracted.hasLyrics)
    }

    func testTagWriterMissingFileThrows() async {
        let missing = LibraryTrack(path: "/nonexistent/path/song.mp3", title: "Missing", fileExtension: "mp3")
        do {
            try await TagWriter.writeTags(for: missing)
            XCTFail("Expected missing file error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("File not found"))
        }
    }

    func testMetadataFinderOrchestratesAndRanksByScore() async {
        struct MockProvider: MetadataLookupProvider {
            let name: String
            let matches: [MetadataMatch]
            func search(query: MetadataQuery) async throws -> [MetadataMatch] { matches }
        }

        let low = MetadataMatch(
            id: "1", source: "Low", score: 0.5, title: "Low", artist: "A", album: nil,
            albumArtist: nil, year: nil, trackNumber: nil, trackCount: nil, discNumber: nil,
            discCount: nil, genre: nil, musicBrainzReleaseID: nil, artworkURL: nil
        )
        let high = MetadataMatch(
            id: "2", source: "High", score: 0.95, title: "High", artist: "B", album: "Alb",
            albumArtist: nil, year: 2020, trackNumber: 1, trackCount: 10, discNumber: 1,
            discCount: 1, genre: "Rock", musicBrainzReleaseID: nil, artworkURL: nil
        )

        let service = MetadataFinderService(providers: [
            MockProvider(name: "Low", matches: [low]),
            MockProvider(name: "High", matches: [high]),
        ])
        let results = await service.search(query: MetadataQuery(title: "Test"))
        XCTAssertEqual(results.map(\.id), ["2", "1"])
    }

    func testLyricsServiceFallsBackAcrossProviders() async {
        struct EmptyLyrics: LyricsLookupProvider {
            let name = "Empty"
            func fetchLyrics(query: LyricsQuery) async throws -> LyricsMatch? { nil }
        }
        struct HitLyrics: LyricsLookupProvider {
            let name = "Hit"
            func fetchLyrics(query: LyricsQuery) async throws -> LyricsMatch? {
                LyricsMatch(source: name, plainLyrics: "Hello world", syncedLyrics: nil, instrumental: false)
            }
        }

        let service = LyricsService(providers: [EmptyLyrics(), HitLyrics()])
        let match = await service.fetchLyrics(query: LyricsQuery(title: "Song", artist: "Artist"))
        XCTAssertEqual(match?.source, "Hit")
        XCTAssertEqual(match?.bestText, "Hello world")
    }
}
