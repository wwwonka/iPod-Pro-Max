#if canImport(AppKitBackend)
import AppKit
import MediaKit

@MainActor final class DockPlaybackMenu: NSObject {
    static let shared = DockPlaybackMenu()
    func makeMenu() -> NSMenu {
        let playback = PlaybackController.shared, menu = NSMenu()
        menu.autoenablesItems = false
        if let track = playback.track {
            for text in [track.playbackTitle ?? track.title, track.artist] where !text.isEmpty {
                let compact = text.count > 90 ? String(text.prefix(44)) + "…" + String(text.suffix(44)) : text
                let item = NSMenuItem(title: compact, action: nil, keyEquivalent: ""); item.isEnabled = false; menu.addItem(item)
            }
            menu.addItem(.separator())
        }
        func item(_ title: String, _ action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item); return item
        }
        let play = item(playback.playing ? "Pause" : "Play", #selector(toggle))
        play.isEnabled = playback.track != nil || MacChrome.shared.canStartSelectionPlayback
        guard playback.track != nil else { return menu }
        _ = item("Next", #selector(next)); _ = item("Previous", #selector(previous))
        let shuffle = NSMenuItem(title: "Shuffle", action: nil, keyEquivalent: ""), shuffleMenu = NSMenu()
        for (index, title) in ["Off", "On"].enumerated() {
            let item = NSMenuItem(title: title, action: #selector(setShuffle(_:)), keyEquivalent: "")
            item.target = self; item.tag = index; item.state = playback.shuffled == (index == 1) ? .on : .off; shuffleMenu.addItem(item)
        }
        shuffle.submenu = shuffleMenu; menu.addItem(shuffle)
        let repeatRoot = NSMenuItem(title: "Repeat", action: nil, keyEquivalent: ""), repeatMenu = NSMenu()
        for (index, title) in ["Off", "All", "One"].enumerated() {
            let item = NSMenuItem(title: title, action: #selector(setRepeat(_:)), keyEquivalent: "")
            item.target = self; item.tag = index; item.state = playback.repeatMode.rawValue == index ? .on : .off; repeatMenu.addItem(item)
        }
        repeatRoot.submenu = repeatMenu; menu.addItem(repeatRoot)
        return menu
    }
    @objc private func toggle() { if PlaybackController.shared.track == nil { MacChrome.shared.startSelectionPlayback() } else { PlaybackController.shared.toggle() } }
    @objc private func next() { PlaybackController.shared.next() }
    @objc private func previous() { PlaybackController.shared.previous() }
    @objc private func setShuffle(_ item: NSMenuItem) { if PlaybackController.shared.shuffled != (item.tag == 1) { PlaybackController.shared.toggleShuffle() } }
    @objc private func setRepeat(_ item: NSMenuItem) { if let mode = PlaybackQueue.RepeatMode(rawValue: item.tag) { PlaybackController.shared.setRepeat(mode) } }
}
#endif
