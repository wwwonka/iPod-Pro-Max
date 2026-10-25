import SwiftCrossUI

// Window chrome like the SwiftUI app: no title bar, the sidebar runs to the top of the window, the
// traffic lights and a sidebar toggle sit in a unified toolbar. SwiftCrossUI has no API for this,
// so each backend's native window is reached through `inspectWindow`. Same backend order as
// DefaultBackend.

#if canImport(AppKitBackend)
    import AppKit
    import AppKitBackend
    import Foundation

    /// Room the detail header leaves for the traffic lights and the toggle once the sidebar is hidden.
    let collapsedHeaderInset = 120

    extension View {
        /// - Parameter sidebarVisible: set when the toggle hides or shows the sidebar.
        func macWindowChrome(sidebarVisible: Binding<Bool>) -> some View {
            inspectWindow { window in
                MacChrome.shared.install(on: window) { sidebarVisible.wrappedValue = $0 }
            }
        }
    }

    @MainActor
    final class MacChrome: NSObject, NSToolbarDelegate {
        static let shared = MacChrome()

        private weak var window: NSWindow?
        private var onVisibilityChange: (Bool) -> Void = { _ in }
        private var splitDelegate: CollapsibleSplitDelegate?
        private var expandedWidth: CGFloat = 230
        private var animation: Timer?
        private static let toggleID = NSToolbarItem.Identifier("toggleSidebar")

        func install(on window: NSWindow, onVisibilityChange: @escaping (Bool) -> Void) {
            self.onVisibilityChange = onVisibilityChange
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

        /// Slides the sidebar closed or open, like SwiftUI's toggle: the divider moves over
        /// 0.25 s with an ease-in-out curve. The timer exists only for the animation.
        @objc func toggleSidebar() {
            guard animation == nil, let split = window?.contentView.flatMap(Self.findSplitView) else { return }
            let delegate = collapsibleDelegate(for: split)
            let from = split.subviews[0].frame.width
            let collapsing = from > 1
            if collapsing { expandedWidth = from } else { onVisibilityChange(true) }
            let to = collapsing ? 0 : expandedWidth
            delegate.allowsCollapse = true

            let start = CACurrentMediaTime()
            let duration = 0.25
            animation = Timer.scheduledTimer(withTimeInterval: 1 / 120, repeats: true) { [weak self] timer in
                MainActor.assumeIsolated {
                    let t = min(1, (CACurrentMediaTime() - start) / duration)
                    let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
                    split.setPosition(from + (to - from) * eased, ofDividerAt: 0)
                    guard t >= 1 else { return }
                    timer.invalidate()
                    self?.animation = nil
                    delegate.allowsCollapse = collapsing
                    if collapsing { self?.onVisibilityChange(false) }
                }
            }
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
    /// sidebar is collapsing or collapsed.
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
            return inner?.splitView?(splitView, constrainMinCoordinate: proposed, ofSubviewAt: index) ?? proposed
        }

        func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
            // Collapsed: keep the sidebar at zero when the window resizes.
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
#else
    // GTK and WinUI keep their system title bar for now.
    let collapsedHeaderInset = 0

    extension View {
        func macWindowChrome(sidebarVisible: Binding<Bool>) -> some View { self }
    }
#endif
