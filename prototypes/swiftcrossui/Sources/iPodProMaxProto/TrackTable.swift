import SwiftCrossUI

// SwiftCrossUI's `Table` builds a widget per cell and lays every row out on each update: 5,000
// songs meant 30,000 views and seconds per sidebar click. On macOS the tracks go in a plain
// NSTableView instead, which only makes the visible rows and reuses them while scrolling.

/// `width` is in points for fixed columns, and a share of the remaining width when below 1.
private let columns: [(title: String, width: Double, value: KeyPath<TrackRow, String>)] = [
    ("#", 36, \.number),
    ("Title", 0.4, \.title),
    ("Artist", 0.3, \.artist),
    ("Album", 0.3, \.album),
    ("Year", 56, \.year),
    ("Time", 56, \.duration),
]

#if canImport(AppKitBackend)
    import AppKit
    import AppKitBackend

    struct TrackTable: NSViewRepresentable {
        /// nil keeps the rows already shown.
        var rows: [TrackRow]?

        func makeCoordinator() -> Coordinator { Coordinator() }

        func makeNSView(context: Context) -> NSScrollView {
            let table = NSTableView()
            table.style = .inset
            table.usesAlternatingRowBackgroundColors = true
            table.allowsMultipleSelection = true
            table.columnAutoresizingStyle = .noColumnAutoresizing
            for (i, column) in columns.enumerated() {
                let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("\(i)"))
                c.title = column.title
                c.width = column.width >= 1 ? column.width : 150
                table.addTableColumn(c)
            }
            table.dataSource = context.coordinator
            table.delegate = context.coordinator

            let scroll = TrackScrollView()
            scroll.documentView = table
            scroll.hasVerticalScroller = true
            scroll.drawsBackground = false
            return scroll
        }

        func updateNSView(_ scroll: NSScrollView, context: Context) {
            let coordinator = context.coordinator
            // Same array storage means same rows: skip the reload on unrelated redraws.
            guard let rows, !coordinator.rows.sameStorage(as: rows) else { return }
            coordinator.rows = rows
            (scroll.documentView as? NSTableView)?.reloadData()
        }

        final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
            var rows: [TrackRow] = []
            private let cellID = NSUserInterfaceItemIdentifier("cell")

            func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

            func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
                guard let tableColumn, let index = Int(tableColumn.identifier.rawValue) else { return nil }
                let field: NSTextField
                if let reused = tableView.makeView(withIdentifier: cellID, owner: nil) as? NSTextField {
                    field = reused
                } else {
                    field = NSTextField(labelWithString: "")
                    field.identifier = cellID
                    field.lineBreakMode = .byTruncatingTail
                }
                field.stringValue = rows[row][keyPath: columns[index].value]
                return field
            }
        }
    }

    /// Lays the columns out on every resize so all of them fit, as SwiftUI's Table does.
    final class TrackScrollView: NSScrollView {
        override func tile() {
            super.tile()
            guard let table = documentView as? NSTableView, table.tableColumns.count == columns.count
            else { return }
            let spacing = table.intercellSpacing.width * CGFloat(columns.count)
            let fixed = columns.filter { $0.width >= 1 }.reduce(0) { $0 + $1.width }
            let flexible = max(0, contentView.bounds.width - spacing - fixed - 24)
            for (column, spec) in zip(table.tableColumns, columns) {
                column.width = spec.width >= 1 ? spec.width : (flexible * spec.width).rounded(.down)
            }
        }
    }

    extension Array {
        /// O(1) identity check: true when both arrays share one buffer (copies, not equal values).
        fileprivate func sameStorage(as other: [Element]) -> Bool {
            count == other.count
                && withUnsafeBufferPointer { a in other.withUnsafeBufferPointer { a.baseAddress == $0.baseAddress } }
        }
    }

    /// The window's own background color, following light and dark mode.
    struct WindowBackground: NSViewRepresentable {
        func makeNSView(context: Context) -> NSBox {
            let box = NSBox()
            box.boxType = .custom
            box.borderWidth = 0
            box.fillColor = .windowBackgroundColor
            return box
        }

        func updateNSView(_ box: NSBox, context: Context) {}
    }
#elseif canImport(GtkBackend)
    import CGtk
    import Gtk
    import GtkBackend

    /// GTK: a GtkColumnView, GTK 4's virtualized table, called through the C API since
    /// SwiftCrossUI doesn't wrap it (and its GtkBackend has no Table at all). The model only
    /// holds one empty item per row: cells read the row by position from a Swift array.
    struct TrackTable: GtkWidgetRepresentable {
        /// nil keeps the rows already shown.
        var rows: [TrackRow]?

        func makeCoordinator() -> Coordinator { Coordinator() }

        func makeGtkWidget(context: Context) -> Gtk.Widget {
            let coordinator = context.coordinator
            let view = gtk_column_view_new(gtk_multi_selection_new(cast(coordinator.model)))!
            gtk_column_view_set_show_column_separators(cast(view), 0)
            gtk_widget_add_css_class(view, "data-table")
            for (index, column) in columns.enumerated() {
                let factory = gtk_signal_list_item_factory_new()
                let binding = Unmanaged.passRetained(CellBinding(coordinator: coordinator, column: index))
                coordinator.bindings.append(binding)
                g_signal_connect_data(cast(factory), "setup", unsafeBitCast(setupCell, to: GCallback.self), nil, nil, GConnectFlags(rawValue: 0))
                g_signal_connect_data(cast(factory), "bind", unsafeBitCast(bindCell, to: GCallback.self),
                                      binding.toOpaque(), nil, GConnectFlags(rawValue: 0))
                let c = gtk_column_view_column_new(column.title, cast(factory))
                if column.width >= 1 {
                    gtk_column_view_column_set_fixed_width(c, Int32(column.width))
                } else {
                    gtk_column_view_column_set_expand(c, 1)
                }
                gtk_column_view_column_set_resizable(c, 1)
                gtk_column_view_append_column(cast(view), c)
                g_object_unref(cast(c))
            }
            let scroll = gtk_scrolled_window_new()!
            gtk_scrolled_window_set_child(cast(scroll), view)
            gtk_widget_set_hexpand(scroll, 1)
            gtk_widget_set_vexpand(scroll, 1)
            return Gtk.Widget(scroll)
        }

        func updateGtkWidget(_ widget: Gtk.Widget, context: Context) {
            guard let rows else { return }
            context.coordinator.show(rows)
        }

        final class Coordinator {
            let model = gtk_string_list_new(nil)!
            var rows: [TrackRow] = []
            var bindings: [Unmanaged<CellBinding>] = []

            /// Replaces every item, so GTK rebinds the visible cells: O(rows) tiny objects, no widgets.
            func show(_ newRows: [TrackRow]) {
                let old = rows.count
                rows = newRows
                let empty = strdup("")
                defer { free(empty) }
                var items = [UnsafePointer<CChar>?](repeating: UnsafePointer(empty), count: newRows.count)
                items.append(nil)
                items.withUnsafeMutableBufferPointer {
                    gtk_string_list_splice(model, 0, UInt32(old), $0.baseAddress)
                }
            }

            deinit {
                bindings.forEach { $0.release() }
                g_object_unref(cast(model))
            }
        }

        final class CellBinding {
            weak var coordinator: Coordinator?
            let column: Int

            init(coordinator: Coordinator, column: Int) {
                self.coordinator = coordinator
                self.column = column
            }
        }
    }

    /// GTK's C types reach Swift as a mix of typed and opaque pointers; this converts between them.
    private func cast<T, U>(_ pointer: T) -> U { unsafeBitCast(pointer, to: U.self) }

    private let setupCell: @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { _, item, _ in
        let label = gtk_label_new(nil)!
        gtk_label_set_xalign(cast(label), 0)
        gtk_label_set_ellipsize(cast(label), PANGO_ELLIPSIZE_END)
        gtk_list_item_set_child(cast(item), label)
    }

    private let bindCell: @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { _, item, data in
        guard let data, let label = gtk_list_item_get_child(cast(item)) else { return }
        let binding = Unmanaged<TrackTable.CellBinding>.fromOpaque(data).takeUnretainedValue()
        guard let rows = binding.coordinator?.rows else { return }
        let position = Int(gtk_list_item_get_position(cast(item)))
        guard position < rows.count else { return }
        gtk_label_set_text(cast(label), rows[position][keyPath: columns[binding.column].value])
    }

    struct WindowBackground: View {
        var body: some View {
            Color.adaptive(light: Color(white: 0.98), dark: Color(white: 0.14))
        }
    }
#else
    struct WindowBackground: View {
        var body: some View {
            Color.adaptive(light: Color(white: 0.93), dark: Color(white: 0.16))
        }
    }

    struct TrackTable: View {
        /// Not kept when nil yet: the generic Table rebuilds anyway.
        var rows: [TrackRow]?

        var body: some View {
            Table(rows ?? []) {
                TableColumn(columns[0].title, value: columns[0].value)
                TableColumn(columns[1].title, value: columns[1].value)
                TableColumn(columns[2].title, value: columns[2].value)
                TableColumn(columns[3].title, value: columns[3].value)
                TableColumn(columns[4].title, value: columns[4].value)
                TableColumn(columns[5].title, value: columns[5].value)
            }
        }
    }
#endif
