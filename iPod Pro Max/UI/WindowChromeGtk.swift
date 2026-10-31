#if canImport(GtkBackend)
    import CGtk
    import Foundation
    import Gtk
    import GtkBackend
    import SwiftCrossUI

    /// GTK has no Mac-style title bar, so the app draws the traffic lights and the toggle.
    let drawsWindowControls = true

    extension View {
        /// - Parameter colorScheme: set from GNOME's setting, which GTK doesn't tell SwiftCrossUI.
        func windowChrome(colorScheme: Binding<ColorScheme>) -> some View {
            inspectWindow { window in
                GtkChrome.shared.install(on: window) { colorScheme.wrappedValue = $0 }
            }
        }
    }

    @MainActor func toggleSidebar() { GtkChrome.shared.toggleSidebar() }
    @MainActor func performWindowAction(_ action: WindowAction) { GtkChrome.shared.perform(action) }

    /// The traffic lights and the sidebar toggle, as GTK buttons styled like macOS's: the lights
    /// show their glyphs while the pointer is over them and turn gray in an inactive window, the
    /// toggle gets a rounded highlight on hover. All of it is GTK CSS, with no SwiftCrossUI update.
    struct WindowControls: GtkWidgetRepresentable {
        func makeGtkWidget(context: Context) -> Gtk.Widget {
            installTitleBarStyle()
            let bar = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)!
            gtk_widget_add_css_class(bar, "ippm-titlebar-buttons")
            let lights = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
            gtk_widget_add_css_class(lights, "ippm-lights")
            gtk_widget_set_valign(lights, GTK_ALIGN_CENTER)
            for (index, (name, glyph)) in [("close", "xmark"), ("minimize", nil),
                                           ("zoom", "arrow.up.left.and.arrow.down.right")].enumerated()
            {
                let light = button(glyph: glyph, pointSize: 7, classes: ["ippm-light", "ippm-\(name)"])
                g_signal_connect_data(cast(light), "clicked", unsafeBitCast(lightClicked, to: GCallback.self),
                                      UnsafeMutableRawPointer(bitPattern: index + 1), nil, GConnectFlags(rawValue: 0))
                gtk_box_append(cast(lights), light)
            }
            gtk_box_append(cast(bar), lights)
            let toggle = button(glyph: "sidebar.left", pointSize: 16, classes: ["ippm-toggle"])
            gtk_widget_set_tooltip_text(toggle, "Hide or show the sidebar")
            g_signal_connect_data(cast(toggle), "clicked", unsafeBitCast(toggleClicked, to: GCallback.self),
                                  nil, nil, GConnectFlags(rawValue: 0))
            gtk_box_append(cast(bar), toggle)
            return Gtk.Widget(bar)
        }

        func updateGtkWidget(_ widget: Gtk.Widget, context: Context) {}

        func sizeThatFits(_ proposal: ProposedViewSize, gtkWidget: Gtk.Widget, context: Context) -> ViewSize {
            ViewSize(TitleBarButtons.width, titleBarHeight)
        }

        /// - Parameter glyph: nil draws a minus sign.
        private func button(glyph: String?, pointSize: Double, classes: [String]) -> UnsafeMutablePointer<GtkWidget> {
            let button = gtk_button_new()!
            classes.forEach { gtk_widget_add_css_class(button, $0) }
            gtk_widget_set_valign(button, GTK_ALIGN_CENTER)
            let label = gtk_label_new(nil)!
            gtk_label_set_markup(cast(label), glyph.map { symbolMarkup($0, pointSize: pointSize, tint: nil, dark: false) }
                ?? "<span size='\(Int(pointSize * 1.4 * 1024))' weight='bold'>\u{2212}</span>")
            // Over the button rather than in it: an overlay doesn't count in its size, so the
            // lights stay 12 pt round whatever their glyph.
            let overlay = gtk_overlay_new()!
            gtk_overlay_set_child(cast(overlay), gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0))
            gtk_overlay_add_overlay(cast(overlay), label)
            gtk_button_set_child(cast(button), overlay)
            return button
        }
    }

    @MainActor private var titleBarStyleInstalled = false

    /// Positions and colors measured on macOS (WindowChrome.swift, SidebarMetrics).
    @MainActor private func installTitleBarStyle() {
        guard !titleBarStyleInstalled else { return }
        titleBarStyleInstalled = true
        let provider = gtk_css_provider_new()!
        gtk_css_provider_load_from_string(provider, """
            .ippm-titlebar-buttons { min-height: \(Int(titleBarHeight))px; }
            .ippm-lights { margin-left: 20px; }
            .ippm-light { min-width: 12px; min-height: 12px; padding: 0; margin: 0; border: none; border-radius: 6px;
                box-shadow: inset 0 0 0 0.5px rgba(0, 0, 0, 0.12); }
            .ippm-light label { opacity: 0; }
            .ippm-lights:hover .ippm-light label { opacity: 1; }
            .ippm-close, window:backdrop .ippm-lights:hover .ippm-close { background: #FF5F57; color: #4D0000; }
            .ippm-minimize, window:backdrop .ippm-lights:hover .ippm-minimize { background: #FEBC2E; color: #985712; }
            .ippm-zoom, window:backdrop .ippm-lights:hover .ippm-zoom { background: #28C840; color: #0A650D; }
            .ippm-light:active { filter: brightness(0.85); }
            window:backdrop .ippm-light { background: #DCDCDC; }
            window.ippm-dark:backdrop .ippm-light { background: #4D4D4D; }
            .ippm-toggle { min-width: \(Int(TitleBarButtons.toggleSize.width))px; min-height: \(Int(TitleBarButtons.toggleSize.height))px;
                padding: 0; margin: 0 0 0 \(Int(TitleBarButtons.toggleGap))px; border: none; border-radius: 6px;
                background-color: transparent; background-image: none; box-shadow: none; color: alpha(currentColor, 0.6);
                transition: background-color \(Int(TitleBarButtons.hoverFade * 1000))ms ease-in-out; }
            .ippm-toggle:hover { background-color: alpha(currentColor, 0.1); }
            .ippm-toggle:active { background-color: alpha(currentColor, 0.2); }
            """)
        gtk_style_context_add_provider_for_display(gdk_display_get_default(), cast(provider), 800)
    }

    private let lightClicked: @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, data in
        let action: WindowAction = switch Int(bitPattern: data) {
        case 1: .close
        case 2: .minimize
        default: .zoom
        }
        MainActor.assumeIsolated { performWindowAction(action) }
    }

    private let toggleClicked: @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, _ in
        MainActor.assumeIsolated { toggleSidebar() }
    }

    /// See WindowChrome.swift. Empty and as wide as the title's clearance.
    struct TitleClearance: GtkWidgetRepresentable {
        func makeGtkWidget(context: Context) -> Gtk.Widget { Gtk.Widget(gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)) }
        func updateGtkWidget(_ widget: Gtk.Widget, context: Context) {}

        func sizeThatFits(_ proposal: ProposedViewSize, gtkWidget: Gtk.Widget, context: Context) -> ViewSize {
            ViewSize(titleClearance(sidebarWidth: GtkChrome.shared.currentSidebarWidth), 0)
        }
    }

    /// The GTK side of the window chrome, through the C API:
    /// - no system title bar (an empty CSD title bar keeps the shadow and resize edges),
    /// - dragging the title area moves the window, double-clicking it maximizes (not over controls),
    /// - dark mode follows GNOME's color-scheme setting, and changes live (signal, no polling),
    /// - the sidebar slides closed and open on the frame clock.
    @MainActor
    final class GtkChrome {
        static let shared = GtkChrome()

        private var window: UnsafeMutablePointer<GtkWindow>?
        private var paned: OpaquePointer?
        private var onColorScheme: (ColorScheme) -> Void = { _ in }
        private var interfaceSettings: UnsafeMutablePointer<GSettings>?

        func install(on window: Gtk.ApplicationWindow, onColorScheme: @escaping (ColorScheme) -> Void) {
            self.onColorScheme = onColorScheme
            let pointer: UnsafeMutablePointer<GtkWindow> = cast(window.widgetPointer)
            guard self.window != pointer else { return }
            self.window = pointer

            // A hidden title bar widget: GTK keeps client-side decorations (shadow, resize edges)
            // but gives no height to it; a visible empty one still takes the theme's 46 px.
            let titlebar = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)
            gtk_widget_set_visible(titlebar, 0)
            gtk_window_set_titlebar(pointer, titlebar)
            // From the icon theme: build-linux.sh installs the app's icon and .desktop file under this name.
            gtk_window_set_icon_name(pointer, appIdentifier)

            roundCorners(pointer)
            LinuxGlass.shared.install(on: pointer)

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
                MainActor.assumeIsolated { GtkChrome.shared.contentReady() }
                return 0
            }, nil, nil)
        }

        /// Styles the content and opens the sidebar at its width (SwiftCrossUI's default is 200).
        fileprivate func contentReady() {
            styleContent()
            guard let window, let paned = Self.findPaned(gtk_window_get_child(window)) else { return }
            self.paned = paned
            gtk_paned_set_position(paned, Int32(sidebarWidth))
            g_signal_connect_data(cast(paned), "notify::position", unsafeBitCast(panedMoved, to: GCallback.self),
                                  nil, nil, GConnectFlags(rawValue: 0))
        }

        /// Dragging the divider: keeps an open sidebar within `sidebarWidthRange`, and remembers its
        /// width for the next time it opens.
        fileprivate func clampDraggedPosition() {
            guard slide == nil, let paned else { return }
            let position = Double(gtk_paned_get_position(paned))
            guard position > 0 else { return }
            let clamped = min(max(position, sidebarWidthRange.lowerBound), sidebarWidthRange.upperBound)
            if clamped != position { gtk_paned_set_position(paned, Int32(clamped)) }
            expandedWidth = Int32(clamped)
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
        private func styleContent() {
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
            // For the sidebar's and the title bar's CSS, which use the Mac's colors.
            if let window {
                if dark { gtk_widget_add_css_class(cast(window), "ippm-dark") } else { gtk_widget_remove_css_class(cast(window), "ippm-dark") }
            }
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

        // MARK: Title area

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
            guard let window, y < titleBarHeight, !isOverControl(x: x, y: y),
                  let surface = gtk_native_get_surface(cast(window)) else { return }
            var dx: Double = 0, dy: Double = 0
            gtk_native_get_surface_transform(cast(window), &dx, &dy)
            gdk_toplevel_begin_move(cast(surface), gtk_gesture_get_device(cast(gesture)),
                                    Int32(gtk_gesture_single_get_current_button(cast(gesture))),
                                    x + dx, y + dy, gtk_event_controller_get_current_event_time(cast(gesture)))
        }

        // MARK: Sidebar

        private var expandedWidth = Int32(sidebarWidth)
        /// The sidebar's sections: given the open width during a slide (see WindowChrome.swift).
        var sidebarContent: UnsafeMutablePointer<GtkWidget>?
        private var slide: SidebarSlide?
        private var slideStart: gint64 = 0

        /// The sidebar's width right now, read by `TitleClearance` while SwiftCrossUI lays out.
        var currentSidebarWidth: Double {
            paned.map { Double(gtk_paned_get_position($0)) } ?? sidebarWidth
        }

        /// Slides the sidebar closed or open: the divider moves every frame and its position
        /// signal lays the panes out (the sidebar accepts any width, so no minimum gets in the way).
        func toggleSidebar() {
            guard slide == nil, let paned else { return }
            let from = gtk_paned_get_position(paned)
            let closing = from > 0
            if closing { expandedWidth = from }
            slide = SidebarSlide(from: Double(from), to: closing ? 0 : Double(expandedWidth))
            if let sidebarContent { gtk_widget_set_size_request(sidebarContent, Int32(slide!.openWidth), -1) }
            // The clock starts on the first frame: if that frame comes late, the slide still plays.
            slideStart = 0
            gtk_widget_add_tick_callback(cast(paned), sidebarTick, nil, nil)
        }

        fileprivate func tick() -> Bool {
            guard var slide, let paned else { return false }
            let now = g_get_monotonic_time()
            if slideStart == 0 { slideStart = now }
            let elapsed = Double(now - slideStart) / 1_000_000
            let (width, done) = slide.width(after: elapsed)
            gtk_paned_set_position(paned, Int32(width))
            slide.record(layout: Double(g_get_monotonic_time() - now) / 1_000_000)
            self.slide = done ? nil : slide
            guard done else { return true }
            if let sidebarContent { gtk_widget_set_size_request(sidebarContent, -1, -1) }
            slide.logResult(elapsed: elapsed)
            return false
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
            guard presses == 2, y < titleBarHeight, !GtkChrome.shared.isOverControl(x: x, y: y) else { return }
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

    private let panedMoved: @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { _, _, _ in
        MainActor.assumeIsolated { GtkChrome.shared.clampDraggedPosition() }
    }

    private let sidebarTick: @convention(c) (UnsafeMutablePointer<GtkWidget>?, OpaquePointer?, gpointer?) -> gboolean = { _, _, _ in
        MainActor.assumeIsolated { GtkChrome.shared.tick() ? 1 : 0 }
    }
#endif
