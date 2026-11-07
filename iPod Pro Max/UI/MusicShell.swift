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
    /// Extra room under the iPod button for the separator line.
    static let separatorExtra = 12.0
}

/// A rail button that behaves like a Mac toolbar item: a short pause under the pointer, then a grey
/// plate fades in; while the mouse is held the glyph turns white and the plate deepens; released
/// inside, the action runs and the button takes the current page's tint. A track dropped on the
/// button gets its own tint. The effects are drawn here (the system's toolbar bezel didn't follow
/// the icons' shape), and nothing runs while the pointer is still.
final class RailButton: NSButton {
    var isCurrent = false {
        didSet {
            activated = false
            // The plate of the page being left fades out (quickly) instead of vanishing.
            refresh(animated: oldValue && !isCurrent)
        }
    }
    /// How long a plate takes to fade out: quicker than it fades in.
    static let fadeOut = 0.04
    /// Set when a click released inside: the button keeps its selected look until the selection
    /// catches up, so the glyph doesn't fall back to the hover color in between.
    private var activated = false { didSet { if activated != oldValue { refresh() } } }
    var isDropTarget = false { didSet { refresh() } }

    /// Pause under the pointer before the hover plate starts to fade in.
    static let hoverDelay = 0.4
    /// The section's name, shown beside the button while the pointer rests on it (instead of a tooltip).
    var label = ""
    /// The library section this button opens (nil for the iPod button and "...").
    var item: SidebarItem?
    /// Called when the button is dragged: the rail runs the reordering until the mouse is released.
    var onReorder: ((RailButton) -> Void)?
    /// Runs once the pointer has rested on the button for the hover delay (the "..." menu opens here).
    var onHoverRest: (() -> Void)?
    /// After a press the name stays away until the pointer has left and come back.
    private var labelSuppressed = false
    /// Whether a click leaves the button lit until the selection catches up (not the "..." menu's).
    var litOnClick = true
    func clearActivation() { activated = false }
    /// A menu opened from this button has closed: the pointer may be anywhere (the exit event goes
    /// to the menu), so the button drops its hover until the pointer enters again.
    func endHover() {
        hoverWork?.cancel()
        activated = false
        labelSuppressed = false
        hovering = false
    }
    /// The glyph is drawn by an image view of its own: it is the view that plays symbol effects
    /// (a button can't). The button itself draws no image.
    private let glyphView = NSImageView()
    private var appearing = false
    /// A menu opened from this button is showing: the button looks pressed, as if it had been clicked.
    var menuOpen = false { didSet { if menuOpen != oldValue { refresh(animated: true) } } }
    var symbolImage: NSImage? { didSet { glyphView.image = symbolImage } }

    override func layout() {
        super.layout()
        glyphView.frame = bounds
    }
    /// The glyph view never takes the mouse: the button does.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.insetBy(dx: -Self.hitPadding.width, dy: -Self.hitPadding.height).contains(point) ? self : nil
    }

    /// The symbol's "appear" effect, as when a section is pinned to the rail (a fade before macOS 14).
    func playAppear() {
        // A button that has just appeared isn't hovered, whatever the pointer's position (it may be
        // resting where the button lands).
        appearing = true
        hoverWork?.cancel()
        hovering = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.appearing = false }
        if #available(macOS 14, *) {
            glyphView.addSymbolEffect(.disappear, options: .default, animated: false)
            DispatchQueue.main.async { [weak self] in self?.glyphView.addSymbolEffect(.appear) }
        } else {
            alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                animator().alphaValue = 1
            }
        }
    }

    /// The "disappear" effect, as when a section is unpinned; `completion` runs once it has played.
    func playDisappear(completion: @escaping () -> Void) {
        if #available(macOS 14, *) {
            glyphView.addSymbolEffect(.disappear)
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                animator().alphaValue = 0
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { completion() }
    }
    private var hovering = false {
        didSet {
            guard hovering != oldValue else { return }
            refresh(animated: true)
            updateLabel()
        }
    }
    private var pressed = false {
        didSet {
            guard pressed != oldValue else { return }
            refresh(animated: false)
            updateLabel()
        }
    }
    private func updateLabel() {
        if hovering && !pressed && !labelSuppressed, let window, !label.isEmpty {
            RailLabel.shared.show(label, besideScreenRect: window.convertToScreen(convert(bounds, to: nil)))
        } else if !hovering {
            // The pointer left: a moment's grace, so the next button's name replaces it with no gap.
            RailLabel.shared.scheduleHide()
        } else {
            RailLabel.shared.hide()
        }
    }
    private var hoverWork: DispatchWorkItem?

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        imagePosition = .imageOnly
        setButtonType(.momentaryPushIn)
        glyphView.imageScaling = .scaleNone
        glyphView.imageAlignment = .alignCenter
        glyphView.wantsLayer = true
        addSubview(glyphView)
    }

    /// The button reacts a little beyond its drawn plate: the gaps between two buttons belong to one
    /// or the other, so the pointer is never over none of them while it crosses the rail (the Dock's
    /// way). The plate itself keeps its size.
    private static let hitPadding = NSSize(width: 6, height: 4)
    private var hitBounds: NSRect { bounds.insetBy(dx: -Self.hitPadding.width, dy: -Self.hitPadding.height) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: hitBounds, options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        // Like a toolbar's items: no hover, no name, while the window isn't the key one.
        guard isEnabled, !appearing, window?.isKeyWindow == true else { return }
        hoverWork?.cancel()
        // Moving from one named button to the next: the name is already up, so no pause.
        if !label.isEmpty && RailLabel.shared.isActive {
            hovering = true
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hovering = true
            self.onHoverRest?()
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hoverDelay, execute: work)
    }

    override func mouseExited(with event: NSEvent) {
        hoverWork?.cancel()
        labelSuppressed = false
        activated = false
        hovering = false
    }

    /// Tracks the press itself: white glyph and deeper plate while the pointer is inside, the action
    /// only when the button is released inside.
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        hoverWork?.cancel()
        labelSuppressed = true
        RailLabel.shared.hide()
        hovering = true
        pressed = true
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let inside = hitBounds.contains(convert(next.locationInWindow, from: nil))
            if next.type == .leftMouseUp {
                pressed = false
                hovering = inside
                if inside {
                    if litOnClick { activated = true }
                    sendAction(action, to: target)
                }
                return
            }
            // Dragging a library button picks it up, to put it elsewhere in the rail.
            if onReorder != nil, abs(next.locationInWindow.y - event.locationInWindow.y) > 4 {
                onReorder?(self)
                pressed = false
                if let window { hovering = hitBounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) }
                return
            }
            pressed = inside
        }
        pressed = false
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh(animated: false)
    }

    override var isEnabled: Bool {
        didSet {
            glyphView.alphaValue = isEnabled ? 1 : 0.4
            if !isEnabled { hoverWork?.cancel(); hovering = false; pressed = false }
        }
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
        guard let window else { hovering = false; return }
        // A toolbar's items dim when their window isn't the key one; the rail does the same.
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if !window.isKeyWindow { self.hoverWork?.cancel(); self.hovering = false; self.pressed = false }
                    self.refresh()
                }
            })
        }
        refresh()
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    /// The toolbar's plate is a translucent overlay (white in dark mode, black in light), measured
    /// on a native item: 6.5 % under the pointer, 13 % while pressed. The background shows through.
    private static func overlay(_ alpha: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return (dark ? NSColor.white : NSColor.black).withAlphaComponent(alpha)
        }
    }

    func refresh(animated: Bool = false) {
        let active = window?.isKeyWindow ?? true
        let plate: NSColor
        let tint: NSColor
        if isDropTarget { plate = .controlAccentColor; tint = .white }
        else if (pressed || menuOpen) && active { plate = Self.overlay(0.13); tint = .white }
        else if (isCurrent || activated) && active { plate = Self.overlay(0.065); tint = .white }
        else if isCurrent { plate = NSColor.white.withAlphaComponent(0.08); tint = NSColor.labelColor.withAlphaComponent(0.35) }
        else if hovering && active { plate = Self.overlay(0.065); tint = .secondaryLabelColor }
        else if active { plate = .clear; tint = .secondaryLabelColor }
        else { plate = .clear; tint = NSColor.labelColor.withAlphaComponent(0.3) }
        contentTintColor = tint
        if animated, glyphView.contentTintColor != tint, let glyphLayer = glyphView.layer {
            // The glyph's color fades too (toward white when the button is pressed).
            let crossfade = CATransition()
            crossfade.type = .fade
            crossfade.duration = TitleBarButtons.hoverFade
            glyphLayer.add(crossfade, forKey: "tintFade")
        }
        glyphView.contentTintColor = tint
        guard let layer else { return }
        // Resolve the dynamic color in this view's appearance, then fade to it like a toolbar item.
        var target = CGColor.clear
        let saved = NSAppearance.current
        NSAppearance.current = effectiveAppearance
        target = plate.cgColor
        NSAppearance.current = saved
        if animated {
            let fade = CABasicAnimation(keyPath: "backgroundColor")
            fade.fromValue = layer.presentation()?.backgroundColor ?? layer.backgroundColor
            fade.toValue = target
            // Arriving eases out, leaving eases in (and is quicker).
            let arriving = target.alpha >= (layer.presentation()?.backgroundColor ?? layer.backgroundColor)?.alpha ?? 0
            fade.duration = arriving ? TitleBarButtons.hoverFade : Self.fadeOut
            fade.timingFunction = CAMediaTimingFunction(name: arriving ? .easeOut : .easeIn)
            layer.add(fade, forKey: "plateFade")
        } else {
            layer.removeAnimation(forKey: "plateFade")
        }
        layer.backgroundColor = target
    }
}

/// The order of the library buttons, chosen by dragging them. Saved in
/// `iPod Pro Max/Persistent Data/rail-order.json`, shared by the three apps; the default order when
/// the file is missing.
enum RailOrder {
    private static var file: URL? {
        PortableRoot.url?.appendingPathComponent("iPod Pro Max/Persistent Data/rail-order.json")
    }

    static let ordered: [SidebarItem] = {
        guard let file, let data = try? Data(contentsOf: file),
              let names = try? JSONDecoder().decode([String].self, from: data) else { return SidebarItem.library }
        // The libraries, plus the extra sections pinned to the rail.
        let known = SidebarItem.library + SidebarItem.otherSections
        return normalized(names.compactMap { name in known.first { $0.railName == name } })
    }()

    /// The libraries first, then the pinned extras, each group in the given order; libraries added
    /// since the file was written go at the end of theirs.
    static func normalized(_ items: [SidebarItem]) -> [SidebarItem] {
        let libraries = items.filter { SidebarItem.library.contains($0) }
        return libraries + SidebarItem.library.filter { !libraries.contains($0) }
            + items.filter { SidebarItem.otherSections.contains($0) }
    }

    static func save(_ items: [SidebarItem]) {
        guard let file, let data = try? JSONEncoder().encode(items.map(\.railName)) else { return }
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
    }
}

/// A row of the "…" menu: the section's icon and name, and a small pin button at the right. Drawn
/// here (a menu item with a view loses the system's highlight), in the system's selection color.
@MainActor
final class ExtraMenuRow: NSView {
    var onOpen: () -> Void = {}
    var onTogglePin: (Bool) -> Void = { _ in }
    private var pinned: Bool
    private let icon = NSImageView()
    private let title: NSTextField
    private let pin = NSButton()
    private var highlighted = false { didSet { if highlighted != oldValue { restyle() } } }

    private let symbolName: String

    init(section: SidebarItem, pinned: Bool, fontSize: CGFloat, titleWidth: CGFloat) {
        self.pinned = pinned
        symbolName = section.icon
        title = NSTextField(labelWithString: section.railName)
        // icon column, the widest name, a short gap, the pin.
        super.init(frame: NSRect(x: 0, y: 0, width: 46 + titleWidth + 14 + 22 + 12, height: 32))
        icon.frame = NSRect(x: 14, y: 6, width: 22, height: 20)
        title.font = .menuFont(ofSize: fontSize)
        title.sizeToFit()
        title.frame.origin = NSPoint(x: 46, y: (bounds.height - title.frame.height) / 2)
        pin.isBordered = false
        pin.imagePosition = .imageOnly
        pin.target = self; pin.action = #selector(togglePin)
        pin.frame = NSRect(x: bounds.width - 34, y: 6, width: 22, height: 20)
        pin.autoresizingMask = [.minXMargin]
        pin.setAccessibilityLabel("Pin to Sidebar")
        [icon, title, pin].forEach(addSubview)
        restyle()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// A dynamic color as it looks in this view's appearance (the menu's own, not the app's).
    private func resolved(_ color: NSColor) -> NSColor {
        let saved = NSAppearance.current
        NSAppearance.current = effectiveAppearance
        defer { NSAppearance.current = saved }
        return color.usingColorSpace(.sRGB) ?? color
    }

    /// A symbol that carries its color itself: a template image's tint is ignored in a menu, which
    /// drew the pin black.
    private func symbol(_ name: String, size: Double, color: NSColor) -> NSImage? {
        let image = systemSymbol(name, description: nil, pointSize: size)
        if #available(macOS 12, *) {
            return image?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
                .applying(.init(paletteColors: [resolved(color)])))
        }
        return image
    }

    private func restyle() {
        icon.image = symbol(symbolName, size: 16, color: highlighted ? .white : .labelColor)
        title.textColor = highlighted ? .white : .labelColor
        // The gray of the system's secondary controls; white on the selection.
        pin.image = symbol(pinned ? "pin.fill" : "pin", size: 11, color: highlighted ? .white : .secondaryLabelColor)
        needsDisplay = true
    }

    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); restyle() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); restyle() }

    @objc private func togglePin() {
        pinned.toggle()
        restyle()
        onTogglePin(pinned)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { highlighted = true }
    override func mouseExited(with event: NSEvent) { highlighted = false }

    override func draw(_ dirtyRect: NSRect) {
        guard highlighted else { return }
        NSColor.selectedContentBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 6, yRadius: 6).fill()
    }

    /// Releasing on the row (not on the pin) opens the section and closes the menu.
    override func mouseUp(with event: NSEvent) {
        guard !pin.frame.contains(convert(event.locationInWindow, from: nil)) else { return }
        let open = onOpen
        DispatchQueue.main.async { open() }
    }
}

/// The two thin lines around the name's pill: black outside, a faint white one just inside.
final class LabelBorderView: NSView {
    var radius: CGFloat = 5
    private let outer = CALayer()
    private let inner = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // Layer borders are drawn on the display's pixel grid, so both lines stay crisp (a path
        // stroked at a fractional width blurred and made the corners uneven).
        outer.borderWidth = 1
        outer.borderColor = NSColor.black.withAlphaComponent(0.9).cgColor
        inner.borderWidth = 1
        inner.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        layer?.addSublayer(outer)
        layer?.addSublayer(inner)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isOpaque: Bool { false }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let scale = window?.backingScaleFactor ?? 2
        outer.contentsScale = scale; inner.contentsScale = scale
        outer.frame = bounds
        outer.cornerRadius = radius
        // Concentric with the outer line: one point in, one point less of radius.
        inner.frame = bounds.insetBy(dx: 1, dy: 1)
        inner.cornerRadius = max(radius - 1, 0)
        CATransaction.commit()
    }
}

/// The Dock's label: a small rounded pill that appears to the right of the item under the pointer,
/// in its own borderless window so it isn't clipped by the rail. Created once, shown only on hover.
@MainActor
final class RailLabel {
    static let shared = RailLabel()
    private let panel: NSPanel
    private let text = NSTextField(labelWithString: "")
    private let glass = NSVisualEffectView()

    private init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // No window shadow: its soft halo thickened the black line, most at the corners. The Dock's
        // label has just the line.
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        // Clipped by a mask image, not by the layer (which would switch the blur off), so the blur,
        // the border and the shadow all follow the rounded shape.
        let radius: CGFloat = 5  // a whole number of points, so the mask's corners stay sharp
        let mask = NSImage(size: NSSize(width: radius * 2 + 1, height: radius * 2 + 1), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        mask.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        mask.resizingMode = .stretch
        glass.maskImage = mask
        // The Dock's label, measured on a screenshot of it: 14 pt regular text in a 28 pt pill.
        text.font = .systemFont(ofSize: 14, weight: .regular)
        text.textColor = .labelColor
        glass.addSubview(text)
        // The Dock's outline, measured on its label: a 1 pt black line at the edge, then a 1 pt
        // light line just inside it. Drawn over the glass, which keeps to the rounded shape.
        let container = NSView()
        glass.frame = container.bounds
        glass.autoresizingMask = [.width, .height]
        border.frame = container.bounds
        border.autoresizingMask = [.width, .height]
        border.radius = radius
        container.addSubview(glass)
        container.addSubview(border)
        panel.contentView = container
    }

    private let border = LabelBorderView()

    func show(_ string: String, besideScreenRect rect: NSRect) {
        pendingHide?.cancel()
        text.stringValue = string
        text.sizeToFit()
        let size = NSSize(width: text.frame.width + 30, height: text.frame.height + 11)
        text.frame.origin = NSPoint(x: 15, y: 5.5)
        // Overlapping the rail's edge by a few points (the button sits 8 pt inside it), so the name
        // reads as floating above everything.
        panel.setFrame(NSRect(x: rect.maxX + 5, y: rect.midY - size.height / 2, width: size.width, height: size.height), display: false)
        border.needsLayout = true
        panel.orderFrontRegardless()
        panel.invalidateShadow()
    }

    var isActive: Bool { panel.isVisible }
    private var pendingHide: DispatchWorkItem?

    func hide() {
        pendingHide?.cancel()
        panel.orderOut(nil)
    }

    /// Hides unless another name is shown within a moment.
    func scheduleHide() {
        pendingHide?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.panel.orderOut(nil) }
        pendingHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }
}

/// The "..." button's menu, in a panel of its own so it can behave like the Dock's: it fades out when
/// the pointer leaves it and the button, and when a click lands outside it (a system menu leaves at
/// once, and only on a click). Closes with Escape too.
@MainActor
final class ExtrasPopover {
    private let panel: NSPanel
    private var monitors: [Any] = []
    private var watcher: Timer?
    private var dismissing = false
    private var outsideSince: Date?
    private let anchor: NSRect
    /// Runs as soon as the menu starts to leave, so the button's highlight fades with it.
    var onDismiss: () -> Void = {}

    /// `anchor` is the button's rect on screen; the menu opens to its right, its top at the button's middle.
    init(rows: [ExtraMenuRow], anchor: NSRect) {
        self.anchor = anchor
        let pad: CGFloat = 5, rowHeight: CGFloat = 32
        let width = rows.first?.frame.width ?? 200
        let size = NSSize(width: width, height: CGFloat(rows.count) * rowHeight + 2 * pad)
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        let glass = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        glass.material = .menu
        glass.blendingMode = .behindWindow
        glass.state = .active
        let radius: CGFloat = 10
        let mask = NSImage(size: NSSize(width: radius * 2 + 1, height: radius * 2 + 1), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        mask.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        mask.resizingMode = .stretch
        glass.maskImage = mask
        for (index, row) in rows.enumerated() {
            row.frame.origin = NSPoint(x: 0, y: size.height - pad - CGFloat(index + 1) * rowHeight)
            glass.addSubview(row)
        }
        panel.contentView = glass
        panel.setFrameTopLeftPoint(NSPoint(x: anchor.maxX + 4, y: anchor.midY))
    }

    func show() {
        panel.orderFrontRegardless()
        panel.invalidateShadow()
        // Clicks outside close it: ours are swallowed (they only close it), the other apps' just seen.
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown], handler: { [weak self] event in
            MainActor.assumeIsolated { () -> NSEvent? in
                guard let self else { return event }
                if event.type == .keyDown {
                    if event.keyCode == 53 { self.dismiss(); return nil }
                    return event
                }
                if event.window === self.panel { return event }
                self.dismiss()
                return nil
            }
        }) { monitors.append(local) }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.dismiss() } }
        }) { monitors.append(global) }
        // Leaves when the pointer rests outside the menu and the button; a short grace lets it cross
        // from one to the other along a diagonal. Lives only as long as the menu.
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.dismissing else { return }
                let pointer = NSEvent.mouseLocation
                if self.anchor.insetBy(dx: -6, dy: -6).contains(pointer) || self.panel.frame.insetBy(dx: -6, dy: -6).contains(pointer) {
                    self.outsideSince = nil
                    return
                }
                let since = self.outsideSince ?? Date()
                self.outsideSince = since
                if Date().timeIntervalSince(since) > 0.25 { self.dismiss() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        watcher = timer
    }

    func dismiss(fade: Bool = true) {
        guard !dismissing else { return }
        dismissing = true
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        watcher?.invalidate()
        onDismiss()
        guard fade else { panel.orderOut(nil); return }
        NSAnimationContext.runAnimationGroup({ [panel] context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [panel] in
            panel.orderOut(nil)
        })
    }
}

final class MediaRailView: NSView {
    var devices: [String] = []
    var onSelect: (SidebarItem) -> Void = { _ in }
    private var buttons: [RailButton] = []
    /// What the rail shows under the iPod, in order: the libraries and the extra sections pinned to it.
    private var railItems = RailOrder.ordered
    /// Under the libraries: a menu of the sections that aren't shown in the rail.
    private let moreButton = RailButton(title: "", target: nil, action: nil)
    private var lastSelection: SidebarItem = .music
    private let separator = NSView()
    /// Between the main sections and the pinned extras.
    private let extrasSeparator = NSView()
    private var reordering = false
    private var menuClosedAt = Date.distantPast
    private var extrasPopover: ExtrasPopover?
    private var railMenuTemplate: NSMenu?
    /// "Reset Order" only when there's something to reset: the libraries and the pinned extras in
    /// their default order need no menu.
    override func menu(for event: NSEvent) -> NSMenu? {
        let pinned = railItems.filter { SidebarItem.otherSections.contains($0) }
        let isDefault = railItems == SidebarItem.library + SidebarItem.otherSections.filter { pinned.contains($0) }
        return isDefault ? nil : railMenuTemplate
    }
    private var dropActive = false
    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.string])
        buttons = [makeButton(for: nil)] + railItems.map { makeButton(for: $0) }
        buttons.forEach(addSubview)
        for line in [separator, extrasSeparator] {
            line.wantsLayer = true
            line.layer?.backgroundColor = NSColor.separatorColor.cgColor
            addSubview(line)
        }
        // A click in the rail's empty space brings up its own menu.
        let railMenu = NSMenu()
        railMenu.font = .menuFont(ofSize: Self.menuFontSize)
        let reset = NSMenuItem(title: "Reset Order", action: #selector(resetOrder(_:)), keyEquivalent: "")
        reset.target = self
        railMenu.addItem(reset)
        railMenuTemplate = railMenu
        moreButton.target = self; moreButton.action = #selector(showMoreSections(_:))
        moreButton.image = systemSymbol("ellipsis", description: "More sections", pointSize: MediaRailMetrics.symbolSize)
        moreButton.tag = -1
        moreButton.litOnClick = false
        // No name label: the menu itself opens when the pointer rests on the button.
        moreButton.onHoverRest = { [weak self] in
            guard let self else { return }
            self.showMoreSections(self.moreButton)
        }
        moreButton.setAccessibilityLabel("More sections")
        moreButton.wantsLayer = true; moreButton.layer?.cornerRadius = MediaRailMetrics.cornerRadius
        addSubview(moreButton)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// A rail button: the iPod's when `item` is nil.
    private func makeButton(for item: SidebarItem?) -> RailButton {
        let title = item?.railName ?? "Connected iPods"
        let button = RailButton(title: "", target: self, action: #selector(selectMedia(_:)))
        // Every glyph, the iPod's included, is drawn at the same point size.
        // (A configuration replaces the previous one, so the size is part of each.)
        let size = MediaRailMetrics.symbolSize
        if #available(macOS 11, *) {
            let base = NSImage(systemSymbolName: item?.icon ?? "ipod", accessibilityDescription: title)
            let sized = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
            if #available(macOS 13, *) {
                // One color (the iPod's symbol is multicolor by default).
                button.symbolImage = base?.withSymbolConfiguration(sized.applying(.preferringMonochrome()))
            } else {
                button.symbolImage = base?.withSymbolConfiguration(sized)
            }
        }
        if button.symbolImage == nil { button.title = title }
        button.label = title
        button.item = item
        if let item {
            button.onReorder = { [weak self] in self?.reorder($0) }
            // A pinned extra section can be taken off the rail from its context menu.
            if SidebarItem.otherSections.contains(item) {
                let menu = NSMenu()
                menu.font = .menuFont(ofSize: Self.menuFontSize)
                let unpin = NSMenuItem(title: "Unpin from Sidebar", action: #selector(unpinSection(_:)), keyEquivalent: "")
                unpin.target = self; unpin.representedObject = item
                menu.addItem(unpin)
                button.menu = menu
            }
        }
        button.setAccessibilityLabel(title)
        button.wantsLayer = true; button.layer?.cornerRadius = MediaRailMetrics.cornerRadius
        return button
    }

    /// The rail's menus are a size up from the system's (13 pt).
    private static let menuFontSize: CGFloat = 15

    private func rebuildButtons() {
        buttons.dropFirst().forEach { $0.removeFromSuperview() }
        buttons = [buttons[0]] + railItems.map { makeButton(for: $0) }
        buttons.dropFirst().forEach(addSubview)
        needsLayout = true
        show(lastSelection)
    }

    /// Pins an extra section at the bottom of the rail's extras, or takes it off.
    private func setPinned(_ item: SidebarItem, _ pinned: Bool) {
        guard railItems.contains(item) != pinned else { return }
        typealias M = MediaRailMetrics
        if pinned {
            // The new button appears (the symbol's "appear" effect) where the "..." button was, which slides down.
            railItems.append(item)
            let button = makeButton(for: item)
            buttons.append(button)
            addSubview(button)
            button.frame = NSRect(x: (bounds.width - M.button) / 2, y: slotY(buttons.count - 2), width: M.button, height: M.button)
            button.layoutSubtreeIfNeeded()
            button.playAppear()
            slideButtonsIntoPlace()
        } else if let button = buttons.first(where: { $0.item == item }) {
            railItems.removeAll { $0 == item }
            buttons.removeAll { $0 === button }
            // The others close the gap at once, as they make room when a section is pinned.
            slideButtonsIntoPlace()
            button.playDisappear { button.removeFromSuperview() }
        }
        RailOrder.save(railItems)
        show(lastSelection)
    }

    private func slideButtonsIntoPlace() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            for (index, button) in buttons.enumerated() where index > 0 { button.animator().frame.origin.y = slotY(index - 1) }
            moreButton.animator().frame.origin.y = slotY(buttons.count - 1)
        }
    }

    @objc private func unpinSection(_ sender: NSMenuItem) {
        if let item = sender.representedObject as? SidebarItem { setPinned(item, false) }
    }

    /// Puts the libraries back in their default order and the pinned extras in theirs.
    @objc private func resetOrder(_ sender: Any?) {
        let pinned = railItems.filter { SidebarItem.otherSections.contains($0) }
        railItems = SidebarItem.library + SidebarItem.otherSections.filter { pinned.contains($0) }
        RailOrder.save(railItems)
        rebuildButtons()
    }

    func show(_ selection: SidebarItem) {
        lastSelection = selection
        buttons[0].isEnabled = !devices.isEmpty
        // The iPod button is named after the iPod itself.
        let current: String? = { if case .device(let id) = selection, devices.contains(id) { return id }; return devices.first }()
        buttons[0].label = current.flatMap { ConnectedDeviceTitles.names[$0] } ?? "iPod"
        for (index, button) in buttons.enumerated() {
            let selected: Bool
            if index == 0 { if case .device = selection { selected = true } else { selected = false } }
            else if button.item == .music {
                switch selection { case .music, .artists, .albums, .recentMusic, .playlist: selected = true; default: selected = false }
            } else { selected = selection == button.item }
            button.isCurrent = selected
            button.isDropTarget = index == 0 && dropActive
        }
        moreButton.isCurrent = SidebarItem.otherSections.contains(selection) && !railItems.contains(selection)
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
    // MARK: Reordering the library buttons

    private var libraryCount: Int { railItems.filter { SidebarItem.library.contains($0) }.count }

    /// Where the button in `slot` (0 = first under the iPod's separator) sits, in points. The extras
    /// (from `libraryCount` on) have a second separator above them.
    private func slotY(_ slot: Int) -> CGFloat {
        typealias M = MediaRailMetrics
        let gap = slot >= libraryCount ? M.separatorExtra : 0
        return bounds.height - titleBarHeight - M.topGap - M.button - M.pitch - M.separatorExtra - CGFloat(slot) * M.pitch - gap
    }

    /// Runs until the mouse is released: the button follows the pointer along the rail, the others
    /// slide out of its way, and the new order is saved.
    private func reorder(_ button: RailButton) {
        guard let window, buttons.count > 2 else { return }
        typealias M = MediaRailMetrics
        var slots = Array(buttons.dropFirst())
        guard var current = slots.firstIndex(of: button) else { return }
        // A button moves within its own group: the main sections or the extras.
        let isExtra = current >= libraryCount
        let lo = isExtra ? libraryCount : 0
        let hi = isExtra ? slots.count - 1 : libraryCount - 1
        reordering = true
        addSubview(button, positioned: .above, relativeTo: nil)
        let grab = convert(window.mouseLocationOutsideOfEventStream, from: nil).y - button.frame.minY
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let pointer = convert(next.locationInWindow, from: nil).y
            let y = min(slotY(lo), max(slotY(hi), pointer - grab))
            button.frame.origin.y = y
            let target = min(hi, max(lo, lo + Int(((slotY(lo) - y) / M.pitch).rounded())))
            if target != current {
                slots.remove(at: current)
                slots.insert(button, at: target)
                current = target
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    for (slot, other) in slots.enumerated() where other !== button {
                        other.animator().frame.origin.y = slotY(slot)
                    }
                }
            }
            if next.type == .leftMouseUp { break }
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            button.animator().frame.origin.y = slotY(current)
        }
        buttons = [buttons[0]] + slots
        reordering = false
        railItems = slots.compactMap(\.item)
        RailOrder.save(railItems)
    }

    override func layout() {
        super.layout()
        guard !reordering else { return }
        typealias M = MediaRailMetrics
        let x = (bounds.width - M.button) / 2
        let top = bounds.height - titleBarHeight - M.topGap - M.button
        for (index, button) in buttons.enumerated() {
            // The iPod sits at the top, under the title bar; a thin line separates it from the libraries.
            let y = index == 0 ? top : slotY(index - 1)
            button.frame = NSRect(x: x, y: y, width: M.button, height: M.button)
        }
        moreButton.frame = NSRect(x: x, y: slotY(buttons.count - 1), width: M.button, height: M.button)
        separator.frame = NSRect(x: x + 4, y: top - (M.pitch - M.button + M.separatorExtra) / 2, width: M.button - 8, height: 1)
        // Between the last main section and the first extra (or the "…" button).
        let lastMain = slotY(max(libraryCount - 1, 0)), firstExtra = slotY(libraryCount)
        extrasSeparator.frame = NSRect(x: x + 4, y: (lastMain + firstExtra + M.button) / 2, width: M.button - 8, height: 1)
    }
    @objc private func selectMedia(_ sender: NSButton) {
        if let item = (sender as? RailButton)?.item { onSelect(item); return }
        if devices.count == 1, let id = devices.first { onSelect(.device(id)); return }
        let menu = NSMenu()
        for (index, id) in devices.enumerated() {
            let item = NSMenuItem(title: ConnectedDeviceTitles.names[id] ?? "iPod", action: #selector(selectDevice(_:)), keyEquivalent: "")
            item.tag = index; item.target = self; menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: sender.frame.maxX, y: sender.frame.midY), in: self)
        // Dismissed without choosing: the iPod button doesn't stay lit.
        (sender as? RailButton)?.endHover()
    }
    @objc private func showMoreSections(_ sender: NSButton) {
        // Already open, or a click that closed it (pointer still on the button) must not reopen it.
        guard extrasPopover == nil, Date().timeIntervalSince(menuClosedAt) > 0.3, let window else { return }
        // Every extra section, each with a small pin at its right: outline when it isn't on the
        // rail, filled once it is (clicking it adds the section at the bottom of the rail's extras).
        let font = NSFont.menuFont(ofSize: Self.menuFontSize)
        let widest = SidebarItem.otherSections.map { ($0.railName as NSString).size(withAttributes: [.font: font]).width }.max() ?? 80
        var rows: [ExtraMenuRow] = []
        for section in SidebarItem.otherSections {
            let row = ExtraMenuRow(section: section, pinned: railItems.contains(section), fontSize: Self.menuFontSize,
                                   titleWidth: ceil(widest))
            row.onOpen = { [weak self] in
                self?.extrasPopover?.dismiss(fade: false)
                self?.onSelect(section)
            }
            row.onTogglePin = { [weak self] pinned in self?.setPinned(section, pinned) }
            rows.append(row)
        }
        RailLabel.shared.hide()
        let popover = ExtrasPopover(rows: rows, anchor: window.convertToScreen(sender.convert(sender.bounds, to: nil)))
        extrasPopover = popover
        // The button lights up as the menu appears, as if it had been clicked, and goes out as the
        // menu starts to leave (not once it is gone).
        let railButton = sender as? RailButton
        railButton?.menuOpen = true
        popover.onDismiss = { [weak self] in
            railButton?.menuOpen = false
            railButton?.endHover()
            self?.menuClosedAt = Date()
            self?.extrasPopover = nil
        }
        popover.show()
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
