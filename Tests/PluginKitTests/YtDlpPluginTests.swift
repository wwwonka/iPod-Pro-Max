import Foundation
import PluginKit
import XCTest
@testable import YtDlpPlugin

final class YtDlpPluginTests: XCTestCase {
    func testSearchEntryParsingHintsAndFiltering() {
        let track = TrackRef(
            source: "spotify",
            sourceID: "tr-1",
            title: "Man I Need",
            artists: ["Olivia Dean"],
            album: "The Art of Loving",
            durationMs: 184_000
        )

        // YouTube Music / Topic channel gets hint 0.9
        let topicJSON: [String: Any] = [
            "id": "fsGjRf-N71I",
            "title": "Man I Need",
            "channel": "Olivia Dean - Topic",
            "duration": 184,
            "ie_key": "Youtube",
            "abr": 130.0,
            "ext": "m4a",
        ]
        let topicCand = YtDlpHandler.parseSearchEntry(topicJSON, isYTMusic: false, primaryArtist: "Olivia Dean", fallbackTrack: track)
        XCTAssertEqual(topicCand?.hint, 0.9)
        XCTAssertEqual(topicCand?.bitrateKbps, 130)
        XCTAssertEqual(topicCand?.container, "m4a")
        XCTAssertEqual(topicCand?.displayName, "Man I Need — Olivia Dean - Topic")

        // Artist / VEVO channel gets hint 0.6
        let vevoJSON: [String: Any] = [
            "id": "oIv_Y2RPQ_A",
            "title": "Olivia Dean - Man I Need",
            "channel": "OliviaDeanVEVO",
            "duration": 202,
            "ie_key": "Youtube",
        ]
        let vevoCand = YtDlpHandler.parseSearchEntry(vevoJSON, isYTMusic: false, primaryArtist: "Olivia Dean", fallbackTrack: track)
        XCTAssertEqual(vevoCand?.hint, 0.6)

        // Third-party uploader gets hint 0.3
        let thirdJSON: [String: Any] = [
            "id": "x1o2NuPWRCg",
            "title": "Man I Need - Olivia Dean (Lyrics)",
            "channel": "Pizza Music",
            "ie_key": "Youtube",
        ]
        let thirdCand = YtDlpHandler.parseSearchEntry(thirdJSON, isYTMusic: false, primaryArtist: "Olivia Dean", fallbackTrack: track)
        XCTAssertEqual(thirdCand?.hint, 0.3)

        // Browse tabs & restricted entries excluded (`YTD-3`)
        XCTAssertNil(YtDlpHandler.parseSearchEntry(["id": "UC123", "title": "Artist", "ie_key": "YoutubeTab"], isYTMusic: true, primaryArtist: "Olivia Dean", fallbackTrack: track))
        XCTAssertNil(YtDlpHandler.parseSearchEntry(["id": "vid", "title": "Age", "age_limit": 18, "ie_key": "Youtube"], isYTMusic: false, primaryArtist: "Olivia Dean", fallbackTrack: track))
        XCTAssertNil(YtDlpHandler.parseSearchEntry(["id": "vid", "title": "Premiere", "live_status": "is_upcoming", "ie_key": "Youtube"], isYTMusic: false, primaryArtist: "Olivia Dean", fallbackTrack: track))
    }

    func testProgressPercentParser() {
        XCTAssertEqual(YtDlpHandler.parseProgressPercent("  42.5%"), 42.5)
        XCTAssertEqual(YtDlpHandler.parseProgressPercent("100.0%"), 100.0)
        XCTAssertEqual(YtDlpHandler.parseProgressPercent("125%"), 100.0)
        XCTAssertNil(YtDlpHandler.parseProgressPercent("[ExtractAudio] Destination: out.m4a"))
    }
}
