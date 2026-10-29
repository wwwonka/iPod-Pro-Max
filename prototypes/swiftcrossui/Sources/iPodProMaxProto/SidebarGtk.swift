#if canImport(GtkBackend)
    import CGtk
    import Gtk
    import GtkBackend
    import SwiftCrossUI

    /// On GTK the sidebar is drawn like macOS's source list, to `SidebarMetrics`: one GtkListBox
    /// per section (native rows, selection and keyboard handling) under a header whose chevron
    /// shows on hover and collapses the section in a GtkRevealer. None of its labels go through
    /// SwiftCrossUI's layout, which measured every one of them on each click.
    ///
    /// It takes whatever width the split view gives it (zero once hidden); during a slide the chrome
    /// gives the sections the open width, kept scrolled to their right edge, so the rows slide with
    /// the pane's edge instead of squeezing.
    struct Sidebar: GtkWidgetRepresentable {
        // Bindings, not values: SwiftCrossUI used to hand a native view's updates the values it
        // was created with (see scripts/patches/representables.patch).
        @Binding var devices: [String]
        @Binding var library: Library?
        @Binding var selection: SidebarItem

        private var playlists: [Playlist] { library?.playlists ?? [] }

        func makeCoordinator() -> Coordinator { Coordinator() }

        func makeGtkWidget(context: Context) -> Gtk.Widget {
            installSidebarStyle()
            let content = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)!
            gtk_widget_add_css_class(content, "ippm-sidebar")
            context.coordinator.content = content
            GtkChrome.shared.sidebarContent = content
            // Scrolls horizontally without a scroll bar, so it can be narrower than its content.
            let scroll = gtk_scrolled_window_new()!
            gtk_widget_add_css_class(scroll, "ippm-sidebar-pane")
            gtk_scrolled_window_set_policy(cast(scroll), GTK_POLICY_EXTERNAL, GTK_POLICY_AUTOMATIC)
            gtk_scrolled_window_set_child(cast(scroll), content)
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
            let key = devices + ["|"] + playlists.map { $0.id + $0.name }
            if key != coordinator.key {
                coordinator.key = key
                coordinator.rebuild(sidebarSections(devices: devices, playlists: playlists))
            }
            coordinator.select(selection)
        }

        func sizeThatFits(_ proposal: ProposedViewSize, gtkWidget: Gtk.Widget, context: Context) -> ViewSize {
            ViewSize(proposal.width ?? sidebarWidth, proposal.height ?? 400)
        }

        @MainActor
        final class Coordinator {
            var content: UnsafeMutablePointer<GtkWidget>?
            var key: [String] = []
            var onSelect: (SidebarItem) -> Void = { _ in }

            private struct Section {
                var title: String
                var header: UnsafeMutablePointer<GtkWidget>
                var chevron: UnsafeMutablePointer<GtkWidget>
                var revealer: OpaquePointer
                var list: OpaquePointer
                /// Item of each row by index; nil for placeholders.
                var items: [SidebarItem?]
            }

            private var sections: [Section] = []
            /// Kept across rebuilds (a playlist added doesn't reopen a closed section).
            private var collapsed: Set<String> = []
            private var isSyncingSelection = false

            func rebuild(_ model: [SidebarSection]) {
                guard let content else { return }
                isSyncingSelection = true
                defer { isSyncingSelection = false }
                while let child = gtk_widget_get_first_child(content) { gtk_box_remove(cast(content), child) }
                sections = model.enumerated().map { index, section in makeSection(section, first: index == 0) }
                for section in sections {
                    gtk_box_append(cast(content), section.header)
                    gtk_box_append(cast(content), cast(section.revealer))
                }
            }

            private func makeSection(_ section: SidebarSection, first: Bool) -> Section {
                let open = !collapsed.contains(section.title)
                let header = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)!
                gtk_widget_add_css_class(header, "ippm-header")
                if first { gtk_widget_add_css_class(header, "ippm-first") }
                if !open { gtk_widget_add_css_class(header, "ippm-collapsed") }
                let title = gtk_label_new(section.title)!
                gtk_label_set_xalign(cast(title), 0)
                gtk_widget_set_hexpand(title, 1)
                gtk_box_append(cast(header), title)
                let chevron = gtk_button_new()!
                gtk_widget_add_css_class(chevron, "ippm-chevron")
                gtk_widget_set_tooltip_text(chevron, open ? "Hide" : "Show")
                gtk_button_set_child(cast(chevron), gtk_image_new_from_icon_name("pan-down-symbolic"))
                g_signal_connect_data(cast(chevron), "clicked", unsafeBitCast(chevronClicked, to: GCallback.self),
                                      Unmanaged.passUnretained(self).toOpaque(), nil, GConnectFlags(rawValue: 0))
                gtk_box_append(cast(header), chevron)

                let list = gtk_list_box_new()!
                gtk_widget_add_css_class(list, "ippm-list")
                gtk_list_box_set_selection_mode(cast(list), GTK_SELECTION_SINGLE)
                let me = Unmanaged.passUnretained(self).toOpaque()
                g_signal_connect_data(cast(list), "row-selected", unsafeBitCast(rowSelected, to: GCallback.self),
                                      me, nil, GConnectFlags(rawValue: 0))
                g_signal_connect_data(cast(list), "keynav-failed", unsafeBitCast(keynavFailed, to: GCallback.self),
                                      me, nil, GConnectFlags(rawValue: 0))
                for row in section.rows { gtk_list_box_append(cast(list), Self.makeRow(row)) }

                let revealer = gtk_revealer_new()!
                gtk_revealer_set_transition_type(cast(revealer), GTK_REVEALER_TRANSITION_TYPE_SLIDE_DOWN)
                gtk_revealer_set_transition_duration(cast(revealer), UInt32(SidebarMetrics.collapseDuration * 1000))
                gtk_revealer_set_reveal_child(cast(revealer), open ? 1 : 0)
                gtk_revealer_set_child(cast(revealer), list)
                return Section(title: section.title, header: header, chevron: chevron, revealer: cast(revealer),
                               list: cast(list), items: section.rows.map(\.item))
            }

            /// Icon and title in a cell inset like the source list's selection.
            private static func makeRow(_ row: SidebarSection.Row) -> UnsafeMutablePointer<GtkWidget> {
                let cell = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, Int32(SidebarMetrics.textX - SidebarMetrics.iconX - SidebarMetrics.iconWidth))!
                gtk_widget_add_css_class(cell, "ippm-cell")
                if row.item == nil { gtk_widget_add_css_class(cell, "ippm-dim") }
                let glyph = gtk_label_new(nil)!
                gtk_widget_add_css_class(glyph, "ippm-icon")
                // 13 pt: the widest glyphs (film) still fit the icon column, as on macOS.
                gtk_label_set_markup(cast(glyph), symbolMarkup(row.icon, pointSize: 13, tint: nil, dark: false))
                let label = gtk_label_new(row.title)!
                gtk_widget_add_css_class(label, "ippm-text")
                gtk_label_set_xalign(cast(label), 0)
                gtk_label_set_ellipsize(cast(label), PANGO_ELLIPSIZE_END)
                gtk_box_append(cast(cell), glyph)
                gtk_box_append(cast(cell), label)
                let listRow = gtk_list_box_row_new()!
                gtk_list_box_row_set_child(cast(listRow), cell)
                gtk_list_box_row_set_selectable(cast(listRow), row.item == nil ? 0 : 1)
                gtk_list_box_row_set_activatable(cast(listRow), row.item == nil ? 0 : 1)
                return listRow
            }

            func select(_ selection: SidebarItem) {
                for section in sections {
                    guard let index = section.items.firstIndex(of: selection) else { continue }
                    guard let row = gtk_list_box_get_row_at_index(section.list, Int32(index)),
                          gtk_list_box_get_selected_row(section.list) != row else { return }
                    isSyncingSelection = true
                    for other in sections where other.list != section.list { gtk_list_box_unselect_all(other.list) }
                    gtk_list_box_select_row(section.list, row)
                    isSyncingSelection = false
                    return
                }
            }

            /// One selection across the sections' lists.
            fileprivate func selected(_ row: OpaquePointer?, in list: OpaquePointer?) {
                guard !isSyncingSelection, let row, let section = sections.first(where: { $0.list == list }) else { return }
                let index = Int(gtk_list_box_row_get_index(cast(row)))
                guard index >= 0, index < section.items.count, let item = section.items[index] else { return }
                isSyncingSelection = true
                for other in sections where other.list != list { gtk_list_box_unselect_all(other.list) }
                isSyncingSelection = false
                onSelect(item)
            }

            /// The arrow keys go on to the next open section, as in a single source list.
            fileprivate func leaveList(_ list: OpaquePointer?, down: Bool) -> Bool {
                guard let index = sections.firstIndex(where: { $0.list == list }) else { return false }
                let order = down ? Array(sections[(index + 1)...]) : sections[..<index].reversed()
                for section in order where gtk_revealer_get_reveal_child(section.revealer) != 0 {
                    let indices = section.items.indices.filter { section.items[$0] != nil }
                    guard let target = down ? indices.first : indices.last,
                          let row = gtk_list_box_get_row_at_index(section.list, Int32(target)) else { continue }
                    gtk_list_box_select_row(section.list, row)
                    gtk_widget_grab_focus(cast(row))
                    return true
                }
                return false
            }

            fileprivate func toggle(chevron: OpaquePointer?) {
                guard let section = sections.first(where: { OpaquePointer($0.chevron) == chevron }) else { return }
                let open = gtk_revealer_get_reveal_child(section.revealer) == 0
                gtk_revealer_set_reveal_child(section.revealer, open ? 1 : 0)
                if open {
                    collapsed.remove(section.title)
                    gtk_widget_remove_css_class(section.header, "ippm-collapsed")
                } else {
                    collapsed.insert(section.title)
                    gtk_widget_add_css_class(section.header, "ippm-collapsed")
                }
                gtk_widget_set_tooltip_text(section.chevron, open ? "Hide" : "Show")
            }
        }
    }

    /// macOS's source list, in GTK CSS (installed once for the display). Colors are the Mac's; the
    /// window carries `ippm-dark` in dark mode (WindowChromeGtk.swift).
    @MainActor private var sidebarStyleInstalled = false

    @MainActor private func installSidebarStyle() {
        guard !sidebarStyleInstalled else { return }
        sidebarStyleInstalled = true
        typealias M = SidebarMetrics
        let provider = gtk_css_provider_new()!
        gtk_css_provider_load_from_string(provider, """
            .ippm-sidebar-pane { background-color: #EBEBEB; }
            .ippm-dark .ippm-sidebar-pane { background-color: #2C2C2C; }
            .ippm-sidebar { margin-top: \(Int(titleBarHeight))px; }
            .ippm-header { margin: \(Int(M.sectionGap))px \(Int(M.chevronTrailing))px 0 \(Int(M.headerTextX))px; min-height: \(Int(M.headerHeight))px; }
            .ippm-header.ippm-first { margin-top: \(Int(M.topGap))px; }
            .ippm-header > label { font-size: \(Int(M.headerFontSize))px; font-weight: bold; color: alpha(currentColor, 0.5); }
            .ippm-chevron { min-width: \(Int(M.chevronWidth))px; min-height: \(Int(M.headerHeight))px; padding: 0; margin: 0;
                border: none; background: none; box-shadow: none; outline: none; color: alpha(currentColor, 0.5);
                opacity: 0; transition: opacity 150ms ease-in-out; }
            .ippm-header:hover .ippm-chevron { opacity: 1; }
            .ippm-chevron image { -gtk-icon-size: 10px; transition: -gtk-icon-transform \(Int(M.collapseDuration * 1000))ms ease-in-out; }
            .ippm-collapsed .ippm-chevron image { -gtk-icon-transform: rotate(-90deg); }
            .ippm-list, .ippm-list > row { background: none; padding: 0; margin: 0; min-height: 0; border: none; box-shadow: none; outline: none; }
            .ippm-cell { min-height: \(Int(M.rowHeight))px; margin: 0 \(Int(M.selectionInset))px;
                padding: 0 \(Int(M.iconX - M.selectionInset))px; border-radius: \(Int(M.selectionRadius))px; }
            .ippm-text { font-size: \(Int(M.rowFontSize))px; }
            .ippm-icon { min-width: \(Int(M.iconWidth))px; color: #007AFF; }
            .ippm-dark .ippm-icon { color: #0A84FF; }
            .ippm-dim > label { color: alpha(currentColor, 0.5); }
            .ippm-dim > .ippm-icon { color: #8A8A8E; }
            .ippm-dark .ippm-dim > .ippm-icon { color: #98989D; }
            .ippm-list > row:selected > .ippm-cell { background-color: \(css(sidebarSelectionRGB(focused: false, dark: false))); }
            .ippm-dark .ippm-list > row:selected > .ippm-cell { background-color: \(css(sidebarSelectionRGB(focused: false, dark: true))); }
            .ippm-sidebar:focus-within .ippm-list > row:selected > .ippm-cell { background-color: \(css(sidebarSelectionRGB(focused: true, dark: false))); color: white; }
            .ippm-dark .ippm-sidebar:focus-within .ippm-list > row:selected > .ippm-cell { background-color: \(css(sidebarSelectionRGB(focused: true, dark: true))); }
            .ippm-sidebar:focus-within .ippm-list > row:selected .ippm-icon { color: white; }
            """)
        gtk_style_context_add_provider_for_display(gdk_display_get_default(), cast(provider), 800)
    }

    func css(_ rgb: (r: UInt8, g: UInt8, b: UInt8)) -> String {
        "rgb(\(rgb.r), \(rgb.g), \(rgb.b))"
    }

    /// Keeps the content scrolled to its right edge whenever the sidebar's width (or a stray
    /// horizontal scroll) moves it.
    private let pinToRightEdge: @convention(c) (UnsafeMutablePointer<GtkAdjustment>?, gpointer?) -> Void = { adjustment, _ in
        let end = gtk_adjustment_get_upper(adjustment) - gtk_adjustment_get_page_size(adjustment)
        if gtk_adjustment_get_value(adjustment) != end { gtk_adjustment_set_value(adjustment, end) }
    }

    private let rowSelected: @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { list, row, data in
        guard let data else { return }
        let coordinator = Unmanaged<Sidebar.Coordinator>.fromOpaque(data).takeUnretainedValue()
        MainActor.assumeIsolated { coordinator.selected(row, in: list) }
    }

    private let keynavFailed: @convention(c) (OpaquePointer?, GtkDirectionType, gpointer?) -> gboolean = { list, direction, data in
        guard let data, direction == GTK_DIR_DOWN || direction == GTK_DIR_UP else { return 0 }
        let coordinator = Unmanaged<Sidebar.Coordinator>.fromOpaque(data).takeUnretainedValue()
        return MainActor.assumeIsolated { coordinator.leaveList(list, down: direction == GTK_DIR_DOWN) } ? 1 : 0
    }

    private let chevronClicked: @convention(c) (OpaquePointer?, gpointer?) -> Void = { button, data in
        guard let data else { return }
        let coordinator = Unmanaged<Sidebar.Coordinator>.fromOpaque(data).takeUnretainedValue()
        MainActor.assumeIsolated { coordinator.toggle(chevron: button) }
    }
#endif
