#if canImport(AppKitBackend)
import AppKit
import SwiftCrossUI

@MainActor final class PlayerQueuePopover: NSObject, NSPopoverDelegate {
    static let shared = PlayerQueuePopover()
    private let popover = NSPopover()
    private weak var button: NSButton?
    override init() {
        super.init(); popover.behavior = .transient; popover.delegate = self
        popover.contentViewController = PlayerQueueViewController(playback: .shared)
        popover.contentSize = NSSize(width: 390, height: 420)
    }
    func toggle(from button: NSButton) {
        if popover.isShown { popover.performClose(nil); return }
        self.button = button
        (button as? ToolbarPlaybackButton)?.isLatched = true
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
    func popoverDidClose(_ notification: Notification) { (button as? ToolbarPlaybackButton)?.isLatched = false }
}

@MainActor final class PlayerQueueViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let playback: PlaybackController
    init(playback: PlaybackController) { self.playback = playback; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }
    private let table = QueueTable()
    private let empty = NSTextField(labelWithString: "No tracks up next")
    private let shuffle = NSButton(), repeatButton = NSButton(), clear = NSButton(title: "Clear", target: nil, action: nil)
    private var subscription: SwiftCrossUI.Cancellable?
    private var revision = -1
    private var renderedShuffle: Bool?
    private var renderedRepeat: Int?
    private var rows: [TrackRow] = []
    private var draggedIDs: [String] = []
    private var dragCancelled = false
    private var escapeMonitor: Any?
    private static let queueType = NSPasteboard.PasteboardType("com.ippm.queue.ids")
    override func loadView() {
        let glass = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 390, height: 420))
        glass.material = .popover; glass.blendingMode = .withinWindow; glass.state = .active
        view = glass
        for (button, symbol, label, action, x) in [(shuffle, "shuffle", "Shuffle", #selector(shuffleQueue), CGFloat(12)), (repeatButton, "repeat", "Repeat", #selector(repeatQueue), CGFloat(48))] {
            button.title = ""; button.image = systemSymbol(symbol, pointSize: 14); button.isBordered = false
            button.frame = NSRect(x: x, y: 380, width: 32, height: 30); button.target = self; button.action = action
            button.setAccessibilityLabel(label); view.addSubview(button)
        }
        clear.bezelStyle = .rounded; clear.controlSize = .small; clear.font = .systemFont(ofSize: 12)
        clear.imagePosition = .noImage; clear.title = "Clear"
        clear.frame = NSRect(x: 310, y: 382, width: 68, height: 26); clear.target = self; clear.action = #selector(clearQueue); view.addSubview(clear)
        let column = NSTableColumn(identifier: .init("track")); column.width = 390; table.addTableColumn(column); table.headerView = nil
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.frame = NSRect(x: 0, y: 0, width: 390, height: 0)
        table.dataSource = self; table.delegate = self; table.rowHeight = 46
        table.allowsMultipleSelection = true; table.target = self; table.doubleAction = #selector(playSelected)
        table.deleteSelection = { [weak self] in self?.removeSelected() }
        table.registerForDraggedTypes([Self.queueType, .string])
        table.setDraggingSourceOperationMask([.move, .delete], forLocal: true)
        table.setDraggingSourceOperationMask(.delete, forLocal: false)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 390, height: 374))
        scroll.autoresizingMask = [.width, .height]; scroll.documentView = table; scroll.hasVerticalScroller = true
        view.addSubview(scroll)
        empty.alignment = .center; empty.textColor = .secondaryLabelColor
        empty.frame = NSRect(x: 20, y: 200, width: 350, height: 22); view.addSubview(empty)
        subscription = playback.didChange.observe { [weak self] in self?.refresh() }
        refresh()
    }
    func checkPresentation(expectedCount: Int) {
        _ = view; view.layoutSubtreeIfNeeded()
        precondition(table.numberOfRows == expectedCount, "Queue must show the frozen order")
        precondition(table.visibleRect.height <= 420, "The queue must remain a virtualized viewport")
        if rows.count >= 5 { checkGroupDrag() }
        playback.clearUpcoming(); refresh()
        precondition(table.numberOfRows == 1, "Clear must keep the playing row")
    }
    private func checkGroupDrag() {
        let current = rows[0].id, moving = [rows[1].id, rows[3].id]
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.writeObjects(moving.map { id -> NSPasteboardItem in
            let item = NSPasteboardItem(); item.setString(id, forType: Self.queueType); return item
        })
        precondition(acceptPasteboard(board, at: rows.count))
        precondition(playback.queueRows.suffix(2).map(\.id) == moving && playback.queueRows.first?.id == current)
        draggedIDs = moving; dragCancelled = true
        finishDrag(at: NSPoint(x: -1000, y: -1000), operation: [])
        precondition(playback.queueRows.suffix(2).map(\.id) == moving, "Escape outside the queue preserves all dragged tracks")
        draggedIDs = moving; dragCancelled = false
        finishDrag(at: NSPoint(x: -1000, y: -1000), operation: .delete)
        precondition(!playback.queueRows.contains { moving.contains($0.id) })
        log("PASS: native multi-item queue drop preserves group order; cancelled outside drag retains tracks; deletion removes the group")
    }
    func snapshot(to path: String) {
        _ = view
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
    override func viewWillAppear() { super.viewWillAppear(); refresh() }
    private func refresh() {
        if renderedShuffle != playback.shuffled {
            renderedShuffle = playback.shuffled
            shuffle.contentTintColor = playback.shuffled ? .controlAccentColor : nil
        }
        if renderedRepeat != playback.repeatMode.rawValue {
            renderedRepeat = playback.repeatMode.rawValue
            repeatButton.contentTintColor = playback.repeatMode == .off ? nil : .controlAccentColor
            repeatButton.image = systemSymbol(playback.repeatMode == .one ? "repeat.1" : "repeat", pointSize: 14)
        }
        clear.isEnabled = playback.queueRows.count > 1
        guard revision != playback.queueRevision else { return }
        revision = playback.queueRevision; rows = playback.queueRows
        empty.isHidden = rows.count > 1
        // The current row remains available above the empty-state caption.
        table.reloadData()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let cell = table.makeView(withIdentifier: .init("queue-row"), owner: self) as? QueueCell ?? QueueCell()
        cell.identifier = .init("queue-row"); cell.configure(rows[row], current: row == 0)
        return cell
    }
    @objc private func shuffleQueue() { playback.toggleShuffle() }
    @objc private func repeatQueue() { playback.cycleRepeat() }
    @objc private func clearQueue() { playback.clearUpcoming() }
    @objc private func playSelected() { let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow; if rows.indices.contains(row) { playback.jump(to: rows[row].id) } }
    private func removeSelected() { playback.removeFromQueue(Set(table.selectedRowIndexes.filter { $0 > 0 && rows.indices.contains($0) }.map { rows[$0].id })) }
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard row > 0, rows.indices.contains(row) else { return nil }
        let item = NSPasteboardItem(); item.setString(rows[row].id, forType: Self.queueType); return item
    }
    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        dragCancelled = false
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.dragCancelled = true }
            return event
        }
        draggedIDs = rowIndexes.filter { $0 > 0 && rows.indices.contains($0) }.map { rows[$0].id }
    }
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        tableView.setDropRow(max(1, row), dropOperation: .above)
        if !queueIDs(from: info.draggingPasteboard).isEmpty { return .move }
        return info.draggingPasteboard.string(forType: .string) == TrackDrag.payload && !TrackDrag.ids.isEmpty ? .copy : []
    }
    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        acceptPasteboard(info.draggingPasteboard, at: max(0, row - 1))
    }
    private func acceptPasteboard(_ pasteboard: NSPasteboard, at offset: Int) -> Bool {
        let ids = queueIDs(from: pasteboard)
        if !ids.isEmpty { playback.moveInQueue(ids, to: offset); return true }
        guard pasteboard.string(forType: .string) == TrackDrag.payload else { return false }
        let tracks = playback.libraryRowsProvider(TrackDrag.ids)
        guard !tracks.isEmpty else { return false }
        playback.enqueue(tracks, at: offset); return true
    }
    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        finishDrag(at: screenPoint, operation: operation)
    }
    private func finishDrag(at screenPoint: NSPoint, operation: NSDragOperation) {
        defer {
            draggedIDs = []
            if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
            escapeMonitor = nil
        }
        // A cancelled drag is never a deletion, even with the pointer outside.
        if !dragCancelled, !draggedIDs.isEmpty, operation == .delete || (operation.isEmpty && view.window?.frame.contains(screenPoint) == false) {
            playback.removeFromQueue(Set(draggedIDs))
        }
    }
    private func queueIDs(from pasteboard: NSPasteboard) -> [String] {
        pasteboard.pasteboardItems?.compactMap { $0.string(forType: Self.queueType) } ?? []
    }
    deinit { if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) } }
}

@MainActor private final class QueueTable: NSTableView {
    var deleteSelection: () -> Void = {}
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 { deleteSelection() } else { super.keyDown(with: event) }
    }
}
@MainActor private final class QueueCell: NSTableCellView {
    private let art = NSImageView(), title = NSTextField(labelWithString: ""), artist = NSTextField(labelWithString: ""), duration = NSTextField(labelWithString: "")
    private var task: Task<Void, Never>?
    private var id = ""
    override init(frame: NSRect) {
        super.init(frame: frame)
        title.font = .systemFont(ofSize: 12, weight: .medium); artist.font = .systemFont(ofSize: 10); artist.textColor = .secondaryLabelColor
        duration.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular); duration.textColor = .secondaryLabelColor
        for field in [title, artist] { field.lineBreakMode = .byTruncatingTail }
        art.imageScaling = .scaleProportionallyUpOrDown
        for child in [art, title, artist, duration] { addSubview(child) }
    }
    required init?(coder: NSCoder) { fatalError() }
    func configure(_ track: TrackRow, current: Bool) {
        task?.cancel(); id = track.id
        title.stringValue = (current ? "▶  " : "") + (track.playbackTitle ?? track.title)
        artist.stringValue = track.artist; duration.stringValue = track.duration
        art.imageScaling = .scaleNone; art.image = systemSymbol("music.note", pointSize: 18)
        if let key = track.artworkKey, let folder = PlayerArtwork.folder {
            task = Task { [weak self] in
                let image = await ThumbnailStore.shared.image(folder.appendingPathComponent(key + ".jpg"), pixels: 80)
                guard !Task.isCancelled, self?.id == track.id else { return }; if let image { self?.art.imageScaling = .scaleProportionallyUpOrDown; self?.art.image = image }
            }
        }
    }
    override func layout() {
        super.layout(); art.frame = NSRect(x: 10, y: 6, width: 34, height: 34)
        title.frame = NSRect(x: 54, y: 24, width: max(0, bounds.width - 116), height: 16)
        artist.frame = NSRect(x: 54, y: 8, width: max(0, bounds.width - 116), height: 14)
        duration.frame = NSRect(x: bounds.width - 58, y: 16, width: 48, height: 14)
    }
}
#endif
