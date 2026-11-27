#if canImport(AppKitBackend)
import AppKit
import SwiftCrossUI
import MediaKit

@MainActor final class PlayerLCDContent: NSView {
    private let playback = PlaybackController.shared
    private let display = PlayerDisplayController.shared
    private let activities = PlayerActivityController.shared
    private let title = LCDMarquee()
    private let subtitle = LCDMarquee(fontSize: 10, weight: .regular, color: .secondaryLabelColor)
    private let elapsed = PassiveLCDLabel(labelWithString: "")
    private let remaining = ToolbarPlaybackButton()
    private let mode = LCDModeButton()
    private let previousMode = LCDModeButton(), nextMode = LCDModeButton()
    private let reveal = ToolbarPlaybackButton()
    private let cover = LCDArtworkButton()
    private let more = ToolbarPlaybackButton()
    private let backActivity = ToolbarPlaybackButton()
    private let nextActivity = ToolbarPlaybackButton()
    private let cancel = ToolbarPlaybackButton()
    private let indicator = PassiveLCDLabel(labelWithString: "")
    private let plot = LCDPlaybackPlot()
    var isSpectrumAnimating: Bool { plot.isSpectrumAnimating }
    private let progressOverlay = LCDProgressOverlay()
    private let spinner = NSProgressIndicator()
    private let hoverTime = LCDHoverLabel(labelWithString: "")
    private var tokens: [NSObjectProtocol] = []
    private var displaySubscription: SwiftCrossUI.Cancellable?
    private var artworkTask: Task<Void, Never>?
    private var timeTrackID: String?
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
        remaining.textOnlyHover = true
        (remaining.cell as? NSButtonCell)?.highlightsBy = []
        remaining.alignment = .right
        remaining.title = ""
        remaining.isBordered = false; remaining.font = .monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        remaining.target = self; remaining.action = #selector(toggleTime)
        remaining.setAccessibilityLabel("Remaining or total time")
        cover.title = ""; cover.imagePosition = .imageOnly
        cover.isBordered = false; cover.imageScaling = .scaleNone
        cover.target = self; cover.action = #selector(revealTrack); cover.setAccessibilityLabel("Show playing track in library")
        elapsed.font = .monospacedDigitSystemFont(ofSize: 9, weight: .regular); elapsed.textColor = .secondaryLabelColor
        indicator.font = .systemFont(ofSize: 7); indicator.alignment = .center
        hoverTime.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        hoverTime.alignment = .center; hoverTime.drawsBackground = true
        hoverTime.backgroundColor = .controlBackgroundColor; hoverTime.wantsLayer = true; hoverTime.layer?.cornerRadius = 3
        hoverTime.layer?.masksToBounds = true; hoverTime.isHidden = true
        spinner.style = .spinning; spinner.controlSize = .mini; spinner.isDisplayedWhenStopped = false
        for view in [title, subtitle, plot, elapsed, remaining] { view.wantsLayer = true }
        for view in [title, subtitle, elapsed, remaining, mode, reveal, cover, plot, more, backActivity, nextActivity, cancel, indicator, spinner, hoverTime, progressOverlay] { addSubview(view) }
        addSubview(plot, positioned: .below, relativeTo: title)
        for view in [previousMode, nextMode] { addSubview(view) }
        addSubview(progressOverlay, positioned: .above, relativeTo: nil)
        plot.onPreview = { [weak self] value in self?.refresh(preview: value) }
        plot.onSpectrumReleaseFinished = { [weak self] in self?.refresh() }
        plot.onHover = { [weak self] value in
            guard let self else { return }
            let overTimeline = value != nil && (self.plot.isScrubbing || (self.plot.hoverPoint.y >= 0 && self.plot.hoverPoint.y <= 7))
            self.progressOverlay.setPointerX(overTimeline ? self.plot.hoverX : nil)
            self.hoverTime.isHidden = !overTimeline || self.activities.list.selected != nil || self.display.resolvedMode == .spectrum
            self.needsLayout = true
            self.hoverTime.stringValue = value.map { (self.plot.hoverChapter.map { $0 + " · " } ?? "") + self.time($0) } ?? ""
        }
        title.onClick = { [weak self] in
            guard self?.display.resolvedMode == .title else { return }; self?.revealTrack()
        }
        title.tracksClick = true
        displaySubscription = display.didChange.observe { [weak self] in self?.refresh() }
        for name in [NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification, NSWindow.willMiniaturizeNotification, NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, MacWindowLifecycle.visualActivationDidChange] {
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
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Keep the centered hover label outside the LCD's clipping mask so it
        // also stays centered over the handle at the two ends of the timeline.
        if window != nil, let header = superview?.superview { header.addSubview(hoverTime, positioned: .above, relativeTo: nil) }
        else { hoverTime.removeFromSuperview() }
        refresh(force: true); visibilityChanged()
    }
    private func visibilityChanged() {
        playback.setVisible(isDisplayVisible)
        display.setVisible(isDisplayVisible)
        if window?.isKeyWindow != true {
            hovered = false; hoverTime.isHidden = true; progressOverlay.setPointerX(nil)
        }
        if !isDisplayVisible { hoverTime.isHidden = true; setSpinning(false); title.stop(); subtitle.stop(); plot.suspendSpectrum() }
        else { refresh(); title.scrollOnce(); subtitle.scrollOnce() }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .inVisibleRect, .activeInKeyWindow], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; refresh() }
    override func mouseExited(with event: NSEvent) {
        hovered = false
        if !plot.isScrubbing {
            hoverTime.isHidden = true
            progressOverlay.setPointerX(nil)
        }
        refresh()
    }
    func refresh(preview: Double? = nil, force: Bool = false) {
        guard (force || isDisplayVisible || capturesHiddenWindow), !rendering else { return }
        rendering = true; defer { rendering = false }
        let hoverChanged = hovered != renderedHover
        renderedHover = hovered
        let track = playback.track
        let activity = activities.list.selected
        let effective = display.resolvedMode
        let position = preview ?? plot.scrub.proposed ?? playback.position
        var input = PlayerLCDPresentation.Input()
        input.track = track.map {
            PlayerLCDPresentation.Track(id: $0.id, title: $0.title, artist: $0.artist, album: $0.album, path: $0.path ?? "",
                                        playbackTitle: $0.playbackTitle, playbackSubtitle: $0.playbackSubtitle)
        }
        input.playing = playback.playing; input.error = playback.error
        input.position = position; input.duration = playback.duration; input.rate = playback.rate
        input.mode = display.mode; input.effectiveMode = effective
        input.lyrics = display.lyrics; input.lyricIndex = display.lyricIndex
        input.showsRemaining = display.showsRemaining; input.idleDetail = display.idleDetail
        input.activity = activity; input.activityCount = activities.list.items.count
        input.hovered = hovered
        let shown = PlayerLCDPresentation(input)
        let presentationChanged = shown.contentKey != lastPresentation
        if presentationChanged {
            // Crossfade content only. The shared placeholder, clock and glass
            // remain stable when moving between tracks with identical artwork.
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                for view in [title, subtitle] {
                    let fade = CATransition(); fade.type = .fade; fade.duration = 0.16
                    view.layer?.add(fade, forKey: "trackContent")
                }
            }
            lastPresentation = shown.contentKey
        }
        mode.isEnabled = track != nil
        mode.isHidden = true
        for view in [previousMode, nextMode] {
            fade(view, to: hovered && shown.canChangeView ? 1 : 0, animated: hoverChanged)
            view.isEnabled = shown.canChangeView
        }
        mode.setSymbol(shown.modeSymbol, size: 10)
        mode.toolTip = shown.modeToolTip
        let available = shown.available
        cover.isHidden = shown.coverHidden
        reveal.isHidden = true
        reveal.isEnabled = track.map { display.canReveal($0.id) } ?? false
        cover.isEnabled = reveal.isEnabled
        more.isHidden = shown.moreHidden
        more.isEnabled = !shown.moreHidden
        elapsed.isHidden = shown.timeHidden
        remaining.isHidden = shown.timeHidden
        setSpinning(shown.spinning)
        for view in [backActivity, nextActivity, cancel, indicator] { view.isHidden = shown.activityControlsHidden }
        cancel.isHidden = shown.cancelHidden
        indicator.stringValue = shown.indicator
        if activity != nil { hoverTime.isHidden = true }
        title.setText(shown.titleText); subtitle.stringValue = shown.subtitleText
        title.isHidden = shown.titleHidden; subtitle.isHidden = shown.subtitleHidden
        plot.activity = activity
        if activity != nil {
            plot.needsDisplay = true
            cancel.isEnabled = shown.cancelEnabled
            cancel.setSymbol(shown.cancelSymbol, size: 10)
        }
        title.canAnimate = shown.textScrolls && isDisplayVisible
        let trackOpacity = CGFloat(shown.metadataOpacity)
        let spectrumOverlay = (available || plot.isReleasingSpectrum) && effective == .spectrum
        let active = MacWindowLifecycle.shared.isWindowVisuallyActive(window)
        let metadataOpacity: CGFloat = spectrumOverlay ? 0 : trackOpacity * (active ? 1 : 0.45)
        fade(title, to: metadataOpacity, animated: hoverChanged && spectrumOverlay)
        fade(subtitle, to: metadataOpacity, animated: hoverChanged && spectrumOverlay)
        fade(more, to: shown.moreVisible ? 1 : 0, animated: hoverChanged)
        if playback.duration > 0 || elapsed.stringValue.isEmpty || track == nil {
            let nextElapsed = shown.elapsedText
            let nextRemaining = shown.remainingText
            if timeTrackID != track?.id, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                for view in [elapsed, remaining] {
                    let fade = CATransition(); fade.type = .fade; fade.duration = 0.18
                    view.layer?.add(fade, forKey: "timeContent")
                }
            }
            elapsed.stringValue = nextElapsed; remaining.title = nextRemaining
            timeTrackID = track?.id
        }
        elapsed.alphaValue = 1; remaining.alphaValue = 1
        elapsed.textColor = active ? .secondaryLabelColor : NSColor.labelColor.withAlphaComponent(0.3)
        remaining.refreshTextTint()
        subtitle.canAnimate = title.canAnimate
        fade(plot, to: 1, animated: false)
        plot.update(trackID: track?.id, position: position, duration: playback.duration, mode: effective, samples: playback.samples, chapters: display.chapters)
        let showReleasingSpectrum = !available && activity == nil && playback.error.isEmpty && plot.isReleasingSpectrum
        plot.isHidden = !available && !showReleasingSpectrum
        if effective == .spectrum { hoverTime.isHidden = true }
        progressOverlay.isHidden = !available && activity == nil
        progressOverlay.update(position: position, duration: playback.duration, activity: activity, proposed: plot.scrub.proposed, chapters: display.chapters, playing: playback.playing && activity == nil)
        if trackID != track?.id {
            trackID = track?.id; artworkTask?.cancel()
            if let key = track?.artworkKey, let folder = PlayerArtwork.folder {
                if cover.displayedArtworkKey != key {
                    let id = track?.id
                    artworkTask = Task { [weak self] in
                        let image = await ThumbnailStore.shared.image(folder.appendingPathComponent(key + ".jpg"), pixels: 128)
                        guard !Task.isCancelled, self?.trackID == id else { return }
                        self?.cover.showArtwork(image, key: key)
                    }
                }
            } else { cover.showArtwork(nil, key: nil) }

        }
        setAccessibilityValue(shown.accessibilityValue)
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
            animation.duration = hovered ? 0.13 : 0.16
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
        previousMode.frame = NSRect(x: width - 16, y: height - 18, width: 16, height: 16)
        nextMode.frame = NSRect(x: width - 16, y: 4, width: 16, height: 16)
        let left = artEdge + 6, right: CGFloat = 19
        let availableWidth = max(0, width - left - right)
        let titleWidth = min(max(0, availableWidth - 40), title.naturalWidth)
        let start = left + (availableWidth - titleWidth) / 2
        title.frame = NSRect(x: start, y: height - 19, width: titleWidth, height: 15)
        // Long secondary metadata shares the lower row with the clocks: keep
        // its scrolling viewport between them so glyphs can never overlap.
        let clockClearance: CGFloat = playback.rate == 1 ? 60 : 90
        subtitle.frame = NSRect(x: left + clockClearance, y: height - 31,
                                width: max(0, availableWidth - clockClearance - 60), height: 12)
        if playback.track == nil && activities.list.selected == nil { title.frame.origin.y = 14 }
        elapsed.frame = NSRect(x: left, y: 4, width: playback.rate == 1 ? 54 : 84, height: 12)
        remaining.frame = NSRect(x: width - right - 54, y: 3, width: 54, height: 14)
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
        let tooltipWidth = min(160, max(38, hoverTime.intrinsicContentSize.width + 10))
        let handle = convert(progressOverlay.hoverHandleRect, from: progressOverlay)
        // Match the 3 pt bottom clearance of the LCD inside the toolbar.
        let tooltip = NSRect(x: handle.midX - tooltipWidth / 2, y: handle.maxY + 3, width: tooltipWidth, height: 15)
        hoverTime.frame = convert(tooltip, to: hoverTime.superview)

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

    func checkInactiveAppearance() {
        guard let window, !window.isKeyWindow else { preconditionFailure("Inactive appearance requires a background window") }
        let oldMode = display.mode
        display.choose(.title); refresh(force: true)
        precondition(abs(title.alphaValue - 0.45) < 0.001 && abs(subtitle.alphaValue - 0.45) < 0.001)
        precondition(abs((elapsed.textColor?.alphaComponent ?? 1) - 0.3) < 0.001)
        let tint = remaining.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        precondition(abs((tint?.alphaComponent ?? 1) - 0.3) < 0.001)
        func checkSidebar(_ view: NSView) {
            if let cell = view as? Sidebar.SidebarCell {
                if let text = cell.textField { precondition(abs(text.alphaValue - 0.45) < 0.001) }
                if let header = cell.headerLabel { precondition(abs(header.alphaValue - 0.45) < 0.001) }
            }
            view.subviews.forEach(checkSidebar)
        }
        if let root = window.contentView { checkSidebar(root) }
        findVolumeSlider(in: window.contentView?.superview ?? window.contentView)?.checkInactiveFill()
        display.choose(oldMode); refresh(force: true)
        log("PASS: inactive LCD metadata, both clocks and sidebar headings share restrained emphasis")
    }

    func checkComposition() {
        LCDArtworkButton.checkTransitions(in: self, behind: cover)
        guard playback.track != nil, activities.list.selected == nil else { return }
        func snapshot(_ name: String) {
            guard let root = name == "timeline-hover" ? hoverTime.superview : superview, let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return }
            root.cacheDisplay(in: root.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/plr-composition-" + name + ".png"))
        }
        let previousMode = display.mode, previousHover = hovered
        defer { hovered = previousHover; display.choose(previousMode); refresh(force: true) }
        display.choose(.title); refresh(force: true); layoutSubtreeIfNeeded()
        precondition(cover.frame == NSRect(x: 0, y: 0, width: bounds.height, height: bounds.height))
        precondition(progressOverlay.frame.minX == cover.frame.maxX && progressOverlay.frame.maxX == bounds.maxX)
        precondition(!more.isHidden && more.usesAccentTint && more.frame.minX == title.frame.maxX + 2)
        precondition(abs(title.frame.midX - (cover.frame.maxX + 6 + bounds.width - 19) / 2) < 0.1, "Title centering does not include the actions button")
        precondition(layer?.animation(forKey: kCATransition) == nil, "Track transitions must never fade the whole LCD")
        precondition(elapsed.alphaValue == 1 && remaining.alphaValue == 1)
        precondition(remaining.textOnlyHover, "The remaining time uses glyph feedback without a hover plate")
        title.checkLoop(); subtitle.checkLoop()
        snapshot("title")
        hovered = true; refresh(force: true); layoutSubtreeIfNeeded()
        precondition(more.alphaValue == 1)
        snapshot("title-hover")
        progressOverlay.setPointerX(progressOverlay.bounds.width - 2)
        hoverTime.stringValue = "1:59"; hoverTime.isHidden = false
        needsLayout = true; layoutSubtreeIfNeeded()
        let label = convert(hoverTime.frame, from: hoverTime.superview)
        let handle = convert(progressOverlay.hoverHandleRect, from: progressOverlay)
        precondition(abs(label.midX - handle.midX) < 0.01, "Hover time stays centered on the pointer, including at the edge")
        snapshot("timeline-hover")
        progressOverlay.setPointerX(nil); hoverTime.isHidden = true
        display.choose(.spectrum); hovered = true; refresh(force: true); layoutSubtreeIfNeeded()
        precondition(more.isHidden && title.isHidden && subtitle.isHidden && plot.alphaValue == 1, "Spectrum hover must preserve the visualization")
        snapshot("spectrum-hover")
        precondition(self.previousMode.alphaValue == 1 && nextMode.alphaValue == 1 && self.previousMode.isEnabled)
        previousLCDMode(); nextLCDMode()
        precondition(display.mode == .spectrum, "LCD chevrons cycle both ways")
        hovered = false; refresh(force: true)
        precondition(more.alphaValue == 0 && title.alphaValue == 0 && !more.isEnabled)
        precondition(self.previousMode.frame.minX == bounds.width - 16)
        precondition(subviews.firstIndex(of: progressOverlay)! > subviews.firstIndex(of: nextMode)!)
        display.choose(.waveform); refresh(force: true); layoutSubtreeIfNeeded(); snapshot("waveform")
        log("PASS: right-side LCD controls below timeline; spectrum hover preserves bars; artwork and accent title actions")
    }

    private func findVolumeSlider(in view: NSView?) -> PlayerVolumeSlider? {
        guard let view else { return nil }
        if let slider = view as? PlayerVolumeSlider { return slider }
        for child in view.subviews { if let found = findVolumeSlider(in: child) { return found } }
        return nil
    }
    private func time(_ value: Double) -> String { PlayerLCDPresentation.time(value) }
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
    override func hitTest(_ point: NSPoint) -> NSView? { alphaValue < 0.99 || !isEnabled ? nil : super.hitTest(point) }
    var makeMenu: () -> NSMenu = { NSMenu() }
    override func rightMouseDown(with event: NSEvent) { guard isEnabled else { return }; NSMenu.popUpContextMenu(makeMenu(), with: event, for: self) }
}

@MainActor private final class LCDHoverLabel: NSView {
    private let label = NSTextField(labelWithString: "")
    var font: NSFont? { get { label.font } set { label.font = newValue; needsLayout = true } }
    var alignment: NSTextAlignment { get { label.alignment } set { label.alignment = newValue } }
    var drawsBackground = true { didSet { needsDisplay = true } }
    var backgroundColor: NSColor? { didSet { layer?.backgroundColor = backgroundColor?.cgColor } }
    var stringValue: String {
        get { label.stringValue }
        set { guard label.stringValue != newValue else { return }; label.stringValue = newValue; needsLayout = true }
    }
    override var intrinsicContentSize: NSSize { label.intrinsicContentSize }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        label.lineBreakMode = .byTruncatingMiddle
        label.usesSingleLineMode = true
        addSubview(label)
    }
    convenience init(labelWithString string: String) {
        self.init(frame: .zero)
        stringValue = string
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() {
        super.layout()
        layer?.backgroundColor = backgroundColor?.cgColor
        let size = label.intrinsicContentSize
        let width = min(bounds.width - 4, size.width)
        let capOffset: CGFloat = -0.5
        label.frame = NSRect(x: (bounds.width - width) / 2,
                             y: (bounds.height - size.height) / 2 + capOffset,
                             width: max(0, width), height: size.height)
    }
}

@MainActor private final class PassiveLCDLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor private final class LCDArtworkPlaceholder: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor private final class LCDArtworkButton: NSButton {
    private(set) var displayedArtworkKey: String?
    func showArtwork(_ image: NSImage?, key: String?) {
        let identity = image == nil ? nil : key
        guard displayedArtworkKey != identity else { return }
        displayedArtworkKey = identity
        fillsArtwork = image != nil; self.image = image; needsDisplay = true
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let fade = CATransition(); fade.type = .fade; fade.duration = 0.20
            layer?.add(fade, forKey: kCATransition)
        }
    }
    static func checkTransitions(in host: NSView, behind cover: NSView) {
        let view = LCDArtworkButton(frame: NSRect(x: 0, y: 0, width: 41, height: 41))
        host.addSubview(view, positioned: .below, relativeTo: cover)
        defer { view.removeFromSuperview() }
        view.layoutSubtreeIfNeeded()
        precondition(view.layer != nil, "Artwork transitions require a live backing layer")
        let image = NSImage(size: NSSize(width: 2, height: 2), flipped: false) { rect in NSColor.red.setFill(); rect.fill(); return true }
        view.showArtwork(nil, key: nil)
        precondition(view.layer?.animation(forKey: kCATransition) == nil)
        view.showArtwork(image, key: "a")
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { precondition(view.layer?.animation(forKey: kCATransition) != nil) }
        view.layer?.removeAllAnimations(); view.showArtwork(image, key: "a")
        precondition(view.layer?.animation(forKey: kCATransition) == nil)
        view.showArtwork(image, key: "b")
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { precondition(view.layer?.animation(forKey: kCATransition) != nil) }
        view.showArtwork(nil, key: nil); view.layer?.removeAllAnimations(); view.showArtwork(nil, key: nil)
        precondition(view.layer?.animation(forKey: kCATransition) == nil && view.alphaValue == 1)
    }
    private let placeholder = LCDArtworkPlaceholder()
    var fillsArtwork = false { didSet { placeholder.isHidden = fillsArtwork; needsDisplay = true } }
    override func mouseDown(with event: NSEvent) {
        guard fillsArtwork, let window else {
            window?.performDrag(with: event)
            return
        }
        let downPoint = event.locationInWindow
        var dragged = false
        var releasedInside = false
        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: .greatestFiniteMagnitude, mode: .eventTracking) { [weak self] ev, stop in
            guard let self, let ev else { stop.pointee = true; return }
            if ev.type == .leftMouseDragged {
                let p = ev.locationInWindow
                if hypot(p.x - downPoint.x, p.y - downPoint.y) >= 3 {
                    dragged = true
                    stop.pointee = true
                }
            } else {
                releasedInside = self.bounds.contains(self.convert(ev.locationInWindow, from: nil))
                stop.pointee = true
            }
        }
        if dragged {
            window.performDrag(with: event)
        } else if releasedInside {
            sendAction(action, to: target)
        }
    }
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        placeholder.image = systemSymbol("music.note", pointSize: 16)
        placeholder.contentTintColor = .secondaryLabelColor
        placeholder.imageScaling = .scaleNone; placeholder.setAccessibilityHidden(true)
        addSubview(placeholder)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); placeholder.frame = bounds }
    override func draw(_ dirtyRect: NSRect) {
        guard fillsArtwork else {
            NSColor.labelColor.withAlphaComponent(0.075).setFill(); bounds.fill()
            NSGradient(starting: NSColor.white.withAlphaComponent(0.06), ending: NSColor.black.withAlphaComponent(0.08))?.draw(in: bounds, angle: -90)
            return
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

/// Two copies form a seamless leftward loop, with a short rest at the start.
/// Core Animation owns the loop; pause, occlusion and reduced motion remove it.
@MainActor private final class LCDMarquee: NSView {
    private let label = NSTextField(labelWithString: "")
    private let continuation = NSTextField(labelWithString: "")
    var onClick: () -> Void = {}
    var tracksClick = false
    var stringValue: String { get { label.stringValue } set { setText(newValue) } }
    var canAnimate = false {
        didSet { guard canAnimate != oldValue else { return }; if !canAnimate { stop() }; needsLayout = true }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        tracksClick && !stringValue.isEmpty ? super.hitTest(point) : nil
    }
    override func mouseDown(with event: NSEvent) {
        guard tracksClick, let window else {
            superview?.mouseDown(with: event)
            return
        }
        let downPoint = event.locationInWindow
        var dragged = false
        var releasedInside = false
        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: .greatestFiniteMagnitude, mode: .eventTracking) { [weak self] ev, stop in
            guard let self, let ev else { stop.pointee = true; return }
            if ev.type == .leftMouseDragged {
                let p = ev.locationInWindow
                if hypot(p.x - downPoint.x, p.y - downPoint.y) >= 3 {
                    dragged = true
                    stop.pointee = true
                }
            } else {
                releasedInside = self.bounds.contains(self.convert(ev.locationInWindow, from: nil))
                stop.pointee = true
            }
        }
        if dragged {
            window.performDrag(with: event)
        } else if releasedInside {
            onClick()
        }
    }
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true; layer?.masksToBounds = true
        for view in [label, continuation] {
            view.font = .systemFont(ofSize: 12, weight: .medium)
            view.lineBreakMode = .byClipping; view.wantsLayer = true; addSubview(view)
        }
        continuation.setAccessibilityHidden(true)
    }
    convenience init(fontSize: CGFloat, weight: NSFont.Weight, color: NSColor) {
        self.init(frame: .zero)
        for view in [label, continuation] { view.font = .systemFont(ofSize: fontSize, weight: weight); view.textColor = color }
    }
    required init?(coder: NSCoder) { fatalError() }
    var naturalWidth: CGFloat { label.intrinsicContentSize.width }
    func setText(_ text: String) {
        guard label.stringValue != text else { return }
        stop(); label.stringValue = text; continuation.stringValue = text; needsLayout = true
    }
    override func layout() {
        super.layout()
        let overflowing = naturalWidth > bounds.width + 4
        let width = max(bounds.width, naturalWidth)
        let oldFrame = label.frame
        label.alignment = overflowing ? .left : .center
        continuation.alignment = .left
        label.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        continuation.frame = NSRect(x: width + 32, y: 0, width: width, height: bounds.height)
        continuation.isHidden = !overflowing
        if oldFrame != label.frame { stop() }
        scrollOnce()
    }
    func checkLoop() {
        layoutSubtreeIfNeeded()
        guard naturalWidth > bounds.width + 4, canAnimate, window?.occlusionState.contains(.visible) == true, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        precondition(label.layer?.animation(forKey: "marquee")?.repeatCount == .infinity)
        precondition(continuation.layer?.animation(forKey: "marquee") != nil)
        canAnimate = false
        precondition(label.layer?.animation(forKey: "marquee") == nil && continuation.layer?.animation(forKey: "marquee") == nil)
        canAnimate = true; layoutSubtreeIfNeeded()
        precondition(label.layer?.animation(forKey: "marquee") != nil, "Resuming a visible long label restores its loop")
    }
    func stop() { for view in [label, continuation] { view.layer?.removeAnimation(forKey: "marquee") } }
    func scrollOnce() {
        guard canAnimate, !isHidden, window?.occlusionState.contains(.visible) == true, bounds.width > 0, naturalWidth > bounds.width + 4,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              label.layer?.animation(forKey: "marquee") == nil else { return }
        let distance = naturalWidth + 32
        let travel = Double(distance) / 20, rest = 2.4
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
        animation.values = [0, 0, -distance]
        animation.keyTimes = [0, NSNumber(value: rest / (rest + travel)), 1]
        animation.duration = rest + travel; animation.repeatCount = .infinity
        animation.calculationMode = .linear
        for view in [label, continuation] { view.layer?.add(animation, forKey: "marquee") }
    }
}

#endif
