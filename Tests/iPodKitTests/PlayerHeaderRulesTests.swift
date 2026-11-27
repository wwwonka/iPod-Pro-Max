import Testing
@testable import iPodKit

@Suite struct PlayerHeaderRulesTests {
    final class Page {}

    @Test func searchOwnership() {
        // Kept alive: a freed page's identifier can be reused.
        let pageA = Page(), pageB = Page()
        let a = ObjectIdentifier(pageA), b = ObjectIdentifier(pageB)
        var search = PlayerHeaderRules.Search()
        #expect(!search.canFind)
        let r1 = search.claim(a)
        #expect(r1)
        let r2 = search.claim(a)
        #expect(!r2)
        let r3 = search.claim(b)
        #expect(r3)
        // Only the owner can give it up.
        let r4 = search.release(a)
        #expect(!r4)
        #expect(search.isOwner(b))
        let r5 = search.release(b)
        #expect(r5)
        #expect(!search.hasOwner)
        withExtendedLifetime((pageA, pageB)) {}
    }

    @Test func searchCollapsesInNarrowWindows() {
        var search = PlayerHeaderRules.Search()
        let r6 = search.display(windowWidth: 1200) == .hidden
        #expect(r6)
        search.claim(ObjectIdentifier(Page.self))
        let r7 = search.display(windowWidth: 1200) == .field
        #expect(r7)
        let r8 = search.display(windowWidth: 800) == .button
        #expect(r8)
        search.expand()
        let r9 = search.display(windowWidth: 800) == .field
        #expect(r9)
        let r10 = search.endEditing(text: "abba")
        #expect(!r10)
        let r11 = search.endEditing(text: "")
        #expect(r11)
        let r12 = search.display(windowWidth: 800) == .button
        #expect(r12)
        // A wide window forgets the expansion.
        search.expand()
        _ = search.display(windowWidth: 1000)
        let r13 = search.display(windowWidth: 800) == .button
        #expect(r13)
    }

    @Test func playButton() {
        typealias T = PlayerHeaderRules.Transport
        let idle = T(hasTrack: false, playing: false, hasSelection: false, optionHovered: true)
        #expect(idle.action == .none && !idle.playEnabled && idle.symbol == "play.fill")
        let selection = T(hasTrack: false, playing: false, hasSelection: true, optionHovered: false)
        #expect(selection.action == .startSelection && selection.playEnabled && !selection.skipEnabled)
        let playing = T(hasTrack: true, playing: true, hasSelection: true, optionHovered: false)
        #expect(playing.action == .toggle && playing.symbol == "pause.fill" && playing.label == "Pause")
        let stop = T(hasTrack: true, playing: true, hasSelection: false, optionHovered: true)
        #expect(stop.action == .stop && stop.symbol == "stop.fill" && stop.label == "Stop")
    }

    @Test func speakerLevels() {
        #expect([0, 0.1, 0.5, 0.9].map(PlayerHeaderRules.speakerLevel) == [0, 1, 2, 3])
    }

    @Test func launchRevealsOnce() {
        var launch = PlayerHeaderRules.Launch()
        let r14 = launch.reveal(hasWindow: true)
        #expect(!r14)
        launch.markReady()
        let r15 = launch.reveal(hasWindow: false)
        #expect(!r15)
        let r16 = launch.reveal(hasWindow: true)
        #expect(r16)
        let r17 = launch.reveal(hasWindow: true)
        #expect(!r17)
    }
}
