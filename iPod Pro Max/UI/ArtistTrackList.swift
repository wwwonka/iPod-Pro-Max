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

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
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
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = table
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.onSend = onSend
        let changedRows = !c.albums.sameStorage(as: albums) || c.artworkFolder != artworkFolder || c.query != query
        let changedButtons = c.devices != devices || c.busyDevices != busyDevices
        guard changedRows || changedButtons else { return }
        c.devices = devices
        c.busyDevices = busyDevices
        if changedRows {
            c.albums = albums
            c.artworkFolder = artworkFolder
            c.query = query
            c.entries = albums.flatMap { album -> [Coordinator.Entry] in
                let songs = album.rows.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)
                    || $0.artist.localizedCaseInsensitiveContains(query) || $0.album.localizedCaseInsensitiveContains(query) }
                return songs.isEmpty ? [] : [Coordinator.Entry.album(album)] + songs.map(Coordinator.Entry.song)
            }
        }
        if let table = scroll.documentView as? NSTableView {
            let selection = table.selectedRowIndexes
            table.reloadData()
            if !changedRows { table.selectRowIndexes(selection, byExtendingSelection: false) }
        }
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        enum Entry { case album(AlbumInfo), song(TrackRow) }
        var albums: [AlbumInfo] = []
        var artworkFolder: URL?
        var entries: [Entry] = []
        var dragPayload: String?
        var query = ""
        var devices: [String] = []
        var busyDevices: Set<String> = []
        var onSend: ([String], String) -> Void = { _, _ in }
        private var loading: Set<URL> = []

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
    init() {
        super.init(frame: .zero)
        for field in [number, title, duration] { field.lineBreakMode = .byTruncatingTail; addSubview(field) }
        number.textColor = .secondaryLabelColor
        duration.textColor = .secondaryLabelColor
        number.alignment = .right
        duration.alignment = .right
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        number.frame = NSRect(x: 14, y: 5, width: 30, height: 18)
        title.frame = NSRect(x: 56, y: 5, width: max(0, bounds.width - 128), height: 18)
        duration.frame = NSRect(x: max(0, bounds.width - 64), y: 5, width: 52, height: 18)
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
