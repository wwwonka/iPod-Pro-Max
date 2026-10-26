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

    /// macOS draws its own traffic lights and toggle (in the toolbar).
    let drawsWindowControls = false

    extension View {
        /// - Parameters:
        ///   - sidebarVisible: set when the toggle hides or shows the sidebar.
        ///   - colorScheme: unused on macOS, where AppKit follows the system appearance itself.
        func windowChrome(sidebarVisible: Binding<Bool>, colorScheme: Binding<ColorScheme>) -> some View {
            inspectWindow { window in
                MacChrome.shared.install(on: window) { sidebarVisible.wrappedValue = $0 }
            }
        }
    }

    @MainActor func toggleSidebar() { MacChrome.shared.toggleSidebar() }
    @MainActor func performWindowAction(_ action: WindowAction) {}

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
            var frames = 0
            animation = Timer.scheduledTimer(withTimeInterval: 1 / 120, repeats: true) { [weak self] timer in
                MainActor.assumeIsolated {
                    frames += 1
                    let t = min(1, (CACurrentMediaTime() - start) / duration)
                    let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
                    split.setPosition(from + (to - from) * eased, ofDividerAt: 0)
                    guard t >= 1 else { return }
                    timer.invalidate()
                    self?.animation = nil
                    log("[bench] sidebar \(collapsing ? "close" : "open"): \(frames) frames in \(Int((CACurrentMediaTime() - start) * 1000)) ms")
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
#elseif canImport(GtkBackend)
    import CGtk
    import Gtk
    import GtkBackend
    import Foundation

    let collapsedHeaderInset = 120
    /// GTK has no Mac-style title bar, so the app draws the traffic lights and the toggle.
    let drawsWindowControls = true

    extension View {
        func windowChrome(sidebarVisible: Binding<Bool>, colorScheme: Binding<ColorScheme>) -> some View {
            inspectWindow { window in
                GtkChrome.shared.install(
                    on: window,
                    onVisibilityChange: { sidebarVisible.wrappedValue = $0 },
                    onColorScheme: { colorScheme.wrappedValue = $0 })
            }
        }
    }

    @MainActor func toggleSidebar() { GtkChrome.shared.toggleSidebar() }
    @MainActor func performWindowAction(_ action: WindowAction) { GtkChrome.shared.perform(action) }

    /// The GTK side of the window chrome, through the C API:
    /// - no system title bar (an empty CSD title bar keeps the shadow and resize edges),
    /// - dragging the top 52 pt moves the window, double-clicking it maximizes (not over controls),
    /// - dark mode follows GNOME's color-scheme setting, and changes live (signal, no polling),
    /// - the sidebar slides closed and open on the frame clock.
    @MainActor
    final class GtkChrome {
        static let shared = GtkChrome()

        private var window: UnsafeMutablePointer<GtkWindow>?
        private var onVisibilityChange: (Bool) -> Void = { _ in }
        private var onColorScheme: (ColorScheme) -> Void = { _ in }
        private var interfaceSettings: UnsafeMutablePointer<GSettings>?
        fileprivate var animation: (paned: OpaquePointer, from: Int32, to: Int32, start: gint64, collapsing: Bool)?
        private var expandedWidth: Int32 = 230

        func install(on window: Gtk.ApplicationWindow,
                     onVisibilityChange: @escaping (Bool) -> Void,
                     onColorScheme: @escaping (ColorScheme) -> Void)
        {
            self.onVisibilityChange = onVisibilityChange
            self.onColorScheme = onColorScheme
            let pointer: UnsafeMutablePointer<GtkWindow> = cast(window.widgetPointer)
            guard self.window != pointer else { return }
            self.window = pointer

            // A hidden title bar widget: GTK keeps client-side decorations (shadow, resize edges)
            // but gives no height to it; a visible empty one still takes the theme's 46 px.
            let titlebar = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)
            gtk_widget_set_visible(titlebar, 0)
            gtk_window_set_titlebar(pointer, titlebar)

            roundCorners(pointer)

            let click = gtk_gesture_click_new()!
            gtk_gesture_single_set_button(cast(click), 1)
            g_signal_connect_data(cast(click), "pressed", unsafeBitCast(titleBarPressed, to: GCallback.self),
                                  nil, nil, GConnectFlags(rawValue: 0))
            gtk_widget_add_controller(cast(pointer), cast(click))
            // Moving starts once the pointer has travelled a few pixels, as GtkWindowHandle does,
            // so a tap on a control in the title area never grabs the window.
            let drag = gtk_gesture_drag_new()!
            gtk_gesture_single_set_button(cast(drag), 1)
            g_signal_connect_data(cast(drag), "drag-update", unsafeBitCast(titleBarDragged, to: GCallback.self),
                                  nil, nil, GConnectFlags(rawValue: 0))
            gtk_widget_add_controller(cast(pointer), cast(drag))

            followColorScheme()
            // Once the first frame is up: SwiftCrossUI may set the window's child after this runs.
            g_idle_add_full(300, { _ in
                MainActor.assumeIsolated { GtkChrome.shared.styleContent() }
                return 0
            }, nil, nil)
        }

        /// Lets the divider go below the sidebar's minimum width, only while sliding: left on, GTK
        /// gives the open sidebar less than its minimum and clips it from the left.
        fileprivate func prepareForCollapse(_ paned: OpaquePointer) {
            if gtk_paned_get_shrink_start_child(paned) == 0 { gtk_paned_set_shrink_start_child(paned, 1) }
        }

        // MARK: Corners

        /// GTK only rounds a window's top corners (its title bar's); without one, the content's
        /// square bottom corners show. Round and clip the content like a Mac window, except when
        /// maximized or tiled.
        private func roundCorners(_ window: UnsafeMutablePointer<GtkWindow>) {
            let provider = gtk_css_provider_new()!
            gtk_css_provider_load_from_string(provider, """
                window.csd { border-radius: 12px; }
                window.csd > .ippm-content { border-radius: 12px; }
                window.maximized > .ippm-content, window.tiled > .ippm-content,
                window.fullscreen > .ippm-content { border-radius: 0; }
                """)
            gtk_style_context_add_provider_for_display(gdk_display_get_default(), cast(provider), 800)
            styleContent()
        }

        /// Also called after the first frame: SwiftCrossUI may set the window's child after this runs.
        fileprivate func styleContent() {
            guard let window, let content = gtk_window_get_child(window),
                  gtk_widget_has_css_class(content, "ippm-content") == 0 else { return }
            gtk_widget_add_css_class(content, "ippm-content")
            gtk_widget_set_overflow(content, GTK_OVERFLOW_HIDDEN)
        }

        // MARK: Dark mode

        private func followColorScheme() {
            // Only GNOME-like desktops have this key; elsewhere stay light rather than abort.
            guard let source = g_settings_schema_source_get_default(),
                  let schema = g_settings_schema_source_lookup(source, "org.gnome.desktop.interface", 1)
            else { return }
            defer { g_settings_schema_unref(schema) }
            guard g_settings_schema_has_key(schema, "color-scheme") != 0 else { return }
            interfaceSettings = g_settings_new("org.gnome.desktop.interface")
            g_signal_connect_data(cast(interfaceSettings), "changed::color-scheme",
                                  unsafeBitCast(colorSchemeChanged, to: GCallback.self), nil, nil, GConnectFlags(rawValue: 0))
            applyColorScheme()
        }

        fileprivate func applyColorScheme() {
            guard let interfaceSettings, let value = g_settings_get_string(interfaceSettings, "color-scheme") else { return }
            let dark = String(cString: value).contains("dark")
            g_free(value)
            // GTK's own widgets (table, scroll bars, text fields) switch with this setting.
            var gvalue = GValue()
            g_value_init(&gvalue, GType(5 << 2))  // G_TYPE_BOOLEAN
            g_value_set_boolean(&gvalue, dark ? 1 : 0)
            g_object_set_property(cast(gtk_settings_get_default()), "gtk-application-prefer-dark-theme", &gvalue)
            g_value_unset(&gvalue)
            onColorScheme(dark ? .dark : .light)
        }

        // MARK: Window buttons

        func perform(_ action: WindowAction) {
            guard let window else { return }
            switch action {
            case .close: gtk_window_close(window)
            case .minimize: gtk_window_minimize(window)
            case .zoom: toggleMaximized()
            }
        }

        fileprivate func toggleMaximized() {
            guard let window else { return }
            if gtk_window_is_maximized(window) != 0 { gtk_window_unmaximize(window) } else { gtk_window_maximize(window) }
        }

        /// True over something clickable (a button, a field, a SwiftCrossUI tap target): those all
        /// carry a click gesture between the widget under the pointer and the window.
        fileprivate func isOverControl(x: Double, y: Double) -> Bool {
            guard let window else { return false }
            var widget = gtk_widget_pick(cast(window), x, y, GTK_PICK_DEFAULT)
            while let w = widget, w != cast(window) {
                if let controllers = gtk_widget_observe_controllers(w) {
                    defer { g_object_unref(cast(controllers)) }
                    for i in 0..<g_list_model_get_n_items(controllers) {
                        guard let item = g_list_model_get_item(controllers, i) else { continue }
                        defer { g_object_unref(item) }
                        if g_type_check_instance_is_a(cast(item), gtk_gesture_click_get_type()) != 0 { return true }
                    }
                }
                widget = gtk_widget_get_parent(w)
            }
            return false
        }

        fileprivate func beginMove(gesture: OpaquePointer?, x: Double, y: Double) {
            guard let window, y < 52, !isOverControl(x: x, y: y),
                  let surface = gtk_native_get_surface(cast(window)) else { return }
            var dx: Double = 0, dy: Double = 0
            gtk_native_get_surface_transform(cast(window), &dx, &dy)
            gdk_toplevel_begin_move(cast(surface), gtk_gesture_get_device(cast(gesture)),
                                    Int32(gtk_gesture_single_get_current_button(cast(gesture))),
                                    x + dx, y + dy, gtk_event_controller_get_current_event_time(cast(gesture)))
        }

        // MARK: Sidebar

        func toggleSidebar() {
            guard animation == nil, let window,
                  let paned = Self.findPaned(gtk_window_get_child(window)) else { return }
            let from = gtk_paned_get_position(paned)
            let collapsing = from > 1
            if collapsing { expandedWidth = from } else { onVisibilityChange(true) }
            prepareForCollapse(paned)
            // SwiftCrossUI lays the whole window out on every position change (~50 ms in the VM):
            // mute it while GTK slides the divider, then lay out once at the end.
            setPositionHandlersBlocked(paned, true)
            // The clock starts on the first frame: if that frame comes late, the slide still plays.
            animation = (paned, from, collapsing ? 0 : expandedWidth, 0, collapsing)
            toggleRequested = g_get_monotonic_time()
            gtk_widget_add_tick_callback(cast(paned), sidebarTick, nil, nil)
        }

        private var frames = 0
        private var toggleRequested: gint64 = 0

        fileprivate func tick() -> Bool {
            guard var a = animation else { return false }
            if a.start == 0 {
                a.start = g_get_monotonic_time()
                animation = a
                log("[bench] sidebar first frame after \((a.start - toggleRequested) / 1000) ms")
            }
            frames += 1
            let t = min(1, Double(g_get_monotonic_time() - a.start) / 250_000)
            let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
            let position = a.from + Int32(Double(a.to - a.from) * eased)
            gtk_paned_set_position(a.paned, position)
            guard t >= 1 else { return true }
            animation = nil
            setPositionHandlersBlocked(a.paned, false)
            if !a.collapsing { gtk_paned_set_shrink_start_child(a.paned, 0) }
            g_object_notify(cast(a.paned), "position")
            log("[bench] sidebar \(a.collapsing ? "close" : "open"): \(frames) frames in \((g_get_monotonic_time() - a.start) / 1000) ms")
            frames = 0
            if a.collapsing { onVisibilityChange(false) }
            return false
        }

        private func setPositionHandlersBlocked(_ paned: OpaquePointer, _ blocked: Bool) {
            let notify = g_signal_lookup("notify", GType(20 << 2))  // G_TYPE_OBJECT
            let detail = g_quark_from_static_string("position")
            let mask = GSignalMatchType(rawValue: 1 | 2)  // G_SIGNAL_MATCH_ID | G_SIGNAL_MATCH_DETAIL
            if blocked {
                g_signal_handlers_block_matched(cast(paned), mask, notify, detail, nil, nil, nil)
            } else {
                g_signal_handlers_unblock_matched(cast(paned), mask, notify, detail, nil, nil, nil)
            }
        }

        private static func findPaned(_ widget: UnsafeMutablePointer<GtkWidget>?) -> OpaquePointer? {
            guard let widget else { return nil }
            if g_type_check_instance_is_a(cast(widget), gtk_paned_get_type()) != 0 { return cast(widget) }
            var child = gtk_widget_get_first_child(widget)
            while let c = child {
                if let found = findPaned(c) { return found }
                child = gtk_widget_get_next_sibling(c)
            }
            return nil
        }
    }


    private let titleBarPressed: @convention(c) (OpaquePointer?, Int32, Double, Double, gpointer?) -> Void = {
        gesture, presses, x, y, _ in
        MainActor.assumeIsolated {
            guard presses == 2, y < 52, !GtkChrome.shared.isOverControl(x: x, y: y) else { return }
            GtkChrome.shared.toggleMaximized()
        }
    }

    private let titleBarDragged: @convention(c) (OpaquePointer?, Double, Double, gpointer?) -> Void = {
        gesture, dx, dy, _ in
        MainActor.assumeIsolated {
            guard dx * dx + dy * dy > 16 else { return }
            var x: Double = 0, y: Double = 0
            gtk_gesture_drag_get_start_point(cast(gesture), &x, &y)
            GtkChrome.shared.beginMove(gesture: gesture, x: x, y: y)
            gtk_event_controller_reset(cast(gesture))
        }
    }

    private let colorSchemeChanged: @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, gpointer?) -> Void = { _, _, _ in
        MainActor.assumeIsolated { GtkChrome.shared.applyColorScheme() }
    }

    private let sidebarTick: @convention(c) (UnsafeMutablePointer<GtkWidget>?, OpaquePointer?, gpointer?) -> gboolean = { _, _, _ in
        MainActor.assumeIsolated { GtkChrome.shared.tick() ? 1 : 0 }
    }
#else
    // WinUI keeps its system title bar for now.
    let collapsedHeaderInset = 0
    let drawsWindowControls = false

    extension View {
        func windowChrome(sidebarVisible: Binding<Bool>, colorScheme: Binding<ColorScheme>) -> some View { self }
    }

    @MainActor func toggleSidebar() {}
    @MainActor func performWindowAction(_ action: WindowAction) {}
#endif

extension View {
    /// Applies the scheme the chrome read from the system where SwiftCrossUI can't (GTK). Elsewhere
    /// the backend already follows the system, and forcing a value would pin it.
    @ViewBuilder
    func followingSystemColorScheme(_ scheme: ColorScheme) -> some View {
        #if canImport(GtkBackend)
            colorScheme(scheme)
        #else
            // AppKit and WinUI report the system scheme to SwiftCrossUI themselves.
            self
        #endif
    }
}

enum WindowAction {
    case close, minimize, zoom
}
