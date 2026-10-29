#if canImport(GtkBackend)
    import CGtk
    import Gtk
    import GtkBackend
    import SwiftCrossUI

    /// On GTK the sidebar is a GtkListBox with the `navigation-sidebar` style, the one GNOME apps
    /// use: native rows, selection and keyboard handling, and none of its labels go through
    /// SwiftCrossUI's layout, which measured every one of them on each click. It takes whatever
    /// width the split view gives it (zero once hidden); during a slide the chrome gives the list
    /// the open width, kept scrolled to its right edge, so the rows slide with the pane's edge
    /// instead of squeezing.
    struct Sidebar: GtkWidgetRepresentable {
        // Bindings, not values: SwiftCrossUI hands a native view's updates the values it was
        // created with, so the playlists loaded later never showed.
        @Binding var devices: [String]
        @Binding var library: Library?
        @Binding var selection: SidebarItem

        private var playlists: [Playlist] { library?.playlists ?? [] }

        func makeCoordinator() -> Coordinator { Coordinator() }

        func makeGtkWidget(context: Context) -> Gtk.Widget {
            let coordinator = context.coordinator
            let list = gtk_list_box_new()!
            coordinator.list = cast(list)
            gtk_widget_add_css_class(list, "navigation-sidebar")
            // Room for the traffic lights and the toggle drawn over the window's corner.
            gtk_widget_set_margin_top(list, 52)
            gtk_widget_set_margin_start(list, 6)
            gtk_widget_set_margin_end(list, 6)
            g_signal_connect_data(cast(list), "row-selected", unsafeBitCast(rowSelected, to: GCallback.self),
                                  Unmanaged.passUnretained(coordinator).toOpaque(), nil, GConnectFlags(rawValue: 0))
            GtkChrome.shared.sidebarList = list
            // Scrolls horizontally without a scroll bar, so it can be narrower than the list.
            let scroll = gtk_scrolled_window_new()!
            gtk_scrolled_window_set_policy(cast(scroll), GTK_POLICY_EXTERNAL, GTK_POLICY_AUTOMATIC)
            gtk_scrolled_window_set_child(cast(scroll), list)
            gtk_widget_set_vexpand(scroll, 1)
            let horizontal = gtk_scrolled_window_get_hadjustment(cast(scroll))
            for signal in ["changed", "value-changed"] {
                g_signal_connect_data(cast(horizontal), signal, unsafeBitCast(pinToRightEdge, to: GCallback.self),
                                      nil, nil, GConnectFlags(rawValue: 0))
            }
            return Gtk.Widget(scroll)
        }

        func updateGtkWidget(_ widget: Gtk.Widget, context: Context) {
            let coordinator = context.coordinator
            coordinator.onSelect = { selection = $0 }
            let dark = context.environment.colorScheme == .dark
            let key = devices + ["|"] + playlists.map { $0.id + $0.name } + [dark ? "dark" : "light"]
            if key != coordinator.key {
                coordinator.key = key
                coordinator.rebuild(devices: devices, playlists: playlists, dark: dark)
            }
            coordinator.select(selection)
        }

        func sizeThatFits(_ proposal: ProposedViewSize, gtkWidget: Gtk.Widget, context: Context) -> ViewSize {
            ViewSize(proposal.width ?? sidebarWidth, proposal.height ?? 400)
        }

        final class Coordinator {
            var list: OpaquePointer?
            var key: [String] = []
            var onSelect: (SidebarItem) -> Void = { _ in }
            /// Item of each row by index; nil for headers and placeholders.
            private var items: [SidebarItem?] = []
            private var isSyncingSelection = false

            func rebuild(devices: [String], playlists: [Playlist], dark: Bool) {
                guard let list else { return }
                isSyncingSelection = true
                gtk_list_box_remove_all(list)
                items = []
                header("iPods")
                if devices.isEmpty {
                    row("No iPod connected", icon: "ipod", item: nil, dark: dark)
                } else {
                    devices.forEach { row($0, icon: "ipod", item: .device($0), dark: dark) }
                }
                header("Library")
                SidebarItem.library.forEach { row($0.title, icon: $0.icon, item: $0, dark: dark) }
                header("Playlists")
                playlists.forEach { row($0.name, icon: "music.note.list", item: .playlist($0.id), dark: dark) }
                row("New Playlist…", icon: "plus", item: nil, dark: dark)
                isSyncingSelection = false
            }

            func select(_ selection: SidebarItem) {
                guard let list, let index = items.firstIndex(of: selection),
                      let row = gtk_list_box_get_row_at_index(list, Int32(index)),
                      gtk_list_box_get_selected_row(list) != row
                else { return }
                isSyncingSelection = true
                gtk_list_box_select_row(list, row)
                isSyncingSelection = false
            }

            fileprivate func selected(_ index: Int32) {
                guard !isSyncingSelection, index >= 0, Int(index) < items.count, let item = items[Int(index)] else { return }
                onSelect(item)
            }

            private func header(_ title: String) {
                let label = gtk_label_new(title)!
                gtk_label_set_xalign(cast(label), 0)
                gtk_widget_add_css_class(label, "caption-heading")
                gtk_widget_add_css_class(label, "dim-label")
                gtk_widget_set_margin_top(label, items.isEmpty ? 4 : 14)
                append(label, item: nil, selectable: false)
            }

            private func row(_ title: String, icon: String, item: SidebarItem?, dark: Bool) {
                let box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
                let glyph = gtk_label_new(nil)!
                gtk_label_set_markup(cast(glyph), symbolMarkup(icon, pointSize: 14,
                                                               tint: item == nil ? .secondary : .accent, dark: dark))
                gtk_widget_set_size_request(glyph, 20, -1)
                let label = gtk_label_new(title)!
                gtk_label_set_xalign(cast(label), 0)
                gtk_label_set_ellipsize(cast(label), PANGO_ELLIPSIZE_END)
                if item == nil { gtk_widget_add_css_class(label, "dim-label") }
                gtk_box_append(cast(box), glyph)
                gtk_box_append(cast(box), label)
                append(box, item: item, selectable: item != nil)
            }

            private func append(_ child: UnsafeMutablePointer<GtkWidget>, item: SidebarItem?, selectable: Bool) {
                guard let list else { return }
                let row = gtk_list_box_row_new()!
                gtk_list_box_row_set_child(cast(row), child)
                gtk_list_box_row_set_selectable(cast(row), selectable ? 1 : 0)
                gtk_list_box_row_set_activatable(cast(row), selectable ? 1 : 0)
                gtk_list_box_append(list, row)
                items.append(item)
            }
        }
    }


    /// Keeps the list scrolled to its right edge whenever the sidebar's width (or a stray
    /// horizontal scroll) moves it.
    private let pinToRightEdge: @convention(c) (UnsafeMutablePointer<GtkAdjustment>?, gpointer?) -> Void = { adjustment, _ in
        let end = gtk_adjustment_get_upper(adjustment) - gtk_adjustment_get_page_size(adjustment)
        if gtk_adjustment_get_value(adjustment) != end { gtk_adjustment_set_value(adjustment, end) }
    }

    private let rowSelected: @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { _, row, data in
        guard let row, let data else { return }
        let coordinator = Unmanaged<Sidebar.Coordinator>.fromOpaque(data).takeUnretainedValue()
        let index = gtk_list_box_row_get_index(cast(row))
        MainActor.assumeIsolated { coordinator.selected(index) }
    }
#endif
