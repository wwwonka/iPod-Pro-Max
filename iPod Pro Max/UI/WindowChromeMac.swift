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
        private var timer: Timer?
        private static let toggleID = NSToolbarItem.Identifier("toggleSidebar")

        func install(on window: NSWindow) {
            guard self.window !== window else { return }
            self.window = window
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
            window.toolbarStyle = .unified
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
            item.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Show or hide the sidebar")
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
            return split.subviews[0].frame.width
        }

        /// Slides the sidebar closed or open: the divider moves every frame and the split view's
        /// resize lays the panes out. The timer exists only for the slide.
        @objc func toggleSidebar() {
            guard slide == nil, let split = findSplitView() else { return }
            let from = split.subviews[0].frame.width
            let closing = from > 0
            if closing { expandedWidth = from }
            collapsibleDelegate(for: split).allowsCollapse = true
            slide = SidebarSlide(from: from, to: closing ? 0 : expandedWidth)
            pinnedSidebarContentWidth = slide?.openWidth
            let start = CACurrentMediaTime()
            timer = Timer.scheduledTimer(withTimeInterval: 1 / 120, repeats: true) { _ in
                MainActor.assumeIsolated { MacChrome.shared.tick(elapsed: CACurrentMediaTime() - start) }
            }
        }

        private func tick(elapsed: Double) {
            guard var slide, let split = splitView else { return }
            let (width, done) = slide.width(after: elapsed)
            let layoutStart = CACurrentMediaTime()
            split.setPosition(width, ofDividerAt: 0)
            slide.record(layout: CACurrentMediaTime() - layoutStart)
            self.slide = slide
            guard done else { return }
            timer?.invalidate()
            timer = nil
            self.slide = nil
            pinnedSidebarContentWidth = nil
            slide.logResult(elapsed: elapsed)
            // Stays allowed while closed: the window's resizes must keep the sidebar at zero.
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
            // Closed: keep the sidebar at zero when the window resizes.
            if allowsCollapse && splitView.subviews[0].frame.width < 1 {
                splitView.adjustSubviews()
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
            try? await Task.sleep(for: .seconds(1.5))
            if env["IPPM_SNAPSHOT_COLLAPSED"] != nil {
                MacChrome.shared.toggleSidebar()
                try? await Task.sleep(for: .seconds(0.6))
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
