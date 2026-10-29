#if canImport(WinUIBackend)
    import CWinRT
    import Foundation
    import SwiftCrossUI
    import UWP
    @_spi(WinRTInternal) import WinAppSDK
    import WinSDK
    import WinUI
    import WinUIBackend
    @_spi(WinRTInternal) import WindowsFoundation

    /// Windows has no Mac-style title bar either: the app draws the traffic lights and the toggle.
    let drawsWindowControls = true

    extension View {
        /// - Parameter colorScheme: unused on Windows, where WinUI reports the system's to SwiftCrossUI.
        func windowChrome(colorScheme: SwiftCrossUI.Binding<ColorScheme>) -> some View {
            inspectWindow { WinUIChrome.shared.install(on: $0) }
        }
    }

    @MainActor func toggleSidebar() { WinUIChrome.shared.toggleSidebar() }
    @MainActor func performWindowAction(_ action: WindowAction) { WinUIChrome.shared.perform(action) }

    /// See WindowChrome.swift. Empty and as wide as the title's clearance.
    struct TitleClearance: WinUIElementRepresentable {
        func makeWinUIElement(context: Context) -> WinUI.Grid { WinUI.Grid() }
        func updateWinUIElement(_ grid: WinUI.Grid, context: Context) {}

        func sizeThatFits(_ proposal: ProposedViewSize, winUIElement: WinUI.Grid, context: Context) -> ViewSize {
            ViewSize(titleClearance(sidebarWidth: WinUIChrome.shared.currentSidebarWidth), 0)
        }
    }

    /// The Windows side of the window chrome:
    /// - no title bar and no caption buttons; the resize border, shadow and Windows 11's rounded
    ///   corners stay,
    /// - the title area is the window's caption, except over its controls: Windows itself moves
    ///   the window, maximizes it on a double-click, snaps it and shows its menu,
    /// - the sidebar slides closed and open on the display's clock.
    @MainActor
    final class WinUIChrome {
        static let shared = WinUIChrome()

        private weak var window: WinUI.Window?
        private var presenter: OverlappedPresenter?
        /// Kept: `content` hands out a new Swift wrapper each time, and its events only hold it
        /// weakly, so subscribing on a temporary silently does nothing.
        private var root: FrameworkElement?

        func install(on window: WinUI.Window) {
            guard self.window !== window, let appWindow = window.appWindow else { return }
            self.window = window
            presenter = appWindow.presenter as? OverlappedPresenter

            // Content under the title bar, and a collapsed title bar hides the caption buttons.
            // (Removing the title bar with setBorderAndTitleBar instead leaves a white strip of
            // frame at the top.)
            appWindow.titleBar.extendsContentIntoTitleBar = true
            appWindow.titleBar.preferredHeightOption = .collapsed

            nonClientInput = InputNonClientPointerSource.getForWindowId(appWindow.id)
            root = window.content as? FrameworkElement
            // After each layout pass: cheap, and the regions only get sent when they change.
            root?.layoutUpdated.addHandler { _, _ in
                MainActor.assumeIsolated { WinUIChrome.shared.updateTitleBarRegions() }
            }
        }

        // MARK: Window buttons

        func perform(_ action: WindowAction) {
            switch action {
            case .close: try? window?.close()
            case .minimize: try? presenter?.minimize()
            case .zoom:
                guard let presenter else { return }
                if presenter.state == .maximized { try? presenter.restore() } else { try? presenter.maximize() }
            }
        }

        // MARK: Title area

        private var nonClientInput: InputNonClientPointerSource?
        /// The controls marked with `titleBarControl()`, and whether each has been on screen yet.
        private var titleBarControls: [(element: FrameworkElement, wasLoaded: Bool)] = []
        private var sentRegions: (caption: [RectInt32], passthrough: [RectInt32])?

        func addTitleBarControl(_ element: FrameworkElement) {
            titleBarControls.append((element, false))
        }

        /// The top of the window is its caption; the title area's controls pass clicks through.
        private func updateTitleBarRegions() {
            guard let root, let scale = root.xamlRoot?.rasterizationScale else { return }
            // Forget controls SwiftCrossUI took off screen for good (another section's header).
            titleBarControls = titleBarControls.compactMap { entry in
                let loaded = entry.element.isLoaded
                return entry.wasLoaded && !loaded ? nil : (entry.element, entry.wasLoaded || loaded)
            }
            let caption = [RectInt32(x: 0, y: 0, width: Int32(root.actualWidth * scale),
                                     height: Int32(titleBarHeight * scale))]
            let passthrough = titleBarControls.compactMap { entry -> RectInt32? in
                guard entry.element.isLoaded, let transform = try? entry.element.transformToVisual(root),
                      let bounds = try? transform.transformBounds(
                          Rect(x: 0, y: 0, width: Float(entry.element.actualWidth), height: Float(entry.element.actualHeight)))
                else { return nil }
                return RectInt32(x: Int32(Double(bounds.x) * scale), y: Int32(Double(bounds.y) * scale),
                                 width: Int32((Double(bounds.width) * scale).rounded(.up)),
                                 height: Int32((Double(bounds.height) * scale).rounded(.up)))
            }
            guard sentRegions?.caption != caption || sentRegions?.passthrough != passthrough else { return }
            sentRegions = (caption, passthrough)
            setRegion(.caption, caption)
            setRegion(.passthrough, passthrough)
        }

        /// `SetRegionRects` takes an array, which the Swift projection leaves out: called through
        /// the interface's C table instead.
        private func setRegion(_ kind: NonClientRegionKind, _ rects: [RectInt32]) {
            guard let nonClientInput,
                  let abi: UnsafeMutablePointer<__x_ABI_CMicrosoft_CUI_CInput_CIInputNonClientPointerSource> =
                      nonClientInput._getABI()
            else { return }
            var cRects = rects.map {
                __x_ABI_CWindows_CGraphics_CRectInt32(X: $0.x, Y: $0.y, Width: $0.width, Height: $0.height)
            }
            let result = cRects.withUnsafeMutableBufferPointer {
                abi.pointee.lpVtbl.pointee.SetRegionRects(abi, kind, UInt32($0.count), $0.baseAddress)
            }
            if result < 0 { log("[chrome] SetRegionRects failed: \(result)") }
        }

        // MARK: Sidebar

        private var splitView: CustomSplitView?
        /// The sidebar's list: given the open width during a slide (see WindowChrome.swift).
        private var sidebarList: FrameworkElement?
        private var slide: SidebarSlide?
        private var slideStart: Date?
        private var rendering: EventCleanup?

        /// The sidebar's width right now, read by `TitleClearance` while SwiftCrossUI lays out.
        var currentSidebarWidth: Double {
            splitView?.openPaneLength ?? sidebarWidth
        }

        /// Called by the sidebar once on screen: finds the split view holding it and opens the pane
        /// at the sidebar's width (WinUI's default is wider).
        func attach(sidebar: FrameworkElement) {
            guard splitView == nil else { return }
            var element: DependencyObject? = sidebar
            while let e = element, !(e is CustomSplitView) { element = VisualTreeHelper.getParent(e) }
            guard let split = element as? CustomSplitView else { return }
            splitView = split
            sidebarList = (sidebar as? WinUI.Grid)?.children.getAt(0) as? FrameworkElement
            setSidebarWidth(sidebarWidth)
        }

        /// Slides the sidebar closed or open. The frame callback exists only for the slide.
        func toggleSidebar() {
            guard let splitView, slide == nil else { return }
            let from = splitView.openPaneLength
            slide = SidebarSlide(from: from, to: from > 0 ? 0 : sidebarWidth)
            slideStart = nil
            sidebarList?.width = slide!.openWidth
            sidebarList?.horizontalAlignment = .right
            rendering = CompositionTarget.rendering.addHandler { _, _ in
                MainActor.assumeIsolated { WinUIChrome.shared.tick() }
            }
        }

        private func tick() {
            guard var slide else { return }
            let now = Date()
            let start = slideStart ?? now
            slideStart = start
            let elapsed = now.timeIntervalSince(start)
            let (width, done) = slide.width(after: elapsed)
            setSidebarWidth(width)
            slide.record(layout: Date().timeIntervalSince(now))
            self.slide = done ? nil : slide
            guard done else { return }
            rendering?.dispose()
            rendering = nil
            // Fills the pane again.
            sidebarList?.width = .nan
            sidebarList?.horizontalAlignment = .stretch
            slide.logResult(elapsed: elapsed)
        }

        /// Moves the pane's edge and lays the panes out at once (the backend's relayout hook).
        private func setSidebarWidth(_ width: Double) {
            guard let splitView else { return }
            splitView.openPaneLength = width
            splitView.sidebarResizeHandler?()
        }
    }
#endif
