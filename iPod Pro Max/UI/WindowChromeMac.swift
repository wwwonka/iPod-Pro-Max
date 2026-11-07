#if canImport(AppKitBackend)
    import AppKit
    import AppKitBackend
    import Foundation
    import SwiftCrossUI

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
        private var slideRevision = 0
        private static let toggleID = NSToolbarItem.Identifier("toggleSidebar")
        private static let searchID = NSToolbarItem.Identifier("search")

        var isSliding: Bool { false }
        /// The sidebar's rows always fill their panel: nothing is pinned during the slide.
        var pinnedSidebarContentWidth: Double? { nil }
        /// What already lies left of the main view, for the title's clearance.
        var currentSidebarWidth: Double { mediaRailWidth }

        func install(on window: NSWindow) {
            guard self.window !== window else { return }
            self.window = window
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
            // A unified toolbar gives the 52 pt title bar SwiftUI uses: traffic lights centered
            // on the header row, the toggle right after them.
            let toolbar = NSToolbar(identifier: "main")
            toolbar.delegate = self
            toolbar.displayMode = .iconOnly
            toolbar.allowsUserCustomization = false
            window.toolbar = toolbar
            self.toolbar = toolbar
            installFindMenuItem()
            shapeAreaWhenReady()
            if #available(macOS 11, *) { window.toolbarStyle = .unified }
            snapshotIfRequested(window)
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
            // The item is part of the toolbar from the start (inserted later, it never showed); a page
            // without a search hides it.
            let item = makeSearchItem()
            if visible {
                searchOwner = owner
                onSearchChange = onChange
                let field = item.searchField
                if field.placeholderString != prompt { field.placeholderString = prompt }
                if field.stringValue != text { field.stringValue = text }
                if #available(macOS 15.0, *) { item.isHidden = false }
            } else if searchOwner === owner {
                searchOwner = nil
                if #available(macOS 15.0, *) { item.isHidden = true }
            }
        }

        /// ⌘F: puts the cursor in the search field (shown only on the pages that search).
        @available(macOS 11.0, *)
        @objc func findInPage(_ sender: Any?) {
            (searchItem as? NSSearchToolbarItem)?.beginSearchInteraction()
        }

        @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
            // Only "Find…" is ours to validate here; it is available while a page has a search field.
            item.keyEquivalent == "f" ? searchOwner != nil : true
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
            [Self.toggleID, .flexibleSpace, Self.searchID]
        }

        func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            [Self.toggleID, .flexibleSpace, Self.searchID]
        }

        func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                     willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem?
        {
            if id == Self.searchID { if #available(macOS 11.0, *) { return makeSearchItem() } else { return nil } }
            guard id == Self.toggleID else { return nil }
            let item = NSToolbarItem(itemIdentifier: id)
            item.image = systemSymbol("sidebar.left", description: "Show or hide the sidebar")
            item.label = "Sidebar"
            item.toolTip = "Hide or show the sidebar"
            item.isBordered = true
            item.target = self
            item.action = #selector(toggleSidebar)
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
            handle.isHidden = !sidebarOpen && !handle.tracking
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
        /// every pointer move, so the sidebar's views are resized directly and the content, still laid out
        /// for the old width, is moved by its layer. The app lays out once, when the drag ends; the width
        /// stays ours until its layout has caught up (`liveWidth` is nil again), and whatever the app
        /// commits in between is put back at once.
        private var liveWidth: CGFloat?
        private var liveObservers: [NSObjectProtocol] = []
        private var liveFixScheduled = false

        func dragSidebarEdge(to x: CGFloat) {
            if sidebarOpen {
                if x < Self.snapShutBelow { setSidebarAtOnce(open: false); applyLiveWidth(); return }
            } else {
                guard x >= Self.snapOpenAbove else { return }
                setSidebarAtOnce(open: true)
            }
            // The content needs its own minimum, so the sidebar can't take more than the window leaves.
            let areaWidth = sidebarColumn()?.superview?.bounds.width ?? 1100
            let upper = max(Self.narrowest, min(sidebarWidthRange.upperBound, Double(areaWidth) - 760 - Double(floatingPanelMargin)))
            liveWidth = CGFloat(min(max(Double(x), Self.narrowest), upper).rounded())
            observeLiveFrames()
            applyLiveWidth()
        }

        private func observeLiveFrames() {
            guard liveObservers.isEmpty, let column = sidebarColumn(), let content = contentContainer else { return }
            for view in [column, content] {
                view.postsFrameChangedNotifications = true
                liveObservers.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: view, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.applyLiveWidth() }
                })
            }
        }

        /// Puts the sidebar's views and the content where the drag left them.
        private func applyLiveWidth() {
            guard let live = liveWidth, let column = sidebarColumn(), let content = contentContainer else { return }
            if sidebarOpen { resizeSidebarViews(to: live); placeResizeHandle() }
            content.wantsLayer = true
            let shift = (sidebarOpen ? live : 0) - content.frame.minX
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            content.layer?.setAffineTransform(abs(shift) < 0.5 ? .identity : CGAffineTransform(translationX: shift, y: 0))
            CATransaction.commit()
            // The app's layout has caught up: nothing left to hold.
            if abs(shift) < 0.5, !(resizeHandle?.tracking ?? false), !sidebarOpen || abs(column.frame.width - live) < 0.5 {
                liveWidth = nil
                return
            }
            // The app sets a column's children after the column itself: look again once it is done.
            guard !liveFixScheduled else { return }
            liveFixScheduled = true
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.liveFixScheduled = false
                    self?.applyLiveWidth()
                }
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

        @objc func toggleSidebar() {
            guard let column = sidebarColumn() else { return }
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
            let easing = CAMediaTimingFunction(name: .easeInEaseOut)
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
            try? await Task.sleep(nanoseconds: 1_500_000_000)
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
