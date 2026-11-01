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
    /// unified toolbar holding the sidebar toggle, and the sidebar slide.
    @MainActor
    final class MacChrome: NSObject, NSToolbarDelegate {
        static let shared = MacChrome()

        private weak var window: NSWindow?
        private weak var splitView: NSSplitView?
        private var splitDelegate: CollapsibleSplitDelegate?
        private var expandedWidth = sidebarWidth
        private var slide: SidebarSlide?
        var isSliding: Bool { slide != nil }
        private var timer: Timer?
        /// A sidebar slide resizes the complete detail hierarchy.  Keeping this at the standard
        /// 60 Hz avoids spending every ProMotion (120 Hz) tick relaying out controls on the iPod
        /// page, while remaining display-smooth and leaving the main run loop responsive.
        private let sidebarSlideFrameInterval = 1.0 / 60.0
        /// The iPod page has many controls and a complete layout can take longer than a display
        /// frame.  A short native slide limits that transient work to a few frames; an explicit
        /// diagnostic duration still wins when `IPPM_SLIDE_SECONDS` is set.
        private let sidebarSlideDuration = ProcessInfo.processInfo.environment["IPPM_SLIDE_SECONDS"] == nil ? 0.16 : SidebarSlide.duration
        private static let toggleID = NSToolbarItem.Identifier("toggleSidebar")

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
            // A unified toolbar gives the 52 pt title bar SwiftUI uses: traffic lights centered
            // on the header row, the toggle right after them.
            let toolbar = NSToolbar(identifier: "main")
            toolbar.delegate = self
            toolbar.displayMode = .iconOnly
            toolbar.allowsUserCustomization = false
            window.toolbar = toolbar
            if #available(macOS 11, *) { window.toolbarStyle = .unified }
            // Once SwiftCrossUI has put its split view in: open the sidebar at its width
            // (SwiftCrossUI's default is 200).
            DispatchQueue.main.async {
                MainActor.assumeIsolated { MacChrome.shared.splitViewReady() }
            }
            snapshotIfRequested(window)
        }

        // MARK: Toolbar

        func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            [Self.toggleID, .flexibleSpace]
        }

        func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            toolbarDefaultItemIdentifiers(toolbar)
        }

        func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                     willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem?
        {
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

        /// Opens the sidebar at its width (SwiftCrossUI's default is 200) and puts the delegate
        /// proxy in front now, so dragging the divider keeps to `sidebarWidthRange` from the start.
        fileprivate func splitViewReady() {
            guard let split = findSplitView() else { return }
            _ = collapsibleDelegate(for: split)
            split.setPosition(sidebarWidth, ofDividerAt: 0)
        }

        /// Width the sidebar's rows keep during a slide; nil: they fill the sidebar.
        private(set) var pinnedSidebarContentWidth: Double?

        /// The sidebar's width right now, read by `TitleClearance` while SwiftCrossUI lays out.
        var currentSidebarWidth: Double {
            guard let split = findSplitView() else { return sidebarWidth }
            return split.subviews[0].isHidden ? 0 : split.subviews[0].frame.width
        }

        /// Slides the sidebar closed or open: the divider moves every frame and the split view's
        /// resize lays the panes out. The timer exists only for the slide.
        @objc func toggleSidebar() {
            guard slide == nil, let split = findSplitView() else { return }
            let sidebar = split.subviews[0]
            let opening = sidebar.isHidden || sidebar.frame.width < 1
            // Once closed, the pane must not participate in an AppKit resize at all.  Leaving a
            // zero-width SwiftCrossUI pane visible lets its split delegate restore the minimum
            // width for a frame during window zooming.
            if opening {
                collapsibleDelegate(for: split).allowsCollapse = true
                sidebar.isHidden = false
                split.setPosition(0, ofDividerAt: 0)
            }
            let from = opening ? 0 : sidebar.frame.width
            let closing = !opening
            if closing { expandedWidth = from }
            collapsibleDelegate(for: split).allowsCollapse = true
            slide = SidebarSlide(from: from, to: closing ? 0 : expandedWidth, duration: sidebarSlideDuration)
            pinnedSidebarContentWidth = slide?.openWidth
            let start = CACurrentMediaTime()
            let timer = Timer(timeInterval: sidebarSlideFrameInterval, repeats: true) { _ in
                MainActor.assumeIsolated { MacChrome.shared.tick(elapsed: CACurrentMediaTime() - start) }
            }
            // Keep the animation moving while AppKit is in an event-tracking run-loop mode, but
            // never keep a timer alive once the short slide has finished.
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }

        private func tick(elapsed: Double) {
            guard var slide, let split = splitView else { return }
            let (width, done) = slide.width(after: elapsed)
            let layoutStart = CACurrentMediaTime()
            // The final divider layout must update the retained page at its new width.
            if done { self.slide = nil }
            split.setPosition(width, ofDividerAt: 0)
            slide.record(layout: CACurrentMediaTime() - layoutStart)
            if !done { self.slide = slide }
            guard done else { return }
            timer?.invalidate()
            timer = nil
            self.slide = nil
            pinnedSidebarContentWidth = nil
            slide.logResult(elapsed: elapsed)
            if slide.to == 0 {
                // Do this only after the final divider layout.  A hidden pane is excluded from
                // the next resize entirely, preventing the visible one-frame width rebound.
                split.subviews[0].isHidden = true
            }
            splitDelegate?.allowsCollapse = slide.to == 0
        }

        fileprivate func findSplitView() -> NSSplitView? {
            if let splitView { return splitView }
            splitView = window?.contentView.flatMap(Self.findSplitView)
            return splitView
        }

        /// SwiftCrossUI's split view delegate keeps the sidebar at its minimum width; a proxy in
        /// front of it lets the divider reach zero.
        private func collapsibleDelegate(for split: NSSplitView) -> CollapsibleSplitDelegate {
            if let splitDelegate, split.delegate === splitDelegate { return splitDelegate }
            let proxy = CollapsibleSplitDelegate(inner: split.delegate)
            split.delegate = proxy
            splitDelegate = proxy
            return proxy
        }

        private static func findSplitView(in view: NSView) -> NSSplitView? {
            if let split = view as? NSSplitView { return split }
            for sub in view.subviews {
                if let found = findSplitView(in: sub) { return found }
            }
            return nil
        }
    }

    /// Forwards everything to SwiftCrossUI's delegate, except the minimum sidebar width while the
    /// sidebar is sliding or closed.
    final class CollapsibleSplitDelegate: NSObject, NSSplitViewDelegate {
        private let inner: (any NSSplitViewDelegate)?
        var allowsCollapse = false

        init(inner: (any NSSplitViewDelegate)?) {
            self.inner = inner
        }

        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || (inner?.responds(to: selector) ?? false)
        }

        override func forwardingTarget(for selector: Selector!) -> Any? {
            inner?.responds(to: selector) == true ? inner : nil
        }

        func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposed: CGFloat,
                       ofSubviewAt index: Int) -> CGFloat
        {
            if index == 0 && allowsCollapse { return 0 }
            let inner = inner?.splitView?(splitView, constrainMinCoordinate: proposed, ofSubviewAt: index) ?? proposed
            return index == 0 ? max(inner, sidebarWidthRange.lowerBound) : inner
        }

        func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposed: CGFloat,
                       ofSubviewAt index: Int) -> CGFloat
        {
            let inner = inner?.splitView?(splitView, constrainMaxCoordinate: proposed, ofSubviewAt: index) ?? proposed
            return index == 0 ? min(inner, sidebarWidthRange.upperBound) : inner
        }

        func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
            // A fully hidden sidebar is intentionally absent from this resize.  In particular,
            // do not forward to SwiftCrossUI: its minimum-width pass is the source of the zoom
            // flash we are avoiding.
            if splitView.subviews[0].isHidden { return }
            // Closed: keep the sidebar at zero when the window resizes.
            if allowsCollapse && splitView.subviews[0].frame.width < 1 {
                // `adjustSubviews()` asks SwiftCrossUI for its minimum sidebar width first, then
                // the following call collapses it again.  A zoom/double-click therefore visibly
                // flashed the sidebar open for one layout pass.  `setPosition` both lays out the
                // detail and preserves the already-collapsed leading pane in one pass.
                splitView.setPosition(0, ofDividerAt: 0)
                return
            }
            if inner?.responds(to: #selector(NSSplitViewDelegate.splitView(_:resizeSubviewsWithOldSize:))) == true {
                inner?.splitView?(splitView, resizeSubviewsWithOldSize: oldSize)
            } else {
                splitView.adjustSubviews()
            }
        }
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
