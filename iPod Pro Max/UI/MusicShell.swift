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
        ViewSize(mediaRailWidth, proposal.height ?? 600)
    }
}

/// Draws nothing itself: the rail sits straight on the window's glass.
/// The rail's measures, in points.
enum MediaRailMetrics {
    static let button = 36.0
    /// From one button's top to the next.
    static let pitch = 44.0
    static let symbolSize = 17.0
    static let cornerRadius = 10.0
    static let topGap = 8.0
    static let bottomGap = 12.0
}

/// A rail button with no hover or press effect for now (the system's toolbar bezel didn't follow the
/// icons' shape); the native effect is to be rebuilt. The current page and a track dropped on the
/// button get their own tint.
final class RailButton: NSButton {
    var isCurrent = false { didSet { refresh() } }
    var isDropTarget = false { didSet { refresh() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        imagePosition = .imageOnly
        setButtonType(.momentaryPushIn)
    }
    required init?(coder: NSCoder) { fatalError() }
    convenience init(title: String, target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        self.title = title; self.target = target; self.action = action
    }

    private var observers: [NSObjectProtocol] = []
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard let window else { return }
        // A toolbar's items dim when their window isn't the key one; the rail does the same.
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        refresh()
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func refresh() {
        let active = window?.isKeyWindow ?? true
        let plate: NSColor
        let tint: NSColor
        if isDropTarget { plate = .controlAccentColor; tint = .white }
        else if isCurrent && active { plate = NSColor.controlAccentColor.withAlphaComponent(0.18); tint = .controlAccentColor }
        else if isCurrent { plate = NSColor.white.withAlphaComponent(0.08); tint = NSColor.labelColor.withAlphaComponent(0.35) }
        else if active { plate = .clear; tint = .secondaryLabelColor }
        else { plate = .clear; tint = NSColor.labelColor.withAlphaComponent(0.3) }
        contentTintColor = tint
        layer?.backgroundColor = plate.cgColor
    }
}

final class MediaRailView: NSView {
    var devices: [String] = []
    var onSelect: (SidebarItem) -> Void = { _ in }
    private var buttons: [RailButton] = []
    /// Under the libraries: a menu of the sections that aren't shown in the rail.
    private let moreButton = RailButton(title: "", target: nil, action: nil)
    private var lastSelection: SidebarItem = .music
    private var dropActive = false
    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.string])
        for (index, symbol) in (["ipod"] + SidebarItem.library.map(\.icon)).enumerated() {
            let title = index == 0 ? "Connected iPods" : SidebarItem.library[index - 1].title
            let button = RailButton(title: "", target: self, action: #selector(selectMedia(_:)))
            button.image = systemSymbol(symbol, description: title, pointSize: MediaRailMetrics.symbolSize)
            if button.image == nil { button.title = title }
            button.tag = index; button.toolTip = title
            button.setAccessibilityLabel(title)
            button.wantsLayer = true; button.layer?.cornerRadius = MediaRailMetrics.cornerRadius
            addSubview(button); buttons.append(button)
        }
        moreButton.target = self; moreButton.action = #selector(showMoreSections(_:))
        moreButton.image = systemSymbol("ellipsis", description: "More sections", pointSize: MediaRailMetrics.symbolSize)
        moreButton.tag = -1; moreButton.toolTip = "More sections"
        moreButton.setAccessibilityLabel("More sections")
        moreButton.wantsLayer = true; moreButton.layer?.cornerRadius = MediaRailMetrics.cornerRadius
        addSubview(moreButton)
    }
    required init?(coder: NSCoder) { fatalError() }
    func show(_ selection: SidebarItem) {
        lastSelection = selection
        buttons[0].isEnabled = !devices.isEmpty
        for (index, button) in buttons.enumerated() {
            let selected: Bool
            if index == 0 { if case .device = selection { selected = true } else { selected = false } }
            else if SidebarItem.library[index - 1] == .music {
                switch selection { case .music, .artists, .albums, .recentMusic, .playlist: selected = true; default: selected = false }
            } else { selected = selection == SidebarItem.library[index - 1] }
            button.isCurrent = selected
            button.isDropTarget = index == 0 && dropActive
        }
        moreButton.isCurrent = SidebarItem.otherSections.contains(selection)
    }

    // MARK: Dropping tracks on the iPod

    /// The iPod a drop would go to: the open one, else the first, when the pointer is on the iPod button.
    private func dropTarget(for sender: any NSDraggingInfo) -> String? {
        guard !devices.isEmpty else { return nil }
        let point = convert(sender.draggingLocation, from: nil)
        guard buttons[0].frame.insetBy(dx: -6, dy: -6).contains(point) else { return nil }
        if case .device(let id) = lastSelection, devices.contains(id) { return id }
        return devices.first
    }
    private func setDropActive(_ active: Bool) {
        guard dropActive != active else { return }
        dropActive = active
        show(lastSelection)
    }
    private func operation(for sender: any NSDraggingInfo) -> NSDragOperation {
        let target = dropTarget(for: sender)
        setDropActive(target != nil)
        return target == nil ? [] : .copy
    }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { operation(for: sender) }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { operation(for: sender) }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) { setDropActive(false) }
    override func draggingEnded(_ sender: any NSDraggingInfo) { setDropActive(false) }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { dropTarget(for: sender) != nil }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        defer { setDropActive(false) }
        guard let id = dropTarget(for: sender) else { return false }
        return TrackDrag.accept(musicDragPayload(in: sender.draggingPasteboard), device: id)
    }
    override func layout() {
        super.layout()
        typealias M = MediaRailMetrics
        let x = (bounds.width - M.button) / 2
        for (index, button) in buttons.enumerated() {
            // The iPod sits at the bottom; the libraries run down from under the title bar.
            let y = index == 0 ? M.bottomGap : bounds.height - titleBarHeight - M.topGap - M.button - CGFloat(index - 1) * M.pitch
            button.frame = NSRect(x: x, y: y, width: M.button, height: M.button)
        }
        let moreY = bounds.height - titleBarHeight - M.topGap - M.button - CGFloat(SidebarItem.library.count) * M.pitch
        moreButton.frame = NSRect(x: x, y: moreY, width: M.button, height: M.button)
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
    @objc private func showMoreSections(_ sender: NSButton) {
        let menu = NSMenu()
        if SidebarItem.otherSections.isEmpty {
            let none = NSMenuItem(title: "No other sections", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        for (index, section) in SidebarItem.otherSections.enumerated() {
            let item = NSMenuItem(title: section.title, action: #selector(selectOther(_:)), keyEquivalent: "")
            item.image = systemSymbol(section.icon, description: section.title, pointSize: 13)
            item.tag = index; item.target = self; menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: sender.frame.maxX, y: sender.frame.midY), in: self)
    }
    @objc private func selectOther(_ sender: NSMenuItem) {
        if SidebarItem.otherSections.indices.contains(sender.tag) { onSelect(SidebarItem.otherSections[sender.tag]) }
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
        view.state = .active  // the glass stays when another app comes forward
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = floating ? .popover : .sidebar
        view.blendingMode = floating ? .withinWindow : .behindWindow
        view.layer?.cornerRadius = floating ? 22 : 0
        view.layer?.masksToBounds = floating
    }
}
/// The sidebar's panel: dark translucent glass, like the App Switcher's highlight, with the main
/// view's shape along its left side: the same rounding at the top left and the bottom left.
/// The blur is clipped by a mask image, not by the layer, which would switch the blur off.
struct SidebarGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> SidebarGlassView { SidebarGlassView() }
    func updateNSView(_ view: SidebarGlassView, context: Context) {}
}

final class SidebarGlassView: NSView {
    private let glass = NSVisualEffectView()
    private let tint = NSView()
    /// A dark 1 pt line along the right edge, as thick as the main view's outline.
    private let edge = NSView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active  // stays glass when another app comes forward
        glass.appearance = NSAppearance(named: .darkAqua)
        glass.maskImage = Self.leftRoundedMask(radius: CGFloat(floatingPanelRadius))
        glass.autoresizingMask = [.width, .height]
        addSubview(glass)
        // Darker than the plain material, still translucent.
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        tint.layer?.cornerRadius = CGFloat(floatingPanelRadius)
        tint.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner]
        tint.autoresizingMask = [.width, .height]
        addSubview(tint)
        edge.wantsLayer = true
        edge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
        addSubview(edge)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        glass.frame = bounds
        tint.frame = bounds
        edge.frame = NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height)
        applyBlurRadius()
        // The backdrop layer is created after the first draw: apply again once it exists.
        if !blurApplied { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.applyBlurRadius() } }
    }
    private var blurApplied = false

    /// The material's blur has no public setting. Its backdrop layer carries a gaussian blur filter whose
    /// radius can be raised; if the system's layer layout is different, the stock blur is kept.
    private func applyBlurRadius() {
        let radius = ProcessInfo.processInfo.environment["IPPM_SIDEBAR_BLUR"].flatMap(Double.init) ?? 60
        func visit(_ layer: CALayer) {
            if let filters = layer.filters, !filters.isEmpty {
                for filter in filters {
                    let object = filter as AnyObject
                    if (object.value(forKey: "name") as? String) == "gaussianBlur" {
                        object.setValue(radius, forKey: "inputRadius")
                        blurApplied = true
                    }
                }
                layer.filters = filters
            }
            layer.sublayers?.forEach(visit)
        }
        if let root = glass.layer { visit(root) }
    }

    /// A stretchable shape: round on the left, square on the right.
    private static func leftRoundedMask(radius r: CGFloat) -> NSImage {
        let side = 2 * r + 2
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            NSBezierPath(rect: NSRect(x: rect.midX, y: 0, width: rect.width / 2, height: rect.height)).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        image.resizingMode = .stretch
        return image
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
