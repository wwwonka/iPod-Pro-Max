#if canImport(AppKitBackend)
    import AppKit
    import AppKitBackend
    import Foundation
    import SwiftCrossUI
    import iPodKit

    /// macOS draws its own traffic lights and toggle (in the toolbar).
    let drawsWindowControls = false

    extension View {
        /// - Parameter colorScheme: unused on macOS, where AppKit follows the system appearance.
        func windowChrome(colorScheme: Binding<ColorScheme>) -> some View {
            inspectWindow { MacChrome.shared.install(on: $0) }
        }
    }

    @MainActor func toggleSidebar() { MacChrome.shared.toggleSidebar() }
    @MainActor func performWindowAction(_ action: WindowAction) {}

    /// macOS draws its traffic lights and toggle itself (the window and its toolbar).
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

    /// The AppKit side of the window chrome: a transparent title bar over full-size content, a
    /// unified toolbar holding the sidebar toggle, and the sidebar slide. The sidebar floats over
    /// the main view's left side: opening or closing it moves nothing else.
    @MainActor
    final class MacChrome: NSObject, NSToolbarDelegate, NSSearchFieldDelegate {
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
        private static let toggleID = NSToolbarItem.Identifier("toggleSidebar")
        private static let searchID = NSToolbarItem.Identifier("search")

        var isSliding: Bool { false }
        var isLiveResizing: Bool { window?.inLiveResize == true }
        /// The sidebar's rows always fill their panel: nothing is pinned during the slide.
        var pinnedSidebarContentWidth: Double? { nil }
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
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            // Glass all over: the window paints nothing itself, its effect views do.
            window.isOpaque = false
            window.backgroundColor = .clear
            installWindowGlass(on: window)
            // A unified toolbar gives a compact 44 pt title bar: traffic lights centered
            // on the header row, the toggle right after them.
            let toolbar = NSToolbar(identifier: "main")
            toolbar.delegate = self
            toolbar.displayMode = .iconOnly
            toolbar.allowsUserCustomization = false
            // The compact style would draw small controls: the regular size, as in a 52 pt bar.
            toolbar.sizeMode = .regular
            window.toolbar = toolbar
            self.toolbar = toolbar
            installFindMenuItem()
            installFindShortcut(window)
            observeWindowWidthForSearch(window)
            shapeAreaWhenReady()
            if #available(macOS 11, *) { window.toolbarStyle = .unifiedCompact }
            keepTrafficLightsCentered(in: window)
            snapshotIfRequested(window)
            if Self.launchPanelEnabled { MacLaunchTransition.shared.prepare(window) }
            // `IPPM_FRONT=1`: floats the window above everything, to screenshot it over the desktop.
            if ProcessInfo.processInfo.environment["IPPM_FRONT"] != nil {
                window.level = .floating
                window.setFrameOrigin(NSPoint(x: 120, y: 120))
                window.orderFrontRegardless()
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
        private func installWindowGlass(on window: NSWindow) {
            guard let content = window.contentView, let frameView = content.superview else { return }
            let glass = NSVisualEffectView(frame: frameView.bounds)
            glass.material = .underWindowBackground
            glass.blendingMode = .behindWindow
            glass.state = .active  // stays glass when another app comes forward
            glass.autoresizingMask = [.width, .height]
            frameView.addSubview(glass, positioned: .below, relativeTo: content)
        }

        // MARK: Traffic lights

        private var trafficLightObservers: [NSObjectProtocol] = []
        /// Lays the title area out again (centering, sizes): after a toolbar item shows or hides.
        private var relayoutTitleArea: (() -> Void)?
        private func scheduleTitleAreaRelayout() {
            DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.relayoutTitleArea?() } }
        }

        /// The compact toolbar is a little shorter than the title area, which would leave the
        /// traffic lights above its middle: they are moved down to the title area's center, and
        /// put back there whenever AppKit lays the title bar out again (resize, full screen).
        private func keepTrafficLightsCentered(in window: NSWindow) {
            let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window.standardWindowButton($0) }
            // The container of the title bar and the toolbar is as tall as the compact toolbar (38);
            // it is made as tall as the title area, so the toolbar's items center on it too.
            let container = buttons.first?.superview?.superview
            container?.postsFrameChangedNotifications = true
            func center() {
                guard let frameView = window.contentView?.superview else { return }
                if let container {
                    let height = CGFloat(titleBarHeight)
                    let frame = NSRect(x: 0, y: frameView.bounds.height - height, width: frameView.bounds.width, height: height)
                    if container.frame != frame { container.frame = frame }
                    // The toolbar itself stays 38 tall inside it: it is stretched as well.
                    if let titlebar = buttons.first?.superview,
                       let toolbarView = titlebar.subviews.first(where: { String(describing: type(of: $0)) == "NSToolbarView" }) {
                        let toolbarFrame = NSRect(x: 0, y: titlebar.bounds.height - height, width: titlebar.bounds.width, height: height)
                        if toolbarView.frame != toolbarFrame { toolbarView.frame = toolbarFrame }
                        func enlarge(_ view: NSView) {
                            if #available(macOS 11, *), let control = view as? NSButton, control.controlSize != .large { control.controlSize = .large }
                            view.subviews.forEach(enlarge)
                        }
                        enlarge(toolbarView)
                    }
                }
                let target = frameView.bounds.height - CGFloat(titleBarHeight) / 2
                for button in buttons {
                    let current = button.convert(NSPoint(x: 0, y: button.bounds.midY), to: frameView).y
                    let delta = target - current
                    guard abs(delta) > 0.25, let parent = button.superview else { continue }
                    let moved = parent.convert(NSPoint(x: 0, y: current + delta), from: frameView)
                    let was = parent.convert(NSPoint(x: 0, y: current), from: frameView)
                    button.setFrameOrigin(NSPoint(x: button.frame.minX, y: button.frame.minY + (moved.y - was.y)))
                }
            }
            for button in buttons {
                button.postsFrameChangedNotifications = true
                trafficLightObservers.append(NotificationCenter.default.addObserver(
                    forName: NSView.frameDidChangeNotification, object: button, queue: .main) { _ in
                        MainActor.assumeIsolated { center() }
                    })
            }
            if let container {
                trafficLightObservers.append(NotificationCenter.default.addObserver(
                    forName: NSView.frameDidChangeNotification, object: container, queue: .main) { _ in
                        MainActor.assumeIsolated { center() }
                    })
            }
            for name in [NSWindow.didResizeNotification, NSWindow.didExitFullScreenNotification, NSWindow.didBecomeKeyNotification] {
                trafficLightObservers.append(NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main) { _ in
                        MainActor.assumeIsolated { center() }
                    })
            }
            relayoutTitleArea = center
            center()
            DispatchQueue.main.async { center() }
        }

        // MARK: Search

        // The page's search lives in the toolbar as the system's own search item, the Finder's. The
        // pages that search put a marker in their header (`SearchAnchor`), which adds the item while
        // it shows and removes it otherwise.
        private weak var toolbar: NSToolbar?
        private var searchItem: NSToolbarItem?
        private var searchOwner: AnyObject?
        private var onSearchChange: (String) -> Void = { _ in }

        @available(macOS 11.0, *)
        private func makeSearchItem() -> NSSearchToolbarItem {
            if let item = searchItem as? NSSearchToolbarItem { return item }
            let item = NSSearchToolbarItem(itemIdentifier: Self.searchID)
            item.searchField.delegate = self
            item.searchField.sendsSearchStringImmediately = true
            item.preferredWidthForSearchField = 240
            item.searchField.controlSize = .large
            item.label = "Search"
            // Hidden until a page that searches claims it.
            if #available(macOS 15.0, *) { item.isHidden = true }
            searchItem = item
            return item
        }

        /// A page's marker asks for the search, or gives it up.
        func setSearch(owner: AnyObject, visible: Bool, prompt: String, text: String, onChange: @escaping (String) -> Void) {
            // The system's search item needs macOS 11; before it, pages have no search field.
            guard #available(macOS 11.0, *) else { return }
            installFindMenuItem()
            // The item is part of the toolbar from the start (inserted later, it never showed); a page
            // without a search hides it.
            let item = makeSearchItem()
            if visible {
                searchOwner = owner
                onSearchChange = onChange
                let field = item.searchField
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
        private static let searchButtonID = NSToolbarItem.Identifier("searchButton")
        private static let searchCollapseWidth: CGFloat = 900
        private var searchButtonItem: NSToolbarItem?
        private var searchExpanded = false
        private var searchResizeObserver: NSObjectProtocol?

        private var searchCollapsed: Bool {
            guard let window, window.frame.width < Self.searchCollapseWidth else { return false }
            return !searchExpanded
        }

        /// Shows the field, the magnifier, or neither, for the page and the window's width.
        private func updateSearchVisibility() {
            // Hiding a toolbar item needs macOS 15; before it the field always shows.
            guard #available(macOS 15.0, *) else { return }
            let hasSearch = searchOwner != nil
            if let window, window.frame.width >= Self.searchCollapseWidth { searchExpanded = false }
            searchItem?.isHidden = !hasSearch || searchCollapsed
            searchButtonItem?.isHidden = !(hasSearch && searchCollapsed)
            scheduleTitleAreaRelayout()
        }

        private func observeWindowWidthForSearch(_ window: NSWindow) {
            guard searchResizeObserver == nil else { return }
            searchResizeObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateSearchVisibility() }
            }
        }

        @objc func expandSearch(_ sender: Any?) {
            searchExpanded = true
            updateSearchVisibility()
            // The field has to be on screen before it can take the focus.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    if #available(macOS 11.0, *) { (self?.searchItem as? NSSearchToolbarItem)?.beginSearchInteraction() }
                }
            }
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard searchExpanded, let field = notification.object as? NSSearchField, field.stringValue.isEmpty else { return }
            searchExpanded = false
            updateSearchVisibility()
        }

        /// ⌘F: puts the cursor in the search field (shown only on the pages that search).
        @available(macOS 11.0, *)
        @objc func findInPage(_ sender: Any?) {
            if searchCollapsed { expandSearch(nil); return }
            (searchItem as? NSSearchToolbarItem)?.beginSearchInteraction()
        }

        @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
            // Only "Find…" is ours to validate here; it is available while a page has a search field.
            item.keyEquivalent == "f" ? searchOwner != nil : true
        }

        private var findMonitor: Any?

        /// ⌘F works whatever the menus hold (the Edit menu can be rebuilt after we add to it): the key
        /// is caught here while a page with a search field is shown, and selects the toolbar's search.
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
        }

        // MARK: Toolbar

        func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            [Self.toggleID, .flexibleSpace, Self.searchButtonID, Self.searchID]
        }

        func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            [Self.toggleID, .flexibleSpace, Self.searchButtonID, Self.searchID]
        }

        func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                     willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem?
        {
            if id == Self.searchID { if #available(macOS 11.0, *) { return makeSearchItem() } else { return nil } }
            if id == Self.searchButtonID {
                let item = NSToolbarItem(itemIdentifier: id)
                item.image = systemSymbol("magnifyingglass", description: "Search")
                item.label = "Search"
                item.toolTip = "Search"
                item.isBordered = true
                item.target = self
                item.action = #selector(expandSearch(_:))
                if #available(macOS 15.0, *) { item.isHidden = true }
                searchButtonItem = item
                return item
            }
            guard id == Self.toggleID else { return nil }
            let item = NSToolbarItem(itemIdentifier: id)
            item.image = systemSymbol("sidebar.left", description: "Show or hide the sidebar")
            item.label = "Sidebar"
            item.toolTip = "Hide or show the sidebar"
            item.isBordered = true
            item.target = self
            item.action = #selector(toggleSidebar)
            item.isEnabled = sidebarAvailable
            toggleItem = item
            return item
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
        private weak var toggleItem: NSToolbarItem?

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

        func setUpSidebarPersistence(width: Double?, onChange: @escaping (Double) -> Void, attempt: Int = 0) {
            guard Self.nativeSplitMode else { return }
            if let split = nativeSplit(), split.frame.width > 500 {
                if let width {
                    split.applySidebarWidth(CGFloat(min(max(width, sidebarWidthRange.lowerBound), sidebarWidthRange.upperBound)))
                }
                split.onDragEnd = { onChange(Double($0.rounded())) }
            } else if attempt < 40 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    MainActor.assumeIsolated { self?.setUpSidebarPersistence(width: width, onChange: onChange, attempt: attempt + 1) }
                }
            }
        }

        func setSidebarAvailable(_ available: Bool, attempt: Int = 0) {
            if Self.nativeSplitMode {
                wantsSidebar = available
                sidebarAvailable = available
                if #available(macOS 15.0, *) { toggleItem?.isHidden = !available; scheduleTitleAreaRelayout() }
                toggleItem?.isEnabled = available
                if let split = nativeSplit() {
                    // At once, in the update pass that changes the page: the layout being computed reads the new width.
                    if ProcessInfo.processInfo.environment["IPPM_BENCH_LAYOUT"] != nil { FileHandle.standardError.write(Data("[avail] \(available) open=\(sidebarOpen) pane=\(Int(split.frame.width))\n".utf8)) }
                    // No interaction with the sidebar's edge on the iPod page, nor from the toolbar.
                    split.dividerDragEnabled = available
                    split.dividerTopInset = CGFloat(titleBarHeight)
                    split.setSidebarOpenAtOnce(available && sidebarOpen)
                } else if attempt < 40 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                        MainActor.assumeIsolated { self?.setSidebarAvailable(available, attempt: attempt + 1) }
                    }
                }
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
            if #available(macOS 15.0, *) { toggleItem?.isHidden = !available; scheduleTitleAreaRelayout() }
            toggleItem?.isEnabled = available
        }

        @objc func toggleSidebar() {
            if Self.nativeSplitMode {
                guard sidebarAvailable, let split = nativeSplit() else { return }
                sidebarOpen.toggle()
                split.setSidebarOpen(sidebarOpen, animated: true)
                return
            }
            guard sidebarAvailable, let column = sidebarColumn() else { return }
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
            guard let view = window.contentView?.superview,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            NSApp.terminate(nil)
        }
    }
#endif


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
