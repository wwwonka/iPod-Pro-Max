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

    let row = NeutralSidebarRow(frame: NSRect(x: 0, y: 0, width: 100, height: 28))
    row.isTargetForDropOperation = true
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
    row.isTargetForDropOperation = false
    precondition(row.interiorBackgroundStyle == .normal)
    log("PASS: native 3-track pasteboard drop, whole-artist drop, external payload rejection, centered spinning glyph/resize lifecycle, accent drop feedback and busy eject guard")
}
#endif
