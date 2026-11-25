import Foundation
import SwiftCrossUI

#if canImport(AppKitBackend)
import AppKit
import AppKitBackend
import ImageIO

/// Album headings and songs share a single virtualized table. Only visible cells exist;
/// selection and dragging work across album boundaries, like the All Songs table.
struct ArtistTrackList: NSViewRepresentable {
    var albums: [AlbumInfo]
    var artworkFolder: URL?
    var query: String
    var devices: [String]
    var busyDevices: Set<String>
    var onSend: ([String], String) -> Void
    var onPlay: (TrackRow, [TrackRow]) -> Void = { _, _ in }
    /// nil hides the favorite icon.
    var onToggleFavorite: (([String], Bool) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let table = ArtistQueueTable()
        table.artistCoordinator = context.coordinator
        context.coordinator.table = table
        // The favorite icon or a pending favorite changed: redraw the visible songs only.
        ListAppearance.shared.observe(context.coordinator) { [weak coordinator = context.coordinator] in
            coordinator?.reloadVisibleSongs()
        }
        table.headerView = nil
        table.rowHeight = 28
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.setDraggingSourceOperationMask(.copy, forLocal: true)
        let column = NSTableColumn(identifier: .init("song"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.playSelected(_:))
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = table
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        defer { NativePlaybackReveal.applyArtist(c) }
        c.onSend = onSend
        c.onPlay = onPlay
        c.onToggleFavorite = onToggleFavorite
        let changedRows = !c.albums.sameStorage(as: albums) || c.artworkFolder != artworkFolder || c.query != query
        let changedButtons = c.devices != devices || c.busyDevices != busyDevices
        guard changedRows || changedButtons else { return }
        c.devices = devices
        c.busyDevices = busyDevices
        // Read before the rows are rebuilt: the selected songs stay selected (a favorite was saved).
        let selected = (scroll.documentView as? NSTableView).map { Set(c.selectedSongIDs($0)) } ?? []
        if changedRows {
            let sameAlbums = c.albums.sameStorage(as: albums)
            c.albums = albums
            c.artworkFolder = artworkFolder
            c.query = query
            c.rebuildEntries(sameAlbums: sameAlbums)
        }
        if let table = scroll.documentView as? NSTableView {
            table.reloadData()
            let kept = IndexSet(c.entries.indices.filter { if case .song(let song) = c.entries[$0] { selected.contains(song.id) } else { false } })
            if kept.isEmpty { table.deselectAll(nil) } else { table.selectRowIndexes(kept, byExtendingSelection: false) }
        }
    }

    private final class ArtistQueueTable: NSTableView {
        weak var artistCoordinator: Coordinator?
        override func menu(for event: NSEvent) -> NSMenu? {
            let row = self.row(at: convert(event.locationInWindow, from: nil))
            guard let c = artistCoordinator, c.entries.indices.contains(row), case .song(let song) = c.entries[row], song.path != nil else { return nil }
            if !selectedRowIndexes.contains(row) { selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
            let menu = NSMenu()
            for (title, action) in [("Play Next", #selector(nextInQueue)), ("Add to Queue", #selector(appendQueue))] {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item)
            }
            return menu
        }
        @objc private func nextInQueue() { enqueue(next: true) }
        @objc private func appendQueue() { enqueue(next: false) }
        private func enqueue(next: Bool) {
            guard let c = artistCoordinator else { return }
            let rows = selectedRowIndexes.compactMap { index -> TrackRow? in
                guard c.entries.indices.contains(index), case .song(let song) = c.entries[index] else { return nil }; return song
            }
            PlayerArtwork.folder = c.artworkFolder
            PlaybackController.shared.enqueue(rows, next: next)
        }
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        enum Entry { case album(AlbumInfo), song(TrackRow) }
        var albums: [AlbumInfo] = []
        private var keysAlbums: [AlbumInfo] = []
        private var foldedSongKeys: [[String]] = []
        var artworkFolder: URL?
        var entries: [Entry] = []

        func rebuildEntries(sameAlbums: Bool) {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                entries = albums.flatMap { [Entry.album($0)] + $0.rows.map(Entry.song) }
                return
            }
            if !sameAlbums || !albums.sameStorage(as: keysAlbums) {
                foldedSongKeys = albums.map { $0.rows.map(FastSearch.rowKey) }
                keysAlbums = albums
            }
            let needle = FastSearch.fold(trimmed)
            var next: [Entry] = []
            for (albumIndex, album) in albums.enumerated() {
                let keys = foldedSongKeys[albumIndex]
                var matched: [TrackRow] = []
                for (rowIndex, row) in album.rows.enumerated() where FastSearch.containsUTF8(keys[rowIndex], needle: needle) {
                    matched.append(row)
                }
                if !matched.isEmpty {
                    next.append(.album(album))
                    next.append(contentsOf: matched.map(Entry.song))
                }
            }
            entries = next
        }
        var dragPayload: String?
        var query = ""
        var devices: [String] = []
        var busyDevices: Set<String> = []
        var onSend: ([String], String) -> Void = { _, _ in }
        var onPlay: (TrackRow, [TrackRow]) -> Void = { _, _ in }
        var onToggleFavorite: (([String], Bool) -> Void)?
        weak var table: NSTableView?
        private var loading: Set<URL> = []

        func selectedSongIDs(_ table: NSTableView) -> [String] {
            table.selectedRowIndexes.compactMap { index in
                guard entries.indices.contains(index), case .song(let song) = entries[index] else { return nil }
                return song.id
            }
        }

        /// The clicked song, or the whole selection when it is part of it; a mixed selection
        /// becomes all favorites. The selection itself doesn't change.
        func toggleFavorite(row: Int) {
            guard let table, let onToggleFavorite, entries.indices.contains(row), case .song = entries[row] else { return }
            let songs = (table.selectedRowIndexes.contains(row) ? table.selectedRowIndexes : IndexSet(integer: row)).compactMap { index -> TrackRow? in
                guard entries.indices.contains(index), case .song(let song) = entries[index] else { return nil }
                return song
            }
            onToggleFavorite(songs.map(\.id), songs.contains { !ListAppearance.shared.isFavorite($0) })
        }

        func reloadVisibleSongs() {
            guard let table else { return }
            let visible = table.rows(in: table.visibleRect)
            for index in visible.location..<NSMaxRange(visible) where entries.indices.contains(index) {
                guard case .song(let song) = entries[index],
                      let cell = table.view(atColumn: 0, row: index, makeIfNecessary: false) as? SongCell else { continue }
                showFavorite(song, in: cell)
            }
        }

        private func showFavorite(_ song: TrackRow, in cell: SongCell) {
            cell.favorite.isHidden = onToggleFavorite == nil || song.path == nil
            guard !cell.favorite.isHidden else { return }
            cell.favorite.show(ListAppearance.shared.isFavorite(song)) { [weak self, weak cell] in
                guard let self, let cell, let table = self.table else { return }
                self.toggleFavorite(row: table.row(for: cell))
            }
        }

        @objc func playSelected(_ table: NSTableView) {
            guard entries.indices.contains(table.clickedRow), case .song(let row) = entries[table.clickedRow], row.path != nil else { return }
            if let event = NSApp.currentEvent, table.hitTest(table.superview?.convert(event.locationInWindow, from: nil) ?? .zero) is FavoriteButton { return }
            onPlay(row, entries.compactMap { if case .song(let song) = $0 { song } else { nil } })
        }

        func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            if case .album = entries[row] { return 100 }
            return 28
        }
        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            if case .song = entries[row] { return true }
            return false
        }
        func selectedIDs(_ table: NSTableView, row: Int) -> [String] {
            let indexes = table.selectedRowIndexes.contains(row) ? table.selectedRowIndexes : IndexSet(integer: row)
            return indexes.compactMap { index in
                guard entries.indices.contains(index), case .song(let song) = entries[index] else { return nil }
                return song.id
            }
        }
        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard case .song = entries[row] else { return nil }
            if dragPayload == nil { dragPayload = TrackDrag.begin(selectedIDs(tableView, row: row)) }
            guard let dragPayload else { return nil }
            let item = NSPasteboardItem()
            item.setString(dragPayload, forType: .string)
            return item
        }
        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                       endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            dragPayload = nil
            TrackDrag.end()
        }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            switch entries[row] {
            case .album(let album):
                let id = NSUserInterfaceItemIdentifier("album")
                let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? AlbumCell) ?? AlbumCell()
                cell.identifier = id
                cell.title.stringValue = album.title
                cell.subtitle.stringValue = [album.rows.first?.artist, album.genre, album.year.isEmpty ? nil : album.year,
                    "\(songCount(album.rows.count)) · \(album.durationMs / 60_000) min"].compactMap { $0 }.joined(separator: " · ")
                cell.configureSend(devices: devices, busy: busyDevices) { [weak self] device in
                    self?.onSend(album.rows.map(\.id), device)
                }
                cell.cover.image = nil
                if let key = album.artworkKey, let folder = artworkFolder {
                    let url = folder.appendingPathComponent(key + ".jpg")
                    cell.cover.image = ThumbnailStore.shared.cached(url, pixels: 160)
                    if cell.cover.image == nil { loadCover(url, table: tableView) }
                }
                return cell
            case .song(let song):
                let id = NSUserInterfaceItemIdentifier("song")
                let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? SongCell) ?? SongCell()
                cell.identifier = id
                cell.number.stringValue = song.number
                cell.title.stringValue = song.title
                cell.duration.stringValue = song.duration
                showFavorite(song, in: cell)
                return cell
            }
        }
        private func loadCover(_ url: URL, table: NSTableView) {
            guard loading.insert(url).inserted else { return }
            Task { [weak self, weak table] in
                let image = await ThumbnailStore.shared.image(url, pixels: 160)
                guard let self else { return }
                // Keep failed URLs in the set: missing artwork must not trigger repeated I/O.
                guard let image else { return }
                self.loading.remove(url)
                // The artist may have changed while decoding. Update visible rows only, using
                // their current keys rather than reloading/resetting the user's selection.
                guard let table else { return }
                let visible = table.rows(in: table.visibleRect)
                for index in visible.location..<NSMaxRange(visible) where self.entries.indices.contains(index) {
                    guard case .album(let album) = self.entries[index],
                          let key = album.artworkKey,
                          self.artworkFolder?.appendingPathComponent(key + ".jpg") == url,
                          let cell = table.view(atColumn: 0, row: index, makeIfNecessary: false) as? AlbumCell else { continue }
                    cell.cover.image = image
                }
            }
        }
    }
}

@MainActor private final class SongCell: NSTableCellView {
    let number = NSTextField(labelWithString: "")
    let title = NSTextField(labelWithString: "")
    let duration = NSTextField(labelWithString: "")
    let favorite = FavoriteButton()
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { favorite.emphasized = backgroundStyle == .emphasized }
    }
    init() {
        super.init(frame: .zero)
        for field in [number, title, duration] { field.lineBreakMode = .byTruncatingTail; addSubview(field) }
        addSubview(favorite)
        number.textColor = .secondaryLabelColor
        duration.textColor = .secondaryLabelColor
        number.alignment = .right
        duration.alignment = .right
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        let y = (bounds.height - 18) / 2
        number.frame = NSRect(x: 14, y: y, width: 30, height: 18)
        title.frame = NSRect(x: 56, y: y, width: max(0, bounds.width - 152), height: 18)
        favorite.frame = NSRect(x: max(0, bounds.width - 90), y: (bounds.height - 20) / 2, width: 20, height: 20)
        duration.frame = NSRect(x: max(0, bounds.width - 64), y: y, width: 52, height: 18)
    }
}
@MainActor private final class AlbumCell: NSTableCellView {
    let cover = NSImageView()
    let title = NSTextField(labelWithString: "")
    let subtitle = NSTextField(labelWithString: "")
    let send = NSPopUpButton(frame: .zero, pullsDown: true)
    private var onSend: (String) -> Void = { _ in }
    func configureSend(devices: [String], busy: Set<String>, action: @escaping (String) -> Void) {
        onSend = action
        send.removeAllItems()
        send.addItem(withTitle: "Send Album to iPod")
        for device in devices {
            let item = NSMenuItem(title: device, action: #selector(sendAlbum(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device
            item.isEnabled = !busy.contains(device)
            send.menu?.addItem(item)
        }
        send.menu?.autoenablesItems = false
        send.isHidden = devices.isEmpty
    }
    @objc private func sendAlbum(_ item: NSMenuItem) {
        if let device = item.representedObject as? String { onSend(device) }
    }
    init() {
        super.init(frame: .zero)
        for view in [cover, title, subtitle, send] { addSubview(view) }
        cover.imageScaling = .scaleProportionallyUpOrDown
        title.font = .systemFont(ofSize: 20, weight: .bold)
        title.lineBreakMode = .byTruncatingTail
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        cover.frame = NSRect(x: 14, y: 10, width: 80, height: 80)
        send.frame = NSRect(x: 110, y: 4, width: 190, height: 24)
        title.frame = NSRect(x: 110, y: 62, width: max(0, bounds.width - 124), height: 26)
        subtitle.frame = NSRect(x: 110, y: 38, width: max(0, bounds.width - 124), height: 20)
    }
}
#endif
