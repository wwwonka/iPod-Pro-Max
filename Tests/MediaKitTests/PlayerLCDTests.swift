import XCTest
@testable import MediaKit
import iPodKit

final class PlayerLCDTests: XCTestCase {
    func testPeaksWaitUntilLevelsAreOffThenFadeAndStop() {
        var levels = PlayerSpectrumRelease(), peaks = PlayerSpectrumPeakRelease()
        levels.show([1]); peaks.show()
        levels.pause(at: 10, animated: true); peaks.pause(at: 10, animated: true)
        levels.advance(to: 10.46); peaks.advance(to: 10.46)
        XCTAssertFalse(levels.isReleasing); XCTAssertEqual(levels.levels[0], 0)
        XCTAssertEqual(peaks.opacity, 1); XCTAssertTrue(peaks.isReleasing)
        peaks.advance(to: 10.65); XCTAssertEqual(peaks.opacity, 0.5, accuracy: 0.001)
        peaks.advance(to: 10.74); XCTAssertEqual(peaks.opacity, 0); XCTAssertFalse(peaks.isReleasing)
        peaks.show(); peaks.pause(at: 20, animated: true); peaks.show(); peaks.advance(to: 21)
        XCTAssertEqual(peaks.opacity, 1); XCTAssertFalse(peaks.isReleasing)
        peaks.pause(at: 22, animated: false); XCTAssertEqual(peaks.opacity, 0)
    }
    func testSpectrumPauseReleasesToDarkAndStops() {
        var release = PlayerSpectrumRelease()
        release.show([1, 0.6])
        release.pause(at: 10, animated: true)
        XCTAssertTrue(release.isReleasing)
        release.advance(to: 10.225)
        XCTAssertEqual(release.levels[0], 0.25, accuracy: 0.001)
        XCTAssertEqual(release.levels[1], 0.15, accuracy: 0.001)
        release.advance(to: 10.5)
        XCTAssertFalse(release.isReleasing)
        XCTAssertTrue(release.levels.allSatisfy { $0 == 0 })
        release.advance(to: 20)
        XCTAssertTrue(release.levels.allSatisfy { $0 == 0 })
    }
    func testSpectrumResumeInterruptsReleaseAndReducedMotionSettlesImmediately() {
        var release = PlayerSpectrumRelease()
        release.show([1]); release.pause(at: 0, animated: true)
        release.advance(to: 0.1)
        release.show([0.8]); release.advance(to: 1)
        XCTAssertFalse(release.isReleasing)
        XCTAssertEqual(release.levels[0], 0.8)
        release.pause(at: 2, animated: false)
        XCTAssertFalse(release.isReleasing)
        XCTAssertTrue(release.levels.allSatisfy { $0 == 0 })
        release.pause(at: 3, animated: true)
        XCTAssertFalse(release.isReleasing)
    }

    func testModesKeepLyricsPreferenceButSkipUnavailableLyrics() {
        XCTAssertEqual(PlayerLCDMode.waveform.next(hasLyrics: false), .title)
        XCTAssertEqual(PlayerLCDMode.waveform.next(hasLyrics: true), .lyrics)
        XCTAssertEqual(PlayerLCDMode.lyrics.resolved(hasLyrics: false), .title)
        XCTAssertEqual(PlayerLCDMode.lyrics.resolved(hasLyrics: true), .lyrics)
    }
    func testLyricsBoundariesAndInvalidSources() {
        let lines = SynchronizedLyrics.parse("[00:02.50]First\n[00:04.00]\n[00:08.1]Next")
        XCTAssertNil(SynchronizedLyrics.index(at: 0, in: lines))
        XCTAssertEqual(SynchronizedLyrics.index(at: 2.5, in: lines), 0)
        XCTAssertEqual(SynchronizedLyrics.index(at: 6, in: lines), 1)
        XCTAssertEqual(SynchronizedLyrics.index(at: 99, in: lines), 2)
        XCTAssertEqual(lines[1].text, "")
        for source in ["Plain words", "[00:70]Wrong", "[00:04]Later\n[00:02]Earlier", "[00:nan]Invalid"] {
            XCTAssertTrue(SynchronizedLyrics.parse(source).isEmpty)
        }
    }
    func testScrubSnapsClampsCancelsAndRejectsChangedTrack() {
        var scrub = PlayerScrub()
        scrub.begin(trackID: "a", position: 10)
        scrub.update(fraction: 0.495, duration: 100, width: 300, chapters: [.init(time: 50, title: "Chapter")])
        XCTAssertEqual(scrub.proposed, 50)
        XCTAssertNil(scrub.finish(currentTrackID: "b"))
        scrub.begin(trackID: "a", position: 0)
        scrub.update(fraction: 2, duration: 100, width: 300, chapters: [])
        XCTAssertEqual(scrub.finish(currentTrackID: "a"), 100)
        scrub.begin(trackID: "a", position: 20); scrub.cancel()
        XCTAssertNil(scrub.finish(currentTrackID: "a"))
    }
    func testActivitySelectionDoesNotStealOnProgressAndFailuresSurviveNewWork() {
        var list = PlayerActivityList()
        let first = PlayerActivity(id: "first", kind: .sync, title: "Sync")
        list.update(first)
        XCTAssertEqual(list.selectedID, "first")
        list.cycle(-1); XCTAssertNil(list.selectedID)
        list.update(first); XCTAssertNil(list.selectedID)
        var failed = first; failed.state = .failed; list.update(failed)
        list.update(.init(id: "second", kind: .download, title: "Download"))
        XCTAssertEqual(list.items.count, 2)
        XCTAssertEqual(list.items.first?.state, .failed)
        list.remove("second"); XCTAssertNil(list.selectedID)
        XCTAssertEqual(list.items.first?.id, "first")
    }
    func testSpectrumInterpolationMonoDuplicationAndPeakDecay() {
        let timeline = PlayerSpectrum(frames: [Array(repeating: 0, count: 16), Array(repeating: 255, count: 16)], framesPerSecond: 20)
        XCTAssertEqual(timeline.levels(at: 0.025), Array(repeating: Float(0.5), count: 32))
        XCTAssertEqual(timeline.levels(at: 5), Array(repeating: Float(1), count: 32))
        var peaks = PlayerSpectrumPeaks()
        peaks.update(levels: Array(repeating: 1, count: 32), elapsed: 0)
        peaks.update(levels: Array(repeating: 0, count: 32), elapsed: 1)
        XCTAssertEqual(peaks.values[0], 0.6, accuracy: 0.001)
        peaks.update(levels: Array(repeating: 0.2, count: 32), elapsed: 0, reset: true)
        XCTAssertEqual(peaks.values[0], 0.2)
    }
    func testPortablePreferencesBackwardCompatibleAndRoundTrip() throws {
        let old = try JSONDecoder().decode(PortableSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(old.playerLCDMode, "title"); XCTAssertTrue(old.playerShowsRemaining)
        var settings = old; settings.playerLCDMode = "lyrics"; settings.playerShowsRemaining = false
        let restored = try JSONDecoder().decode(PortableSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(restored.playerLCDMode, "lyrics"); XCTAssertFalse(restored.playerShowsRemaining)
    }
}
