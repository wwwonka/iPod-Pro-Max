#if canImport(AppKitBackend)
import AppKit

/// Opt-in native regression check, no music writes and no use of the user's clipboard.
@MainActor
func checkNativeMusicInteractions() {
    let rows = (0..<3).map {
        TrackRow(id: UUID().uuidString, title: "Track \($0)", artist: "Artist", album: "Album", number: "\($0)", year: "", duration: "")
    }
    let table = NSTableView()
    table.addTableColumn(NSTableColumn(identifier: .init("track")))
    let source = TrackTable.Coordinator()
    source.rows = rows
    table.dataSource = source
    table.allowsMultipleSelection = true
    table.reloadData()
    table.selectRowIndexes(IndexSet(0..<3), byExtendingSelection: false)
    let board = NSPasteboard(name: .init("ipodpromax-interaction-check-" + UUID().uuidString))
    defer { board.releaseGlobally(); TrackDrag.end() }
    let writers = (0..<3).compactMap { source.tableView(table, pasteboardWriterForRow: $0) }
    precondition(writers.count == 3 && board.writeObjects(writers))
    log("[check] native pasteboard: \(board.pasteboardItems?.count ?? 0) items; aggregate matches nonce: \(board.string(forType: .string) == TrackDrag.payload)")
    var received: [String] = []
    MusicTransfer.shared.onDrop = { ids, device in received = ids; return device == "test-device" }
    precondition(TrackDrag.accept(musicDragPayload(in: board), device: "test-device"))
    precondition(Set(received) == Set(rows.map(\.id)), "Multi-row drag lost selected tracks")
    precondition(!TrackDrag.accept("external", device: "test-device"))
    TrackDrag.end()

    let artist = ArtistList.Coordinator()
    artist.artists = [NamedGroup(id: "Artist", count: 3)]
    artist.tracksByArtist = ["Artist": rows]
    board.clearContents()
    precondition(board.writeObjects([artist.tableView(table, pasteboardWriterForRow: 0)!]))
    precondition(TrackDrag.accept(musicDragPayload(in: board), device: "test-device"))
    precondition(Set(received) == Set(rows.map(\.id)), "Artist drag omitted tracks")
    TrackDrag.end()

    let button = EjectButton(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
    var ejected = false
    button.action = { ejected = true }
    button.isBusy = true
    guard let rotor = button.layer?.sublayers?.first(where: { $0.name == "syncGlyph" }) else { fatalError("Missing centered sync layer") }
    log("[check] rotor anchor=\(rotor.anchorPoint) position=\(rotor.position) contents=\(rotor.contents != nil)")
    precondition(rotor.animation(forKey: "syncRotation") != nil)
    precondition(rotor.anchorPoint == CGPoint(x: 0.5, y: 0.5))
    precondition(rotor.position == CGPoint(x: button.bounds.midX, y: button.bounds.midY))
    precondition(rotor.contents != nil)
    button.setFrameSize(NSSize(width: 30, height: 24))
    button.layoutSubtreeIfNeeded()
    log("[check] resized rotor position=\(rotor.position), bounds=\(button.bounds)")
    precondition(rotor.position == CGPoint(x: 15, y: 12), "Rotation center moved away from icon center")
    if let event = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
        button.mouseDown(with: event)
    }
    precondition(!ejected, "Busy device could eject")
    button.isBusy = false
    precondition(rotor.animation(forKey: "syncRotation") == nil)
    precondition(rotor.isHidden)

    let outline = MusicDropOutlineView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    outline.addTableColumn(NSTableColumn(identifier: .init("sidebar")))
    outline.headerView = nil
    outline.draggingDestinationFeedbackStyle = .none
    let destination = Sidebar.Coordinator()
    let target = Sidebar.Node(title: "Test iPod", icon: "ipod", item: .device("test-device"), ejectable: true)
    let music = Sidebar.Node(title: "Music", icon: "music.note", item: .music)
    destination.sections = [Sidebar.Node(title: "iPods", children: [target]), Sidebar.Node(title: "Library", children: [music])]
    outline.dataSource = destination
    outline.delegate = destination
    let window = NSWindow(contentRect: outline.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = outline
    outline.reloadData()
    outline.expandItem(nil, expandChildren: true)
    window.makeKeyAndOrderFront(nil)
    defer { window.close() }
    let info = CheckDraggingInfo()
    info.draggingDestinationWindow = window
    info.draggingPasteboard = board
    board.clearContents()
    let token = TrackDrag.begin(rows.map(\.id))!
    let item = NSPasteboardItem(); item.setString(token, forType: .string)
    precondition(board.writeObjects([item]))
    let targetRow = outline.row(forItem: target)
    let targetRect = outline.rect(ofRow: targetRow)
    info.draggingLocation = outline.convert(NSPoint(x: 60, y: targetRect.midY), to: nil)
    precondition(destination.outlineView(outline, validateDrop: info, proposedItem: nil, proposedChildIndex: -1) == .copy)
    guard let row = outline.rowView(atRow: targetRow, makeIfNecessary: true) as? NeutralSidebarRow else { fatalError("Missing real drop row") }
    log("[check] real delegate feedback: native=\(row.isTargetForDropOperation), explicit=\(row.isMusicDropTarget)")
    precondition(row.isMusicDropTarget, "Delegate did not activate drop feedback")
    precondition(row.interiorBackgroundStyle == .emphasized)
    let rendered = NSImage(size: row.bounds.size)
    rendered.lockFocus()
    row.drawDraggingDestinationFeedback(in: row.bounds)
    rendered.unlockFocus()
    let pixels = NSBitmapImageRep(data: rendered.tiffRepresentation!)!
    let actual = pixels.colorAt(x: pixels.pixelsWide / 2, y: pixels.pixelsHigh / 2)!.usingColorSpace(.deviceRGB)!
    // Compare two rendered pixels so the bitmap's display color profile is identical.
    let reference = NSImage(size: row.bounds.size)
    reference.lockFocus()
    NSColor.controlAccentColor.setFill()
    row.bounds.fill()
    reference.unlockFocus()
    let referencePixels = NSBitmapImageRep(data: reference.tiffRepresentation!)!
    let accent = referencePixels.colorAt(x: referencePixels.pixelsWide / 2, y: referencePixels.pixelsHigh / 2)!.usingColorSpace(.deviceRGB)!
    log("[check] drop color=\(actual), accent=\(accent)")
    precondition(abs(actual.redComponent - accent.redComponent) < 0.03
        && abs(actual.greenComponent - accent.greenComponent) < 0.03
        && abs(actual.blueComponent - accent.blueComponent) < 0.03, "Drop target was not painted with accent color")
    outline.draggingExited(info)
    precondition(!row.isMusicDropTarget && row.interiorBackgroundStyle == .normal, "Exit left drop feedback active")
    _ = destination.outlineView(outline, validateDrop: info, proposedItem: nil, proposedChildIndex: -1)
    precondition(destination.outlineView(outline, acceptDrop: info, item: target, childIndex: -1))
    precondition(!row.isMusicDropTarget, "Drop left feedback active")
    precondition(Set(received) == Set(rows.map(\.id)))
    info.draggingLocation = outline.convert(NSPoint(x: 60, y: outline.rect(ofRow: outline.row(forItem: music)).midY), to: nil)
    precondition(destination.outlineView(outline, validateDrop: info, proposedItem: nil, proposedChildIndex: -1).isEmpty)
    TrackDrag.end()
    log("PASS: native 3-track pasteboard drop, whole-artist drop, external payload rejection, centered spinning glyph/resize lifecycle, accent drop feedback and busy eject guard")
}
@MainActor final class CheckDraggingInfo: NSObject, NSDraggingInfo {
    var draggingDestinationWindow: NSWindow?
    var draggingSourceOperationMask: NSDragOperation = .copy
    var draggingLocation = NSPoint.zero
    var draggedImageLocation = NSPoint.zero
    nonisolated var draggedImage: NSImage? { nil }
    var draggingPasteboard = NSPasteboard(name: .init("ipod-check"))
    var draggingSource: Any? = nil
    var draggingSequenceNumber = 1
    var draggingFormation = NSDraggingFormation.none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 3
    var springLoadingHighlight = NSSpringLoadingHighlight.none
    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?, classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}

#endif
