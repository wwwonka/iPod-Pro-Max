#if canImport(AppKitBackend)
    import AppKit
    import AppKitBackend
    import Foundation
    import SwiftCrossUI
    import iPodKit

    /// macOS draws its own traffic lights; the player header belongs to the content.
    let drawsWindowControls = false

    extension View {
        /// - Parameter colorScheme: unused on macOS, where AppKit follows the system appearance.
        func windowChrome(colorScheme: Binding<ColorScheme>) -> some View {
            inspectWindow { MacChrome.shared.install(on: $0) }
        }
    }

    @MainActor func toggleSidebar() { MacChrome.shared.toggleSidebar() }
    @MainActor func performWindowAction(_ action: WindowAction) {}

    /// macOS draws its traffic lights itself.
    struct WindowControls: View {
        var body: some View { EmptyView() }
    }

    /// See WindowChrome.swift. Empty and as wide as the title's clearance.
    struct TitleClearance: NSViewRepresentable {
        func makeNSView(context: Context) -> NSView { NSView() }
        func updateNSView(_ view: NSView, context: Context) {}

        func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> ViewSize {
            ViewSize(titleClearance(sidebarWidth: MacChrome.shared.currentSidebarWidth), 0)
        }
    }

    /// Transparent window chrome with a stable player header over full-size content
    /// and the native sidebar split view.
    @MainActor
    final class MacChrome: NSObject, NSSearchFieldDelegate {
        static let shared = MacChrome()

        private weak var window: NSWindow?
        /// The window starts as a small square and grows when the launch is ready (`MacLaunchTransition`).
        /// `IPPM_NO_LAUNCH_PANEL=1` shows it at once, as before.
        static let launchPanelEnabled = ProcessInfo.processInfo.environment["IPPM_NO_LAUNCH_PANEL"] == nil
        /// Longest the launch may wait: a slow iPod must never keep the app from showing.
        private static let launchTimeout: UInt64 = 4_000_000_000
        private var launchIsReady = false
        private var launchTimeoutTask: Task<Void, Never>?
        private var revealedInitialWindow = false
        /// The sidebar's list view, registered when AppKit creates it.
        weak var sidebarAnchor: NSView?
        /// A marker inside the main view's content.
        weak var contentAnchor: NSView?
        /// The view holding the content, which the app moves when the sidebar opens or closes: the
        /// marker's wrapper, the content stack, then the padding around it.
        private var contentContainer: NSView? { contentAnchor?.superview?.superview?.superview }
        /// Tells the app whether the sidebar is open, so the content leaves it room.
        var onSidebarChange: ((Bool) -> Void)?
        /// Tells the app the sidebar's width while its edge is dragged.
        var onSidebarWidth: ((Int) -> Void)?
        private var sidebarOpen = true
        /// Preserve actions made while the portable settings are still loading.
        private var sidebarPreferencesRestored = false
        private var sidebarChangedBeforeRestore = false
        private var sidebarWidthBeforeRestore: Double?
        private var pendingSidebarWidth: Double?
        private var onPersistSidebarWidth: ((Double) -> Void)?
        /// Only one short-lived retry can be pending, even if multiple views update together.
        private var sidebarRetry: DispatchWorkItem?
        private weak var observedSidebarSplit: NSCustomSplitView?
        private var splitDelegateProxy: SidebarSplitDelegateProxy?
        private var sidebarFrameObserver: NSObjectProtocol?
        private var persistedSidebarWidth: CGFloat = CGFloat(sidebarWidth)
        var isSidebarVisible: Bool { sidebarOpen }
        var isSidebarAvailable: Bool { sidebarAvailable }
        /// The sidebar is SwiftCrossUI's own NSSplitView, which owns its geometry (IPPM_LEGACY_SPLIT=1 brings the old overlay back).
        static let nativeSplitMode = ProcessInfo.processInfo.environment["IPPM_LEGACY_SPLIT"] == nil
        private var benchStarted = false
        private func nativeSplit() -> NSCustomSplitView? {
            func find(_ view: NSView) -> NSCustomSplitView? {
                if let split = view as? NSCustomSplitView { return split }
                for sub in view.subviews { if let found = find(sub) { return found } }
                return nil
            }
            return window?.contentView.flatMap(find)
        }
        /// Open, and the page has a sidebar.
        private var sidebarShown: Bool { sidebarOpen && sidebarAvailable }
        private var slideRevision = 0
        private let queueButton = ToolbarPlaybackButton()
        private var queueToken: SwiftCrossUI.Cancellable?
        private let player = ToolbarPlayerMac()
        var canStartSelectionPlayback: Bool { player.canPlaySelection }
        func startSelectionPlayback() { player.toggle() }
        @objc private func showPlayerQueue() { PlayerQueuePopover.shared.toggle(from: queueButton) }
        func checkPlayerToolbarLayout() {
            guard let window else { preconditionFailure("Player layout check requires a window") }
            precondition(window.level == .normal, "Main window must remain a standard Mission Control window")
            let original = window.frame
            var measurements: [Double] = []
            for width in [820.0, 1000, 1240, 1600, 1240, 1000, 820, 1240] {
                let started = ProcessInfo.processInfo.systemUptime
                var frame = window.frame; frame.size.width = width
                window.setFrame(frame, display: false)
                player.updateWidth()
                window.contentView?.superview?.layoutSubtreeIfNeeded()
                player.updateWidth()
                window.contentView?.superview?.layoutSubtreeIfNeeded()
                relayoutTitleArea?()
                layoutPlayerHeader()
                if let root = window.contentView?.superview, let close = window.standardWindowButton(.closeButton) {
                    let y = close.convert(NSPoint(x: close.bounds.midX, y: close.bounds.midY), to: root).y
                    for (index, type) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
                        guard let button = window.standardWindowButton(type) else { preconditionFailure("Native window control missing") }
                        let center = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: root)
                        precondition(abs(center.x - (20 + CGFloat(index) * 18)) <= 0.5 && abs(root.bounds.height - center.y - 22) <= 0.5, "Traffic lights retain the reference offsets")
                    }
                    let controls: [NSView] = player.transport.subviews + player.volumeView.subviews + [queueButton]
                    for control in controls where !control.isHidden && control.window != nil {
                        let actual = control.convert(NSPoint(x: control.bounds.midX, y: control.bounds.midY), to: root).y
                        precondition(abs(actual - y) <= 0.5, "Toolbar control must align with traffic lights: \(control), \(actual) vs \(y), parent frame \(String(describing: control.superview?.frame)), bounds \(String(describing: control.superview?.bounds)), control \(control.frame)")
                    }
                }
                if let root = window.contentView?.superview {
                    let lcdRect = player.lcd.convert(player.lcd.bounds, to: root)
                    let leftGap = player.nextToVolumeGap(in: root)
                    let reference = player.trafficToBackGap(in: root)
                    log(String(format: "Toolbar spacing %.0f pt: next/volume %.2f, traffic lights/back %.2f", width, leftGap, reference))
                    precondition(abs(leftGap - reference) <= 1, "Next/volume margin must match traffic lights/back: volume=\(player.volumeView.frame), children=\(player.volumeView.subviews.map { $0.frame }), LCD=\(player.lcd.frame)")
                }
                precondition(player.route.bounds.size == NSSize(width: 39, height: 26) && abs(player.route.frame.maxX + 8 - player.lcd.frame.minX) < 0.1, "AirPlay mirrors Queue outside the LCD")
                precondition(window.toolbar == nil && player.lcd.window === window, "Player stays in the content window without NSToolbar")
                if let root = window.contentView?.superview {
                    for control in player.transport.subviews + [queueButton] {
                        let point = control.convert(NSPoint(x: control.bounds.midX, y: control.bounds.midY), to: root)
                        let hit = root.hitTest(point)
                        precondition(hit === control || hit?.isDescendant(of: control) == true, "Native title area must not intercept player clicks: \(String(describing: hit))")
                    }
                }
                measurements.append((ProcessInfo.processInfo.systemUptime - started) * 1000)
                precondition(abs(player.transportLeadingSpace - min(8, max(0, (width - 900) / 340 * 8))) < 0.1)
                precondition(queueButton.bounds.size == NSSize(width: 39, height: 26), "Queue matches native toolbar plate")
                precondition(abs(player.lcd.frame.maxY - (player.lcd.superview?.bounds.height ?? 0)) < 0.5, "LCD stays anchored at the top")
                precondition(player.lcd.frame.width >= 280 && player.lcd.frame.width <= 460)
                precondition(abs(player.lcd.frame.minY - 3) < 0.5, "LCD must retain its bottom clearance")
            }
            window.setFrame(original, display: false); player.updateWidth(); layoutPlayerHeader()
            player.checkVolumeSlider()
            player.setFullScreenLayout(true)
            precondition(playerUsesFullScreenSpacing, "Full screen removes the window-button clearance")
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                precondition(player.transport.layer?.animation(forKey: "fullScreenSpacing")?.duration == 0.25, "Spacing uses a bounded native animation")
            }
            player.setFullScreenLayout(false)
            precondition(player.transport.frame.minX == 74 && !player.fullScreenLayout, "Leaving full screen restores window-button clearance")
            log("PASS: playback clearance animates in/out over 250 ms and restores its windowed position")
            measurements.sort()
            log(String(format: "PASS: toolbar resize 820–1600 pt, LCD bounds; synchronous layout median %.2f ms, max %.2f ms", measurements[measurements.count / 2], measurements.last ?? 0))
        }
        func checkPlayerHeaderSearch() async -> Bool {
            guard let window else { return false }
            let savedFrame = window.frame, savedOwner = searchOwner, savedText = searchField.stringValue
            let savedPrompt = searchField.placeholderString, savedChange = onSearchChange, savedExpanded = searchExpanded
            let savedResponder = window.firstResponder
            defer {
                searchOwner = savedOwner; onSearchChange = savedChange
                searchField.stringValue = savedText; searchField.placeholderString = savedPrompt
                searchExpanded = savedExpanded; window.setFrame(savedFrame, display: false)
                updateSearchVisibility(); layoutPlayerHeader(); window.makeFirstResponder(savedResponder)
            }
            let owner = NSObject()
            var query = ""
            setSearch(owner: owner, visible: true, prompt: "Search", text: "check", onChange: { query = $0 })
            var frame = window.frame; frame.size.width = 820; window.setFrame(frame, display: false)
            updateSearchVisibility(); layoutPlayerHeader()
            guard searchField.isHidden && !searchButton.isHidden else { return false }
            searchButton.performClick(nil)
            await Task.yield()
            guard !searchField.isHidden && searchButton.isHidden && searchField.currentEditor() != nil else { return false }
            searchField.stringValue = "new query"
            controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: searchField))
            log("[search check] focused=\(searchField.editing), editor=\(searchField.currentEditor() != nil), queryDelivered=\(query == "new query")")
            guard query == "new query" && searchField.editing else { return false }
            log("[search check] appearance field=\(searchField.effectiveAppearance.name.rawValue), editor=\(String(describing: (searchField.currentEditor() as? NSView)?.effectiveAppearance.name.rawValue))")
            if let root = searchField.superview, let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
                let savedAppearance = NSAppearance.current
                NSAppearance.current = root.effectiveAppearance
                root.cacheDisplay(in: root.bounds, to: bitmap)
                NSAppearance.current = savedAppearance
                try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/plr-search-focused-header.png"))
            }
            if let editor = searchField.currentEditor() as? NSTextView {
                editor.string = String(repeating: "long search query ", count: 30)
                editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
                searchField.revealCaret()
                log("[search check] long query visible=\(editor.visibleRect), bounds=\(editor.bounds), selected=\(editor.selectedRange())")
                guard editor.visibleRect.maxX > 170 else { return false }
                let handled = self.control(searchField, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
                log("[search check] escape handled=\(handled), editor=\(searchField.currentEditor() != nil), focused=\(searchField.editing)")
                guard handled && searchField.currentEditor() == nil && !searchField.editing else { return false }
            } else { return false }
            window.makeFirstResponder(searchField); searchField.selectText(nil); searchField.setEditing(true)
            guard let outside = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 10, y: 10), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1) else { return false }
            guard handleSearchPointerDown(outside) === outside && searchField.currentEditor() == nil && !searchField.editing else { return false }
            searchField.stringValue = ""
            controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: searchField))
            guard searchField.isHidden && !searchButton.isHidden else { return false }
            setSearch(owner: owner, visible: false, prompt: "Search", text: "", onChange: { _ in })
            guard searchField.isHidden && searchButton.isHidden else { return false }
            log("PASS: search focuses with scale, scrolls its long query to the caret, defocuses on Escape/outside clicks and releases page ownership")
            return true
        }
        func setPlaybackSelection(rows: [TrackRow], selectedIDs: [String], onStart: @escaping (TrackRow, [TrackRow]) -> Void) {
            player.onStart = onStart
            player.selectionRows = rows
            player.selectedIDs = selectedIDs
        }

        var isSliding: Bool { false }
        var isLiveResizing: Bool { window?.inLiveResize == true }
        /// The sidebar's rows always fill their panel: nothing is pinned during the slide.
        var pinnedSidebarContentWidth: Double? {
            isAnimatingSidebar ? Double(persistedSidebarWidth) : nil
        }
        /// What already lies left of the main view, for the title's clearance.
        var currentSidebarWidth: Double { mediaRailWidth }

        func install(on window: NSWindow) {
            guard self.window !== window else { return }
            self.window = window
            if Self.launchPanelEnabled {
                window.alphaValue = 0
                // Ready before the window existed: reveal once its chrome and content are laid out.
                if launchIsReady { DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.revealWhenReady() } } }
            }
            MacWindowLifecycle.shared.beforeTerminate = { try await ApplicationLifecycle.shared.prepareForExit() }
            MacWindowLifecycle.shared.onTerminationError = { ApplicationLifecycle.shared.report($0) }
            MacWindowLifecycle.shared.afterHide = {
                Task {
                    do { try await ApplicationLifecycle.shared.savePreferences() }
                    catch { ApplicationLifecycle.shared.report(error) }
                }
            }
            MacWindowLifecycle.shared.install(on: window)
            // The portable app does not persist window state in the host's defaults.
            _ = window.setFrameAutosaveName("")
            window.isRestorable = false
            if let theme = ProcessInfo.processInfo.environment["IPPM_QA_APPEARANCE"] {
                let appearance = NSAppearance(named: theme == "light" ? .aqua : .darkAqua)
                NSApp.appearance = appearance; window.appearance = appearance
            }
            window.styleMask.insert(.fullSizeContentView)
            // Full-screen eligibility must survive the titlebar-free full-screen style.
            window.collectionBehavior.insert(.fullScreenPrimary)
            if let nativeWindow = window as? NSCustomWindow {
                nativeWindow.acceptsKeyWithoutTitle = true
            }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            // Glass all over: the window paints nothing itself, its effect views do.
            window.isOpaque = false
            window.backgroundColor = .clear
            installWindowGlass(on: window)
            // Controls belong to the content, never to AppKit's sliding full-screen toolbar.
            window.toolbar = nil
            installPlayerHeader(in: window)
            installFindMenuItem()
            installFindShortcut(window)
            observeWindowWidthForSearch(window)
            shapeAreaWhenReady()
            keepTrafficLightsCentered(in: window)
            snapshotIfRequested(window)
            if Self.launchPanelEnabled { MacLaunchTransition.shared.prepare(window) }
            // Foreground requests must retain an ordinary Mission Control window.
            // Floating is reserved for explicit screenshot runs.
            window.level = .normal
            if ProcessInfo.processInfo.environment["IPPM_FRONT"] != nil {
                if ProcessInfo.processInfo.environment["IPPM_SNAPSHOT"] != nil {
                    window.level = .floating
                    window.setFrameOrigin(NSPoint(x: 120, y: 120))
                }
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                // `IPPM_FRONT=inactive`: a second window takes the key, so this one is shown inactive.
                if ProcessInfo.processInfo.environment["IPPM_FRONT"] == "inactive" {
                    let other = NSWindow(contentRect: NSRect(x: 1400, y: 120, width: 160, height: 120),
                                         styleMask: [.titled], backing: .buffered, defer: false)
                    other.level = .floating
                    other.makeKeyAndOrderFront(nil)
                }
            }
        }

        /// Arms the launch: waits for the app to be ready, with a time limit. Called first thing at launch.
        func beginLaunch() {
            guard Self.launchPanelEnabled else { return }
            LaunchReadiness.shared.onReady = { [weak self] in self?.launchReady() }
            launchTimeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: Self.launchTimeout)
                guard !Task.isCancelled else { return }
                self?.launchReady()
            }
        }

        /// Everything the first page shows is loaded (or the time limit passed).
        private func launchReady() {
            launchIsReady = true
            launchTimeoutTask?.cancel()
            launchTimeoutTask = nil
            revealWhenReady()
        }

        private func revealWhenReady() {
            guard launchIsReady, let window, !revealedInitialWindow else { return }
            revealedInitialWindow = true
            MacLaunchTransition.shared.expand(window)
        }

        /// The first of the two glass panels: the whole window, under everything. The sidebar's own
        /// panel sits over it and the (opaque) main view over both.
        private let windowGlass = NSVisualEffectView()
        private func installWindowGlass(on window: NSWindow) {
            windowGlass.material = .underWindowBackground
            windowGlass.blendingMode = .behindWindow
            windowGlass.state = .active
            windowGlass.identifier = NSUserInterfaceItemIdentifier("windowGlass")
            windowGlass.autoresizingMask = [.width, .height]
            attachWindowGlass()
        }
        private func attachWindowGlass() {
            guard let content = window?.contentView else { return }
            if windowGlass.superview !== content {
                windowGlass.removeFromSuperview()
                windowGlass.frame = content.bounds
                content.addSubview(windowGlass, positioned: .below, relativeTo: nil)
            }
        }

        // MARK: Traffic lights

        private var trafficLightObservers: [NSObjectProtocol] = []
        private var nativeButtonFrameObservers: [NSObjectProtocol] = []
        private var observedNativeButtonViews: [NSView] = []
        private var hostedTrafficLights: [NSButton] = []
        private var hidingTrafficLights = false
        private var nativeTitlebarRevealed = false
        private var holdingTrafficLightReveal = false
        private var trafficLightArea: NSTrackingArea?
        var revealedFullScreenZoomButton: NSButton? { hostedTrafficLights.count == 3 ? hostedTrafficLights[2] : nil }
        var fullScreenTrafficLightsVisible: Bool { player.fullScreenLayout && !hidingTrafficLights && hostedTrafficLights.count == 3 && hostedTrafficLights.allSatisfy { !$0.isHidden } }
        private func updateFullScreenTrafficLights() {
            guard player.fullScreenLayout else { return }
            let visible = nativeTitlebarRevealed || holdingTrafficLightReveal
            hidingTrafficLights = !visible
            player.setTrafficLightsRevealed(visible)
            relayoutTitleArea?()
        }
        @objc func mouseEntered(with event: NSEvent) {
            holdingTrafficLightReveal = player.fullScreenLayout && !hidingTrafficLights
            updateFullScreenTrafficLights()
        }
        @objc func mouseExited(with event: NSEvent) { holdingTrafficLightReveal = false; updateFullScreenTrafficLights() }
        private(set) var exitButtonLayoutSamples = 0
        private(set) var exitButtonClippedSamples = 0
        var playerUsesFullScreenSpacing: Bool { player.fullScreenLayout && player.transportLeadingSpace == 0 && player.transport.frame.minX == (player.trafficLightsRevealed ? 82 : CGFloat(mediaRailWidth) + 12) }
        private func observeNativeButtonFrames(_ views: [NSView], onChange: @escaping () -> Void) {
            guard views.map(ObjectIdentifier.init) != observedNativeButtonViews.map(ObjectIdentifier.init) else { return }
            nativeButtonFrameObservers.forEach(NotificationCenter.default.removeObserver)
            nativeButtonFrameObservers.removeAll(); observedNativeButtonViews = views
            for view in views {
                view.postsFrameChangedNotifications = true
                nativeButtonFrameObservers.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: view, queue: .main) { _ in
                    MainActor.assumeIsolated { onChange() }
                })
            }
        }
        private var titlebarSuppressionObservations: [NSKeyValueObservation] = []
        private var suppressedTitlebar: (host: NSWindow, content: NSView, hidden: Bool, opaque: Bool, color: NSColor, ignoresMouse: Bool)?
        private func suppressFullScreenTitlebar(_ container: NSView?, in primary: NSWindow) {
            guard suppressedTitlebar == nil else { return }
            // AppKit may clone the titlebar during the style transition; the original
            // buttons then no longer lead to the reveal host. Restrict the fallback
            // to this process's native titlebar on the primary window's screen.
            let originalHost = container?.window
            let host = originalHost !== primary && originalHost != nil ? originalHost : NSApp.windows.first {
                String(describing: type(of: $0)) == "NSToolbarFullScreenWindow" && $0.screen === primary.screen && abs($0.frame.width - primary.frame.width) < 2
            }
            guard let host, host !== primary, let content = host.contentView else { return }
            // AppKit retains this host for menu-bar hover even without NSToolbar.
            // Its resting alpha is irrelevant: keep the host transparent and non-interactive
            // even when AppKit animates it to alpha 1 during reveal.
            suppressedTitlebar = (host, content, content.isHidden, host.isOpaque, host.backgroundColor, host.ignoresMouseEvents)
            titlebarSuppressionObservations = [
                content.observe(\.isHidden, options: [.new]) { [weak self] view, _ in
                    MainActor.assumeIsolated { if self?.suppressedTitlebar != nil && !view.isHidden { view.isHidden = true } }
                },
                host.observe(\.alphaValue, options: [.new]) { [weak self] window, _ in
                    MainActor.assumeIsolated {
                        self?.nativeTitlebarRevealed = window.alphaValue > 0.05
                        self?.updateFullScreenTrafficLights()
                    }
                },
                host.observe(\.ignoresMouseEvents, options: [.new]) { [weak self] window, _ in
                    MainActor.assumeIsolated { if self?.suppressedTitlebar != nil && !window.ignoresMouseEvents { window.ignoresMouseEvents = true } }
                }
            ]
            nativeTitlebarRevealed = host.alphaValue > 0.05
            content.isHidden = true
            host.isOpaque = false; host.backgroundColor = .clear; host.ignoresMouseEvents = true
        }
        private func restoreFullScreenTitlebar() {
            guard let saved = suppressedTitlebar else { return }
            suppressedTitlebar = nil
            if window?.styleMask.contains(.fullScreen) != true { saved.host.orderOut(nil) }
            titlebarSuppressionObservations.removeAll()
            saved.content.isHidden = saved.hidden
            saved.host.isOpaque = saved.opaque; saved.host.backgroundColor = saved.color
            saved.host.ignoresMouseEvents = saved.ignoresMouse
        }
        /// Relayout after search visibility changes and native title-area events.
        private var relayoutTitleArea: (() -> Void)?
        private func scheduleTitleAreaRelayout() {
            DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.relayoutTitleArea?() } }
        }

        /// Keep actual AppKit window buttons in the same stable row as playback.
        /// Native titlebar containers are resized/replaced during full-screen transitions;
        /// the content header has its final height from the first animation frame.
        private func keepTrafficLightsCentered(in window: NSWindow) {
            let originalContainer = window.standardWindowButton(.closeButton)?.superview?.superview
            var centering = false
            var exitingFullScreen = false
            func center() {
                guard !centering else { return }; centering = true; defer { centering = false }
                guard let header = self.playerHeader else { return }
                let native = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window.standardWindowButton($0) }
                if !native.isEmpty && native.map(ObjectIdentifier.init) != self.hostedTrafficLights.map(ObjectIdentifier.init) {
                    self.hostedTrafficLights.forEach { if $0.superview === header { $0.removeFromSuperview() } }
                    self.hostedTrafficLights = native
                }
                self.observeNativeButtonFrames(self.hostedTrafficLights, onChange: center)
                for (index, button) in self.hostedTrafficLights.enumerated() {
                    if button.superview !== header { button.removeFromSuperview(); header.addSubview(button) }
                    button.autoresizingMask = []
                    button.isHidden = self.hidingTrafficLights
                    button.setFrameOrigin(NSPoint(x: 20 + CGFloat(index) * 18 - button.bounds.width / 2,
                                                  y: header.bounds.height - 22 - button.bounds.height / 2))
                    if exitingFullScreen && !button.isHiddenOrHasHiddenAncestor {
                        self.exitButtonLayoutSamples += 1
                        if button.visibleRect.height < button.bounds.height - 0.5 { self.exitButtonClippedSamples += 1 }
                    }
                }
                self.layoutPlayerHeader()
            }
            trafficLightObservers.append(NotificationCenter.default.addObserver(forName: NSWindow.willEnterFullScreenNotification, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { self.hidingTrafficLights = true; self.nativeTitlebarRevealed = false; self.holdingTrafficLightReveal = false; center() }
            })
            trafficLightObservers.append(NotificationCenter.default.addObserver(forName: NSWindow.willExitFullScreenNotification, object: window, queue: .main) { _ in
                MainActor.assumeIsolated {
                    exitingFullScreen = true; self.hidingTrafficLights = false; self.holdingTrafficLightReveal = false
                    self.exitButtonLayoutSamples = 0; self.exitButtonClippedSamples = 0
                    self.player.setFullScreenLayout(false)
                    center()
                }
            })
            for name in [NSWindow.didResizeNotification, NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification, NSWindow.didBecomeKeyNotification] {
                trafficLightObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { _ in
                    MainActor.assumeIsolated {
                        if name == NSWindow.didEnterFullScreenNotification {
                            self.suppressFullScreenTitlebar(originalContainer, in: window)
                            self.player.setFullScreenLayout(true)
                            self.updateFullScreenTrafficLights()
                        }
                        if name == NSWindow.didExitFullScreenNotification {
                            exitingFullScreen = false; self.hidingTrafficLights = false
                            self.player.setFullScreenLayout(false); self.restoreFullScreenTitlebar()
                        }
                        center()
                        if name == NSWindow.didExitFullScreenNotification { DispatchQueue.main.async { center() } }
                    }
                })
            }
            relayoutTitleArea = center
            center()
            DispatchQueue.main.async { center() }
        }

        // MARK: Search

        private var playerHeader: PlayerHeaderMac?
        private var headerContentObservation: NSKeyValueObservation?
        private let searchField = PlayerSearchField()
        private let searchButton = ToolbarPlaybackButton()
        private var searchOwner: AnyObject?
        private var onSearchChange: (String) -> Void = { _ in }

        /// A page's marker asks for the search, or gives it up.
        func setSearch(owner: AnyObject, visible: Bool, prompt: String, text: String, onChange: @escaping (String) -> Void) {
            installFindMenuItem()
            // Pages own the query and whether the native field is shown.
            if visible {
                searchOwner = owner
                onSearchChange = onChange
                let field = searchField
                if field.placeholderString != prompt { field.placeholderString = prompt }
                if field.stringValue != text { field.stringValue = text }
                updateSearchVisibility()
            } else if searchOwner === owner {
                searchOwner = nil
                updateSearchVisibility()
            }
        }

        // Like the Finder's: in a narrow window the search field gives way to a magnifier button, and
        // a click on it brings the field back (focused) until it loses focus empty.
        private static let searchCollapseWidth: CGFloat = 900
        private var searchExpanded = false
        private var searchResizeObserver: NSObjectProtocol?

        private var searchCollapsed: Bool {
            guard let window, window.frame.width < Self.searchCollapseWidth else { return false }
            return !searchExpanded
        }

        /// Shows the field, the magnifier, or neither, for the page and the window's width.
        private func updateSearchVisibility() {
            let hasSearch = searchOwner != nil
            if let window, window.frame.width >= Self.searchCollapseWidth { searchExpanded = false }
            searchField.isHidden = !hasSearch || searchCollapsed
            searchButton.isHidden = !(hasSearch && searchCollapsed)
            scheduleTitleAreaRelayout()
        }

        private func observeWindowWidthForSearch(_ window: NSWindow) {
            guard searchResizeObserver == nil else { return }
            searchResizeObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateSearchVisibility(); self?.layoutPlayerHeader() }
            }
        }

        @objc func expandSearch(_ sender: Any?) {
            searchExpanded = true
            updateSearchVisibility()
            // The field has to be on screen before it can take the focus.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }; self.window?.makeFirstResponder(self.searchField); self.searchField.selectText(nil); self.searchField.setEditing(true)
                }
            }
        }

        func controlTextDidBeginEditing(_ notification: Notification) { searchField.setEditing(true) }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard control === searchField, commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            window?.makeFirstResponder(nil); searchField.setEditing(false)
            return true
        }
        func controlTextDidEndEditing(_ notification: Notification) {
            searchField.setEditing(false)
            guard searchExpanded, let field = notification.object as? NSSearchField, field.stringValue.isEmpty else { return }
            searchExpanded = false
            updateSearchVisibility()
        }

        /// ⌘F: puts the cursor in the search field (shown only on the pages that search).
        @available(macOS 11.0, *)
        @objc func findInPage(_ sender: Any?) {
            if searchCollapsed { expandSearch(nil); return }
            window?.makeFirstResponder(searchField); searchField.selectText(nil); searchField.setEditing(true)
        }

        @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
            // Only "Find…" is ours to validate here; it is available while a page has a search field.
            item.keyEquivalent == "f" ? searchOwner != nil : true
        }

        private var findMonitor: Any?
        private var outsideSearchMonitor: Any?

        /// ⌘F works whatever the menus hold (the Edit menu can be rebuilt after we add to it): the key
        /// is caught here while a page with a search field is shown, and selects the integrated search field.
        private func installFindShortcut(_ window: NSWindow) {
            guard findMonitor == nil else { return }
            findMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak window] event in
                guard let self, let window, event.window === window,
                      event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                      event.charactersIgnoringModifiers == "f", self.searchOwner != nil else { return event }
                if #available(macOS 11.0, *) { MainActor.assumeIsolated { self.findInPage(nil) } }
                return nil
            }
        }

        /// Adds "Find…" ⌘F to the Edit menu, once the app's menus exist.
        private func installFindMenuItem(attempt: Int = 0) {
            guard #available(macOS 11.0, *) else { return }
            guard let edit = NSApp.mainMenu?.items.first(where: { $0.title == "Edit" })?.submenu else {
                if attempt < 10 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in MainActor.assumeIsolated { self?.installFindMenuItem(attempt: attempt + 1) } } }
                return
            }
            guard !edit.items.contains(where: { $0.action == #selector(findInPage(_:)) }) else { return }
            let find = NSMenuItem(title: "Find…", action: #selector(findInPage(_:)), keyEquivalent: "f")
            find.target = self
            edit.addItem(.separator())
            edit.addItem(find)
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            onSearchChange(field.stringValue)
            searchField.revealCaret()
            DispatchQueue.main.async { [weak self] in self?.searchField.revealCaret() }
        }

        // MARK: Integrated player header

        private func handleSearchPointerDown(_ event: NSEvent) -> NSEvent {
            guard event.window === window, searchField.editing, searchField.currentEditor() != nil else { return event }
            let fieldRect = searchField.convert(searchField.bounds, to: nil).insetBy(dx: -4, dy: -2)
            if !fieldRect.contains(event.locationInWindow) { window?.makeFirstResponder(nil); searchField.setEditing(false) }
            return event
        }

        private func installPlayerHeader(in window: NSWindow) {
            guard let content = window.contentView else { return }
            let header = PlayerHeaderMac(frame: NSRect(x: 0, y: content.bounds.height - CGFloat(titleBarHeight), width: content.bounds.width, height: CGFloat(titleBarHeight)))
            header.identifier = NSUserInterfaceItemIdentifier("playerHeader")
            header.autoresizingMask = [.width, .minYMargin]
            header.onLayout = { [weak self] in self?.layoutPlayerHeader() }
            playerHeader = header
            let trafficArea = NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self)
            header.addTrackingArea(trafficArea); trafficLightArea = trafficArea
            queueButton.setSymbol("list.bullet", size: 14)
            queueButton.isBordered = false; queueButton.target = self; queueButton.action = #selector(showPlayerQueue)
            queueButton.setAccessibilityLabel("Up Next"); queueButton.toolTip = "Up Next"
            queueButton.isEnabled = PlaybackController.shared.track != nil
            queueToken = PlaybackController.shared.didChange.observe { [weak self] in self?.queueButton.isEnabled = PlaybackController.shared.track != nil }
            searchField.delegate = self; searchField.sendsSearchStringImmediately = true
            if #available(macOS 11, *) { searchField.controlSize = .large }
            searchField.setAccessibilityLabel("Search")
            if outsideSearchMonitor == nil {
                outsideSearchMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                    MainActor.assumeIsolated { _ = self?.handleSearchPointerDown(event) }
                    return event
                }
            }
            searchButton.setSymbol("magnifyingglass", size: 15)
            searchButton.isBordered = false; searchButton.target = self; searchButton.action = #selector(expandSearch(_:))
            searchButton.setAccessibilityLabel("Search"); searchButton.toolTip = "Search"
            searchField.isHidden = searchOwner == nil; searchButton.isHidden = true
            for view in [player.transport, player.volumeView, player.route, player.lcd, queueButton, searchField, searchButton] { header.addSubview(view) }
            content.addSubview(header, positioned: .above, relativeTo: nil)
            // inspectWindow runs before the backend installs its final content root.
            // Follow that replacement, rather than attaching to a discarded placeholder.
            headerContentObservation = window.observe(\.contentView, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.attachPlayerHeader() }
            }
            layoutPlayerHeader()
        }

        private func attachPlayerHeader() {
            attachWindowGlass()
            guard let header = playerHeader, let content = window?.contentView else { return }
            if header.superview !== content {
                header.removeFromSuperview()
                header.frame = NSRect(x: 0, y: content.bounds.height - CGFloat(titleBarHeight), width: content.bounds.width, height: CGFloat(titleBarHeight))
                content.addSubview(header, positioned: .above, relativeTo: nil)
            }
            layoutPlayerHeader()
        }

        private func layoutPlayerHeader() {
            guard let header = playerHeader else { return }
            player.layout(in: header)
            queueButton.frame = NSRect(x: player.lcd.frame.maxX + 8, y: 9, width: 39, height: 26)
            searchField.frame = NSRect(x: header.bounds.width - 182, y: 8, width: 170, height: 28)
            searchButton.frame = NSRect(x: header.bounds.width - 51, y: 9, width: 39, height: 26)
        }

        // MARK: Sidebar

        /// The sidebar's whole column: the highest ancestor of its list still as narrow as the sidebar.
        private func sidebarColumn() -> NSView? {
            guard var view = sidebarAnchor else { return nil }
            while let parent = view.superview, parent.frame.width <= sidebarWidthRange.upperBound + 1 { view = parent }
            return view
        }

        /// The sidebar and the content move together, from the very first frame. Nothing waits for
        /// the app's layout: both start on the compositor at once, the content's left edge following
        /// the sidebar's right edge. The app lays the content out for the new state a few frames later;
        /// the moment that lands, the content's slide is replaced by one that begins at the same
        /// instant as the first and picks up exactly where it was, so the edge never jumps. Layers
        /// are cut at the edge of the area they live in, so nothing crosses the rail.
        /// The cut and the rim must exist from the start, not only after the first slide: waits for the
        /// sidebar's views to be built.
        private func shapeAreaWhenReady(attempt: Int = 0) {
            if Self.nativeSplitMode {
                if ProcessInfo.processInfo.environment["IPPM_BENCH_SIDEBAR"] != nil {
                    if let split = nativeSplit(), split.frame.width > 500 {
                        guard !benchStarted else { return }
                        benchStarted = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            split.setSidebarOpen(true, animated: false)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { split.benchDrag() }
                        }
                    } else if attempt < 100 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                            MainActor.assumeIsolated { self?.shapeAreaWhenReady(attempt: attempt + 1) }
                        }
                    }
                }
                return
            }
            // Only once the layout has settled: the column is as wide as the sidebar and its area is wider.
            if let column = sidebarColumn(), let area = column.superview,
               column.frame.width > 150, column.frame.width <= sidebarWidthRange.upperBound + 10, area.frame.width > 500, abs(area.frame.minX - CGFloat(mediaRailWidth)) < 1 {
                shapeArea(area)
                installResizeHandle(on: column)
                return
            }
            guard attempt < 100 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                MainActor.assumeIsolated { self?.shapeAreaWhenReady(attempt: attempt + 1) }
            }
        }

        private var resizeHandle: SidebarResizeHandle?
        private var handleObserver: NSObjectProtocol?
        /// A thin strip along the sidebar's right edge that resizes it, like the Finder's: it stops at
        /// the narrowest width, and dragged on past that point the sidebar closes at once. It lives in the
        /// area the slides share, above the list and the content, and follows the column's width.
        private func installResizeHandle(on column: NSView) {
            guard resizeHandle == nil, let area = column.superview else { return }
            let handle = SidebarResizeHandle(frame: .zero)
            area.addSubview(handle, positioned: .above, relativeTo: nil)
            resizeHandle = handle
            column.postsFrameChangedNotifications = true
            handleObserver = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: column, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.placeResizeHandle() }
            }
            placeResizeHandle()
        }

        private func placeResizeHandle() {
            guard let handle = resizeHandle, let column = sidebarColumn() else { return }
            let top = CGFloat(titleBarHeight), margin = CGFloat(floatingPanelMargin)
            let area = column.superview
            let y = (area?.isFlipped ?? false) ? top : margin
            handle.frame = NSRect(x: column.frame.maxX - 4, y: y, width: 8, height: column.frame.height - top - margin)
            // Kept while a drag is under way, so the gesture can reopen what it closed.
            handle.isHidden = (!sidebarOpen || !sidebarAvailable) && !handle.tracking
            // Always the topmost sibling, whatever the app added since.
            if let area, area.subviews.last !== handle { area.addSubview(handle, positioned: .above, relativeTo: nil) }
        }

        /// Narrowest the sidebar can be dragged to. It snaps shut once its edge is dragged past half that width
        /// (`snapShutBelow`); dragged back out 16 pt further (`snapOpenAbove`) it snaps open at the narrowest
        /// width, then follows the pointer.
        private static let narrowest: Double = 128
        private static let snapShutBelow: CGFloat = 64
        private static let snapOpenAbove: CGFloat = 80

        /// While the edge is dragged, the width is native: the app's layout takes ~40 ms, far too slow for
        /// every pointer move, so the sidebar's views are resized directly and so is the content, which
        /// keeps its right edge and takes whatever width the sidebar leaves (views as wide as the content
        /// follow it). The app lays out once, when the drag ends; the width stays ours until its layout
        /// has caught up (`liveWidth` is nil again), and whatever the app commits in between is put back.
        private var liveWidth: CGFloat?
        private var liveContentRight: CGFloat?
        private var liveObserver: NSObjectProtocol?
        private var applyingLive = false

        func dragSidebarEdge(to x: CGFloat) {
            if sidebarShown {
                if x < Self.snapShutBelow { setSidebarAtOnce(open: false); applyLiveWidth(); return }
            } else {
                guard x >= Self.snapOpenAbove else { return }
                setSidebarAtOnce(open: true)
            }
            // The content needs its own minimum, so the sidebar can't take more than the window leaves.
            let areaWidth = sidebarColumn()?.superview?.bounds.width ?? 1100
            let upper = max(Self.narrowest, min(sidebarWidthRange.upperBound, Double(areaWidth) - 760 - Double(floatingPanelMargin)))
            if liveContentRight == nil { liveContentRight = contentContainer?.frame.maxX }
            liveWidth = CGFloat(min(max(Double(x), Self.narrowest), upper).rounded())
            observeLiveFrame()
            applyLiveWidth()
        }

        /// Watches the content's frame, for the app putting it back to a stale layout (or catching up).
        private func observeLiveFrame() {
            guard liveObserver == nil, let content = contentContainer else { return }
            content.postsFrameChangedNotifications = true
            liveObserver = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: content, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.applyingLive, let live = self.liveWidth, let content = self.contentContainer else { return }
                    let left = self.sidebarShown ? live : 0
                    if abs(content.frame.minX - left) < 0.5, !(self.resizeHandle?.tracking ?? false) {
                        self.finishLive()  // the app's layout has caught up
                    } else {
                        self.applyLiveWidth()  // a stale layout: put the drag back
                    }
                }
            }
        }

        private func finishLive() {
            liveWidth = nil
            liveContentRight = nil
            if let observer = liveObserver { NotificationCenter.default.removeObserver(observer) }
            liveObserver = nil
        }

        /// Puts the sidebar's views and the content where the drag left them. Never re-entered by the
        /// frame changes it causes itself.
        private func applyLiveWidth() {
            guard !applyingLive, let live = liveWidth, let content = contentContainer else { return }
            applyingLive = true
            defer { applyingLive = false }
            if sidebarShown { resizeSidebarViews(to: live); placeResizeHandle() }
            let left = sidebarShown ? live : 0
            let right = liveContentRight ?? content.frame.maxX
            let target = NSRect(x: left, y: content.frame.minY, width: max(right - left, 1), height: content.frame.height)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            content.layer?.setAffineTransform(.identity)
            if abs(content.frame.minX - target.minX) >= 0.5 || abs(content.frame.width - target.width) >= 0.5 {
                let old = content.frame.width
                content.frame = target
                resizeWidth(of: content, from: old, to: target.width)
            }
            CATransaction.commit()
        }

        /// Descendants as wide as their parent was follow it to the new width.
        private func resizeWidth(of view: NSView, from oldWidth: CGFloat, to width: CGFloat) {
            for sub in view.subviews {
                let subOld = sub.frame.width
                guard abs(subOld - oldWidth) < 1.5 else { continue }
                var frame = sub.frame
                frame.size.width = width
                sub.frame = frame
                resizeWidth(of: sub, from: subOld, to: width)
            }
        }

        /// Every view of the sidebar column that is as wide as the column gets the new width.
        private func resizeSidebarViews(to width: CGFloat) {
            guard let column = sidebarColumn() else { return }
            let old = column.frame.width
            func resize(_ view: NSView, from oldWidth: CGFloat) {
                for sub in view.subviews where sub !== resizeHandle {
                    let subOld = sub.frame.width
                    guard abs(subOld - oldWidth) < 1.5 || abs(subOld - width) < 0.5 else { continue }
                    if abs(subOld - width) >= 0.5 {
                        var frame = sub.frame
                        frame.size.width = width
                        sub.frame = frame
                    }
                    resize(sub, from: subOld)
                }
            }
            resize(column, from: old)
            if abs(old - width) >= 0.5 {
                var frame = column.frame
                frame.size.width = width
                column.frame = frame
            }
        }

        /// Opens or closes the sidebar with no slide and no fade: the drag itself is the motion.
        private func setSidebarAtOnce(open: Bool) {
            guard let column = sidebarColumn() else { return }
            if !sidebarPreferencesRestored { sidebarChangedBeforeRestore = true }
            sidebarOpen = open
            slideRevision += 1
            column.layer?.removeAnimation(forKey: "sidebarSlide")
            column.isHidden = !open
            if let list = sidebarAnchor?.layer { list.removeAnimation(forKey: "sidebarFade"); list.opacity = open ? 1 : 0 }
            onSidebarChange?(open)
        }

        /// The drag is over: the app lays out once for the final width; the handle takes its place again.
        func endSidebarDrag() {
            if sidebarOpen, let width = liveWidth { onSidebarWidth?(Int(width)) }
            placeResizeHandle()
            applyLiveWidth()
            // A safety net, once: if the app never lays out (same width as before), let go of the drag.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                MainActor.assumeIsolated { if !(self?.resizeHandle?.tracking ?? false) { self?.finishLive() } }
            }
        }

        private var areaObserver: NSObjectProtocol?
        private var rim: PanelRim?
        /// The area both slides live in is cut to the main view's outline: its two left corners are
        /// rounded where the rail ends, whatever the sidebar and the content are doing, so the shape
        /// never changes during a slide. The band above (title bar) is left whole.
        private func shapeArea(_ area: NSView) {
            area.wantsLayer = true
            guard let layer = area.layer else { return }
            layer.masksToBounds = true
            func update() {
                let w = area.bounds.width, h = area.bounds.height
                let top = CGFloat(titleBarHeight), bottom = CGFloat(floatingPanelMargin)
                let r = CGFloat(floatingPanelRadius)
                let path = CGMutablePath()
                // y grows downward in a flipped view, upward otherwise.
                let (bandY, panelY): (CGFloat, CGFloat) = area.isFlipped ? (0, top) : (h - top, bottom)
                path.addRect(CGRect(x: 0, y: bandY, width: w, height: top))
                path.addRoundedRect(in: CGRect(x: 0, y: panelY, width: w + 2 * r, height: h - top - bottom), cornerWidth: r, cornerHeight: r)
                let mask = CAShapeLayer()
                mask.frame = area.bounds
                mask.path = path
                layer.mask = mask
            }
            update()
            // The glass rim around the whole main view, over the content and the sidebar, outside the area's cut.
            if rim == nil, let host = area.superview {
                let line = PanelRim()
                line.areaIsFlipped = area.isFlipped
                rim = line
                host.addSubview(line, positioned: .above, relativeTo: area)
            }
            func placeRim() { rim?.frame = area.frame; rim?.needsDisplay = true }
            placeRim()
            if areaObserver == nil {
                area.postsFrameChangedNotifications = true
                areaObserver = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: area, queue: .main) { _ in
                    MainActor.assumeIsolated { update(); placeRim() }
                }
            }
        }

        /// Pages with nothing to navigate (an iPod's page, for now) have no sidebar and no toggle.
        private var sidebarAvailable = true
        private(set) var isAnimatingSidebar = false
        private var sidebarAnimationGeneration = 0
        private weak var sidebarOutlineView: NSOutlineView?

        private var wantsSidebar = true

        /// True once the sidebar's column is laid out (the same test `shapeAreaWhenReady` waits for):
        /// before that, `sidebarColumn()` can't tell the column from the window's other views.
        private func sidebarIsLaidOut() -> Bool {
            guard let column = sidebarColumn(), let area = column.superview else { return false }
            return column.frame.width > 150 && column.frame.width <= sidebarWidthRange.upperBound + 10
                && area.frame.width > 500 && abs(area.frame.minX - CGFloat(mediaRailWidth)) < 1
        }

        /// Restores the saved sidebar width once the split view exists, and reports each width the user
        /// drags it to. Native split mode only.
        /// One rounded shape for the sidebar and the main view together: the split view is clipped to a
        /// rounded rectangle (the area below the title bar, inside the margins), and the title bar stays
        /// whole. The pages inside are square: opening or closing the sidebar never changes a corner.
        private var containerMask: ContainerMask?
        func installContainerMask(attempt: Int = 0) {
            guard Self.nativeSplitMode, containerMask == nil else { return }
            if let split = nativeSplit(), split.frame.width > 500 {
                containerMask = ContainerMask(split)
            } else if attempt < 40 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    MainActor.assumeIsolated { self?.installContainerMask(attempt: attempt + 1) }
                }
            }
        }

        /// Builds an isolated chrome for the opt-in native sidebar state-machine check, without
        /// installing application lifecycle hooks or changing the real window's chrome.
        static func sidebarCheckChrome(window: NSWindow) -> MacChrome {
            let chrome = MacChrome()
            chrome.window = window
            return chrome
        }

        /// Reconciles late-arriving preferences with any action the user already made.
        @discardableResult
        func restoreSidebar(open: Bool, width: Double?, onChange: @escaping (Double) -> Void) -> Bool {
            if !sidebarChangedBeforeRestore { sidebarOpen = open }
            sidebarPreferencesRestored = true
            onSidebarChange?(sidebarOpen)
            setUpSidebarPersistence(width: sidebarWidthBeforeRestore ?? width, onChange: onChange)
            if let width = sidebarWidthBeforeRestore { onChange(width); sidebarWidthBeforeRestore = nil }
            return sidebarOpen
        }

        func setUpSidebarPersistence(width: Double?, onChange: @escaping (Double) -> Void) {
            guard Self.nativeSplitMode else { return }
            pendingSidebarWidth = width
            onPersistSidebarWidth = onChange
            reconcileNativeSidebar()
        }

        /// Called by the sidebar when it joins a window. A pending setup survives slow launches.
        func sidebarHierarchyDidChange() {
            guard Self.nativeSplitMode else { return }
            reconcileNativeSidebar()
        }

        private func scheduleSidebarRetry(attempt: Int) {
            guard sidebarRetry == nil, attempt < 40 else { return }
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.sidebarRetry = nil
                    self.reconcileNativeSidebar(attempt: attempt + 1)
                }
            }
            sidebarRetry = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        }

        private func reconcileNativeSidebar(attempt: Int = 0) {
            guard Self.nativeSplitMode else { return }
            guard let split = nativeSplit() else {
                scheduleSidebarRetry(attempt: attempt)
                return
            }
            if observedSidebarSplit !== split {
                if let observer = sidebarFrameObserver { NotificationCenter.default.removeObserver(observer) }
                observedSidebarSplit = split
                split.postsFrameChangedNotifications = true
                sidebarFrameObserver = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: split, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, self.pendingSidebarWidth != nil || self.sidebarRetry != nil else { return }
                        self.reconcileNativeSidebar()
                    }
                }
                split.onDragEnd = { [weak self, weak split] width in
                    MainActor.assumeIsolated {
                        guard let self, let split else { return }
                        if width == 0 {
                            self.splitDelegateProxy?.dividerDragEnded(in: split)
                            return
                        }
                        self.splitDelegateProxy?.widthBeforeDrag = nil
                        self.splitDelegateProxy?.inDefaultDetent = false
                        let value = Double(width.rounded())
                        self.persistedSidebarWidth = CGFloat(value)
                        if !self.sidebarPreferencesRestored { self.sidebarWidthBeforeRestore = value }
                        self.onSidebarWidth?(Int(value))
                        self.onPersistSidebarWidth?(value)
                    }
                }
            }
            if split.delegate !== splitDelegateProxy, let original = split.delegate {
                let proxy = SidebarSplitDelegateProxy(target: original, chrome: self)
                splitDelegateProxy = proxy
                split.delegate = proxy
            }
            guard split.frame.width > 500, split.subviews.count > 1 else {
                scheduleSidebarRetry(attempt: attempt)
                return
            }
            sidebarRetry?.cancel()
            sidebarRetry = nil
            if let width = pendingSidebarWidth {
                pendingSidebarWidth = nil
                let clamped = CGFloat(min(max(width, Self.narrowest), sidebarWidthRange.upperBound))
                persistedSidebarWidth = clamped
                split.applySidebarWidth(clamped)
            }
            split.dividerDragEnabled = sidebarAvailable && sidebarOpen
            split.dividerTopInset = CGFloat(titleBarHeight)
            split.setSidebarOpenAtOnce(sidebarAvailable && sidebarOpen)
        }

        /// The divider was dragged past half the narrowest width and AppKit collapsed the pane: the
        /// sidebar is closed from this very moment, so nothing in the same gesture can reopen it unless
        /// the user drags back right past 64 px before releasing.
        fileprivate func sidebarDidCollapseByDrag(in split: NSCustomSplitView) {
            guard sidebarOpen else { return }
            if !sidebarPreferencesRestored { sidebarChangedBeforeRestore = true }
            sidebarOpen = false
        }

        /// The user dragged back right past 64 px before releasing: mark the sidebar open again.
        fileprivate func sidebarDidReopenByDrag(in split: NSCustomSplitView) {
            guard !sidebarOpen else { return }
            sidebarOpen = true
            split.dividerDragEnabled = true
            onSidebarChange?(true)
        }

        /// Once AppKit is out of its resize pass: the pane is left exactly as the toolbar button leaves
        /// it (hidden at width 0, SwiftCrossUI's sidebar width 0), the width from before the drag is
        /// what reopening restores, and the app is told.
        fileprivate func finishSidebarCollapsedByDrag(in split: NSCustomSplitView, restoringWidth width: CGFloat?) {
            guard !sidebarOpen, let pane = split.subviews.first else { return }
            split.dividerDragEnabled = false
            // AppKit hides a collapsed pane but keeps its frame, and SwiftCrossUI's delegate may have
            // read the width before the pane was hidden: both would leave the sidebar's room empty.
            if pane.isHidden { pane.isHidden = false }
            split.setSidebarOpenAtOnce(false)
            if let width, width >= CGFloat(Self.narrowest) {
                persistedSidebarWidth = width
                split.applySidebarWidth(width)
                let value = Double(width.rounded())
                if !sidebarPreferencesRestored { sidebarWidthBeforeRestore = value }
                onSidebarWidth?(Int(value))
                onPersistSidebarWidth?(value)
            }
            onSidebarChange?(false)
        }

        func setSidebarAvailable(_ available: Bool, attempt: Int = 0) {
            if Self.nativeSplitMode {
                wantsSidebar = available
                sidebarAvailable = available
                reconcileNativeSidebar()
                return
            }
            if attempt == 0 { wantsSidebar = available }
            guard wantsSidebar == available, available != sidebarAvailable else { return }
            // Taking the sidebar away waits until it exists (an iPod can be the first page shown).
            if !available, !sidebarIsLaidOut() {
                guard attempt < 40 else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    MainActor.assumeIsolated { self?.setSidebarAvailable(available, attempt: attempt + 1) }
                }
                return
            }
            // No slide either way: the column is simply there or not with the page, in the same
            // update pass as the content's new padding (the app calls this from the sidebar's own
            // update). The user's open/closed choice (`sidebarOpen`) is left alone.
            sidebarAvailable = available
            if let column = sidebarColumn() {
                column.isHidden = !(available && sidebarOpen)
                if let list = sidebarAnchor?.layer { list.removeAnimation(forKey: "sidebarFade"); list.opacity = column.isHidden ? 0 : 1 }
            }
            placeResizeHandle()
        }

        private func findSidebarOutlineView(in root: NSView) -> NSOutlineView? {
            if let cached = sidebarOutlineView, cached.isDescendant(of: root) { return cached }
            var stack = [root]
            while let view = stack.popLast() {
                if let outline = view as? NSOutlineView {
                    sidebarOutlineView = outline
                    return outline
                }
                stack.append(contentsOf: view.subviews)
            }
            return nil
        }

        fileprivate func setSidebarAnimationActive(_ active: Bool, in split: NSCustomSplitView?) {
            guard isAnimatingSidebar != active else { return }
            isAnimatingSidebar = active
            split?.dividerDragEnabled = !active && sidebarOpen
            if active, let anchor = sidebarAnchor {
                anchor.resizeSubviews(withOldSize: anchor.bounds.size)
            }
            if !active {
                while NSCursor.current == .resizeLeftRight { NSCursor.pop() }
                NSCursor.arrow.set()
                window?.resetCursorRects()
            }
            guard let pane = split?.subviews.first, let outline = findSidebarOutlineView(in: pane) else { return }
            let mode: NSLineBreakMode = active ? .byClipping : .byTruncatingTail
            let mouseInWindow = pane.window?.mouseLocationOutsideOfEventStream
            outline.enumerateAvailableRowViews { rowView, _ in
                guard let cell = rowView.view(atColumn: 0) as? NSTableCellView else { return }
                let id = cell.identifier?.rawValue
                if id == "DataCell" || id == "DeviceCell" {
                    cell.textField?.lineBreakMode = mode
                } else if id == "HeaderCell" || id == "SubHeaderCell", let sidebarCell = cell as? Sidebar.SidebarCell {
                    if active {
                        sidebarCell.fadePlus(to: 0, duration: 0.08)
                    } else if !pane.isHidden, let mouseInWindow {
                        let visibleRect = sidebarCell.convert(sidebarCell.visibleRect, to: nil)
                        if !visibleRect.isEmpty, visibleRect.contains(mouseInWindow) {
                            sidebarCell.fadePlus(to: 1)
                        }
                    }
                }
            }
        }

        @objc func toggleSidebar() {
            if Self.nativeSplitMode {
                guard sidebarAvailable, let split = nativeSplit(), split.frame.width > 500, split.subviews.count > 1 else { return }
                if !sidebarPreferencesRestored { sidebarChangedBeforeRestore = true }
                sidebarOpen.toggle()
                if sidebarOpen, let pane = split.subviews.first {
                    // `applySidebarWidth` snaps the divider immediately if `isSidebarOpen` (`!pane.isHidden`)
                    // is true; temporarily hiding the pane updates `openWidth` without jump-cutting a
                    // running close animation.
                    let wasHidden = pane.isHidden
                    if !wasHidden { pane.isHidden = true }
                    split.applySidebarWidth(persistedSidebarWidth)
                    if !wasHidden { pane.isHidden = false }
                }
                if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    sidebarAnimationGeneration += 1
                    let generation = sidebarAnimationGeneration
                    setSidebarAnimationActive(true, in: split)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { [weak self, weak split] in
                        MainActor.assumeIsolated {
                            guard let self, self.sidebarAnimationGeneration == generation else { return }
                            self.setSidebarAnimationActive(false, in: split)
                        }
                    }
                }
                split.setSidebarOpen(sidebarOpen, animated: true)
                if isAnimatingSidebar {
                    while NSCursor.current == .resizeLeftRight { NSCursor.pop() }
                    NSCursor.arrow.set()
                }
                split.subviews.first?.layoutSubtreeIfNeeded()
                split.dividerDragEnabled = !isAnimatingSidebar && sidebarOpen
                onSidebarChange?(sidebarOpen)
                return
            }
            guard sidebarAvailable, let column = sidebarColumn() else { return }
            if !sidebarPreferencesRestored { sidebarChangedBeforeRestore = true }
            sidebarOpen.toggle()
            let opening = sidebarOpen
            slideRevision += 1
            let revision = slideRevision
            let width = column.frame.width
            column.wantsLayer = true
            if let area = column.superview { shapeArea(area) }
            installResizeHandle(on: column)
            resizeHandle?.isHidden = true  // back, once the slide has ended
            // Where both are drawn right now, in case this interrupts a slide.
            let sidebarVisual = column.isHidden ? -width : (column.layer?.presentation()?.transform.m41 ?? 0)
            let content = contentContainer
            let contentVisualX = content.map { $0.layer?.presentation()?.frame.minX ?? $0.frame.minX }
            let contentVisualShift = content?.layer?.presentation()?.transform.m41 ?? 0
            let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            column.layer?.removeAnimation(forKey: "sidebarSlide")
            content?.layer?.removeAnimation(forKey: "contentPre")
            content?.layer?.removeAnimation(forKey: "contentSlide")
            if reduceMotion { onSidebarChange?(opening); column.isHidden = !opening; placeResizeHandle(); return }
            // The app's own update (laying the content out again) comes last: the slides below are handed
            // to the compositor first, so nothing the app computes can delay their start.
            defer {
                CATransaction.flush()
                DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.onSidebarChange?(opening) } }
            }

            let duration = ProcessInfo.processInfo.environment["IPPM_SLIDE_SECONDS"].flatMap(Double.init) ?? 0.3
            // Arriving eases out, leaving eases in.
            let easing = CAMediaTimingFunction(name: opening ? .easeOut : .easeIn)
            let startTime = CACurrentMediaTime()
            func slide(_ layer: CALayer?, from: CGFloat, to: CGFloat, key: String, begin: CFTimeInterval? = nil) {
                guard let layer else { return }
                let animation = CABasicAnimation(keyPath: "transform.translation.x")
                animation.fromValue = from; animation.toValue = to
                animation.duration = duration; animation.timingFunction = easing
                animation.fillMode = .both; animation.isRemovedOnCompletion = false
                if let begin { animation.beginTime = layer.convertTime(begin, from: nil) }
                layer.add(animation, forKey: key)
            }
            // Sidebar and content, now.
            if opening { column.isHidden = false }
            slide(column.layer, from: sidebarVisual, to: opening ? 0 : -width, key: "sidebarSlide")
            // The list fades in as the panel slides in, and out as it slides out.
            if let list = sidebarAnchor {
                list.wantsLayer = true
                if let layer = list.layer {
                    let target: Float = opening ? 1 : 0
                    let from = layer.presentation()?.opacity ?? layer.opacity
                    layer.removeAnimation(forKey: "sidebarFade")
                    layer.opacity = target
                    let fade = CABasicAnimation(keyPath: "opacity")
                    fade.fromValue = from; fade.toValue = target
                    fade.duration = duration; fade.timingFunction = easing
                    layer.add(fade, forKey: "sidebarFade")
                }
            }
            if let content {
                content.wantsLayer = true
                // Until the new layout lands the old one moves by the sidebar's width.
                slide(content.layer, from: contentVisualShift, to: contentVisualShift + (opening ? width : -width), key: "contentPre")
            }
            // Bounded completion only; a reversal invalidates this callback.
            DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.02) { [weak self, weak column, weak content] in
                guard let self, let column, self.slideRevision == revision else { return }
                column.layer?.removeAnimation(forKey: "sidebarSlide")
                content?.layer?.removeAnimation(forKey: "contentPre")
                content?.layer?.removeAnimation(forKey: "contentSlide")
                // Hidden, a closed sidebar neither draws nor catches clicks meant for the main view.
                if !opening { column.isHidden = true }
                self.placeResizeHandle()
            }
            // The layout landing: delivered synchronously from inside the app's layout pass.
            guard let content, let contentVisualX else { return }
            content.postsFrameChangedNotifications = true
            var token: NSObjectProtocol?
            func finish() { if let token { NotificationCenter.default.removeObserver(token) }; token = nil }
            token = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: content, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.slideRevision == revision else { return finish() }
                    // The size may change before the origin does: wait for the move itself.
                    let delta = contentVisualX - content.frame.minX
                    guard abs(delta) > 0.5 else { return }
                    finish()
                    content.layer?.removeAnimation(forKey: "contentPre")
                    slide(content.layer, from: delta, to: 0, key: "contentSlide", begin: startTime)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.1) { MainActor.assumeIsolated { finish() } }
        }
    }

    /// A zero-size marker in the main view's content: its parent is the container that slides.
    struct PanelAnchor: NSViewRepresentable {
        final class AnchorView: NSView {
            override func viewDidMoveToSuperview() {
                super.viewDidMoveToSuperview()
                if superview != nil { MainActor.assumeIsolated { MacChrome.shared.contentAnchor = self } }
            }
        }
        func makeNSView(context: Context) -> AnchorView { AnchorView() }
        func updateNSView(_ view: AnchorView, context: Context) {}
        func sizeThatFits(_ proposal: ProposedViewSize, nsView: AnchorView, context: Context) -> ViewSize { ViewSize(0, 0) }
    }

    /// `IPPM_SNAPSHOT=<file.png>`: saves the window as the app draws it, then quits. Lets the UI be
    /// checked without screen-recording permission. `IPPM_SNAPSHOT_COLLAPSED=1` hides the sidebar first.
    @MainActor
    private func snapshotIfRequested(_ window: NSWindow) {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["IPPM_SNAPSHOT"] else { return }
        Task { @MainActor in
            let delay = env["IPPM_SNAPSHOT_DELAY"].flatMap(Double.init) ?? 1.5
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if env["IPPM_SNAPSHOT_COLLAPSED"] != nil {
                MacChrome.shared.toggleSidebar()
                try? await Task.sleep(nanoseconds: 600_000_000)
            }
            // Switch key windows after launch has finished; the backend otherwise takes
            // the key back while initially presenting its window.
            var inactiveCompanion: NSWindow?
            if env["IPPM_FRONT"] == "inactive" {
                let companion = NSWindow(contentRect: NSRect(x: 1400, y: 120, width: 160, height: 120),
                                         styleMask: [.titled], backing: .buffered, defer: false)
                companion.makeKeyAndOrderFront(nil)
                inactiveCompanion = companion
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            defer { withExtendedLifetime(inactiveCompanion) {} }
            guard let view = window.contentView?.superview,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            NSApp.terminate(nil)
        }
    }


/// A thin glass-like rim around the main view: bright where the light would catch it, at the top left
/// and the bottom right, nearly clear between. Drawn just outside the panel, in the window's margin.
@MainActor
final class PanelRim: NSView {
    var areaIsFlipped = true
    override var isFlipped: Bool { areaIsFlipped }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let top = CGFloat(titleBarHeight), margin = CGFloat(floatingPanelMargin), r = CGFloat(floatingPanelRadius)
        // The panel's frame in this view: from the rail's edge to the right margin, under the title bar.
        let panel = NSRect(x: 0, y: isFlipped ? top : margin, width: bounds.width - margin, height: bounds.height - top - margin)
        // 1 pt, the usual thickness of a macOS separator or window outline.
        let outer = NSBezierPath(roundedRect: panel.insetBy(dx: -0.5, dy: -0.5), xRadius: r + 0.5, yRadius: r + 0.5)
        let inner = NSBezierPath(roundedRect: panel.insetBy(dx: 0.5, dy: 0.5), xRadius: r - 0.5, yRadius: r - 0.5)
        let ring = NSBezierPath()
        ring.windingRule = .evenOdd
        ring.append(outer)
        ring.append(inner)
        let gradient = NSGradient(colorsAndLocations:
            (NSColor.white.withAlphaComponent(0.25), 0),
            (NSColor.white.withAlphaComponent(0.035), 0.45),
            (NSColor.white.withAlphaComponent(0.035), 0.6),
            (NSColor.white.withAlphaComponent(0.15), 1))
        // Top left to bottom right, whichever way the view's y runs.
        gradient?.draw(in: ring, angle: isFlipped ? 45 : -45)
    }
}


/// The sidebar's draggable edge. Its cursor is the resize one; dragging past the narrowest width closes the
/// sidebar, dragging back reopens it, all within one gesture.
@MainActor
final class SidebarResizeHandle: NSView {
    private(set) var tracking = false
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }

    override func mouseDown(with event: NSEvent) { tracking = true }
    override func mouseUp(with event: NSEvent) {
        tracking = false
        MacChrome.shared.endSidebarDrag()
        // Back to the normal cursor unless the pointer is still on the edge.
        let point = convert(event.locationInWindow, from: nil)
        if isHidden || !bounds.contains(point) { NSCursor.arrow.set() }
        window?.invalidateCursorRects(for: self)
    }
    override func mouseDragged(with event: NSEvent) {
        guard tracking, let area = superview else { return }
        NSCursor.resizeLeftRight.set()
        MacChrome.shared.dragSidebarEdge(to: area.convert(event.locationInWindow, from: nil).x)
    }
}


@MainActor
final class ContainerMask {
    private weak var split: NSView?
    private let shape = CAShapeLayer()
    private var observer: NSObjectProtocol?
    init(_ split: NSView) {
        self.split = split
        split.wantsLayer = true
        split.postsFrameChangedNotifications = true
        split.layer?.mask = shape
        observer = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: split, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        update()
    }
    private func update() {
        guard let split else { return }
        let bounds = split.bounds
        let margin = CGFloat(floatingPanelMargin), top = CGFloat(titleBarHeight), r = CGFloat(floatingPanelRadius)
        // Coordinates follow the layer: the origin is at the bottom unless the view is flipped.
        let flipped = split.isFlipped
        let panel = CGRect(x: 0, y: flipped ? top : margin, width: bounds.width - margin, height: bounds.height - top - margin)
        let strip = CGRect(x: 0, y: flipped ? 0 : bounds.height - top, width: bounds.width, height: top)
        let path = CGMutablePath()
        path.addRoundedRect(in: panel, cornerWidth: r, cornerHeight: r)
        path.addRect(strip)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        shape.frame = bounds
        shape.path = path
        CATransaction.commit()
    }
}

/// Stands in front of SwiftCrossUI's `NSSplitViewResizingDelegate`: the divider stops at 128 pt, the
/// sidebar collapses past half that width, can reopen in the same gesture, and a completed
/// collapse restores the previous width when reopened. Everything else is SwiftCrossUI's own behavior, forwarded untouched.
@MainActor
private final class SidebarSplitDelegateProxy: NSObject, NSSplitViewDelegate {
    private static let narrowest: CGFloat = 128
    private weak var target: NSSplitViewDelegate?
    private weak var chrome: MacChrome?
    var widthBeforeDrag: CGFloat?
    var inDefaultDetent = false
    private var collapsedSavedWidth: CGFloat?

    init(target: NSSplitViewDelegate, chrome: MacChrome) {
        self.target = target
        self.chrome = chrome
    }

    /// SwiftCrossUI lifts its bounds while it opens or closes the sidebar itself (the slide, or at once
    /// inside an update): it then returns the proposed minimum as is. Asked with a value no layout
    /// produces, the answer tells which case this is.
    private func boundsLifted(in splitView: NSSplitView) -> Bool {
        guard let target else { return false }
        let probe: CGFloat = -4096
        return target.splitView?(splitView, constrainMinCoordinate: probe, ofSubviewAt: 0) == probe
    }

    /// AppKit is tracking a divider drag (it fetches the events itself, inside `mouseDown`).
    private func userIsDragging(_ splitView: NSSplitView) -> Bool {
        guard let type = NSApp.currentEvent?.type, type == .leftMouseDragged || type == .leftMouseDown else { return false }
        return !boundsLifted(in: splitView)
    }

    /// Only a drag collapses the pane: AppKit does it at half the minimum width (64 pt).
    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        subview === splitView.subviews.first && !boundsLifted(in: splitView)
    }

    func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool {
        target?.splitView?(splitView, shouldAdjustSizeOfSubview: view) ?? true
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        let base = target?.splitView?(splitView, constrainMinCoordinate: proposedMinimumPosition, ofSubviewAt: dividerIndex) ?? proposedMinimumPosition
        guard dividerIndex == 0, !boundsLifted(in: splitView) else { return base }
        return max(Self.narrowest, base)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        target?.splitView?(splitView, constrainMaxCoordinate: proposedMaximumPosition, ofSubviewAt: dividerIndex) ?? proposedMaximumPosition
    }

    func splitView(_ splitView: NSSplitView, constrainSplitPosition proposedPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        guard dividerIndex == 0 else { return proposedPosition }
        guard userIsDragging(splitView) else { return proposedPosition }
        if proposedPosition >= 193 && proposedPosition <= 213 {
            if !inDefaultDetent {
                inDefaultDetent = true
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
            return CGFloat(sidebarWidth)
        }
        inDefaultDetent = false
        return proposedPosition
    }

    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        target?.splitView?(splitView, resizeSubviewsWithOldSize: oldSize)
    }

    func splitViewWillResizeSubviews(_ notification: Notification) {
        if widthBeforeDrag == nil,
           let split = notification.object as? NSSplitView,
           let pane = split.subviews.first,
           !pane.isHidden,
           pane.frame.width >= Self.narrowest,
           userIsDragging(split) {
            chrome?.setSidebarAnimationActive(false, in: split as? NSCustomSplitView)
            widthBeforeDrag = pane.frame.width
        }
        target?.splitViewWillResizeSubviews?(notification)
    }

    func dividerDragEnded(in split: NSCustomSplitView) {
        let saved = collapsedSavedWidth ?? widthBeforeDrag
        collapsedSavedWidth = nil; widthBeforeDrag = nil; inDefaultDetent = false
        guard !split.isSidebarOpen else { return }
        chrome?.finishSidebarCollapsedByDrag(in: split, restoringWidth: saved)
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard let chrome, chrome.isSidebarAvailable,
              let split = notification.object as? NSCustomSplitView,
              let pane = split.subviews.first,
              !boundsLifted(in: split) else {
            target?.splitViewDidResizeSubviews?(notification)
            return
        }

        if pane.isHidden, chrome.isSidebarVisible {
            // AppKit has just collapsed the pane under the drag (< 64 px).
            collapsedSavedWidth = widthBeforeDrag
            widthBeforeDrag = nil
            inDefaultDetent = false
            chrome.sidebarDidCollapseByDrag(in: split)
            target?.splitViewDidResizeSubviews?(notification)
            return
        }

        if !pane.isHidden, !chrome.isSidebarVisible, collapsedSavedWidth != nil {
            // User dragged back right past 64 px before releasing: reopen live.
            widthBeforeDrag = collapsedSavedWidth
            collapsedSavedWidth = nil
            chrome.sidebarDidReopenByDrag(in: split)
        }

        target?.splitViewDidResizeSubviews?(notification)
    }
}

#endif
