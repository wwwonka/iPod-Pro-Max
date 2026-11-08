import SwiftCrossUI
import Foundation

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

extension Array {
    /// O(1) identity check: true when both arrays share one buffer (copies, not equal values).
    /// Lets each native table skip reloading on redraws that didn't change its rows.
    func sameStorage(as other: [Element]) -> Bool {
        count == other.count
            && withUnsafeBufferPointer { a in other.withUnsafeBufferPointer { a.baseAddress == $0.baseAddress } }
    }
}

#if canImport(AppKitBackend)
    import AppKit
    import AppKitBackend

    struct TrackTable: NSViewRepresentable {
        /// nil keeps the rows already shown.
        var rows: [TrackRow]?
        var isActive = true
        var onPlay: (TrackRow, [TrackRow]) -> Void = { _, _ in }
        var artworkFolder: URL?
        var playlists: [Playlist] = []
        var onAddToPlaylist: ([String], String) -> Void = { _, _ in }
        var currentPlaylistID: String?
        var onRemoveFromPlaylist: ([String], String) -> Void = { _, _ in }

        func makeCoordinator() -> Coordinator { Coordinator() }

        func makeNSView(context: Context) -> NSScrollView {
            let table = MusicTrackTable()
            table.coordinator = context.coordinator
            table.target = context.coordinator
            table.doubleAction = #selector(Coordinator.playSelected(_:))
            if #available(macOS 11, *) { table.style = .inset }
            table.usesAlternatingRowBackgroundColors = true
            table.rowHeight = 42
            table.allowsMultipleSelection = true
            table.allowsColumnReordering = true
            table.setDraggingSourceOperationMask(.copy, forLocal: true)
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
            coordinator.onPlay = onPlay
            coordinator.artworkFolder = artworkFolder
            coordinator.playlists = playlists
            coordinator.onAddToPlaylist = onAddToPlaylist
            coordinator.currentPlaylistID = currentPlaylistID
            coordinator.onRemoveFromPlaylist = onRemoveFromPlaylist
            coordinator.setActive(isActive, in: scroll)
            // Same array storage means same rows: skip the reload on unrelated redraws.
            guard let rows, !coordinator.sourceRows.sameStorage(as: rows),
                  let table = scroll.documentView as? NSTableView else { return }
            coordinator.setRows(rows, in: table)
        }

        @MainActor
        final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
            var rows: [TrackRow] = []
            var sourceRows: [TrackRow] = []
            var isActive = true
            var onPlay: (TrackRow, [TrackRow]) -> Void = { _, _ in }
            var artworkFolder: URL?
            var playlists: [Playlist] = []
            var onAddToPlaylist: ([String], String) -> Void = { _, _ in }
            var currentPlaylistID: String?
            var onRemoveFromPlaylist: ([String], String) -> Void = { _, _ in }
            @objc func playSelected(_ sender: NSTableView) {
                guard isActive, rows.indices.contains(sender.clickedRow), rows[sender.clickedRow].path != nil else { return }
                onPlay(rows[sender.clickedRow], rows)
            }
            private var sortColumn: Int?
            private var ascending = true
            private var sortRevision = 0

            func setRows(_ rows: [TrackRow], in table: NSTableView) {
                sourceRows = rows
                self.rows = rows
                table.deselectAll(nil)
                table.reloadData()
                applySort(in: table)
            }

            func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
                guard let index = Int(tableColumn.identifier.rawValue), columns.indices.contains(index) else { return }
                if sortColumn == index { ascending.toggle() }
                else { sortColumn = index; ascending = true }
                for column in tableView.tableColumns {
                    guard let i = Int(column.identifier.rawValue), columns.indices.contains(i) else { continue }
                    column.title = columns[i].title + (i == index ? (ascending ? " ↑" : " ↓") : "")
                }
                applySort(in: tableView)
            }

            private func applySort(in table: NSTableView) {
                sortRevision += 1
                let revision = sortRevision
                let source = sourceRows
                guard let sortColumn else { rows = source; table.reloadData(); return }
                let key = columns[sortColumn].value
                let forward = ascending
                Task { [weak self, weak table] in
                    let sorted = await Task.detached(priority: .userInitiated) {
                        source.enumerated().sorted { a, b in
                            let left = a.element[keyPath: key], right = b.element[keyPath: key]
                            let order: ComparisonResult
                            if sortColumn == 5 {
                                func seconds(_ value: String) -> Int {
                                    value.split(separator: ":").reduce(0) { $0 * 60 + (Int($1) ?? 0) }
                                }
                                let l = seconds(left), r = seconds(right)
                                order = l == r ? .orderedSame : (l < r ? .orderedAscending : .orderedDescending)
                            } else { order = left.localizedStandardCompare(right) }
                            if order == .orderedSame { return a.offset < b.offset }
                            return forward ? order == .orderedAscending : order == .orderedDescending
                        }.map(\.element)
                    }.value
                    guard let self, let table, self.sortRevision == revision else { return }
                    let selected = Set(table.selectedRowIndexes.compactMap { self.rows.indices.contains($0) ? self.rows[$0].id : nil })
                    self.rows = sorted
                    table.reloadData()
                    table.selectRowIndexes(IndexSet(sorted.indices.filter { selected.contains(sorted[$0].id) }), byExtendingSelection: false)
                }
            }
            func setActive(_ active: Bool, in scroll: NSScrollView) {
                if isActive && !active {
                    dragPayload = nil
                    TrackDrag.end()
                }
                isActive = active
                scroll.isHidden = !active
                scroll.setAccessibilityHidden(!active)
            }
            private let cellID = NSUserInterfaceItemIdentifier("cell")

            private var dragPayload: String?
            func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
                guard isActive else { return nil }
                if dragPayload == nil {
                    let indexes = tableView.selectedRowIndexes.contains(row) ? tableView.selectedRowIndexes : IndexSet(integer: row)
                    let ids = indexes.compactMap { rows.indices.contains($0) ? rows[$0].id : nil }
                    dragPayload = TrackDrag.begin(ids)
                }
                guard let dragPayload else { return nil }
                let item = NSPasteboardItem()
                item.setString(dragPayload, forType: .string)
                return item
            }
            func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
                dragPayload = nil
                TrackDrag.end()
            }

            func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

            func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
                guard let tableColumn, let index = Int(tableColumn.identifier.rawValue) else { return nil }
                let cell = (tableView.makeView(withIdentifier: cellID, owner: nil) as? CenteredTrackCell) ?? CenteredTrackCell()
                cell.identifier = cellID
                cell.label.stringValue = rows[row][keyPath: columns[index].value]
                cell.setLyrics(index == 1 && rows[row].hasLyrics)
                cell.showArtwork(index == 1 ? rows[row].artworkKey.flatMap { artworkFolder?.appendingPathComponent($0 + ".jpg") } : nil,
                                 reservesSpace: index == 1)
                return cell
            }
        }
    }

    final class MusicTrackTable: NSTableView {
        weak var coordinator: TrackTable.Coordinator?

        override func menu(for event: NSEvent) -> NSMenu? {
            let clicked = row(at: convert(event.locationInWindow, from: nil))
            guard let coordinator, coordinator.isActive, coordinator.rows.indices.contains(clicked),
                  coordinator.rows[clicked].path != nil else { return nil }
            if !selectedRowIndexes.contains(clicked) { selectRowIndexes(IndexSet(integer: clicked), byExtendingSelection: false) }
            let menu = NSMenu()
            if selectedRowIndexes.count == 1 {
                let play = NSMenuItem(title: "Play", action: #selector(playSelection), keyEquivalent: "")
                play.target = self
                menu.addItem(play)
                menu.addItem(.separator())
            }
            if !coordinator.playlists.isEmpty {
                let parent = NSMenuItem(title: "Add to Playlist", action: nil, keyEquivalent: "")
                let choices = NSMenu()
                for playlist in coordinator.playlists {
                    let item = NSMenuItem(title: playlist.name, action: #selector(addToPlaylist(_:)), keyEquivalent: "")
                    item.representedObject = playlist.id
                    item.target = self
                    choices.addItem(item)
                }
                parent.submenu = choices
                menu.addItem(parent)
            }
            if coordinator.currentPlaylistID != nil {
                let remove = NSMenuItem(title: "Remove from Playlist", action: #selector(removeFromPlaylist), keyEquivalent: "")
                remove.target = self
                menu.addItem(remove)
            }
            let reveal = NSMenuItem(title: "Reveal in Finder", action: #selector(revealSelection), keyEquivalent: "")
            reveal.target = self
            menu.addItem(reveal)
            if selectedRowIndexes.count == 1 {
                let info = NSMenuItem(title: "Track Info", action: #selector(showTrackInfo), keyEquivalent: "")
                info.target = self
                menu.addItem(info)
            }
            return menu
        }

        @objc private func playSelection() {
            guard let coordinator, coordinator.rows.indices.contains(selectedRow) else { return }
            coordinator.onPlay(coordinator.rows[selectedRow], coordinator.rows)
        }
        @objc private func addToPlaylist(_ sender: NSMenuItem) {
            guard let coordinator, let playlist = sender.representedObject as? String else { return }
            let ids = selectedRowIndexes.compactMap { coordinator.rows.indices.contains($0) ? coordinator.rows[$0].id : nil }
            coordinator.onAddToPlaylist(ids, playlist)
        }
        @objc private func removeFromPlaylist() {
            guard let coordinator, let playlist = coordinator.currentPlaylistID else { return }
            let ids = selectedRowIndexes.compactMap { coordinator.rows.indices.contains($0) ? coordinator.rows[$0].id : nil }
            coordinator.onRemoveFromPlaylist(ids, playlist)
        }

        @objc private func revealSelection() {
            guard let coordinator else { return }
            let urls = selectedRowIndexes.compactMap { coordinator.rows.indices.contains($0) ? coordinator.rows[$0].path.map { URL(fileURLWithPath: $0) } : nil }
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }

        @objc private func showTrackInfo() {
            guard let coordinator, coordinator.rows.indices.contains(selectedRow) else { return }
            let row = coordinator.rows[selectedRow]
            let alert = NSAlert()
            alert.messageText = row.title
            alert.informativeText = "Artist: \(row.artist)\nAlbum: \(row.album)\nYear: \(row.year)\nDuration: \(row.duration)\nFile: \(row.path ?? "")"
            alert.addButton(withTitle: "OK")
            if let window { alert.beginSheetModal(for: window) }
            else { alert.runModal() }
        }
    }

    /// Keep the text centered in the native row, regardless of the row-height preference.
    final class CenteredTrackCell: NSTableCellView {
        let label = NSTextField(labelWithString: "")
        private let lyrics = NSImageView()
        private let cover = NSImageView()
        private var url: URL?
        private var task: Task<Void, Never>?
        private var reservesSpace = false
        override init(frame: NSRect) {
            super.init(frame: frame)
            label.lineBreakMode = .byTruncatingTail
            lyrics.image = systemSymbol("text.quote", pointSize: 12)
            lyrics.contentTintColor = .secondaryLabelColor
            lyrics.toolTip = "Lyrics available"
            cover.imageScaling = .scaleProportionallyUpOrDown
            cover.wantsLayer = true; cover.layer?.cornerRadius = 5; cover.layer?.masksToBounds = true
            for child in [cover, label, lyrics] { addSubview(child) }
        }
        func showArtwork(_ newURL: URL?, reservesSpace: Bool) {
            self.reservesSpace = reservesSpace; cover.isHidden = !reservesSpace
            needsLayout = true
            guard url != newURL else { return }
            url = newURL; task?.cancel(); cover.image = nil
            guard let newURL else { return }
            cover.image = ThumbnailStore.shared.cached(newURL, pixels: 64)
            guard cover.image == nil else { return }
            task = Task { [weak self] in
                let image = await ThumbnailStore.shared.image(newURL, pixels: 64)
                guard !Task.isCancelled, self?.url == newURL else { return }
                self?.cover.image = image
            }
        }
        func setLyrics(_ available: Bool) { lyrics.isHidden = !available }
        override func layout() {
            super.layout()
            let start: CGFloat = reservesSpace ? 42 : 0
            cover.frame = NSRect(x: 2, y: (bounds.height - 32) / 2, width: 32, height: 32)
            label.frame = NSRect(x: start, y: (bounds.height - 18) / 2, width: max(0, bounds.width - start - (reservesSpace ? 20 : 2)), height: 18)
            lyrics.frame = NSRect(x: max(0, bounds.width - 16), y: (bounds.height - 14) / 2, width: 14, height: 14)
        }
        required init?(coder: NSCoder) { fatalError() }
    }

    /// Lays the columns out on every resize so all of them fit, as SwiftUI's Table does.
    final class TrackScrollView: NSScrollView {
        override func tile() {
            super.tile()
            guard let table = documentView as? NSTableView, table.tableColumns.count == columns.count
            else { return }
            let spacing = table.intercellSpacing.width * CGFloat(columns.count)
            let fixed = columns.filter { $0.width >= 1 }.reduce(0) { $0 + $1.width }
            let flexible = max(0, contentView.bounds.width - spacing - fixed - 24).rounded(.down)
            // Rounding each flexible column down separately leaves up to a few points over, which moved the
            // fixed columns behind them (Year, Time) at every width: the last flexible one takes the exact rest.
            let lastFlexible = columns.indices.last { columns[$0].width < 1 }
            var used: CGFloat = 0
            for column in table.tableColumns {
                guard let index = Int(column.identifier.rawValue), columns.indices.contains(index) else { continue }
                let spec = columns[index]
                if spec.width >= 1 {
                    column.width = spec.width
                } else if index == lastFlexible {
                    column.width = max(0, flexible - used)
                } else {
                    let width = (flexible * spec.width).rounded(.down)
                    column.width = width
                    used += width
                }
            }
        }
    }

    /// The main view's own surface: frosted glass, lighter than the sidebar's, following light and
    /// dark mode. Blurs what is behind the window and keeps its state when another app comes forward.
    struct WindowBackground: NSViewRepresentable {
        /// Round the left side only (the sidebar's panel).
        var leftRounded = false
        func makeNSView(context: Context) -> FrostedSurface { FrostedSurface(leftRounded: leftRounded) }
        func updateNSView(_ view: FrostedSurface, context: Context) {}
    }

    /// Squares off the main view's left corners: the panel is clipped by an ancestor layer whose
    /// rounding is switched to the right corners only.
    struct RightCornersOnly: NSViewRepresentable {
        /// False when no sidebar sits at the panel's left: all four corners are round then.
        var squareLeft = true
        func makeNSView(context: Context) -> NSView { let view = RightCornersView(); view.squareLeft = squareLeft; return view }
        func updateNSView(_ view: NSView, context: Context) {
            guard let view = view as? RightCornersView else { return }
            view.squareLeft = squareLeft
            view.apply()
        }
    }

    final class RightCornersView: NSView {
        var squareLeft = true
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }
        /// Runs whenever the panel's frame changes, which is what opening or closing the sidebar does.
        override func layout() {
            super.layout()
            apply()
        }
        /// The sidebar's real state decides: square at the left only while it sits there.
        private func sidebarIsBesidePanel() -> Bool {
            var view = superview
            while let current = view {
                if let split = current as? NSCustomSplitView { return split.isSidebarOpen && split.dividerDragEnabled }
                view = current.superview
            }
            return squareLeft
        }
        func apply() {
            let square = sidebarIsBesidePanel()
            var view = superview
            while let current = view {
                if let layer = current.layer, layer.cornerRadius == CGFloat(floatingPanelRadius) {
                    let corners: CACornerMask = square
                        ? [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
                        : [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
                    if layer.maskedCorners != corners { layer.maskedCorners = corners }
                    return
                }
                view = current.superview
            }
        }
    }

    final class FrostedSurface: NSView {
        private let glass = NSVisualEffectView()
        private let tint = NSBox()
        private let tintMask = CAShapeLayer()
        private let leftRounded: Bool
        init(leftRounded: Bool = false) {
            self.leftRounded = leftRounded
            super.init(frame: .zero)
            if leftRounded {
                // A mask image, not the layer's corners: those would switch the blur off.
                glass.maskImage = SidebarGlassView.leftRoundedMask(radius: CGFloat(floatingPanelRadius))
                tint.wantsLayer = true
                tint.layer?.mask = tintMask
            }
            commonInit()
        }
        override init(frame: NSRect) {
            leftRounded = false
            super.init(frame: frame)
            commonInit()
        }
        private func commonInit() {
            glass.material = .underWindowBackground
            glass.blendingMode = .behindWindow
            glass.state = .active
            glass.autoresizingMask = [.width, .height]
            addSubview(glass)
            tint.boxType = .custom
            tint.borderWidth = 0
            tint.fillColor = NSColor.windowBackgroundColor.withAlphaComponent(0.7)
            tint.autoresizingMask = [.width, .height]
            addSubview(tint)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func layout() {
            super.layout()
            glass.frame = bounds
            tint.frame = bounds
            if leftRounded {
                let r = CGFloat(floatingPanelRadius)
                // Only when the size changed: this runs on every frame of a live resize.
                guard tintMask.frame.size != bounds.size else { return }
                CATransaction.begin(); CATransaction.setDisableActions(true)
                defer { CATransaction.commit() }
                tintMask.frame = bounds
                tintMask.path = CGPath(roundedRect: CGRect(x: 0, y: 0, width: bounds.width + 2 * r, height: bounds.height),
                                       cornerWidth: r, cornerHeight: r, transform: nil)
            }
        }

    }

    /// The iPod page and the surface exposed while it slides use exactly the same color.
    let devicePageBackgroundColor = NSColor(srgbRed: 40.0 / 255, green: 40.0 / 255, blue: 40.0 / 255, alpha: 1)

    struct DevicePageBackground: NSViewRepresentable {
        func makeNSView(context: Context) -> NSBox {
            let box = NSBox()
            box.boxType = .custom
            box.borderWidth = 0
            box.fillColor = devicePageBackgroundColor
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
        var isActive = true
        var onPlay: (TrackRow, [TrackRow]) -> Void = { _, _ in }
        var artworkFolder: URL?
        var playlists: [Playlist] = []
        var onAddToPlaylist: ([String], String) -> Void = { _, _ in }
        var currentPlaylistID: String?
        var onRemoveFromPlaylist: ([String], String) -> Void = { _, _ in }

        func makeCoordinator() -> Coordinator { Coordinator() }

        func makeGtkWidget(context: Context) -> Gtk.Widget {
            let coordinator = context.coordinator
            // The selection takes the model's reference (transfer full): give it one of its own,
            // so the coordinator's unref in deinit stays balanced.
            g_object_ref(cast(coordinator.model))
            let selection = gtk_multi_selection_new(cast(coordinator.model))!
            coordinator.selection = selection
            let view = gtk_column_view_new(selection)!
            g_signal_connect_data(cast(view), "activate", unsafeBitCast(activateTrack, to: GCallback.self),
                                  Unmanaged.passUnretained(coordinator).toOpaque(), nil, GConnectFlags(rawValue: 0))
            let drag = gtk_drag_source_new()!
            gtk_drag_source_set_actions(drag, GDK_ACTION_COPY)
            g_signal_connect_data(cast(drag), "prepare", unsafeBitCast(prepareMusicDrag, to: GCallback.self),
                Unmanaged.passUnretained(coordinator).toOpaque(), nil, GConnectFlags(rawValue: 0))
            g_signal_connect_data(cast(drag), "drag-end", unsafeBitCast(endMusicDrag, to: GCallback.self), nil, nil, GConnectFlags(rawValue: 0))
            g_signal_connect_data(cast(drag), "drag-begin", unsafeBitCast(beginMusicDrag, to: GCallback.self), nil, nil, GConnectFlags(rawValue: 0))
            gtk_widget_add_controller(view, cast(drag))
            gtk_column_view_set_show_column_separators(cast(view), 0)
            gtk_widget_add_css_class(view, "data-table")
            for (index, column) in columns.enumerated() {
                let factory = gtk_signal_list_item_factory_new()
                // The handler owns its binding; GLib releases it when the handler goes away.
                let binding = Unmanaged.passRetained(CellBinding(coordinator: coordinator, column: index))
                g_signal_connect_data(cast(factory), "setup", unsafeBitCast(setupCell, to: GCallback.self),
                    Unmanaged.passRetained(CellBinding(coordinator: coordinator, column: index)).toOpaque(), releaseBinding, GConnectFlags(rawValue: 0))
                g_signal_connect_data(cast(factory), "bind", unsafeBitCast(bindCell, to: GCallback.self),
                                      binding.toOpaque(), releaseBinding, GConnectFlags(rawValue: 0))
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
            let coordinator = context.coordinator
            if coordinator.isActive && !isActive { TrackDrag.end() }
            coordinator.isActive = isActive
            coordinator.onPlay = onPlay
            coordinator.artworkFolder = artworkFolder
            gtk_widget_set_visible(widget.widgetPointer, isActive ? 1 : 0)
            gtk_widget_set_sensitive(widget.widgetPointer, isActive ? 1 : 0)
            // Same rows: keep the model, and with it the selection and scroll position.
            guard let rows, !context.coordinator.rows.sameStorage(as: rows) else { return }
            context.coordinator.show(rows)
        }

        final class Coordinator {
            let model = gtk_string_list_new(nil)!
            var selection: OpaquePointer?
            var isActive = true
            var rows: [TrackRow] = []
            var onPlay: (TrackRow, [TrackRow]) -> Void = { _, _ in }
            var artworkFolder: URL?
            var revision = 0

            /// Replaces every item, so GTK rebinds the visible cells: O(rows) tiny objects, no widgets.
            func show(_ newRows: [TrackRow]) {
                let old = rows.count
                revision += 1
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


    private let activateTrack: @convention(c) (OpaquePointer?, UInt32, gpointer?) -> Void = { _, position, data in
        guard let data else { return }
        MainActor.assumeIsolated {
            let c = Unmanaged<TrackTable.Coordinator>.fromOpaque(data).takeUnretainedValue()
            if c.isActive, c.rows.indices.contains(Int(position)) { c.onPlay(c.rows[Int(position)], c.rows) }
        }
    }
    private let prepareMusicDrag: @convention(c) (OpaquePointer?, Double, Double, gpointer?) -> UnsafeMutablePointer<GdkContentProvider>? = { _, _, _, data in
        guard let data else { return nil }
        return MainActor.assumeIsolated { () -> UnsafeMutablePointer<GdkContentProvider>? in
            let c = Unmanaged<TrackTable.Coordinator>.fromOpaque(data).takeUnretainedValue()
            guard c.isActive, let selection = c.selection else { return nil }
            let ids = c.rows.indices.filter { gtk_selection_model_is_selected(selection, UInt32($0)) != 0 }.map { c.rows[$0].id }
            guard let text = TrackDrag.begin(ids) else { return nil }
            var value = GValue()
            g_value_init(&value, g_type_from_name("gchararray"))
            g_value_set_string(&value, text)
            defer { g_value_unset(&value) }
            return gdk_content_provider_new_for_value(&value)
        }
    }
    private let beginMusicDrag: @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { _, drag, _ in
        MainActor.assumeIsolated {
            showMusicDragCount(drag)
        }
    }
    private let endMusicDrag: @convention(c) (OpaquePointer?, OpaquePointer?, gboolean, gpointer?) -> Void = { _, _, _, _ in
        MainActor.assumeIsolated { TrackDrag.end() }
    }

    private let releaseBinding: @convention(c) (gpointer?, UnsafeMutablePointer<GClosure>?) -> Void = { data, _ in
        guard let data else { return }
        Unmanaged<TrackTable.CellBinding>.fromOpaque(data).release()
    }

    private let setupCell: @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { _, item, data in
        let label = gtk_label_new(nil)!
        gtk_label_set_xalign(cast(label), 0)
        gtk_label_set_yalign(cast(label), 0.5)
        gtk_label_set_ellipsize(cast(label), PANGO_ELLIPSIZE_END)
        gtk_widget_set_margin_top(label, 6); gtk_widget_set_margin_bottom(label, 6)
        if let data, Unmanaged<TrackTable.CellBinding>.fromOpaque(data).takeUnretainedValue().column == 1 {
            let box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 10)!
            let image = gtk_image_new_from_icon_name("audio-x-generic-symbolic")!
            gtk_image_set_pixel_size(cast(image), 32); gtk_widget_set_size_request(image, 32, 32)
            gtk_box_append(cast(box), image); gtk_box_append(cast(box), label)
            gtk_list_item_set_child(cast(item), box)
        } else { gtk_list_item_set_child(cast(item), label) }
    }

    private let bindCell: @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { _, item, data in
        guard let data, let child = gtk_list_item_get_child(cast(item)) else { return }
        let binding = Unmanaged<TrackTable.CellBinding>.fromOpaque(data).takeUnretainedValue()
        MainActor.assumeIsolated {
            guard let c = binding.coordinator else { return }
            let position = Int(gtk_list_item_get_position(cast(item)))
            guard c.rows.indices.contains(position) else { return }
            let row = c.rows[position]
            if binding.column != 1 { gtk_label_set_text(cast(child), row[keyPath: columns[binding.column].value]); return }
            guard let image = gtk_widget_get_first_child(child), let label = gtk_widget_get_next_sibling(image) else { return }
            gtk_label_set_text(cast(label), row.title)
            gtk_image_set_from_icon_name(cast(image), "audio-x-generic-symbolic")
            guard let folder = c.artworkFolder, let key = row.artworkKey else { return }
            let revision = c.revision
            g_object_ref(cast(item))
            Task { [weak c] in
                defer { g_object_unref(cast(item)) }
                let texture = await GtkThumbnailStore.shared.image(folder.appendingPathComponent(key + ".jpg"), pixels: 64)
                guard let c, c.revision == revision, gtk_list_item_get_position(cast(item)) == UInt32(position),
                      c.rows.indices.contains(position), c.rows[position].id == row.id, let texture else { return }
                gtk_image_set_from_paintable(cast(image), cast(texture.pointer))
            }
        }
    }

#elseif canImport(WinUIBackend)
    import WindowsFoundation
    import UWP
    import WinUI
    import WinUIBackend

    /// WinUI: a virtualized ListView under a header Grid with the table's columns. For now each row
    /// is one line of text (see the comment in makeWinUIElement).
    struct TrackTable: WinUIElementRepresentable {
        /// nil keeps the rows already shown.
        var rows: [TrackRow]?
        var isActive = true
        var onPlay: (TrackRow, [TrackRow]) -> Void = { _, _ in }
        var artworkFolder: URL?
        var playlists: [Playlist] = []
        var onAddToPlaylist: ([String], String) -> Void = { _, _ in }
        var currentPlaylistID: String?
        var onRemoveFromPlaylist: ([String], String) -> Void = { _, _ in }

        func makeCoordinator() -> Coordinator { Coordinator() }

        func makeWinUIElement(context: Context) -> WinUI.Grid {
            let coordinator = context.coordinator
            let root = WinUI.Grid()
            for height in [GridLength(value: 0, gridUnitType: .auto), GridLength(value: 1, gridUnitType: .star)] {
                let row = RowDefinition()
                row.height = height
                root.rowDefinitions.append(row)
            }
            let header = Self.rowGrid()
            for (i, column) in columns.enumerated() {
                (header.children.getAt(UInt32(i)) as? TextBlock)?.text = column.title
            }
            header.padding = Thickness(left: 12, top: 6, right: 12, bottom: 6)
            WinUI.Grid.setRow(header, 0)

            let list = WinUI.ListView()
            list.selectionMode = .extended
            list.containerContentChanging.addHandler { [weak coordinator] _, args in
                MainActor.assumeIsolated {
                    guard let c = coordinator, let args, !args.inRecycleQueue,
                          c.rows.indices.contains(Int(args.itemIndex)) else { return }
                    let row = c.rows[Int(args.itemIndex)]
                    let grid = Self.rowGrid()
                    grid.padding = Thickness(left: 12, top: 6, right: 12, bottom: 6)
                    for (index, column) in columns.enumerated() {
                        (grid.children.getAt(UInt32(index)) as? TextBlock)?.text = row[keyPath: column.value]
                    }
                    if let folder = c.artworkFolder, let key = row.artworkKey,
                       let title = grid.children.getAt(1) as? TextBlock {
                        title.margin = Thickness(left: 42, top: 0, right: 0, bottom: 0)
                        let cover = WinUI.Image(); cover.width = 32; cover.height = 32
                        cover.horizontalAlignment = .left
                        let bitmap = BitmapImage(WindowsFoundation.Uri(folder.appendingPathComponent(key + ".jpg").absoluteString))
                        bitmap.decodePixelWidth = 64; cover.source = bitmap
                        WinUI.Grid.setColumn(cover, 1); grid.children.append(cover)
                    }
                    args.itemContainer.content = grid
                    args.itemContainer.horizontalContentAlignment = .stretch
                    args.handled = true
                }
            }
            list.canDragItems = true
            list.doubleTapped.addHandler { [weak coordinator, weak list] _, _ in
                MainActor.assumeIsolated {
                    guard let c = coordinator, c.isActive, let list, c.rows.indices.contains(Int(list.selectedIndex)) else { return }
                    c.onPlay(c.rows[Int(list.selectedIndex)], c.rows)
                }
            }
            list.dragItemsStarting.addHandler { [weak coordinator, weak list] _, args in
                guard let coordinator, let list, let args else { return }
                MainActor.assumeIsolated {
                    guard coordinator.isActive else { args.cancel = true; return }
                    var ids: [String] = []
                    for index in 0..<list.selectedRanges.size {
                        guard let range = list.selectedRanges.getAt(index), range.firstIndex >= 0,
                              Int(range.firstIndex) < coordinator.rows.count else { continue }
                        let end = min(Int(range.lastIndex), coordinator.rows.count - 1)
                        if end >= Int(range.firstIndex) {
                            ids.append(contentsOf: coordinator.rows[Int(range.firstIndex)...end].map(\.id))
                        }
                    }
                    guard let payload = TrackDrag.begin(ids) else { args.cancel = true; return }
                    do { try args.data.setText(payload) } catch { TrackDrag.end(); args.cancel = true; return }
                    args.data.properties.title = "\(ids.count) songs"
                    args.data.requestedOperation = .copy
                }
            }
            list.dragItemsCompleted.addHandler { _, _ in MainActor.assumeIsolated { TrackDrag.end() } }
            // Interim: rows use WinUI's default item rendering (a string per row, virtualized).
            // Filling our own column grid into the containers left the rows blank (see the
            // project card); until that's solved, one readable line per song.
            WinUI.Grid.setRow(list, 1)
            coordinator.list = list
            root.children.append(header)
            root.children.append(list)
            return root
        }

        func updateWinUIElement(_ root: WinUI.Grid, context: Context) {
            let coordinator = context.coordinator
            if coordinator.isActive && !isActive { TrackDrag.end() }
            coordinator.isActive = isActive
            coordinator.onPlay = onPlay
            coordinator.artworkFolder = artworkFolder
            root.visibility = isActive ? .visible : .collapsed
            root.isHitTestVisible = isActive
            guard let rows, !coordinator.rows.sameStorage(as: rows) else { return }
            coordinator.rows = rows
            // itemsSource rejects the Swift-backed vector (XAML wants a bindable collection), so
            // the items go in one by one.
            guard let items = coordinator.list?.items else { return }
            items.clear()
            for row in rows { items.append("\(row.title)   —   \(row.artist)   —   \(row.album)") }
        }

        func sizeThatFits(_ proposal: ProposedViewSize, winUIElement: WinUI.Grid, context: Context) -> ViewSize {
            ViewSize(proposal.width ?? 600, proposal.height ?? 400)
        }

        /// A row: one TextBlock per column, fixed or star widths like the other platforms.
        static func rowGrid() -> WinUI.Grid {
            let grid = WinUI.Grid()
            grid.columnSpacing = 8
            for (i, column) in columns.enumerated() {
                let definition = ColumnDefinition()
                definition.width =
                    column.width >= 1
                    ? GridLength(value: column.width, gridUnitType: .pixel)
                    : GridLength(value: column.width, gridUnitType: .star)
                grid.columnDefinitions.append(definition)
                let text = TextBlock()
                text.textTrimming = .characterEllipsis
                WinUI.Grid.setColumn(text, Int32(i))
                grid.children.append(text)
            }
            return grid
        }

        final class Coordinator {
            var rows: [TrackRow] = []
            var list: WinUI.ListView?
            var artworkFolder: URL?
            var onPlay: (TrackRow, [TrackRow]) -> Void = { _, _ in }
            var isActive = true
        }
    }

#else
    struct TrackTable: View {
        /// Not kept when nil yet: the generic Table rebuilds anyway.
        var rows: [TrackRow]?
        var isActive = true

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

#if !canImport(AppKitBackend)
    /// The content background of macOS (`controlBackgroundColor`); the native one follows the
    /// system on macOS.
    struct WindowBackground: View {
        var body: some View {
            Color.adaptive(light: Color(white: 1), dark: Color(red: 0x1E / 255, green: 0x1E / 255, blue: 0x1E / 255))
        }
    }
#endif
