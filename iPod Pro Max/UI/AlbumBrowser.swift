import Foundation
import SwiftCrossUI

private func matchingAlbums(_ albums: [AlbumInfo], _ query: String) -> [AlbumInfo] {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    if query.isEmpty { return albums }
    return albums.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.artist.localizedCaseInsensitiveContains(query) }
}

#if canImport(AppKitBackend)
import AppKit
import AppKitBackend

struct AlbumBrowser: NSViewRepresentable {
    var albums: [AlbumInfo]
    var artworkFolder: URL?
    var query: String
    var onSelect: (String) -> Void
    var artworkSize: Double = 172
    var onArtworkSize: (Double) -> Void = { _ in }
    var onArtworkCommit: (Double) -> Void = { _ in }
    var onPlay: (TrackRow, [TrackRow]) -> Void = { _, _ in }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView { Self.makeScroll(coordinator: context.coordinator) }
    static func makeScroll(coordinator: Coordinator) -> NSScrollView {
        let collection = AlbumCollectionView()
        collection.coordinator = coordinator
        collection.backgroundColors = [.clear]
        collection.isSelectable = true
        collection.setDraggingSourceOperationMask(.copy, forLocal: true)
        collection.dataSource = coordinator; collection.delegate = coordinator
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 172, height: 222)
        layout.minimumInteritemSpacing = 20; layout.minimumLineSpacing = 20
        layout.sectionInset = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        collection.collectionViewLayout = layout
        // Assigning the first layout switches NSCollectionView out of legacy mode and clears registrations.
        collection.register(AlbumTile.self, forItemWithIdentifier: .init("album"))
        collection.register(AlbumExpansion.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionFooter, withIdentifier: .init("detail"))
        let scroll = NSScrollView(); scroll.documentView = collection
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.onSelect = onSelect; c.onArtworkSize = onArtworkSize; c.onArtworkCommit = onArtworkCommit; c.onPlay = onPlay
        guard let collection = scroll.documentView as? AlbumCollectionView else { return }
        let changed = !c.source.sameStorage(as: albums) || c.query != query || c.folder != artworkFolder
        // An unrelated update must not restore the pre-gesture size over a live pinch.
        let sizeChanged = !c.zoomActive && abs(c.artworkSize - artworkSize) > 0.5
        guard changed || sizeChanged else { return }
        c.source = albums; c.query = query; c.folder = artworkFolder
        if !c.zoomActive { c.artworkSize = artworkSize }
        if changed { c.albums = matchingAlbums(albums, query) }
        c.reflow(collection, reload: changed)
    }
    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout {
        var source: [AlbumInfo] = []
        var albums: [AlbumInfo] = [] {
            didSet {
                selectedIndex = selectedID.flatMap { id in albums.firstIndex { $0.id == id } }
                if selectedIndex == nil { selectedID = nil }
            }
        }
        var query = ""
        var folder: URL?
        var onSelect: (String) -> Void = { _ in }
        var onArtworkSize: (Double) -> Void = { _ in }
        var onArtworkCommit: (Double) -> Void = { _ in }
        var zoomActive = false
        var mouseTracking = false
        var dragStarted = false
        // Only the currently displayed covers are pinned through a collection reload.
        private var visibleArtwork: [URL: NSImage] = [:]
        var onPlay: (TrackRow, [TrackRow]) -> Void = { _, _ in }
        var artworkSize = 172.0
        private(set) var selectedID: String?
        private(set) var selectedIndex: Int?
        private var selectedAlbum: AlbumInfo? {
            guard let index = selectedIndex, albums.indices.contains(index) else { return nil }
            return albums[index]
        }
        var split = 0
        var columns = 0
        private var dragPayload: String?
        func updateZoom(_ size: Double, in collection: NSCollectionView) {
            zoomActive = true
            let size = min(280, max(110, size))
            guard abs(size - artworkSize) >= 0.1 else { return }
            artworkSize = size
            reflow(collection)
            onArtworkSize(size)
        }
        func finishZoom() {
            guard zoomActive else { return }
            zoomActive = false
            onArtworkCommit(artworkSize)
        }
        func reflow(_ collection: NSCollectionView, reload: Bool = false) {
            let previousSplit = split
            let hadSelection = selectedID != nil
            let n = max(1, Int((max(0, Double(collection.bounds.width) - 48) + 20) / (artworkSize + 20)))
            columns = n
            if let index = selectedIndex {
                split = min(albums.count, ((index / n) + 1) * n)
            } else { split = albums.count }
            if let layout = collection.collectionViewLayout as? NSCollectionViewFlowLayout {
                layout.itemSize = NSSize(width: artworkSize, height: artworkSize + 50)
                layout.invalidateLayout()
            }
            if reload || previousSplit != split || hadSelection != (selectedID != nil) {
                let visible = collection.visibleItems().compactMap { ($0 as? AlbumTile)?.displayedArtwork }
                if !visible.isEmpty { visibleArtwork = Dictionary(visible, uniquingKeysWith: { _, last in last }) }
                collection.reloadData()
            }
        }
        func numberOfSections(in collectionView: NSCollectionView) -> Int { selectedID == nil ? 1 : 2 }
        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
            selectedID == nil ? albums.count : (section == 0 ? split : albums.count - split)
        }
        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let tile = collectionView.makeItem(withIdentifier: .init("album"), for: indexPath) as! AlbumTile
            let album = albums[indexPath.item + (indexPath.section == 0 ? 0 : split)]
            let url = album.artworkKey.flatMap { key in folder?.appendingPathComponent(key + ".jpg") }
            tile.onActivate = { [weak self, weak collectionView, weak tile] in
                guard let self, let collectionView, let tile, let path = collectionView.indexPath(for: tile) else { return }
                self.activate(path, in: collectionView)
            }
            tile.show(album, folder: folder, selected: album.id == selectedID, retained: url.flatMap { visibleArtwork[$0] })
            return tile
        }
        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt paths: Set<IndexPath>) {
            guard !mouseTracking, let path = paths.first else { return }
            activate(path, in: collectionView)
        }
        func activate(_ path: IndexPath, in collectionView: NSCollectionView) {
            let index = path.item + (path.section == 0 ? 0 : split)
            guard albums.indices.contains(index) else { return }
            let id = albums[index].id
            if selectedID == id { selectedID = nil; selectedIndex = nil }
            else { selectedID = id; selectedIndex = index }
            collectionView.deselectAll(nil)
            reflow(collectionView, reload: true)
        }
        func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
            let index = indexPath.item + (indexPath.section == 0 ? 0 : split)
            guard albums.indices.contains(index) else { return nil }
            guard let payload = TrackDrag.begin(albums[index].rows.map(\.id)) else { return nil }
            dragPayload = payload
            dragStarted = true
            let item = NSPasteboardItem()
            item.setString(payload, forType: .string)
            return item
        }
        func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, dragOperation operation: NSDragOperation) {
            dragPayload = nil
            TrackDrag.end()
        }
        func collectionView(_ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout, referenceSizeForFooterInSection section: Int) -> NSSize {
            guard section == 0, let album = selectedAlbum else { return .zero }
            return NSSize(width: collectionView.bounds.width, height: CGFloat(max(230, min(560, 100 + album.rows.count * 30))))
        }
        func collectionView(_ collectionView: NSCollectionView, viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind, at indexPath: IndexPath) -> NSView {
            let detail = collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: .init("detail"), for: indexPath) as! AlbumExpansion
            if let album = selectedAlbum { detail.show(album, folder: folder, onPlay: onPlay) }
            return detail
        }
    }
}

private final class AlbumCollectionView: NSCollectionView {
    weak var coordinator: AlbumBrowser.Coordinator?
    override func beginGesture(with event: NSEvent) {
        coordinator?.zoomActive = true
        super.beginGesture(with: event)
    }
    override func magnify(with event: NSEvent) {
        guard let coordinator else { return }
        let size = coordinator.artworkSize * (1 + event.magnification * 2.4)
        // Stage only: no observed UI state is changed during the gesture. This also covers
        // an exit/eject before AppKit sends the final gesture event.
        coordinator.updateZoom(size, in: self)
        if event.phase == .ended || event.phase == .cancelled { finishZoom() }
    }
    override func endGesture(with event: NSEvent) {
        finishZoom()
        super.endGesture(with: event)
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { finishZoom() }
        super.viewWillMove(toWindow: newWindow)
    }
    private func finishZoom() {
        coordinator?.finishZoom()
    }
    override func mouseDown(with event: NSEvent) {
        guard let coordinator, let path = indexPathForItem(at: convert(event.locationInWindow, from: nil)) else {
            super.mouseDown(with: event); return
        }
        // NSCollectionView handles tracking/drag inside mouseDown. Don't reload its source item
        // until tracking has finished, otherwise AppKit can lose a newly started drag.
        coordinator.mouseTracking = true; coordinator.dragStarted = false
        super.mouseDown(with: event)
        coordinator.mouseTracking = false
        guard !coordinator.dragStarted else { return }
        if let window, indexPathForItem(at: convert(window.mouseLocationOutsideOfEventStream, from: nil)) == path {
            coordinator.activate(path, in: self)
        }
    }
    override func setFrameSize(_ newSize: NSSize) {
        let oldWidth = frame.width
        super.setFrameSize(newSize)
        guard abs(oldWidth - newSize.width) > 1, let coordinator else { return }
        let n = max(1, Int((max(0, Double(newSize.width) - 48) + 20) / (coordinator.artworkSize + 20)))
        if coordinator.columns != n { coordinator.reflow(self) }
    }
}

private final class AlbumExpansion: NSView {
    private let title = NSTextField(labelWithString: "")
    private let artist = NSTextField(labelWithString: "")
    private let scroll = NSScrollView()
    private let table = MusicTrackTable()
    private let tableCoordinator = TrackTable.Coordinator()
    private var album: AlbumInfo?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true; layer?.backgroundColor = NSColor.black.withAlphaComponent(0.24).cgColor
        title.font = .systemFont(ofSize: 24, weight: .bold)
        artist.font = .systemFont(ofSize: 16); artist.textColor = .controlAccentColor
        addSubview(title); addSubview(artist)
        for index in 0..<6 {
            let column = NSTableColumn(identifier: .init("\(index)"))
            column.isHidden = (2...4).contains(index)
            table.addTableColumn(column)
        }
        table.headerView = nil; table.rowHeight = 29; table.backgroundColor = .clear
        table.allowsMultipleSelection = true
        table.setDraggingSourceOperationMask(.copy, forLocal: true)
        tableCoordinator.showsArtwork = false
        table.coordinator = tableCoordinator
        table.dataSource = tableCoordinator; table.delegate = tableCoordinator
        table.target = tableCoordinator; table.doubleAction = #selector(TrackTable.Coordinator.playSelected(_:))
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        addSubview(scroll)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        let x: CGFloat = 24
        title.frame = NSRect(x: x, y: bounds.height - 54, width: max(0, bounds.width - x - 24), height: 30)
        artist.frame = NSRect(x: x, y: bounds.height - 78, width: max(0, bounds.width - x - 24), height: 22)
        scroll.frame = NSRect(x: x, y: 20, width: max(0, bounds.width - x - 24), height: max(0, bounds.height - 110))
        table.tableColumns[0].width = 36
        table.tableColumns[1].width = max(50, scroll.bounds.width - 110)
        table.tableColumns[5].width = 56
    }
    func show(_ album: AlbumInfo, folder: URL?, onPlay: @escaping (TrackRow, [TrackRow]) -> Void) {
        self.album = album; tableCoordinator.onPlay = onPlay; tableCoordinator.artworkFolder = folder
        title.stringValue = album.title; artist.stringValue = album.artist
        tableCoordinator.setRows(album.rows, in: table)
    }

}


private final class AccessibleAlbumTileView: NSView {
    var onPress: () -> Void = {}
    override func accessibilityPerformPress() -> Bool { onPress(); return true }
}

private final class AlbumTile: NSCollectionViewItem {
    var onActivate: () -> Void = {}
    private let shadow = NSView()
    private let cover = NSImageView()
    private let albumTitle = NSTextField(labelWithString: "")
    private let artist = NSTextField(labelWithString: "")
    private var task: Task<Void, Never>?
    private var albumID = ""
    private var artworkURL: URL?
    private var hasRealArtwork = false
    var displayedArtwork: (URL, NSImage)? {
        guard hasRealArtwork, let artworkURL, let image = cover.image else { return nil }
        return (artworkURL, image)
    }
    override init(nibName nibNameOrNil: NSNib.Name?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }
    override func viewDidLayout() {
        super.viewDidLayout()
        let width = view.bounds.width
        shadow.frame = NSRect(x: 2, y: 52, width: max(0, width - 4), height: max(0, width - 4))
        cover.frame = shadow.bounds
        shadow.layer?.shadowPath = CGPath(roundedRect: shadow.bounds, cornerWidth: 3, cornerHeight: 3, transform: nil)
        albumTitle.frame = NSRect(x: 0, y: 25, width: width, height: 19)
        artist.frame = NSRect(x: 0, y: 6, width: width, height: 17)
    }
    override func loadView() {
        let accessibleView = AccessibleAlbumTileView(frame: NSRect(x: 0, y: 0, width: 172, height: 222))
        accessibleView.setAccessibilityElement(true)
        accessibleView.setAccessibilityRole(.button)
        accessibleView.onPress = { [weak self] in self?.onActivate() }
        view = accessibleView
        cover.frame = NSRect(x: 0, y: 50, width: 172, height: 172)
        cover.imageScaling = .scaleProportionallyUpOrDown
        shadow.wantsLayer = true
        shadow.layer?.shadowColor = NSColor.black.cgColor; shadow.layer?.shadowOpacity = 0.28
        shadow.layer?.shadowRadius = 4; shadow.layer?.shadowOffset = CGSize(width: 0, height: -2)
        cover.wantsLayer = true; cover.layer?.cornerRadius = 3; cover.layer?.masksToBounds = true
        shadow.addSubview(cover)
        albumTitle.frame = NSRect(x: 0, y: 25, width: 172, height: 19)
        artist.frame = NSRect(x: 0, y: 6, width: 172, height: 17)
        albumTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        artist.font = .systemFont(ofSize: 12); artist.textColor = .secondaryLabelColor
        for field in [albumTitle, artist] { field.lineBreakMode = .byTruncatingTail }
        for child in [shadow, albumTitle, artist] { view.addSubview(child) }
    }
    func show(_ album: AlbumInfo, folder: URL?, selected: Bool, retained: NSImage? = nil) {
        _ = view
        albumID = album.id; task?.cancel()
        cover.layer?.borderWidth = selected ? 3 : 0
        cover.layer?.borderColor = NSColor.controlAccentColor.cgColor
        albumTitle.stringValue = album.title; artist.stringValue = album.artist
        view.setAccessibilityLabel("\(album.title), \(album.artist)")
        view.setAccessibilitySelected(selected)
        view.setAccessibilityExpanded(selected)
        guard let key = album.artworkKey, let folder else {
            artworkURL = nil; hasRealArtwork = false
            cover.image = systemSymbol("square.stack", pointSize: 55); return
        }
        let url = folder.appendingPathComponent(key + ".jpg")
        artworkURL = url
        if let image = retained ?? ThumbnailStore.shared.cached(url, pixels: 344) {
            hasRealArtwork = true; cover.image = image; return
        }
        hasRealArtwork = false
        cover.image = systemSymbol("square.stack", pointSize: 55)
        task = Task { [weak self] in
            let image = await ThumbnailStore.shared.image(url, pixels: 344)
            guard !Task.isCancelled, self?.albumID == album.id else { return }
            if let image { self?.cover.image = image; self?.hasRealArtwork = true }
        }
    }
    override func prepareForReuse() { super.prepareForReuse(); task?.cancel(); albumID = ""; artworkURL = nil; hasRealArtwork = false; cover.image = nil }
}
@MainActor func checkNativeAlbumGrid() {
    let coordinator = AlbumBrowser.Coordinator()
    coordinator.albums = [AlbumInfo(id: "check", title: "Album", year: "2026", rows: [], durationMs: 0)]
    let scroll = AlbumBrowser.makeScroll(coordinator: coordinator)
    let collection = scroll.documentView as! NSCollectionView
    let tile = coordinator.collectionView(collection, itemForRepresentedObjectAt: IndexPath(item: 0, section: 0))
    precondition(tile.view.subviews.count == 3)
    scroll.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
    let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = scroll
    collection.reloadData()
    window.layoutIfNeeded()
    collection.layoutSubtreeIfNeeded()
    precondition(collection.numberOfItems(inSection: 0) == 1)
    coordinator.collectionView(collection, didSelectItemsAt: [IndexPath(item: 0, section: 0)])
    precondition(coordinator.selectedID == "check" && coordinator.split == 1)
    precondition(coordinator.numberOfSections(in: collection) == 2)
    var stagedSizes: [Double] = [], committedSizes: [Double] = []
    coordinator.onArtworkSize = { stagedSizes.append($0) }
    coordinator.onArtworkCommit = { committedSizes.append($0) }
    coordinator.updateZoom(190, in: collection)
    coordinator.updateZoom(210, in: collection)
    precondition(stagedSizes == [190, 210] && committedSizes.isEmpty)
    coordinator.finishZoom()
    coordinator.finishZoom() // AppKit can send both an ended phase and endGesture.
    precondition(committedSizes == [210] && !coordinator.zoomActive)
    let opened = coordinator.albums[0]
    let other = AlbumInfo(id: "other", title: "Other", year: "", rows: [], durationMs: 0)
    coordinator.albums = [other, opened]
    coordinator.reflow(collection, reload: true)
    precondition(coordinator.selectedID == "check" && coordinator.selectedIndex == 1,
                 "An open album must keep its identity when the list is reordered")
    coordinator.albums = matchingAlbums(coordinator.albums, "Album")
    coordinator.reflow(collection, reload: true)
    precondition(coordinator.selectedID == "check" && coordinator.selectedIndex == 0,
                 "Filtering must relocate the selected album without dropping it")
    let accessibleTile = coordinator.collectionView(collection, itemForRepresentedObjectAt: IndexPath(item: 0, section: 0))
    precondition(accessibleTile.view.isAccessibilitySelected() && accessibleTile.view.isAccessibilityExpanded(),
                 "The open album must expose selected and expanded states")
    collection.layoutSubtreeIfNeeded()
    let footer = coordinator.collectionView(collection, viewForSupplementaryElementOfKind: NSCollectionView.elementKindSectionFooter, at: IndexPath(item: 0, section: 0))
    precondition(footer is AlbumExpansion)
    precondition(coordinator.collectionView(collection, layout: collection.collectionViewLayout!, referenceSizeForFooterInSection: 0).height > 0)
    coordinator.mouseTracking = true
    coordinator.collectionView(collection, didSelectItemsAt: [IndexPath(item: 0, section: 0)])
    precondition(coordinator.selectedID == "check", "A selection callback must not reload during mouse tracking")
    coordinator.mouseTracking = false
    coordinator.collectionView(collection, didSelectItemsAt: [IndexPath(item: 0, section: 0)])
    precondition(coordinator.selectedID == nil && coordinator.selectedIndex == nil)
    coordinator.albums = [opened, other]
    coordinator.activate(IndexPath(item: 0, section: 0), in: collection)
    coordinator.albums = [other]
    coordinator.reflow(collection, reload: true)
    precondition(coordinator.selectedID == nil && coordinator.selectedIndex == nil,
                 "Removing or filtering out an open album must close its detail")
    // None of these 100 covers is in ThumbnailStore: force the case where its bounded
    // cache has evicted every visible image, and verify a reload still keeps those images.
    coordinator.albums = (0..<100).map { index in
        AlbumInfo(id: "album-\(index)", title: "Album \(index)", year: "", artworkKey: "cover-\(index)", rows: [], durationMs: 0)
    }
    coordinator.folder = URL(fileURLWithPath: "/fixture")
    coordinator.reflow(collection, reload: true)
    collection.layoutSubtreeIfNeeded()
    let sample = NSImage(size: NSSize(width: 2, height: 2))
    let visible = collection.visibleItems()
    precondition(!visible.isEmpty)
    for item in visible {
        guard let tile = item as? AlbumTile, let path = collection.indexPath(for: item) else { continue }
        tile.show(coordinator.albums[path.item], folder: coordinator.folder, selected: false, retained: sample)
    }
    coordinator.reflow(collection, reload: true)
    collection.layoutSubtreeIfNeeded()
    precondition(collection.visibleItems().allSatisfy { ($0 as? AlbumTile)?.displayedArtwork?.1 === sample },
                 "Visible artwork must survive reload even when the shared thumbnail cache has evicted it")
    window.orderOut(nil)
    log("PASS: native album grid reuses tiles and retains visible artwork through reload")
}

#endif
