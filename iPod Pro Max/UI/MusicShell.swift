import SwiftCrossUI
import Foundation

#if canImport(AppKitBackend)
import AppKit
import AppKitBackend

struct MediaRail: NSViewRepresentable {
    @Binding var selection: SidebarItem
    var devices: [String]
    func makeNSView(context: Context) -> MediaRailView { MediaRailView() }
    func updateNSView(_ view: MediaRailView, context: Context) {
        view.devices = devices
        view.onSelect = { selection = $0 }
        view.show(selection)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MediaRailView, context: Context) -> ViewSize {
        ViewSize(68, proposal.height ?? 600)
    }
}

final class MediaRailView: NSVisualEffectView {
    var devices: [String] = []
    var onSelect: (SidebarItem) -> Void = { _ in }
    private var buttons: [NSButton] = []
    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .sidebar; blendingMode = .behindWindow; state = .followsWindowActiveState
        for (index, symbol) in (["ipod"] + SidebarItem.library.map(\.icon)).enumerated() {
            let title = index == 0 ? "Connected iPods" : SidebarItem.library[index - 1].title
            let button = NSButton(title: "", target: self, action: #selector(selectMedia(_:)))
            button.image = systemSymbol(symbol, description: title, pointSize: 25)
            if button.image == nil { button.title = title }
            button.tag = index; button.isBordered = false; button.toolTip = title
            button.setAccessibilityLabel(title)
            button.wantsLayer = true; button.layer?.cornerRadius = 12
            addSubview(button); buttons.append(button)
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    func show(_ selection: SidebarItem) {
        buttons[0].isEnabled = !devices.isEmpty
        for (index, button) in buttons.enumerated() {
            let selected: Bool
            if index == 0 { if case .device = selection { selected = true } else { selected = false } }
            else if SidebarItem.library[index - 1] == .music {
                switch selection { case .music, .artists, .albums, .recentMusic, .playlist: selected = true; default: selected = false }
            } else { selected = selection == SidebarItem.library[index - 1] }
            button.contentTintColor = selected ? .controlAccentColor : .secondaryLabelColor
            button.layer?.backgroundColor = selected ? NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor : NSColor.clear.cgColor
        }
    }
    override func layout() {
        super.layout()
        for (index, button) in buttons.enumerated() {
            button.frame = NSRect(x: 11, y: bounds.height - titleBarHeight - 58 - CGFloat(index) * 60, width: 46, height: 46)
        }
    }
    @objc private func selectMedia(_ sender: NSButton) {
        if sender.tag > 0 { onSelect(SidebarItem.library[sender.tag - 1]); return }
        if devices.count == 1, let id = devices.first { onSelect(.device(id)); return }
        let menu = NSMenu()
        for (index, id) in devices.enumerated() {
            let item = NSMenuItem(title: ConnectedDeviceTitles.names[id] ?? "iPod", action: #selector(selectDevice(_:)), keyEquivalent: "")
            item.tag = index; item.target = self; menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: sender.frame.maxX, y: sender.frame.midY), in: self)
    }
    @objc private func selectDevice(_ sender: NSMenuItem) {
        if devices.indices.contains(sender.tag) { onSelect(.device(devices[sender.tag])) }
    }
}
#else
struct MediaRail: View {
    @Binding var selection: SidebarItem
    var devices: [String]
    var body: some View {
        VStack(spacing: 14) {
            Spacer().frame(height: titleBarHeight + 6)
            Button(action: { if let id = devices.first { selection = .device(id) } }) {
                Symbol(name: "ipod", size: 32, pointSize: 25, tint: .primary)
            }.buttonStyle(.plain).frame(width: 46, height: 46).help("Connected iPods")
            ForEach(SidebarItem.library, id: \.self) { item in
                Button(action: { selection = item }) {
                    Symbol(name: item.icon, size: 32, pointSize: 25, tint: isSelected(item) ? .primary : .secondary)
                }
                .buttonStyle(.plain).help(item.title)
                .frame(width: 46, height: 46)
                .background(isSelected(item) ? Color.blue.opacity(0.28) : Color.clear)
                .cornerRadius(12)
                .titleBarControl()
            }
            Spacer()
        }
        .frame(width: 68)
        .background(GlassSurface())
    }
    private func isSelected(_ item: SidebarItem) -> Bool {
        if item == .music {
            switch selection { case .music, .artists, .albums, .recentMusic, .playlist: return true; default: return false }
        }
        return selection == item
    }
}

#endif

#if canImport(AppKitBackend)
import AppKit
import AppKitBackend

struct GlassSurface: NSViewRepresentable {
    var floating = false
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.wantsLayer = true
        view.state = .followsWindowActiveState
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = floating ? .popover : .sidebar
        view.blendingMode = floating ? .withinWindow : .behindWindow
        view.layer?.cornerRadius = floating ? 22 : 0
        view.layer?.masksToBounds = floating
    }
}
#else
struct GlassSurface: View {
    var floating = false
    var body: some View {
        Color.adaptive(light: Color(white: 0.94), dark: Color(white: 0.17)).opacity(floating ? 0.94 : 0.72)
    }
}
#endif

/// Kept separate from ContentView so playback updates never change its library inputs.
struct PlayerDock: View {
    #if canImport(AppKitBackend)
    var body: some View { NativePlayerDock().frame(height: 100).padding(12) }
    #else
    @State private var player = PlaybackController.shared
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 16) {
                if let track = player.track {
                    if let key = track.artworkKey, let folder = PlayerArtwork.folder {
                        Thumbnail(url: folder.appendingPathComponent(key + ".jpg"), pixels: 112)
                            .frame(width: 56, height: 56).cornerRadius(9)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(track.title).font(.system(size: 15, weight: .semibold))
                        Text(track.artist).font(.system(size: 12)).foregroundColor(.gray)
                    }.frame(width: 210)
                }
                Spacer()
                PlayerButton(symbol: "shuffle", label: "Shuffle", active: player.shuffled) { player.toggleShuffle() }
                PlayerButton(symbol: "backward.end.fill", label: "Previous") { player.previous() }
                PlayerButton(symbol: player.playing ? "pause.fill" : "play.fill", label: player.playing ? "Pause" : "Play") { player.toggle() }
                PlayerButton(symbol: "forward.end.fill", label: "Next") { player.next() }
                PlayerButton(symbol: player.repeatMode == .one ? "repeat.1" : "repeat", label: "Repeat", active: player.repeatMode != .off) { player.cycleRepeat() }
                Spacer()
                Symbol(name: "speaker.wave.2.fill", size: 20, pointSize: 17, tint: .secondary)
                Slider(value: Binding(get: { player.volume }, set: { player.setVolume($0) }), in: 0.0...1.0).frame(width: 80)
                PlayerButton(symbol: "xmark", label: "Close") { player.close() }
            }
            WaveformShape(samples: player.samples).fill(Color.blue.opacity(0.7)).frame(height: 24)
            Slider(value: Binding(get: { player.position }, set: { player.seek($0) }), in: 0.0...max(1, player.duration))
            if !player.error.isEmpty { Text(player.error).foregroundColor(.red) }
        }.padding(16).background(GlassSurface(floating: true)).cornerRadius(22).padding(12)
    }
    #endif
}

struct PlayerButton: View {
    var symbol: String
    var label: String
    var active = false
    var action: @MainActor @Sendable () -> Void
    var body: some View {
        Button(action: action) {
            Symbol(name: symbol, size: 26, pointSize: 22, tint: active ? .accent : .primary)
        }.buttonStyle(.plain).frame(width: 34, height: 36).help(label)
    }
}

struct WaveformShape: Shape {
    var samples: [Float]
    nonisolated func path(in bounds: Path.Rect) -> Path {
        var path = Path()
        let count = max(1, min(128, Int(bounds.width / 4)))
        for i in 0..<count {
            let sample = samples.isEmpty ? 0.05 : Double(samples[min(samples.count - 1, i * samples.count / count)])
            let h = max(2, min(bounds.height, sample * bounds.height))
            path = path.addRectangle(.init(x: bounds.x + Double(i) * bounds.width / Double(count),
                                          y: bounds.y + (bounds.height - h) / 2, width: 2, height: h))
        }
        return path
    }
}

@MainActor enum PlayerArtwork { static var folder: URL? }
