#if canImport(AppKitBackend)
import AppKit
import iPodKit

/// Opt-in native regression check, no music writes and no use of the user's clipboard.
@MainActor
func checkNativeMusicInteractions() async {
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

    // A retained podcast table under an iPod page must neither hit-test nor start a drag.
    let retainedScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    retainedScroll.documentView = table
    source.setActive(false, in: retainedScroll)
    precondition(retainedScroll.isHidden && source.rows.count == 3)
    precondition(source.tableView(table, pasteboardWriterForRow: 0) == nil)
    precondition(TrackDrag.payload == nil && TrackDrag.ids.isEmpty)
    source.setActive(true, in: retainedScroll)
    board.clearContents()
    precondition(board.writeObjects([source.tableView(table, pasteboardWriterForRow: 0)!]))
    precondition(TrackDrag.accept(musicDragPayload(in: board), device: "test-device"), "Returning to podcasts reused a stale drag token")
    precondition(Set(received) == Set(rows.map(\.id)))
    source.setActive(false, in: retainedScroll)
    log("PASS: retained hidden podcast table rejects drags, clears its token and resumes safely")

    // The artist page's visible song list, including a selection spanning album headings.
    let albumSource = ArtistTrackList.Coordinator()
    albumSource.entries = [.album(AlbumInfo(id: "one", title: "One", year: "", rows: [rows[0]], durationMs: 0)),
                           .song(rows[0]),
                           .album(AlbumInfo(id: "two", title: "Two", year: "", rows: Array(rows[1...]), durationMs: 0)),
                           .song(rows[1]), .song(rows[2])]
    table.dataSource = albumSource
    table.delegate = albumSource
    table.reloadData()
    precondition(!albumSource.tableView(table, shouldSelectRow: 0))
    precondition(albumSource.tableView(table, shouldSelectRow: 1))
    table.selectRowIndexes(IndexSet([1, 3, 4]), byExtendingSelection: false)
    board.clearContents()
    let albumWriters = [1, 3, 4].compactMap { albumSource.tableView(table, pasteboardWriterForRow: $0) }
    precondition(albumWriters.count == 3 && board.writeObjects(albumWriters))
    precondition(TrackDrag.accept(musicDragPayload(in: board), device: "test-device"))
    precondition(Set(received) == Set(rows.map(\.id)), "Artist album list lost a cross-album selection")
    TrackDrag.end()
    log("PASS: artist album list selection and 3-track drag across album headings")

    let artist = ArtistList.Coordinator()
    artist.artists = [NamedGroup(id: "Artist A", count: 1), NamedGroup(id: "Artist B", count: 2)]
    artist.tracksByArtist = ["Artist A": [rows[0]], "Artist B": Array(rows[1...])]
    table.dataSource = artist
    table.delegate = artist
    table.reloadData()
    table.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)
    var selected: Set<String> = []
    artist.onSelect = { selected = $0 }
    artist.tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification, object: table))
    precondition(selected == Set(["Artist A", "Artist B"]))
    board.clearContents()
    precondition(board.writeObjects([artist.tableView(table, pasteboardWriterForRow: 0)!]))
    precondition(TrackDrag.accept(musicDragPayload(in: board), device: "test-device"))
    precondition(Set(received) == Set(rows.map(\.id)), "Multi-artist drag omitted tracks")
    TrackDrag.end()
    let cache = ArtistSelectionCache()
    var library = Library(source: "check", allRows: rows, artists: artist.artists, rowsByArtist: artist.tracksByArtist,
        albumsByArtist: ["Artist A": [AlbumInfo(id: "a", title: "A", year: "", rows: [rows[0]], durationMs: 0)],
                         "Artist B": [AlbumInfo(id: "b", title: "B", year: "", rows: Array(rows[1...]), durationMs: 0)]],
        artworkFolder: nil, playlists: [], rowsByPlaylist: [:], loadMs: 0, indexMs: 0)
    let combined = cache.group(library, selected: selected)!
    precondition(combined.albums.count == 2 && combined.artist.count == 3 && combined.photoArtist == nil)
    let again = cache.group(library, selected: selected)!
    precondition(combined.albums.sameStorage(as: again.albums))
    library.artists[0].photo = URL(fileURLWithPath: "/check/photo.jpg")
    precondition(cache.group(library, selected: selected)!.albums.sameStorage(as: combined.albums), "Photo update rebuilt selected albums")
    precondition(cache.group(library, selected: []) == nil)
    log("PASS: multi-artist native selection, combined drag and stable album buffers on photo updates")

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
    precondition(outline.draggingUpdated(info) == .copy)
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
    _ = outline.draggingUpdated(info)
    precondition(outline.prepareForDragOperation(info) && outline.performDragOperation(info))
    precondition(!row.isMusicDropTarget, "Drop left feedback active")
    precondition(Set(received) == Set(rows.map(\.id)))
    info.draggingLocation = outline.convert(NSPoint(x: 60, y: outline.rect(ofRow: outline.row(forItem: music)).midY), to: nil)
    precondition(outline.draggingUpdated(info).isEmpty)
    TrackDrag.end()
    await checkViewCaches()
    log("PASS: native 3-track pasteboard drop, whole-artist drop, external payload rejection, centered spinning glyph/resize lifecycle, accent drop feedback and busy eject guard")
}
/// Real disk fixtures, isolated from the launching iPod and the user's media.
@MainActor private func checkViewCaches() async {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ippm-view-cache-" + UUID().uuidString)
    let ipod = root.appendingPathComponent("ipod")
    let store = PortableLibraryStore(root: ipod, hostID: "check")
    let pictures = root.appendingPathComponent("Pictures")
    await Task.detached {
        try! IPodDevice.createSimulatedIPod(at: ipod)
        try! FileManager.default.createDirectory(at: pictures, withIntermediateDirectories: true)
        _ = try! store.register(name: "View check")
        try! store.addSource(kind: .photos, path: pictures.path)
        // Folder enumeration needs no valid pixel data; thumbnail decoding has its own fixture below.
        try! Data().write(to: pictures.appendingPathComponent("one.jpg"))
    }.value
    let inventory = PhotoInventory.shared
    let scans = inventory.scanCount
    async let first = inventory.load(store)
    async let joined = inventory.load(store)
    let (a, b) = await (first, joined)
    precondition(a.counts.values.reduce(0, +) == 1 && b.counts == a.counts)
    _ = await inventory.load(store)
    precondition(inventory.scanCount == scans + 1, "Photos navigation rescanned folders")
    await Task.detached { try! Data().write(to: pictures.appendingPathComponent("two.jpg")) }.value
    let refreshed = await inventory.load(store, refresh: true)
    precondition(refreshed.counts.values.reduce(0, +) == 2 && inventory.scanCount == scans + 2)
    let otherHost = PortableLibraryStore(root: ipod, hostID: "other")
    let other = await inventory.load(otherHost)
    precondition(other.folders.isEmpty, "Photo cache leaked one host's sources to another")
    let thumbnail = pictures.appendingPathComponent("thumbnail.png")
    let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")!
    await Task.detached { try! png.write(to: thumbnail) }.value
    @MainActor @Sendable func thumbnailWasCached() async -> Bool {
        guard let image = await ThumbnailStore.shared.image(thumbnail, pixels: 68) else { return false }
        return ThumbnailStore.shared.cached(thumbnail, pixels: 68) === image
    }
    async let imageA = thumbnailWasCached()
    async let imageB = thumbnailWasCached()
    let (cachedA, cachedB) = await (imageA, imageB)
    precondition(cachedA && cachedB, "Thumbnail requests did not share their cached result")
    log("PASS: concurrent thumbnail loads share one cached image")
    await Task.detached { try? FileManager.default.removeItem(at: root) }.value
    log("PASS: Photos concurrent loads share one scan; navigation adds zero scans; Refresh sees changes; host caches are isolated")
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
