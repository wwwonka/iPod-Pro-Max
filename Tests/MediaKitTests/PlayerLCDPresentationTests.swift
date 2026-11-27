import Testing
@testable import MediaKit

@Suite struct PlayerLCDPresentationTests {
    private func input(_ edit: (inout PlayerLCDPresentation.Input) -> Void = { _ in }) -> PlayerLCDPresentation {
        var input = PlayerLCDPresentation.Input()
        input.track = .init(id: "t", title: "Song", artist: "Artist", album: "Album", path: "/m/song.mp3")
        input.playing = true; input.duration = 200; input.position = 65
        edit(&input)
        return PlayerLCDPresentation(input)
    }

    @Test func trackInTitleMode() {
        let shown = input()
        #expect(shown.available && !shown.coverHidden && !shown.timeHidden && !shown.moreHidden)
        #expect(shown.titleText == "Song" && shown.subtitleText == "Artist — Album")
        #expect(shown.elapsedText == "1:05" && shown.remainingText == "−2:15")
        #expect(shown.textScrolls && shown.metadataOpacity == 1)
        #expect(shown.activityControlsHidden && shown.indicator.isEmpty)
    }

    @Test func titleFallbacksAndPause() {
        let shown = input { $0.track = .init(id: "t", title: "", path: "/m/file.m4a"); $0.playing = false }
        #expect(shown.titleText == "file.m4a" && shown.subtitleText.isEmpty)
        #expect(shown.metadataOpacity == 0.65 && !shown.textScrolls)
        #expect(input { $0.track?.playbackTitle = "Episode 4" }.titleText == "Episode 4")
    }

    @Test func activityCoversTrack() {
        var activity = PlayerActivity(id: "a", kind: .sync, title: "Syncing", detail: "12 of 40")
        let running = input { $0.activity = activity; $0.activityCount = 2 }
        #expect(!running.available && running.coverHidden && running.titleText == "Syncing")
        #expect(running.spinning && running.indicator == "••" && !running.cancelHidden && running.cancelSymbol == "xmark")
        activity.state = .completed
        let done = input { $0.activity = activity; $0.activityCount = 1 }
        #expect(!done.spinning && done.cancelSymbol == "checkmark" && done.cancelEnabled)
        #expect(input { $0.activityCount = 9 }.indicator == "•••••")
    }

    @Test func errorAndIdle() {
        let error = input { $0.error = "Can't play" }
        #expect(error.titleText == "⚠ Can't play" && error.subtitleHidden && !error.available)
        let idle = input { $0.track = nil; $0.idleDetail = "Choose a song" }
        #expect(idle.titleHidden && !idle.subtitleHidden && idle.subtitleText == "Choose a song" && !idle.canChangeView)
    }

    @Test func modes() {
        let lyrics = [TimedLyric(time: 0, text: "First"), TimedLyric(time: 5, text: ""), TimedLyric(time: 9, text: "Last")]
        let shown = input { $0.mode = .lyrics; $0.effectiveMode = .lyrics; $0.lyrics = lyrics; $0.lyricIndex = 1 }
        #expect(shown.titleText == "♪" && shown.subtitleText == "Last" && shown.timeHidden && shown.modeSymbol == "quote.bubble")
        let spectrum = input { $0.effectiveMode = .spectrum; $0.mode = .spectrum }
        #expect(spectrum.titleHidden && spectrum.timeHidden && spectrum.moreHidden && spectrum.modeSymbol == "chart.bar.fill")
        #expect(input().contentKey != spectrum.contentKey)
        #expect(input { $0.position = 120 }.contentKey == input().contentKey)
    }

    @Test func clock() {
        #expect(PlayerLCDPresentation.time(3725) == "1:02:05")
        #expect(PlayerLCDPresentation.time(.nan) == "0:00")
        let shown = input { $0.duration = 0; $0.rate = 1.5; $0.showsRemaining = false }
        #expect(shown.elapsedText == "--:-- · 1.5×" && shown.remainingText == "--:--")
        #expect(input { $0.showsRemaining = false }.remainingText == "3:20")
    }
}
