import SwiftCrossUI

// The "By Artist" list: a native, virtualized list on each platform, like the track table.
// SwiftCrossUI's List made a view per artist and asked for the height of all of them, which
// became the window's minimum height: switching modes resized the window to over 1,200 pt and
// kept it there.

#if canImport(AppKitBackend)
    import AppKit
    import AppKitBackend

    struct ArtistList: NSViewRepresentable {
        var artists: [NamedGroup]
        @Binding var selection: String?

        func makeCoordinator() -> Coordinator { Coordinator() }

        func makeNSView(context: Context) -> NSScrollView {
            let table = NSTableView()
            if #available(macOS 11, *) { table.style = .plain }
            table.headerView = nil
            table.rowHeight = 24
            table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("artist")))
            table.dataSource = context.coordinator
            table.delegate = context.coordinator
            let scroll = NSScrollView()
            scroll.documentView = table
            scroll.hasVerticalScroller = true
            scroll.drawsBackground = false
            return scroll
        }

        func updateNSView(_ scroll: NSScrollView, context: Context) {
            guard let table = scroll.documentView as? NSTableView else { return }
            let coordinator = context.coordinator
            coordinator.onSelect = { selection = $0 }
            if !coordinator.artists.sameStorage(as: artists) {
                coordinator.artists = artists
                table.reloadData()
            }
            let row = selection.flatMap { name in artists.firstIndex { $0.id == name } } ?? -1
            if table.selectedRow != row {
                coordinator.isSyncing = true
                if row >= 0 { table.selectRowIndexes([row], byExtendingSelection: false) } else { table.deselectAll(nil) }
                coordinator.isSyncing = false
            }
        }

        func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> ViewSize {
            ViewSize(proposal.width ?? 250, proposal.height ?? 400)
        }

        final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
            var artists: [NamedGroup] = []
            var onSelect: (String?) -> Void = { _ in }
            var isSyncing = false

            func numberOfRows(in tableView: NSTableView) -> Int { artists.count }

            func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
                let id = NSUserInterfaceItemIdentifier("artistCell")
                let cell = tableView.makeView(withIdentifier: id, owner: nil) as? ArtistCell ?? ArtistCell(id: id)
                cell.name.stringValue = artists[row].id
                cell.count.stringValue = "\(artists[row].count)"
                return cell
            }

            func tableViewSelectionDidChange(_ notification: Notification) {
                guard !isSyncing, let table = notification.object as? NSTableView else { return }
                onSelect(table.selectedRow >= 0 ? artists[table.selectedRow].id : nil)
            }
        }

        /// The artist's name, and its song count in gray at the right.
        final class ArtistCell: NSTableCellView {
            let name = NSTextField(labelWithString: "")
            let count = NSTextField(labelWithString: "")

            init(id: NSUserInterfaceItemIdentifier) {
                super.init(frame: .zero)
                identifier = id
                name.lineBreakMode = .byTruncatingTail
                count.textColor = .secondaryLabelColor
                for field in [name, count] {
                    field.translatesAutoresizingMaskIntoConstraints = false
                    addSubview(field)
                }
                name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                NSLayoutConstraint.activate([
                    name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
                    name.centerYAnchor.constraint(equalTo: centerYAnchor),
                    count.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 8),
                    count.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
                    count.centerYAnchor.constraint(equalTo: centerYAnchor),
                ])
            }

            required init?(coder: NSCoder) { fatalError() }
        }
    }
#elseif canImport(GtkBackend)
    import CGtk
    import Gtk
    import GtkBackend

    /// A GtkListView over a string list of the names; cells read the counts from a Swift array.
    struct ArtistList: GtkWidgetRepresentable {
        var artists: [NamedGroup]
        @Binding var selection: String?

        func makeCoordinator() -> Coordinator { Coordinator() }

        func makeGtkWidget(context: Context) -> Gtk.Widget {
            let coordinator = context.coordinator
            // The selection takes the model's reference (transfer full): give it one of its own.
            g_object_ref(cast(coordinator.model))
            let selectionModel = gtk_single_selection_new(cast(coordinator.model))!
            gtk_single_selection_set_autoselect(selectionModel, 0)
            gtk_single_selection_set_can_unselect(selectionModel, 1)
            coordinator.selectionModel = selectionModel
            // Each handler owns a weak reference to the coordinator; GLib releases it with the handler,
            // so a signal after the view is gone finds nothing rather than a freed object.
            g_signal_connect_data(cast(selectionModel), "notify::selected", unsafeBitCast(artistSelected, to: GCallback.self),
                                  ArtistBinding.retained(coordinator), releaseArtistBinding, GConnectFlags(rawValue: 0))
            let factory = gtk_signal_list_item_factory_new()
            g_signal_connect_data(cast(factory), "setup", unsafeBitCast(setupArtist, to: GCallback.self), nil, nil, GConnectFlags(rawValue: 0))
            g_signal_connect_data(cast(factory), "bind", unsafeBitCast(bindArtist, to: GCallback.self),
                                  ArtistBinding.retained(coordinator), releaseArtistBinding, GConnectFlags(rawValue: 0))
            let list = gtk_list_view_new(cast(selectionModel), factory)!
            let scroll = gtk_scrolled_window_new()!
            gtk_scrolled_window_set_policy(cast(scroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
            gtk_scrolled_window_set_child(cast(scroll), list)
            return Gtk.Widget(scroll)
        }

        func updateGtkWidget(_ widget: Gtk.Widget, context: Context) {
            let coordinator = context.coordinator
            coordinator.onSelect = { selection = $0 }
            coordinator.show(artists)
            let position = selection.flatMap { name in artists.firstIndex { $0.id == name } }.map(UInt32.init)
                ?? UInt32.max  // GTK_INVALID_LIST_POSITION
            if let model = coordinator.selectionModel, gtk_single_selection_get_selected(model) != position {
                coordinator.isSyncing = true
                gtk_single_selection_set_selected(model, position)
                coordinator.isSyncing = false
            }
        }

        func sizeThatFits(_ proposal: ProposedViewSize, gtkWidget: Gtk.Widget, context: Context) -> ViewSize {
            ViewSize(proposal.width ?? 250, proposal.height ?? 400)
        }

        @MainActor
        final class Coordinator {
            let model = gtk_string_list_new(nil)!
            var selectionModel: OpaquePointer?
            var artists: [NamedGroup] = []
            var onSelect: (String?) -> Void = { _ in }
            var isSyncing = false

            func show(_ newArtists: [NamedGroup]) {
                guard !artists.sameStorage(as: newArtists) else { return }
                let old = artists.count
                artists = newArtists
                let names = newArtists.map { strdup($0.id) }
                defer { names.forEach { free($0) } }
                var items = names.map { UnsafePointer($0) } + [nil]
                // Replacing the items drops the selection: not the user's doing.
                isSyncing = true
                items.withUnsafeMutableBufferPointer {
                    gtk_string_list_splice(model, 0, UInt32(old), $0.baseAddress)
                }
                isSyncing = false
            }

            fileprivate func selectionChanged() {
                guard !isSyncing, let selectionModel else { return }
                let position = Int(gtk_single_selection_get_selected(selectionModel))
                onSelect(position < artists.count ? artists[position].id : nil)
            }

            deinit {
                g_object_unref(cast(model))
            }
        }
    }

    final class ArtistBinding {
        weak var coordinator: ArtistList.Coordinator?

        static func retained(_ coordinator: ArtistList.Coordinator) -> UnsafeMutableRawPointer {
            let binding = ArtistBinding()
            binding.coordinator = coordinator
            return Unmanaged.passRetained(binding).toOpaque()
        }
    }

    private let releaseArtistBinding: @convention(c) (gpointer?, UnsafeMutablePointer<GClosure>?) -> Void = { data, _ in
        guard let data else { return }
        Unmanaged<ArtistBinding>.fromOpaque(data).release()
    }

    private let setupArtist: @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { _, item, _ in
        let box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
        gtk_widget_set_margin_start(box, 8)
        gtk_widget_set_margin_end(box, 8)
        let name = gtk_label_new(nil)!
        gtk_label_set_xalign(cast(name), 0)
        gtk_label_set_ellipsize(cast(name), PANGO_ELLIPSIZE_END)
        gtk_widget_set_hexpand(name, 1)
        let count = gtk_label_new(nil)!
        gtk_widget_add_css_class(count, "dim-label")
        gtk_box_append(cast(box), name)
        gtk_box_append(cast(box), count)
        gtk_list_item_set_child(cast(item), box)
    }

    private let bindArtist: @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { _, item, data in
        guard let data, let box = gtk_list_item_get_child(cast(item)),
              let name = gtk_widget_get_first_child(box), let count = gtk_widget_get_next_sibling(name) else { return }
        let position = Int(gtk_list_item_get_position(cast(item)))
        MainActor.assumeIsolated {
            guard let coordinator = Unmanaged<ArtistBinding>.fromOpaque(data).takeUnretainedValue().coordinator,
                  position < coordinator.artists.count else { return }
            gtk_label_set_text(cast(name), coordinator.artists[position].id)
            gtk_label_set_text(cast(count), "\(coordinator.artists[position].count)")
        }
    }

    private let artistSelected: @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { _, _, data in
        guard let data else { return }
        MainActor.assumeIsolated {
            Unmanaged<ArtistBinding>.fromOpaque(data).takeUnretainedValue().coordinator?.selectionChanged()
        }
    }
#elseif canImport(WinUIBackend)
    import UWP
    import WinUI
    import WinUIBackend

    /// A ListView of rows with the name and, in gray at the right, the song count.
    struct ArtistList: WinUIElementRepresentable {
        var artists: [NamedGroup]
        @SwiftCrossUI.Binding var selection: String?

        func makeCoordinator() -> Coordinator { Coordinator() }

        func makeWinUIElement(context: Context) -> ListView {
            let list = ListView()
            list.selectionMode = .single
            list.selectionChanged.addHandler { [weak coordinator = context.coordinator, weak list] _, _ in
                guard let list else { return }
                MainActor.assumeIsolated { coordinator?.selectionChanged(Int(list.selectedIndex)) }
            }
            return list
        }

        func updateWinUIElement(_ list: ListView, context: Context) {
            let coordinator = context.coordinator
            coordinator.onSelect = { selection = $0 }
            if !coordinator.artists.sameStorage(as: artists) {
                coordinator.artists = artists
                coordinator.isSyncing = true
                list.items.clear()
                for artist in artists { list.items.append(Self.row(artist)) }
                coordinator.isSyncing = false
            }
            let index = Int32(selection.flatMap { name in artists.firstIndex { $0.id == name } } ?? -1)
            if list.selectedIndex != index {
                coordinator.isSyncing = true
                list.selectedIndex = index
                coordinator.isSyncing = false
            }
        }

        func sizeThatFits(_ proposal: ProposedViewSize, winUIElement: ListView, context: Context) -> ViewSize {
            ViewSize(proposal.width ?? 250, proposal.height ?? 400)
        }

        private static func row(_ artist: NamedGroup) -> ListViewItem {
            let grid = WinUI.Grid()
            for width in [GridLength(value: 1, gridUnitType: .star), GridLength(value: 1, gridUnitType: .auto)] {
                let column = ColumnDefinition()
                column.width = width
                grid.columnDefinitions.append(column)
            }
            let name = TextBlock()
            name.text = artist.id
            name.textTrimming = .characterEllipsis
            let count = TextBlock()
            count.text = "\(artist.count)"
            count.opacity = 0.5
            WinUI.Grid.setColumn(count, 1)
            grid.children.append(name)
            grid.children.append(count)
            let item = ListViewItem()
            item.content = grid
            item.horizontalContentAlignment = .stretch
            return item
        }

        @MainActor
        final class Coordinator {
            var artists: [NamedGroup] = []
            var onSelect: (String?) -> Void = { _ in }
            var isSyncing = false

            func selectionChanged(_ index: Int) {
                guard !isSyncing else { return }
                onSelect(index >= 0 && index < artists.count ? artists[index].id : nil)
            }
        }
    }
#endif
