import Testing
@testable import MediaKit

@Suite struct PlaybackClockTests {
    @Test func advancesWhilePlayingAtRate() {
        var clock = PlaybackClock()
        clock.load(rate: 1.5, at: 100)
        clock.progress(position: 10, duration: 60, at: 100)
        #expect(clock.current(at: 102) == 13)
        clock.setPlaying(false, at: 102)
        #expect(clock.current(at: 500) == 13)
        // Never past the end, and the engine's own reading wins.
        clock.setPlaying(true, at: 500)
        #expect(clock.current(at: 10_000) == 60)
        #expect(clock.current(at: 501, enginePosition: 20) == 20)
    }

    @Test func durationBecomingKnownIsReportedOnce() {
        var clock = PlaybackClock()
        clock.load(rate: 1, at: 0)
        let first = clock.progress(position: 0, duration: 0, at: 0)
        let known = clock.progress(position: 1, duration: 30, at: 1)
        let again = clock.progress(position: 2, duration: 30, at: 2)
        #expect(!first && known && !again)
    }

    @Test func seekPinsPositionUntilConfirmed() {
        var clock = PlaybackClock()
        clock.load(rate: 1, at: 0)
        clock.progress(position: 0, duration: 100, at: 0)
        let target = clock.beginSeek(to: 250, at: 10)
        #expect(target == 100)
        let second = clock.beginSeek(to: 40, at: 10)
        // Engine progress during the seek is ignored, and the pending seek beats the engine reading.
        clock.progress(position: 5, duration: 100, at: 11)
        #expect(clock.current(at: 11, enginePosition: 5) == 41)
        // The first seek's confirmation is stale.
        let stale = clock.completeSeek(target, at: 12)
        let confirmed = clock.completeSeek(second, at: 12)
        #expect(!stale && confirmed && clock.pendingSeek == nil)
        #expect(clock.current(at: 12) == 40)
    }

    @Test func finishAndReset() {
        var clock = PlaybackClock()
        clock.load(rate: 1, at: 0)
        clock.progress(position: 10, duration: 30, at: 0)
        clock.finish()
        #expect(clock.atEnd && !clock.playing)
        clock.reset()
        #expect(clock == PlaybackClock())
    }

    @Test func rules() {
        #expect(!PlaybackRules.previousRestarts(position: 3))
        #expect(PlaybackRules.previousRestarts(position: 3.1))
        #expect(PlaybackRules.canSetRate(1.5, spoken: true))
        #expect(!PlaybackRules.canSetRate(1.5, spoken: false))
        #expect(!PlaybackRules.canSetRate(3, spoken: true))
    }
}
