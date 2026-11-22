#if canImport(AppKitBackend)
import AppKit
import SwiftCrossUI
import MediaKit

@MainActor final class PlayerLCDContent: NSView {
    private let playback = PlaybackController.shared
    private let display = PlayerDisplayController.shared
    private let activities = PlayerActivityController.shared
    private let title = LCDMarquee()
    private let subtitle = NSTextField(labelWithString: "")
    private let elapsed = NSTextField(labelWithString: "")
    private let remaining = ToolbarPlaybackButton()
    private let mode = LCDModeButton()
    private let previousMode = LCDModeButton(), nextMode = LCDModeButton()
    private let reveal = ToolbarPlaybackButton()
    private let cover = LCDArtworkButton()
    private let more = ToolbarPlaybackButton()
    private let backActivity = ToolbarPlaybackButton()
    private let nextActivity = ToolbarPlaybackButton()
    private let cancel = ToolbarPlaybackButton()
    private let indicator = NSTextField(labelWithString: "")
    private let plot = LCDPlaybackPlot()
    var isSpectrumAnimating: Bool { plot.isSpectrumAnimating }
    private let progressOverlay = LCDProgressOverlay()
    private let spinner = NSProgressIndicator()
    private let hoverTime = NSTextField(labelWithString: "")
    private var tokens: [NSObjectProtocol] = []
    private var displaySubscription: SwiftCrossUI.Cancellable?
    private var artworkTask: Task<Void, Never>?
    private var trackID: String?
    private var lastPresentation = ""
    private var hovered = false
    private var renderedHover = false
    private var tracking: NSTrackingArea?
    private var rendering = false
    private var spinning = false
    private let capturesHiddenWindow = ProcessInfo.processInfo.environment["IPPM_SNAPSHOT"] != nil
    private var isDisplayVisible: Bool { window?.isVisible == true && window?.isMiniaturized == false && window?.occlusionState.contains(.visible) == true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for (button, symbol, label, action) in [
            (mode as ToolbarPlaybackButton, "text.alignleft", "Display mode", #selector(cycleMode)),
            (reveal, "arrow.uturn.left", "Show in library", #selector(revealTrack)),
            (more, "ellipsis", "Track actions", #selector(showTrackMenu)),
            (backActivity, "chevron.left", "Previous activity or playback", #selector(previousActivity)),
            (nextActivity, "chevron.right", "Next activity or playback", #selector(followingActivity)),
            (cancel, "xmark", "Cancel or dismiss activity", #selector(cancelActivity))] {
            button.setSymbol(symbol, size: 10); button.isBordered = false
            button.target = self; button.action = action; button.toolTip = label; button.setAccessibilityLabel(label)
        }
        more.usesAccentTint = true
        for (button, symbol, label, selector) in [(previousMode, "chevron.up", "Previous LCD view", #selector(previousLCDMode)), (nextMode, "chevron.down", "Next LCD view", #selector(nextLCDMode))] {
            button.setSymbol(symbol, size: 8); button.isBordered = false; button.target = self; button.action = selector
            button.toolTip = label; button.setAccessibilityLabel(label)
            button.makeMenu = { [weak self] in self?.modeMenu() ?? NSMenu() }
            button.wantsLayer = true; button.alphaValue = 0
        }
        mode.makeMenu = { [weak self] in self?.modeMenu() ?? NSMenu() }
        remaining.alignment = .right
        remaining.title = ""
        remaining.isBordered = false; remaining.font = .monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        remaining.target = self; remaining.action = #selector(toggleTime)
        remaining.setAccessibilityLabel("Remaining or total time")
        cover.title = ""; cover.imagePosition = .imageOnly
        cover.isBordered = false; cover.imageScaling = .scaleNone
        cover.target = self; cover.action = #selector(revealTrack); cover.setAccessibilityLabel("Show playing track in library")
        subtitle.alignment = .center; subtitle.font = .systemFont(ofSize: 10); subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        elapsed.font = .monospacedDigitSystemFont(ofSize: 9, weight: .regular); elapsed.textColor = .secondaryLabelColor
        indicator.font = .systemFont(ofSize: 7); indicator.alignment = .center
        hoverTime.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        hoverTime.alignment = .center; hoverTime.drawsBackground = true
        hoverTime.backgroundColor = .controlBackgroundColor; hoverTime.wantsLayer = true; hoverTime.layer?.cornerRadius = 3
        hoverTime.layer?.masksToBounds = true; hoverTime.isHidden = true
        spinner.style = .spinning; spinner.controlSize = .mini; spinner.isDisplayedWhenStopped = false
        for view in [title, subtitle, plot] { view.wantsLayer = true }
        for view in [title, subtitle, elapsed, remaining, mode, reveal, cover, plot, more, backActivity, nextActivity, cancel, indicator, spinner, hoverTime, progressOverlay] { addSubview(view) }
        addSubview(plot, positioned: .below, relativeTo: title)
        for view in [previousMode, nextMode] { addSubview(view) }
        addSubview(progressOverlay, positioned: .above, relativeTo: nil)
        plot.onPreview = { [weak self] value in self?.refresh(preview: value) }
        plot.onHover = { [weak self] value in
            guard let self else { return }
            self.hoverTime.isHidden = value == nil || self.activities.list.selected != nil || self.display.resolvedMode == .spectrum
            self.needsLayout = true
            self.hoverTime.stringValue = value.map { (self.plot.hoverChapter.map { $0 + " · " } ?? "") + self.time($0) } ?? ""
        }
        title.onClick = { [weak self] in
            guard self?.display.resolvedMode == .title else { return }; self?.revealTrack()
        }
        displaySubscription = display.didChange.observe { [weak self] in self?.refresh() }
        for name in [NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification, NSWindow.didChangeOcclusionStateNotification] {
            tokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, notification.object as? NSWindow === self.window else { return }
                    self.visibilityChanged()
                }
            })
        }
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel("Now Playing")
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); refresh(force: true); visibilityChanged() }
    private func visibilityChanged() {
        playback.setVisible(isDisplayVisible)
        display.setVisible(isDisplayVisible)
        if !isDisplayVisible { setSpinning(false); title.stop(); plot.suspendSpectrum() }
        else { refresh() }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .inVisibleRect, .activeAlways], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; title.scrollOnce(); refresh() }
    override func mouseExited(with event: NSEvent) { hovered = false; hoverTime.isHidden = true; refresh() }
    func refresh(preview: Double? = nil, force: Bool = false) {
        guard (force || isDisplayVisible || capturesHiddenWindow), !rendering else { return }
        rendering = true; defer { rendering = false }
        let hoverChanged = hovered != renderedHover
        renderedHover = hovered
        let track = playback.track
        let activity = activities.list.selected
        let effective = display.resolvedMode
        let position = preview ?? plot.scrub.proposed ?? playback.position
        let key = "\(track?.id ?? "")|\(effective.rawValue)|\(activity?.id ?? "")|\(effective == .lyrics ? (display.lyricIndex ?? -1) : -1)|\(playback.error)"
        let presentationChanged = key != lastPresentation
        if presentationChanged {
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                let fade = CATransition()
                fade.type = effective == .lyrics && !display.jumpedLastRefresh && playback.playing ? .push : .fade
                fade.subtype = .fromTop; fade.duration = 0.15
                layer?.add(fade, forKey: "LCDContent")
            }
            lastPresentation = key
        }
        mode.isEnabled = track != nil
        mode.isHidden = true
        let canChangeView = track != nil || activity != nil || !activities.list.items.isEmpty
        for view in [previousMode, nextMode] {
            let opacity: CGFloat = hovered && canChangeView ? 1 : 0
            fade(view, to: opacity, animated: hoverChanged)
            view.isEnabled = opacity > 0
        }
        let symbols: [PlayerLCDMode: String] = [.title: "text.alignleft", .spectrum: "chart.bar.fill", .waveform: "waveform", .lyrics: "quote.bubble"]
        mode.setSymbol(symbols[display.mode] ?? "text.alignleft", size: 10)
        mode.toolTip = "Display: \(display.mode.rawValue.capitalized)"
        let showTitle = effective == .title
        let available = track != nil && playback.error.isEmpty && activity == nil
        cover.isHidden = !available
        reveal.isHidden = true
        reveal.isEnabled = track.map { display.canReveal($0.id) } ?? false
        cover.isEnabled = reveal.isEnabled
        more.isHidden = !available || !showTitle
        more.isEnabled = available && showTitle
        elapsed.isHidden = !available || effective == .spectrum || effective == .lyrics
        remaining.isHidden = elapsed.isHidden
        plot.isHidden = !available
        setSpinning(activity?.state == .running && activity?.fraction == nil)
        for view in [backActivity, nextActivity, cancel, indicator] { view.isHidden = activity == nil && activities.list.items.isEmpty }
        cancel.isHidden = activity == nil
        indicator.stringValue = activities.list.items.isEmpty ? "" : String(repeating: "•", count: min(5, activities.list.items.count))
        if let activity {
            hoverTime.isHidden = true
            title.setText(activity.title); subtitle.stringValue = activity.detail
            title.isHidden = false; subtitle.isHidden = false
            plot.isHidden = false; plot.activity = activity; plot.needsDisplay = true
            cancel.isEnabled = activity.cancellable || activity.state != .running
            cancel.setSymbol(activity.state == .failed ? "xmark" : activity.state == .completed ? "checkmark" : "xmark", size: 10)
        } else if !playback.error.isEmpty {
            title.setText("⚠ " + playback.error); title.isHidden = false; subtitle.isHidden = true
            plot.activity = nil
        } else if track == nil {
            title.setText(""); subtitle.stringValue = display.idleDetail
            title.isHidden = true; subtitle.isHidden = display.idleDetail.isEmpty
            plot.activity = nil
        } else {
            plot.activity = nil
            title.isHidden = !showTitle && effective != .lyrics
            subtitle.isHidden = title.isHidden
            if effective == .lyrics {
                let index = display.lyricIndex
                title.setText(index.map { display.lyrics[$0].text.isEmpty ? "♪" : display.lyrics[$0].text } ?? "♪")
                let next = index.map { $0 + 1 } ?? 0
                subtitle.stringValue = next < display.lyrics.count ? display.lyrics[next].text : ""
            } else {
                title.setText(track?.playbackTitle ?? (track?.title.isEmpty == false ? track!.title : URL(fileURLWithPath: track?.path ?? "").lastPathComponent))
                subtitle.stringValue = track?.playbackSubtitle ?? [track?.artist ?? "", track?.album ?? ""].filter { !$0.isEmpty }.joined(separator: " — ")
            }
        }
        title.canAnimate = playback.playing && activity == nil && isDisplayVisible && (effective == .title || effective == .lyrics)
        let trackOpacity: CGFloat = track != nil && !playback.playing && activity == nil ? 0.65 : 1
        let spectrumOverlay = available && effective == .spectrum
        let metadataOpacity: CGFloat = spectrumOverlay ? 0 : trackOpacity
        fade(title, to: metadataOpacity, animated: hoverChanged && spectrumOverlay)
        fade(subtitle, to: metadataOpacity, animated: hoverChanged && spectrumOverlay)
        fade(more, to: metadataOpacity, animated: hoverChanged && spectrumOverlay)
        elapsed.stringValue = (playback.duration > 0 ? time(position) : "--:--") + (playback.rate == 1 ? "" : " · \(playback.rate)×")
        remaining.title = playback.duration > 0 ? (display.showsRemaining ? "−" + time(max(0, playback.duration - position)) : time(playback.duration)) : "--:--"
        fade(plot, to: 1, animated: false)
        plot.update(trackID: track?.id, position: position, duration: playback.duration, mode: effective, samples: playback.samples, chapters: display.chapters)
        progressOverlay.isHidden = plot.isHidden
        progressOverlay.update(position: position, duration: playback.duration, activity: activity, proposed: plot.scrub.proposed, chapters: display.chapters)
        if trackID != track?.id {
            trackID = track?.id; artworkTask?.cancel()
            cover.fillsArtwork = false; cover.imageScaling = .scaleNone
            cover.image = systemSymbol("music.note", pointSize: 16)
            if let key = track?.artworkKey, let folder = PlayerArtwork.folder {
                let id = track?.id
                artworkTask = Task { [weak self] in
                    let image = await ThumbnailStore.shared.image(folder.appendingPathComponent(key + ".jpg"), pixels: 128)
                    guard !Task.isCancelled, self?.trackID == id else { return }
                    if let image { self?.cover.fillsArtwork = true; self?.cover.imageScaling = .scaleProportionallyUpOrDown; self?.cover.image = image }
                }
            }
        }
        setAccessibilityValue([activity?.title ?? track?.title ?? "", subtitle.stringValue, time(position), effective.rawValue].joined(separator: ", "))
        if presentationChanged || hoverChanged { needsLayout = true; layoutSubtreeIfNeeded() }

    }
    private func setSpinning(_ value: Bool) {
        guard spinning != value else { return }
        spinning = value
        if value { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }
    private func fade(_ view: NSView, to opacity: CGFloat, animated: Bool) {
        guard abs(view.alphaValue - opacity) > 0.001 else { return }
        let start = view.layer?.presentation()?.opacity ?? Float(view.alphaValue)
        view.alphaValue = opacity
        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = start; animation.toValue = Float(opacity)
            animation.duration = hovered ? 0.13 : 0.10
            if view === previousMode || view === nextMode {
                let move = CABasicAnimation(keyPath: "transform.translation.x")
                move.fromValue = view.layer?.presentation()?.transform.m41 ?? (hovered ? -8 : 0)
                move.toValue = hovered ? 0 : -8; move.duration = animation.duration
                move.timingFunction = CAMediaTimingFunction(name: .easeOut)
                view.layer?.add(move, forKey: "modeReveal")
            }
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            view.layer?.add(animation, forKey: "metadataHover")
        }
    }
    override func layout() {
        super.layout()
        let width = bounds.width, height = bounds.height
        cover.frame = NSRect(x: 0, y: 0, width: height, height: height)
        let hasCover = !cover.isHidden
        let artEdge: CGFloat = hasCover ? height : 0
        mode.frame = .zero
        previousMode.frame = NSRect(x: width - 18, y: height - 19, width: 16, height: 16)
        nextMode.frame = NSRect(x: width - 18, y: 3, width: 16, height: 16)
        let left = artEdge + 4, right: CGFloat = 22
        let availableWidth = max(0, width - left - right)
        let actionsWidth: CGFloat = more.isHidden ? 0 : 20
        let titleWidth = min(max(0, availableWidth - actionsWidth), title.naturalWidth)
        let start = left + max(0, (availableWidth - titleWidth - actionsWidth) / 2)
        title.frame = NSRect(x: start, y: height - 19, width: titleWidth, height: 15)
        subtitle.frame = NSRect(x: left, y: height - 31, width: availableWidth, height: 12)
        if playback.track == nil && activities.list.selected == nil { title.frame.origin.y = 14 }
        elapsed.frame = NSRect(x: artEdge + 1, y: 3, width: playback.rate == 1 ? 48 : 84, height: 11)
        remaining.frame = NSRect(x: width - right - 54, y: 2, width: 54, height: 15)
        reveal.frame = .zero
        more.frame = NSRect(x: title.frame.maxX + 2, y: height - 20, width: 18, height: 16)
        backActivity.frame = NSRect(x: width - 70, y: 20, width: 16, height: 16)
        nextActivity.frame = NSRect(x: width - 52, y: 20, width: 16, height: 16)
        cancel.frame = NSRect(x: width - 52, y: 3, width: 16, height: 16)
        indicator.frame = NSRect(x: width - 72, y: 7, width: 26, height: 9)
        let expanded = display.resolvedMode == .waveform || display.resolvedMode == .spectrum
        plot.frame = NSRect(x: artEdge, y: 0, width: max(0, width - artEdge), height: expanded && activities.list.selected == nil ? height - 3 : 7)
        progressOverlay.frame = NSRect(x: artEdge, y: 0, width: max(0, width - artEdge), height: 7)
        spinner.frame = NSRect(x: width - 72, y: 3, width: 12, height: 12)
        hoverTime.frame = NSRect(x: max(25, min(width - 115, plot.hoverX + 3)), y: 14, width: 72, height: 15)
    }
    override func scrollWheel(with event: NSEvent) { plot.scrollWheel(with: event) }
    func checkScrollRouting() {
        // Exercise both event entry points: a child hit and a hit elsewhere in
        // the LCD. Vertical scrolls and horizontal scrolls while idle are ignored.
        for horizontal: Int32 in [0, 12] {
            let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                             wheel1: 10, wheel2: horizontal, wheel3: 0)!
            let event = NSEvent(cgEvent: cg)!
            scrollWheel(with: event)
            plot.scrollWheel(with: event)
        }
        plot.update(trackID: "scroll-check", position: 0, duration: 60, mode: .title, samples: [], chapters: [])
        let vertical = NSEvent(cgEvent: CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                               wheel1: 10, wheel2: 0, wheel3: 0)!)!
        scrollWheel(with: vertical)
        plot.scrollWheel(with: vertical)
        for delta: Int32 in [-20, -1, 1, 20] {
            let horizontal = NSEvent(cgEvent: CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                                     wheel1: 0, wheel2: delta, wheel3: 0)!)!
            scrollWheel(with: horizontal); plot.scrollWheel(with: horizontal)
            precondition(plot.scrub.proposed == nil, "Discrete wheel gestures must finish")
        }
        for type: CGEventType in [.leftMouseDown, .leftMouseDragged, .leftMouseUp] {
            let click = NSEvent(cgEvent: CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: CGPoint(x: 100, y: 4), mouseButton: .left)!)!
            if type == .leftMouseDown { plot.mouseDown(with: click) }
            else if type == .leftMouseDragged { plot.mouseDragged(with: click) }
            else { plot.mouseUp(with: click) }
        }
        precondition(plot.scrub.proposed == nil, "Click/drag release must end the scrub")
        // Cancellation belongs to the entire gesture, not only its proposal.
        var seeks: [Double] = []
        plot.onSeek = { seeks.append($0) }; plot.currentTrackID = { "scroll-check" }
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 1, y: 1), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        plot.mouseDown(with: down); plot.keyDown(with: escape)
        plot.mouseDragged(with: down); plot.mouseUp(with: down)
        precondition(seeks.isEmpty && plot.scrub.proposed == nil, "Escape prevents a seek until a new gesture")
        plot.mouseDown(with: down); plot.mouseUp(with: down)
        precondition(seeks.count == 1, "A fresh gesture works after cancellation")
        plot.onSeek = { PlaybackController.shared.seek($0) }
        plot.currentTrackID = { PlaybackController.shared.track?.id }
        log("PASS: Escape cancels the full scrub gesture; a new press restores seeking")
        refresh(force: true)
        precondition(title.isHidden, "Idle LCD must not show a device or app name")
        precondition(subviews.firstIndex(of: progressOverlay)! > subviews.firstIndex(of: subtitle)!, "Progress must draw above the metadata")
        progressOverlay.checkHoverRendering()
        log("PASS: LCD vertical/horizontal scroll and click/drag without responder recursion; idle title hidden")
    }

    func checkComposition() {
        guard playback.track != nil, activities.list.selected == nil else { return }
        func snapshot(_ name: String) {
            guard let root = superview, let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return }
            root.cacheDisplay(in: root.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/plr-composition-" + name + ".png"))
        }
        let previousMode = display.mode, previousHover = hovered
        defer { hovered = previousHover; display.choose(previousMode); refresh(force: true) }
        display.choose(.title); refresh(force: true); layoutSubtreeIfNeeded()
        precondition(cover.frame == NSRect(x: 0, y: 0, width: bounds.height, height: bounds.height))
        precondition(progressOverlay.frame.minX == cover.frame.maxX && progressOverlay.frame.maxX == bounds.maxX)
        precondition(!more.isHidden && more.usesAccentTint && more.frame.minX == title.frame.maxX + 2)
        snapshot("title")
        display.choose(.spectrum); hovered = true; refresh(force: true); layoutSubtreeIfNeeded()
        precondition(more.isHidden && title.isHidden && subtitle.isHidden && plot.alphaValue == 1, "Spectrum hover must preserve the visualization")
        snapshot("spectrum-hover")
        precondition(self.previousMode.alphaValue == 1 && nextMode.alphaValue == 1 && self.previousMode.isEnabled)
        previousLCDMode(); nextLCDMode()
        precondition(display.mode == .spectrum, "LCD chevrons cycle both ways")
        hovered = false; refresh(force: true)
        precondition(more.alphaValue == 0 && title.alphaValue == 0 && !more.isEnabled)
        precondition(self.previousMode.frame.minX == bounds.width - 18)
        precondition(subviews.firstIndex(of: progressOverlay)! > subviews.firstIndex(of: nextMode)!)
        display.choose(.waveform); refresh(force: true); layoutSubtreeIfNeeded(); snapshot("waveform")
        log("PASS: right-side LCD controls below timeline; spectrum hover preserves bars; artwork and accent title actions")
    }

    private func time(_ value: Double) -> String { let n = Int(max(0, value.isFinite ? value : 0)); return n >= 3600 ? String(format: "%d:%02d:%02d", n / 3600, n / 60 % 60, n % 60) : String(format: "%d:%02d", n / 60, n % 60) }
    @objc private func previousLCDMode() { changeLCDMode(-1) }
    @objc private func nextLCDMode() { changeLCDMode(1) }
    private func changeLCDMode(_ direction: Int) {
        if activities.list.selected != nil { activities.cycle(direction); return }
        let modes = PlayerLCDMode.allCases.filter { $0 != .lyrics || !display.lyrics.isEmpty }
        let index = modes.firstIndex(of: display.mode) ?? 0
        display.choose(modes[(index + direction + modes.count) % modes.count])
    }
    @objc private func cycleMode() { display.cycle() }
    @objc private func toggleTime() { display.toggleTime() }
    @objc private func revealTrack() { if let id = playback.track?.id, display.canReveal(id) { display.onReveal?(id) } }
    @objc private func previousActivity() { activities.cycle(-1) }
    @objc private func followingActivity() { activities.cycle(1) }
    @objc private func cancelActivity() {
        guard let activity = activities.list.selected else { return }
        if activity.state != .running { activities.dismiss(activity.id); return }
        if activity.kind == .sync {
            let alert = NSAlert(); alert.messageText = "Cancel iPod synchronization?"
            alert.addButton(withTitle: "Keep Synchronizing"); alert.addButton(withTitle: "Cancel Synchronization")
            guard let window else { return }
            alert.beginSheetModal(for: window) { result in if result == .alertSecondButtonReturn { Task { @MainActor in self.activities.cancel(activity.id) } } }
        } else { activities.cancel(activity.id) }
    }
    private func modeMenu() -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        for (index, value) in PlayerLCDMode.allCases.enumerated() {
            let item = NSMenuItem(title: value.rawValue.capitalized, action: #selector(pickMode(_:)), keyEquivalent: "")
            item.tag = index; item.target = self; item.state = display.mode == value ? .on : .off
            item.isEnabled = playback.track != nil; menu.addItem(item)
        }
        return menu
    }
    @objc private func pickMode(_ sender: NSMenuItem) { display.choose(PlayerLCDMode.allCases[sender.tag]) }
    @objc private func showTrackMenu() {
        let menu = NSMenu(); menu.autoenablesItems = false
        let show = NSMenuItem(title: "Show in Library", action: #selector(revealTrack), keyEquivalent: ""); show.target = self
        show.isEnabled = playback.track.map { display.canReveal($0.id) } ?? false
        menu.addItem(show)
        if let track = playback.track {
            let info = NSMenuItem(title: "Track Info…", action: #selector(showTrackInfo), keyEquivalent: "")
            info.target = self; info.isEnabled = show.isEnabled; menu.addItem(info)
            if let favorite = display.favoriteValue(track.id) {
                let item = NSMenuItem(title: favorite ? "Remove Favorite" : "Favorite", action: #selector(toggleFavorite), keyEquivalent: "")
                item.target = self; item.state = favorite ? .on : .off; menu.addItem(item)
            }
            if track.playbackKind != .music {
                let root = NSMenuItem(title: "Playback Speed", action: nil, keyEquivalent: ""), speeds = NSMenu()
                for speed in [0.75, 1.0, 1.25, 1.5, 2.0] {
                    let item = NSMenuItem(title: "\(speed)×", action: #selector(changeRate(_:)), keyEquivalent: "")
                    item.target = self; item.representedObject = speed; item.state = playback.rate == speed ? .on : .off; speeds.addItem(item)
                }
                root.submenu = speeds; menu.addItem(root)
            }
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: more.bounds.maxY), in: more)
    }
    @objc private func showTrackInfo() { if let track = playback.track { MetadataEditorController.shared.open(rows: [track], index: 0) } }
    @objc private func toggleFavorite() {
        guard let track = playback.track, let current = display.favoriteValue(track.id) else { return }
        display.onFavorite?(track.id, !current)
    }
    @objc private func changeRate(_ item: NSMenuItem) { if let value = item.representedObject as? Double { playback.setRate(value) } }

}

@MainActor private final class LCDModeButton: ToolbarPlaybackButton {
    override func hitTest(_ point: NSPoint) -> NSView? { alphaValue < 0.01 || !isEnabled ? nil : super.hitTest(point) }
    var makeMenu: () -> NSMenu = { NSMenu() }
    override func rightMouseDown(with event: NSEvent) { guard isEnabled else { return }; NSMenu.popUpContextMenu(makeMenu(), with: event, for: self) }
}

@MainActor private final class LCDArtworkButton: NSButton {
    var fillsArtwork = false { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        guard fillsArtwork else {
            NSColor.labelColor.withAlphaComponent(0.075).setFill(); bounds.fill()
            NSGradient(starting: NSColor.white.withAlphaComponent(0.06), ending: NSColor.black.withAlphaComponent(0.08))?.draw(in: bounds, angle: -90)
            super.draw(dirtyRect); return
        }
        guard let image, image.size.width > 0, image.size.height > 0 else { return }
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: bounds).addClip()
        let scale = max(bounds.width / image.size.width, bounds.height / image.size.height)
        let rect = NSRect(x: (bounds.width - image.size.width * scale) / 2, y: (bounds.height - image.size.height * scale) / 2,
                          width: image.size.width * scale, height: image.size.height * scale)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

@MainActor private final class LCDMarquee: NSView {
    private let label = NSTextField(labelWithString: "")
    private var pendingScroll = false
    var onClick: () -> Void = {}
    override func mouseDown(with event: NSEvent) { onClick() }
    var canAnimate = false { didSet { if !canAnimate { stop() } } }
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true; layer?.masksToBounds = true
        label.font = .systemFont(ofSize: 12, weight: .medium); label.alignment = .center
        label.lineBreakMode = .byClipping; label.wantsLayer = true; addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError() }
    var naturalWidth: CGFloat { label.intrinsicContentSize.width }
    func setText(_ text: String) { guard label.stringValue != text else { return }; label.stringValue = text; stop(); pendingScroll = true; needsLayout = true }
    override func layout() {
        super.layout(); label.frame = NSRect(x: 0, y: 0, width: max(bounds.width, label.intrinsicContentSize.width), height: bounds.height)
        if pendingScroll && canAnimate { pendingScroll = false; scrollOnce() }
    }
    func stop() { label.layer?.removeAnimation(forKey: "marquee") }
    func scrollOnce() {
        guard canAnimate, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let overflow = label.frame.width - bounds.width
        guard overflow > 4 else { return }
        let animation = CABasicAnimation(keyPath: "transform.translation.x")
        animation.fromValue = 0; animation.toValue = -overflow
        animation.duration = min(12, max(3, Double(overflow) / 24)); animation.autoreverses = true
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        label.layer?.add(animation, forKey: "marquee")
    }
}

#endif
