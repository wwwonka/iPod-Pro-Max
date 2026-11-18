import SwiftCrossUI
import Foundation

// SwiftCrossUI's `Table` builds a widget per cell and lays every row out on each update: 5,000
// songs meant 30,000 views and seconds per sidebar click. On macOS the tracks go in a plain
// NSTableView instead, which only makes the visible rows and reuses them while scrolling.

/// A column of every list view. Which ones show is one choice for the whole app
/// (`ListAppearance.hiddenColumns`), made from the header's contextual menu.
struct TrackColumn {
    var id: String
    var title: String
    /// In points for fixed columns, and a share of the remaining width when below 1.
    var width: Double
    var value: KeyPath<TrackRow, String>
    /// Always shown, so a list can never end up without a column.
    var locked = false
    /// The name in the header's menu, when the header itself is too short to read alone.
    var menuTitle: String { id == "number" ? "Track Number" : title }
}

let trackColumns: [TrackColumn] = [
    TrackColumn(id: "number", title: "#", width: 36, value: \.number),
    TrackColumn(id: "title", title: "Title", width: 0.4, value: \.title, locked: true),
    TrackColumn(id: "artist", title: "Artist", width: 0.3, value: \.artist),
    TrackColumn(id: "album", title: "Album", width: 0.3, value: \.album),
    TrackColumn(id: "year", title: "Year", width: 56, value: \.year),
    TrackColumn(id: "time", title: "Time", width: 56, value: \.duration),
    TrackColumn(id: "dateAdded", title: "Date Added", width: 96, value: \.addedText),
]
private let columns = trackColumns
/// The title column carries the cover, the favorite icon and the lyrics mark.
private let titleColumn = 1

extension TrackRow {
    /// The day the song was added, as `2026-11-13`; "" when unknown. Only computed for visible cells.
    var addedText: String {
        guard let dateAdded else { return "" }
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: dateAdded)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return "" }
        return "\(year)-\(month < 10 ? "0" : "")\(month)-\(day < 10 ? "0" : "")\(day)"
    }
}

/// The icon of a row's favorite state, in the style chosen in Settings.
@MainActor
func favoriteSymbol(_ favorite: Bool) -> String {
    let icon = ListAppearance.shared.favoriteIcon
    return favorite ? icon.filled : icon.outline
}

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
        var onReorderPlaylist: (([String], Int) -> Void)? = nil
        var onSelectionChange: ([String]) -> Void = { _ in }
        /// Rows that keep the same key belong to one list: its selection survives a reload.
        var viewKey = ""
        /// A different scope starts from the list's own order again (Recently Added: newest first).
        var sortScope = ""
        /// nil hides the favorite icon (lists of things that can't be favorites).
        var onToggleFavorite: (([String], Bool) -> Void)?

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
            table.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
            table.registerForDraggedTypes([.string])
            table.columnAutoresizingStyle = .noColumnAutoresizing
            for (i, column) in columns.enumerated() {
                let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("\(i)"))
                c.title = column.title
                c.width = column.width >= 1 ? column.width : 150
                table.addTableColumn(c)
            }
            table.dataSource = context.coordinator
            table.delegate = context.coordinator
            // Right-click anywhere on the header: which columns to show.
            let menu = NSMenu()
            menu.delegate = context.coordinator
            menu.autoenablesItems = false
            table.headerView?.menu = menu
            context.coordinator.table = table
            context.coordinator.applyColumns()
            ListAppearance.shared.observe(context.coordinator) { [weak coordinator = context.coordinator] in
                coordinator?.appearanceChanged()
            }

            let scroll = TrackScrollView()
            scroll.documentView = table
            scroll.hasVerticalScroller = true
            scroll.drawsBackground = false
            return scroll
        }

        func updateNSView(_ scroll: NSScrollView, context: Context) {
            let coordinator = context.coordinator
            defer { NativePlaybackReveal.apply() }
            coordinator.onPlay = onPlay
            coordinator.artworkFolder = artworkFolder
            coordinator.playlists = playlists
            coordinator.onAddToPlaylist = onAddToPlaylist
            coordinator.currentPlaylistID = currentPlaylistID
            coordinator.onRemoveFromPlaylist = onRemoveFromPlaylist
            coordinator.onReorderPlaylist = onReorderPlaylist
            coordinator.onSelectionChange = onSelectionChange
            let showsFavorites = onToggleFavorite != nil
            let favoritesChanged = coordinator.showsFavorites != showsFavorites
            coordinator.onToggleFavorite = onToggleFavorite
            coordinator.showsFavorites = showsFavorites
            coordinator.setActive(isActive, in: scroll)
            if isActive { NativePlaybackReveal.active = coordinator }
            guard let table = scroll.documentView as? NSTableView else { return }
            if coordinator.sortScope != sortScope {
                coordinator.sortScope = sortScope
                coordinator.resetSort(in: table)
            }
            // Same array storage means same rows: skip the reload on unrelated redraws.
            guard let rows, !coordinator.sourceRows.sameStorage(as: rows) else {
                if favoritesChanged { coordinator.reloadTitleCells() }
                return
            }
            coordinator.setRows(rows, in: table, keepSelection: coordinator.viewKey == viewKey)
            coordinator.viewKey = viewKey
        }

        @MainActor
        final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
            weak var table: NSTableView?
            var viewKey = ""
            var sortScope = ""
            var showsFavorites = false
            var onToggleFavorite: (([String], Bool) -> Void)?
            var rows: [TrackRow] = []
            var sourceRows: [TrackRow] = []
            var isActive = true
            var onPlay: (TrackRow, [TrackRow]) -> Void = { _, _ in }
            var artworkFolder: URL?
            var showsArtwork = true
            var playlists: [Playlist] = []
            var onAddToPlaylist: ([String], String) -> Void = { _, _ in }
            var currentPlaylistID: String?
            var onRemoveFromPlaylist: ([String], String) -> Void = { _, _ in }
            var onReorderPlaylist: (([String], Int) -> Void)?
            var onSelectionChange: ([String]) -> Void = { _ in }
            private var canReorderPlaylist: Bool {
                currentPlaylistID != nil && sortColumn == nil && onReorderPlaylist != nil
            }
            func tableViewSelectionDidChange(_ notification: Notification) {
                guard let table = notification.object as? NSTableView else { return }
                onSelectionChange(table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].id : nil })
                (table as? MusicTrackTable)?.updateTrackInfoCommand()
            }
            @objc func playSelected(_ sender: NSTableView) {
                guard isActive, rows.indices.contains(sender.clickedRow), rows[sender.clickedRow].path != nil else { return }
                // A quick second click on the favorite icon toggles it again; it doesn't play.
                if let event = NSApp.currentEvent, sender.hitTest(sender.superview?.convert(event.locationInWindow, from: nil) ?? .zero) is FavoriteButton { return }
                onPlay(rows[sender.clickedRow], rows)
            }

            // MARK: Favorites

            /// The clicked row, or the whole selection when the row is part of it. A mixed selection
            /// becomes all favorites. Neither the selection nor playback changes.
            func toggleFavorite(row: Int) {
                guard isActive, let table, let onToggleFavorite, rows.indices.contains(row) else { return }
                let selected = table.selectedRowIndexes
                let targets = (selected.contains(row) ? selected : IndexSet(integer: row)).compactMap { rows.indices.contains($0) ? rows[$0] : nil }
                let favorite = targets.contains { !ListAppearance.shared.isFavorite($0) }
                onToggleFavorite(targets.map(\.id), favorite)
            }

            /// Only the visible title cells are redrawn: selection and scroll position stay.
            func reloadTitleCells() {
                guard let table else { return }
                let column = table.column(withIdentifier: NSUserInterfaceItemIdentifier("\(titleColumn)"))
                guard column >= 0 else { return }
                let visible = table.rows(in: table.visibleRect)
                guard visible.length > 0 else { return }
                table.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<NSMaxRange(visible)), columnIndexes: IndexSet(integer: column))
                table.needsDisplay = true
            }

            /// The favorite icon, a pending favorite or the visible columns changed.
            func appearanceChanged() {
                applyColumns()
                reloadTitleCells()
            }

            // MARK: Columns

            /// Shows and hides the native columns; no reload, so the scroll position stays.
            func applyColumns() {
                guard let table else { return }
                let hidden = ListAppearance.shared.hiddenColumns
                var changed = false
                for column in table.tableColumns {
                    guard let index = Int(column.identifier.rawValue), columns.indices.contains(index) else { continue }
                    let hide = !columns[index].locked && hidden.contains(columns[index].id)
                    if column.isHidden != hide { column.isHidden = hide; changed = true }
                }
                guard changed else { return }
                // Sorted on a column that just went away: back to the list's own order.
                if let sortColumn, hidden.contains(columns[sortColumn].id) { resetSort(in: table) }
                table.enclosingScrollView?.tile()
            }

            func menuNeedsUpdate(_ menu: NSMenu) {
                menu.removeAllItems()
                let hidden = ListAppearance.shared.hiddenColumns
                for column in columns {
                    let item = NSMenuItem(title: column.menuTitle, action: #selector(toggleColumn(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = column.id
                    item.state = column.locked || !hidden.contains(column.id) ? .on : .off
                    item.isEnabled = !column.locked
                    menu.addItem(item)
                }
            }

            @objc private func toggleColumn(_ sender: NSMenuItem) {
                guard let id = sender.representedObject as? String else { return }
                ListAppearance.shared.setColumn(id, hidden: sender.state == .on)
            }

            func resetSort(in table: NSTableView) {
                guard sortColumn != nil else { return }
                sortColumn = nil
                ascending = true
                for column in table.tableColumns {
                    guard let i = Int(column.identifier.rawValue), columns.indices.contains(i) else { continue }
                    column.title = columns[i].title
                }
                applySort(in: table)
            }
            private var sortColumn: Int?
            private var ascending = true
            private var sortRevision = 0

            /// - Parameter keepSelection: the same list with new rows (an import batch, a favorite saved,
            ///   a search): the selected songs stay selected. Another list starts with none.
            func setRows(_ rows: [TrackRow], in table: NSTableView, keepSelection: Bool = false) {
                if sourceRows == rows { return }
                let selected = keepSelection
                    ? Set(table.selectedRowIndexes.compactMap { self.rows.indices.contains($0) ? self.rows[$0].id : nil }) : []
                sourceRows = rows
                if sortColumn != nil {
                    if !keepSelection {
                        self.rows = []
                        table.reloadData()
                        table.deselectAll(nil)
                    }
                    applySort(in: table)
                    return
                }
                self.rows = rows
                table.reloadData()
                if selected.isEmpty { table.deselectAll(nil) }
                else { table.selectRowIndexes(IndexSet(rows.indices.filter { selected.contains(rows[$0].id) }), byExtendingSelection: false) }
                sortRevision += 1
            }

            func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
                RoundedTrackRowView()
            }

            func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
                guard canReorderPlaylist,
                      let text = info.draggingPasteboard.string(forType: .string),
                      text == TrackDrag.payload, !TrackDrag.ids.isEmpty else { return [] }
                tableView.setDropRow(row, dropOperation: .above)
                return .move
            }

            func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
                guard canReorderPlaylist,
                      let text = info.draggingPasteboard.string(forType: .string),
                      text == TrackDrag.payload, !TrackDrag.ids.isEmpty else { return false }
                let ids = TrackDrag.ids
                onReorderPlaylist?(ids, row)
                return true
            }

            func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
                guard let index = Int(tableColumn.identifier.rawValue), columns.indices.contains(index) else { return }
                if sortColumn == index {
                    if ascending { ascending = false }
                    else if currentPlaylistID != nil { resetSort(in: tableView); return }
                    else { ascending = true }
                } else { sortColumn = index; ascending = true }
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
                let kind = columns[sortColumn].id
                let forward = ascending
                Task { [weak self, weak table] in
                    let sorted = await Task.detached(priority: .userInitiated) {
                        source.enumerated().sorted { a, b in
                            let left = a.element[keyPath: key], right = b.element[keyPath: key]
                            let order: ComparisonResult
                            if kind == "dateAdded" {
                                let l = a.element.dateAdded ?? .distantPast, r = b.element.dateAdded ?? .distantPast
                                order = l == r ? .orderedSame : (l < r ? .orderedAscending : .orderedDescending)
                            } else if kind == "time" {
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
                let value = rows[row][keyPath: columns[index].value]
                // A list without the clickable icon (an album's songs in the grid) still marks its favorites.
                cell.label.stringValue = index == titleColumn && !showsFavorites && rows[row].isFavorite
                    ? ListAppearance.shared.favoriteIcon.filledCharacter + "  " + value : value
                cell.setLyrics(index == titleColumn && rows[row].hasLyrics)
                cell.showArtwork(index == titleColumn && showsArtwork ? rows[row].artworkKey.flatMap { artworkFolder?.appendingPathComponent($0 + ".jpg") } : nil,
                                 reservesSpace: index == titleColumn && showsArtwork)
                if index == titleColumn && showsFavorites && rows[row].path != nil {
                    cell.showFavorite(ListAppearance.shared.isFavorite(rows[row])) { [weak self, weak tableView, weak cell] in
                        guard let self, let tableView, let cell else { return }
                        self.toggleFavorite(row: tableView.row(for: cell))
                    }
                } else { cell.hideFavorite() }
                return cell
            }
        }
    }

    final class RoundedTrackRowView: NSTableRowView {
        override var wantsUpdateLayer: Bool { false }
        override func drawSelection(in dirtyRect: NSRect) {
            guard selectionHighlightStyle != .none else { return }
            let color: NSColor = isEmphasized
                ? .selectedContentBackgroundColor
                : .unemphasizedSelectedContentBackgroundColor
            color.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 1), xRadius: 6, yRadius: 6).fill()
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
            for (title, action) in [("Play Next", #selector(playNext)), ("Add to Queue", #selector(addToQueue))] {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item)
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
            if selectedRowIndexes.count >= 1 {
                let title = selectedRowIndexes.count > 1 ? "Track Info (\(selectedRowIndexes.count) Tracks)" : "Track Info"
                let info = NSMenuItem(title: title, action: #selector(showTrackInfo), keyEquivalent: "")
                info.target = self
                menu.addItem(info)
            }
            return menu
        }

        override func keyDown(with event: NSEvent) {
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
               event.charactersIgnoringModifiers?.lowercased() == "i",
               !selectedRowIndexes.isEmpty {
                showTrackInfo()
                return
            }
            super.keyDown(with: event)
        }

        func updateTrackInfoCommand() {
            AppCommands.canOpenTrackInfo = { [weak self] in
                guard let self, let coordinator = self.coordinator, coordinator.isActive else { return false }
                return !self.selectedRowIndexes.isEmpty
            }
            AppCommands.openTrackInfo = { [weak self] in
                self?.showTrackInfo()
            }
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

        @objc private func playNext() { enqueueSelection(next: true) }
        @objc private func addToQueue() { enqueueSelection(next: false) }
        private func enqueueSelection(next: Bool) {
            guard let coordinator else { return }
            let selected = selectedRowIndexes.compactMap { coordinator.rows.indices.contains($0) ? coordinator.rows[$0] : nil }
            PlayerArtwork.folder = coordinator.artworkFolder
            PlaybackController.shared.enqueue(selected, next: next)
        }
        @objc private func revealSelection() {
            guard let coordinator else { return }
            let urls = selectedRowIndexes.compactMap { coordinator.rows.indices.contains($0) ? coordinator.rows[$0].path.map { URL(fileURLWithPath: $0) } : nil }
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }

        @objc private func showTrackInfo() {
            guard let coordinator, coordinator.isActive else { return }
            let indices = selectedRowIndexes.filter { coordinator.rows.indices.contains($0) }.sorted()
            guard !indices.isEmpty else { return }
            if indices.count == 1 {
                MetadataEditorController.shared.open(rows: coordinator.rows, index: indices[0])
            } else {
                MetadataEditorController.shared.open(rows: coordinator.rows, indices: indices)
            }
        }
    }

    /// Keep the text centered in the native row, regardless of the row-height preference.
    final class CenteredTrackCell: NSTableCellView {
        let label = NSTextField(labelWithString: "")
        private let lyrics = NSImageView()
        private let cover = NSImageView()
        /// Made for the first title cell that needs it: the other columns' cells never get one.
        private var favorite: FavoriteButton?
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
        func showFavorite(_ isFavorite: Bool, onToggle: @escaping () -> Void) {
            if favorite == nil {
                let button = FavoriteButton()
                addSubview(button)
                favorite = button
                needsLayout = true
            }
            if favorite?.isHidden == true { favorite?.isHidden = false; needsLayout = true }
            favorite?.emphasized = backgroundStyle == .emphasized
            favorite?.show(isFavorite, onToggle: onToggle)
        }
        func hideFavorite() {
            guard let favorite, !favorite.isHidden else { return }
            favorite.isHidden = true
            needsLayout = true
        }
        /// On a selected row the icon is drawn in the selection's text color, to stay readable.
        override var backgroundStyle: NSView.BackgroundStyle {
            didSet { favorite?.emphasized = backgroundStyle == .emphasized }
        }
        override func layout() {
            super.layout()
            let start: CGFloat = reservesSpace ? 42 : 0
            let heart: CGFloat = favorite?.isHidden == false ? 22 : 0
            cover.frame = NSRect(x: 2, y: (bounds.height - 32) / 2, width: 32, height: 32)
            label.frame = NSRect(x: start, y: (bounds.height - 18) / 2, width: max(0, bounds.width - start - (reservesSpace ? 20 : 2) - heart), height: 18)
            lyrics.frame = NSRect(x: max(0, bounds.width - 16), y: (bounds.height - 14) / 2, width: 14, height: 14)
            favorite?.frame = NSRect(x: max(0, bounds.width - 18 - heart), y: (bounds.height - 20) / 2, width: 20, height: 20)
        }
        required init?(coder: NSCoder) { fatalError() }
    }

    /// The favorite icon of a row, shared by the song lists: outlined and discreet, stronger under
    /// the pointer, filled in the accent color for a favorite. A click toggles the favorite and
    /// nothing else: the table neither selects the row nor starts a drag from a button.
    final class FavoriteButton: NSButton {
        private static var images: [String: NSImage] = [:]
        private var isFavorite = false
        private var hovered = false
        private var symbol = ""
        private var onToggle: () -> Void = {}
        var emphasized = false { didSet { if emphasized != oldValue { tint() } } }

        init() {
            super.init(frame: .zero)
            isBordered = false
            imagePosition = .imageOnly
            imageScaling = .scaleNone
            setButtonType(.momentaryChange)
            focusRingType = .none
            refusesFirstResponder = true
            target = self
            action = #selector(clicked)
        }
        required init?(coder: NSCoder) { fatalError() }

        func show(_ isFavorite: Bool, onToggle: @escaping () -> Void) {
            self.onToggle = onToggle
            self.isFavorite = isFavorite
            let name = favoriteSymbol(isFavorite)
            if name != symbol {
                symbol = name
                // One image per icon for every row.
                if Self.images[name] == nil { Self.images[name] = systemSymbol(name, pointSize: 13) }
                image = Self.images[name]
                toolTip = isFavorite ? "Remove from Favorites" : "Add to Favorites"
                setAccessibilityLabel(toolTip)
            }
            tint()
        }

        private func tint() {
            let color: NSColor = emphasized ? .alternateSelectedControlTextColor
                : isFavorite ? .controlAccentColor : (hovered ? .secondaryLabelColor : .tertiaryLabelColor)
            if contentTintColor != color { contentTintColor = color }
        }

        @objc private func clicked() { onToggle() }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas { removeTrackingArea(area) }
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        }
        override func mouseEntered(with event: NSEvent) { hovered = true; tint() }
        override func mouseExited(with event: NSEvent) { hovered = false; tint() }
    }

    /// Lays the columns out on every resize so all the visible ones fit, as SwiftUI's Table does.
    final class TrackScrollView: NSScrollView {
        override func tile() {
            super.tile()
            guard let table = documentView as? NSTableView, table.tableColumns.count == columns.count
            else { return }
            let shown: [(column: NSTableColumn, spec: TrackColumn)] = table.tableColumns.compactMap { column in
                guard !column.isHidden, let index = Int(column.identifier.rawValue), columns.indices.contains(index) else { return nil }
                return (column, columns[index])
            }
            let spacing = table.intercellSpacing.width * CGFloat(shown.count)
            let fixed = shown.filter { $0.spec.width >= 1 }.reduce(0) { $0 + $1.spec.width }
            let flexible = max(0, contentView.bounds.width - spacing - fixed - 24).rounded(.down)
            // The shares of the flexible columns left on screen, so they still fill the width.
            let shares = shown.filter { $0.spec.width < 1 }.reduce(0) { $0 + $1.spec.width }
            // Rounding each flexible column down separately leaves up to a few points over, which moved the
            // fixed columns behind them (Year, Time) at every width: the last flexible one takes the exact rest.
            let lastFlexible = shown.last { $0.spec.width < 1 }?.spec.id
            var used: CGFloat = 0
            for (column, spec) in shown {
                if spec.width >= 1 {
                    column.width = spec.width
                } else if spec.id == lastFlexible {
                    column.width = max(0, flexible - used)
                } else {
                    let width = (flexible * spec.width / max(shares, 0.01)).rounded(.down)
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
            tint.fillColor = NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? NSColor.black.withAlphaComponent(0.50)
                    : NSColor.white.withAlphaComponent(0.50)
            }
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

    struct DevicePageBackground: NSViewRepresentable {
        /// Exposes the one window-level glass shared with the rail and title toolbar.
        func makeNSView(context: Context) -> NSView { NSView() }

        func updateNSView(_ view: NSView, context: Context) {}
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
        var onReorderPlaylist: (([String], Int) -> Void)? = nil
        var onSelectionChange: ([String]) -> Void = { _ in }
        /// Kept for the same call as on macOS; GTK has no sorting to reset and replaces its model.
        var viewKey = ""
        var sortScope = ""
        /// nil hides the favorite icon (lists of things that can't be favorites).
        var onToggleFavorite: (([String], Bool) -> Void)?

        func makeCoordinator() -> Coordinator { Coordinator() }

        func makeGtkWidget(context: Context) -> Gtk.Widget {
            let coordinator = context.coordinator
            // The selection takes the model's reference (transfer full): give it one of its own,
            // so the coordinator's unref in deinit stays balanced.
            g_object_ref(cast(coordinator.model))
            let selection = gtk_multi_selection_new(cast(coordinator.model))!
            coordinator.selection = selection
            g_signal_connect_data(cast(selection), "selection-changed", unsafeBitCast(trackSelectionChanged, to: GCallback.self),
                                  Unmanaged.passUnretained(coordinator).toOpaque(), nil, GConnectFlags(rawValue: 0))
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
            // The header's contextual menu: one checked item per column, shared by every header.
            // GTK shows a column's header menu on a secondary click; boolean actions draw the checks.
            let actions = g_simple_action_group_new()!
            let menu = g_menu_new()!
            for column in columns {
                let action = g_simple_action_new_stateful(column.id, nil, g_variant_new_boolean(1))!
                g_simple_action_set_enabled(action, column.locked ? 0 : 1)
                g_signal_connect_data(cast(action), "activate", unsafeBitCast(toggleTrackColumn, to: GCallback.self),
                    Unmanaged.passRetained(ColumnChoice(id: column.id)).toOpaque(), releaseColumnChoice, GConnectFlags(rawValue: 0))
                g_action_map_add_action(cast(actions), cast(action))
                coordinator.columnActions.append(cast(action))
                g_menu_append(menu, column.menuTitle, "columns." + column.id)
            }
            gtk_widget_insert_action_group(view, "columns", cast(actions))
            g_object_unref(cast(actions))
            for (index, column) in columns.enumerated() {
                let factory = gtk_signal_list_item_factory_new()
                // The handler owns its binding; GLib releases it when the handler goes away.
                let binding = Unmanaged.passRetained(CellBinding(coordinator: coordinator, column: index))
                g_signal_connect_data(cast(factory), "setup", unsafeBitCast(setupCell, to: GCallback.self),
                    Unmanaged.passRetained(CellBinding(coordinator: coordinator, column: index)).toOpaque(), releaseBinding, GConnectFlags(rawValue: 0))
                g_signal_connect_data(cast(factory), "bind", unsafeBitCast(bindCell, to: GCallback.self),
                                      binding.toOpaque(), releaseBinding, GConnectFlags(rawValue: 0))
                if index == titleColumn {
                    g_signal_connect_data(cast(factory), "unbind", unsafeBitCast(unbindTitleCell, to: GCallback.self),
                        Unmanaged.passRetained(CellBinding(coordinator: coordinator, column: index)).toOpaque(), releaseBinding, GConnectFlags(rawValue: 0))
                }
                let c = gtk_column_view_column_new(column.title, cast(factory))
                gtk_column_view_column_set_header_menu(c, cast(menu))
                // The view owns the column; the coordinator only shows and hides it, while the view lives.
                coordinator.columnViews.append(cast(c))
                if column.width >= 1 {
                    gtk_column_view_column_set_fixed_width(c, Int32(column.width))
                } else {
                    gtk_column_view_column_set_expand(c, 1)
                }
                gtk_column_view_column_set_resizable(c, 1)
                gtk_column_view_append_column(cast(view), c)
                g_object_unref(cast(c))
            }
            g_object_unref(cast(menu))
            coordinator.applyColumns()
            ListAppearance.shared.observe(coordinator) { [weak coordinator] in
                coordinator?.applyColumns()
                coordinator?.refreshFavorites()
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
            coordinator.onSelectionChange = onSelectionChange
            coordinator.artworkFolder = artworkFolder
            let dark = context.environment.colorScheme == .dark
            let favoritesChanged = (coordinator.onToggleFavorite == nil) != (onToggleFavorite == nil) || coordinator.dark != dark
            coordinator.onToggleFavorite = onToggleFavorite
            coordinator.dark = dark
            if favoritesChanged { coordinator.refreshFavorites() }
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
            var onSelectionChange: ([String]) -> Void = { _ in }
            var artworkFolder: URL?
            var revision = 0
            var selectedPositions: Set<Int> = []
            var onToggleFavorite: (([String], Bool) -> Void)?
            var dark = false
            /// The columns and their menu actions, in the order of `trackColumns`.
            var columnViews: [OpaquePointer] = []
            var columnActions: [OpaquePointer] = []
            /// The title cells on screen (list item → row), to redraw their favorite icon alone.
            var titleCells: [OpaquePointer: Int] = [:]

            /// Shows and hides the columns and checks the menu to match; the model isn't touched,
            /// so the selection and the scroll position stay.
            @MainActor func applyColumns() {
                let hidden = ListAppearance.shared.hiddenColumns
                for (index, column) in columns.enumerated() where columnViews.indices.contains(index) && columnActions.indices.contains(index) {
                    let visible = column.locked || !hidden.contains(column.id)
                    gtk_column_view_column_set_visible(cast(columnViews[index]), visible ? 1 : 0)
                    g_simple_action_set_state(cast(columnActions[index]), g_variant_new_boolean(visible ? 1 : 0))
                }
            }

            /// The favorite icon of a title cell, in the chosen style; hidden for rows that can't be favorites.
            @MainActor func showFavorite(_ row: TrackRow, in button: OpaquePointer) {
                let shown = onToggleFavorite != nil && row.path != nil
                gtk_widget_set_visible(cast(button), shown ? 1 : 0)
                guard shown, let label = gtk_button_get_child(cast(button)) else { return }
                let favorite = ListAppearance.shared.isFavorite(row)
                gtk_label_set_markup(cast(label), symbolMarkup(favoriteSymbol(favorite), pointSize: 12, tint: favorite ? .accent : .secondary, dark: dark))
            }

            @MainActor func refreshFavorites() {
                for (item, position) in titleCells where rows.indices.contains(position) {
                    guard let child = gtk_list_item_get_child(cast(item)), let button = gtk_widget_get_last_child(child) else { continue }
                    showFavorite(rows[position], in: cast(button))
                }
            }

            /// The clicked row, or the whole selection when the row is part of it; a mixed selection
            /// becomes all favorites. The selection isn't changed.
            @MainActor func toggleFavorite(position: Int) {
                guard isActive, let onToggleFavorite, rows.indices.contains(position) else { return }
                let targets = (selectedPositions.contains(position) ? selectedPositions.sorted() : [position]).filter { rows.indices.contains($0) }.map { rows[$0] }
                onToggleFavorite(targets.map(\.id), targets.contains { !ListAppearance.shared.isFavorite($0) })
            }

            /// Replaces every item, so GTK rebinds the visible cells: O(rows) tiny objects, no widgets.
            func show(_ newRows: [TrackRow]) {
                let old = rows.count
                revision += 1
                selectedPositions.removeAll()
                titleCells.removeAll()
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


    private let trackSelectionChanged: @convention(c) (OpaquePointer?, UInt32, UInt32, gpointer?) -> Void = { _, first, count, data in
        guard let data else { return }
        MainActor.assumeIsolated {
            let c = Unmanaged<TrackTable.Coordinator>.fromOpaque(data).takeUnretainedValue()
            guard c.isActive, let selection = c.selection else { return }
            let start = min(Int(first), c.rows.count)
            let end = min(c.rows.count, start + Int(count))
            if start < end {
                for position in start..<end {
                    if gtk_selection_model_is_selected(selection, UInt32(position)) != 0 { c.selectedPositions.insert(position) }
                    else { c.selectedPositions.remove(position) }
                }
            }
            c.onSelectionChange(c.selectedPositions.sorted().map { c.rows[$0].id })
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

    /// What a column's menu item carries: the column it shows or hides.
    private final class ColumnChoice {
        let id: String
        init(id: String) { self.id = id }
    }
    private let releaseColumnChoice: @convention(c) (gpointer?, UnsafeMutablePointer<GClosure>?) -> Void = { data, _ in
        guard let data else { return }
        Unmanaged<ColumnChoice>.fromOpaque(data).release()
    }
    private let toggleTrackColumn: @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { _, _, data in
        guard let data else { return }
        let id = Unmanaged<ColumnChoice>.fromOpaque(data).takeUnretainedValue().id
        MainActor.assumeIsolated {
            ListAppearance.shared.setColumn(id, hidden: !ListAppearance.shared.hiddenColumns.contains(id))
        }
    }

    /// The favorite button of a title cell: its list item gives the row when it is clicked.
    private final class FavoriteClick {
        weak var coordinator: TrackTable.Coordinator?
        let item: OpaquePointer
        init(coordinator: TrackTable.Coordinator?, item: OpaquePointer) { self.coordinator = coordinator; self.item = item }
    }
    private let releaseFavoriteClick: @convention(c) (gpointer?, UnsafeMutablePointer<GClosure>?) -> Void = { data, _ in
        guard let data else { return }
        Unmanaged<FavoriteClick>.fromOpaque(data).release()
    }
    private let favoriteClicked: @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, data in
        guard let data else { return }
        let click = Unmanaged<FavoriteClick>.fromOpaque(data).takeUnretainedValue()
        MainActor.assumeIsolated {
            click.coordinator?.toggleFavorite(position: Int(gtk_list_item_get_position(cast(click.item))))
        }
    }
    private let unbindTitleCell: @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { _, item, data in
        guard let data, let item else { return }
        let binding = Unmanaged<TrackTable.CellBinding>.fromOpaque(data).takeUnretainedValue()
        MainActor.assumeIsolated { binding.coordinator?.titleCells[item] = nil }
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
        if let data, let item, Unmanaged<TrackTable.CellBinding>.fromOpaque(data).takeUnretainedValue().column == titleColumn {
            let box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 10)!
            let image = gtk_image_new_from_icon_name("audio-x-generic-symbolic")!
            gtk_image_set_pixel_size(cast(image), 32); gtk_widget_set_size_request(image, 32, 32)
            // The title takes the width; the favorite icon sits at the cell's trailing edge. A
            // button keeps its click: the row is neither selected nor activated by it.
            gtk_widget_set_hexpand(label, 1)
            let favorite = gtk_button_new()!
            gtk_button_set_child(cast(favorite), gtk_label_new(nil))
            gtk_widget_add_css_class(favorite, "flat")
            gtk_widget_set_valign(favorite, GTK_ALIGN_CENTER)
            let coordinator = Unmanaged<TrackTable.CellBinding>.fromOpaque(data).takeUnretainedValue().coordinator
            g_signal_connect_data(cast(favorite), "clicked", unsafeBitCast(favoriteClicked, to: GCallback.self),
                Unmanaged.passRetained(FavoriteClick(coordinator: coordinator, item: item)).toOpaque(), releaseFavoriteClick, GConnectFlags(rawValue: 0))
            gtk_box_append(cast(box), image); gtk_box_append(cast(box), label); gtk_box_append(cast(box), favorite)
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
            if binding.column != titleColumn { gtk_label_set_text(cast(child), row[keyPath: columns[binding.column].value]); return }
            guard let item, let image = gtk_widget_get_first_child(child), let label = gtk_widget_get_next_sibling(image),
                  let favorite = gtk_widget_get_next_sibling(label) else { return }
            // A list without the clickable icon still marks its favorites.
            gtk_label_set_text(cast(label), c.onToggleFavorite == nil && row.isFavorite ? ListAppearance.shared.favoriteIcon.filledCharacter + "  " + row.title : row.title)
            c.titleCells[item] = position
            c.showFavorite(row, in: cast(favorite))
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
        var onReorderPlaylist: (([String], Int) -> Void)? = nil
        var onSelectionChange: ([String]) -> Void = { _ in }
        /// Kept for the same call as on macOS; WinUI has no sorting to reset and replaces its items.
        var viewKey = ""
        var sortScope = ""
        /// nil hides the favorite mark. Rows are one line of text for now, so the mark can't be
        /// clicked here yet: the title bar's Favorite buttons do it.
        var onToggleFavorite: (([String], Bool) -> Void)?

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
            // Right-click anywhere on the header: one checked item per column. The transparent
            // background makes the empty parts of the header take the click too.
            let clear = SolidColorBrush()
            clear.color = UWP.Color(a: 0, r: 0, g: 0, b: 0)
            header.background = clear
            let flyout = MenuFlyout()
            for column in columns {
                let item = ToggleMenuFlyoutItem()
                item.text = column.menuTitle
                item.isEnabled = !column.locked
                let id = column.id
                item.click.addHandler { _, _ in
                    MainActor.assumeIsolated {
                        ListAppearance.shared.setColumn(id, hidden: !ListAppearance.shared.hiddenColumns.contains(id))
                    }
                }
                flyout.items.append(item)
                coordinator.columnItems.append(item)
            }
            header.contextFlyout = flyout
            coordinator.header = header
            coordinator.applyColumns()
            ListAppearance.shared.observe(coordinator) { [weak coordinator] in
                coordinator?.applyColumns()
                coordinator?.showRows()
            }

            let list = WinUI.ListView()
            list.selectionMode = .extended
            list.containerContentChanging.addHandler { [weak coordinator] _, args in
                MainActor.assumeIsolated {
                    guard let c = coordinator, let args, !args.inRecycleQueue,
                          c.rows.indices.contains(Int(args.itemIndex)) else { return }
                    let row = c.rows[Int(args.itemIndex)]
                    let grid = Self.rowGrid()
                    grid.padding = Thickness(left: 12, top: 6, right: 12, bottom: 6)
                    Self.applyColumns(to: grid)
                    for (index, column) in columns.enumerated() {
                        let value = row[keyPath: column.value]
                        (grid.children.getAt(UInt32(index)) as? TextBlock)?.text = index == titleColumn ? c.favoritePrefix(row) + value : value
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
            list.selectionChanged.addHandler { [weak coordinator, weak list] _, _ in
                guard let coordinator, let list else { return }
                MainActor.assumeIsolated {
                    guard coordinator.isActive else { return }
                    var ids: [String] = []
                    for index in 0..<list.selectedRanges.size {
                        guard let range = list.selectedRanges.getAt(index), range.firstIndex >= 0,
                              Int(range.firstIndex) < coordinator.rows.count else { continue }
                        let end = min(Int(range.lastIndex), coordinator.rows.count - 1)
                        if end >= Int(range.firstIndex) { ids.append(contentsOf: coordinator.rows[Int(range.firstIndex)...end].map(\.id)) }
                    }
                    coordinator.onSelectionChange(ids)
                }
            }
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
            coordinator.onSelectionChange = onSelectionChange
            coordinator.artworkFolder = artworkFolder
            let favoritesChanged = coordinator.showsFavorites != (onToggleFavorite != nil)
            coordinator.showsFavorites = onToggleFavorite != nil
            root.visibility = isActive ? .visible : .collapsed
            root.isHitTestVisible = isActive
            guard let rows, !coordinator.rows.sameStorage(as: rows) else {
                if favoritesChanged { coordinator.showRows() }
                return
            }
            coordinator.rows = rows
            coordinator.showRows()
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

        /// Collapses the hidden columns of a header or row grid: no width, no text.
        @MainActor static func applyColumns(to grid: WinUI.Grid) {
            let hidden = ListAppearance.shared.hiddenColumns
            for (index, column) in columns.enumerated() {
                let visible = column.locked || !hidden.contains(column.id)
                guard let definition = grid.columnDefinitions.getAt(UInt32(index)) else { continue }
                definition.width = !visible ? GridLength(value: 0, gridUnitType: .pixel)
                    : column.width >= 1 ? GridLength(value: column.width, gridUnitType: .pixel)
                    : GridLength(value: column.width, gridUnitType: .star)
                (grid.children.getAt(UInt32(index)) as? TextBlock)?.visibility = visible ? .visible : .collapsed
            }
        }

        final class Coordinator {
            var showsFavorites = false
            var header: WinUI.Grid?
            /// The header menu's items, in the order of `trackColumns`.
            var columnItems: [ToggleMenuFlyoutItem] = []

            @MainActor func applyColumns() {
                let hidden = ListAppearance.shared.hiddenColumns
                for (index, column) in columns.enumerated() where columnItems.indices.contains(index) {
                    columnItems[index].isChecked = column.locked || !hidden.contains(column.id)
                }
                if let header { TrackTable.applyColumns(to: header) }
            }

            /// "♥  " or "★  " before a favorite's title, in the icon chosen in Settings.
            @MainActor func favoritePrefix(_ row: TrackRow) -> String {
                showsFavorites && ListAppearance.shared.isFavorite(row) ? ListAppearance.shared.favoriteIcon.filledCharacter + "  " : ""
            }

            /// One line per row, made of the visible columns after the title (the track number is
            /// left to the header). itemsSource rejects the Swift-backed vector (XAML wants a
            /// bindable collection), so the items go in one by one.
            @MainActor func showRows() {
                guard let items = list?.items else { return }
                let hidden = ListAppearance.shared.hiddenColumns
                let shown = columns.filter { $0.id != "number" && ($0.locked || !hidden.contains($0.id)) }
                items.clear()
                for row in rows {
                    items.append(favoritePrefix(row) + shown.map { row[keyPath: $0.value] }.filter { !$0.isEmpty }.joined(separator: "   —   "))
                }
            }

            var rows: [TrackRow] = []
            var list: WinUI.ListView?
            var artworkFolder: URL?
            var onPlay: (TrackRow, [TrackRow]) -> Void = { _, _ in }
            var onSelectionChange: ([String]) -> Void = { _ in }
            var isActive = true
        }
    }

#else
    struct TrackTable: View {
        /// Not kept when nil yet: the generic Table rebuilds anyway.
        var rows: [TrackRow]?
        var isActive = true
        var viewKey = ""
        var sortScope = ""
        var onToggleFavorite: (([String], Bool) -> Void)?

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
            Color.adaptive(light: Color(white: 1, opacity: 0.50), dark: Color(white: 0, opacity: 0.50))
        }
    }
#endif

#if canImport(AppKitBackend)
@MainActor enum NativePlaybackReveal {
    static weak var active: TrackTable.Coordinator?
    enum Kind { case table, artist, album }
    private static var kind: Kind = .table
    private static var pending: String?
    static func request(_ id: String, kind: Kind = .table) { pending = id; self.kind = kind }
    static func applyArtist(_ coordinator: ArtistTrackList.Coordinator) {
        guard kind == .artist, let id = pending, let table = coordinator.table,
              let index = coordinator.entries.firstIndex(where: { if case .song(let row) = $0 { return row.id == id }; return false }) else { return }
        pending = nil
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        table.scrollRowToVisible(index)
    }
    static var pendingAlbumID: String? { kind == .album ? pending : nil }
    static func completeAlbum() { if kind == .album { pending = nil } }
    static func apply() {
        guard kind == .table, let id = pending, let active, active.isActive, let table = active.table,
              let index = active.rows.firstIndex(where: { $0.id == id }) else { return }
        pending = nil
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        table.scrollRowToVisible(index)
    }
}
#endif
