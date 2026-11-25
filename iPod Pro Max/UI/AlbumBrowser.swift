import Foundation
import SwiftCrossUI

#if canImport(AppKitBackend)
import AppKit
import AppKitBackend
import CoreImage

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
        defer {
            if let id = NativePlaybackReveal.pendingAlbumID { c.revealPlaybackTrack(id, in: collection) }
        }
        guard changed || sizeChanged else { return }
        let sameAlbums = c.source.sameStorage(as: albums)
        c.source = albums; c.query = query; c.folder = artworkFolder
        if !c.zoomActive { c.artworkSize = artworkSize }
        if changed { c.albums = c.filterAlbums(albums, query: query, sameSource: sameAlbums) }
        c.reflow(collection, reload: changed)
    }
    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout, NSDraggingSource {
        var source: [AlbumInfo] = []
        private var keysSource: [AlbumInfo] = []
        private var foldedKeys: [String] = []
        private var lastFoldedQuery = ""
        private var filteredIndices: [Int] = []

        func filterAlbums(_ albums: [AlbumInfo], query: String, sameSource: Bool) -> [AlbumInfo] {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                lastFoldedQuery = ""
                filteredIndices = []
                return albums
            }
            if !albums.sameStorage(as: keysSource) {
                foldedKeys = albums.map(FastSearch.albumKey)
                keysSource = albums
            }
            let needle = FastSearch.fold(trimmed)
            let narrowing = sameSource && !lastFoldedQuery.isEmpty && needle.hasPrefix(lastFoldedQuery)
            var nextIndices: [Int] = []
            var nextAlbums: [AlbumInfo] = []
            if narrowing {
                for i in filteredIndices where FastSearch.containsUTF8(foldedKeys[i], needle: needle) {
                    nextIndices.append(i)
                    nextAlbums.append(albums[i])
                }
            } else {
                for i in albums.indices where FastSearch.containsUTF8(foldedKeys[i], needle: needle) {
                    nextIndices.append(i)
                    nextAlbums.append(albums[i])
                }
            }
            lastFoldedQuery = needle
            filteredIndices = nextIndices
            return nextAlbums
        }
        var albums: [AlbumInfo] = [] {
            didSet {
                selectedIndex = selectedID.flatMap { id in albums.firstIndex { $0.id == id } }
                if selectedIndex == nil { selectedID = nil }
                let valid = Set(albums.map(\.id))
                selectedIDs = selectedIDs.intersection(valid)
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
        var interactionBlocked = false
        // Only the currently displayed covers are pinned through a collection reload.
        private var visibleArtwork: [URL: NSImage] = [:]
        weak var collectionView: NSCollectionView?
        var onPlay: (TrackRow, [TrackRow]) -> Void = { _, _ in }
        var artworkSize = 172.0
        private(set) var selectedID: String?
        private(set) var selectedIndex: Int?
        var selectedIDs: Set<String> = []
        private var selectedAlbum: AlbumInfo? {
            guard let index = selectedIndex, albums.indices.contains(index) else { return nil }
            return albums[index]
        }
        var split = 0
        var columns = 0
        var dragPayload: String?
        private var draggedTileIDs: Set<String> = []
        private var playbackSubscription: SwiftCrossUI.Cancellable?
        private var currentPlayingTrackID: String?
        private var isPlaybackPlaying = false
        @MainActor override init() {
            super.init()
            currentPlayingTrackID = PlaybackController.shared.track?.id
            isPlaybackPlaying = PlaybackController.shared.playing
            playbackSubscription = PlaybackController.shared.didChange.observe { [weak self] in
                MainActor.assumeIsolated { self?.refreshPlaybackState() }
            }
        }
        private func isAlbumPlaying(_ album: AlbumInfo) -> Bool {
            guard isPlaybackPlaying, let trackID = currentPlayingTrackID else { return false }
            return album.rows.contains { $0.id == trackID }
        }
        @MainActor private func refreshPlaybackState() {
            let trackID = PlaybackController.shared.track?.id
            let playing = PlaybackController.shared.playing
            guard trackID != currentPlayingTrackID || playing != isPlaybackPlaying else { return }
            currentPlayingTrackID = trackID
            isPlaybackPlaying = playing
            guard let collectionView else { return }
            for item in collectionView.visibleItems() {
                guard let tile = item as? AlbumTile,
                      let path = collectionView.indexPath(for: tile) else { continue }
                let index = path.item + (path.section == 0 ? 0 : split)
                guard albums.indices.contains(index) else { continue }
                tile.setAlbumPlaying(isAlbumPlaying(albums[index]), animated: true)
            }
        }
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
            self.collectionView = collectionView
            let tile = collectionView.makeItem(withIdentifier: .init("album"), for: indexPath) as! AlbumTile
            let album = albums[indexPath.item + (indexPath.section == 0 ? 0 : split)]
            let url = album.artworkKey.flatMap { key in folder?.appendingPathComponent(key + ".jpg") }
            tile.onActivate = { [weak self, weak collectionView, weak tile] in
                guard let self, let collectionView, let tile, let path = collectionView.indexPath(for: tile) else { return }
                self.activate(path, in: collectionView)
            }
            tile.onPlayAlbum = { [weak self] in
                guard let self, let first = album.rows.first else { return }
                if let activeID = PlaybackController.shared.track?.id, album.rows.contains(where: { $0.id == activeID }) {
                    PlaybackController.shared.toggle()
                } else {
                    self.onPlay(first, album.rows)
                }
            }
            let isSelected = selectedIDs.contains(album.id) || album.id == selectedID
            tile.show(
                album,
                folder: folder,
                selected: isSelected,
                isPlaying: isAlbumPlaying(album),
                interactionBlocked: interactionBlocked,
                draggingHidden: draggedTileIDs.contains(album.id),
                retained: url.flatMap { visibleArtwork[$0] }
            )
            return tile
        }
        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt paths: Set<IndexPath>) {
            guard !mouseTracking, let path = paths.first else { return }
            activate(path, in: collectionView)
        }
        @MainActor func revealPlaybackTrack(_ id: String, in collection: NSCollectionView) {
            guard let index = albums.firstIndex(where: { $0.rows.contains(where: { $0.id == id }) }) else { return }
            if selectedID != albums[index].id {
                selectedID = albums[index].id; selectedIndex = index; selectedIDs = [albums[index].id]
                reflow(collection, reload: true)
            }
            collection.layoutSubtreeIfNeeded()
            if let detail = collection.supplementaryView(forElementKind: NSCollectionView.elementKindSectionFooter, at: IndexPath(item: 0, section: 0)) as? AlbumExpansion,
               detail.revealPlaybackTrack(id) { NativePlaybackReveal.completeAlbum() }
        }
        func activate(_ path: IndexPath, in collectionView: NSCollectionView) {
            let index = path.item + (path.section == 0 ? 0 : split)
            guard albums.indices.contains(index) else { return }
            let id = albums[index].id
            let closing = (selectedID == id)
            if closing {
                selectedID = nil; selectedIndex = nil; selectedIDs = [id]
            } else {
                selectedID = id; selectedIndex = index; selectedIDs = [id]
            }
            collectionView.deselectAll(nil)
            reflow(collectionView, reload: true)
            guard !closing, let scroll = collectionView.enclosingScrollView else { return }
            collectionView.layoutSubtreeIfNeeded()
            let targetPath = IndexPath(item: index, section: 0)
            guard let attrs = collectionView.layoutAttributesForItem(at: targetPath) else { return }
            let maxY = max(0, collectionView.bounds.height - scroll.contentView.bounds.height)
            let targetY = max(0, min(maxY, attrs.frame.minY - 16))
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                scroll.contentView.animator().setBoundsOrigin(NSPoint(x: scroll.contentView.bounds.origin.x, y: targetY))
            }
        }
        func playAlbum(at path: IndexPath) {
            let index = path.item + (path.section == 0 ? 0 : split)
            guard albums.indices.contains(index), let first = albums[index].rows.first else { return }
            onPlay(first, albums[index].rows)
        }
        func toggleSelection(_ path: IndexPath, in collectionView: NSCollectionView) {
            let index = path.item + (path.section == 0 ? 0 : split)
            guard albums.indices.contains(index) else { return }
            let id = albums[index].id
            if selectedIDs.contains(id) { selectedIDs.remove(id) }
            else { selectedIDs.insert(id) }
            updateVisibleSelection(in: collectionView)
        }
        func selectAll(in collectionView: NSCollectionView) {
            selectedIDs = Set(albums.map(\.id))
            updateVisibleSelection(in: collectionView)
        }
        func setSelectedIDs(_ ids: Set<String>, in collectionView: NSCollectionView) {
            guard selectedIDs != ids else { return }
            selectedIDs = ids
            updateVisibleSelection(in: collectionView)
        }
        func setInteractionBlocked(_ blocked: Bool, in collectionView: NSCollectionView) {
            guard interactionBlocked != blocked else { return }
            interactionBlocked = blocked
            for item in collectionView.visibleItems() {
                (item as? AlbumTile)?.setInteractionBlocked(blocked)
            }
        }
        func albumID(at path: IndexPath) -> String? {
            let index = path.item + (path.section == 0 ? 0 : split)
            guard albums.indices.contains(index) else { return nil }
            return albums[index].id
        }
        private func updateVisibleSelection(in collectionView: NSCollectionView) {
            for item in collectionView.visibleItems() {
                guard let tile = item as? AlbumTile,
                      let path = collectionView.indexPath(for: tile),
                      let id = albumID(at: path) else { continue }
                tile.setSelected(selectedIDs.contains(id) || id == selectedID)
            }
        }
        func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
            let index = indexPath.item + (indexPath.section == 0 ? 0 : split)
            guard albums.indices.contains(index) else { return nil }
            guard let payload = TrackDrag.begin(albums[index].rows.map(\.id)) else { return nil }
            dragPayload = payload
            let item = NSPasteboardItem()
            item.setString(payload, forType: .string)
            return item
        }
        func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forItemsAt indexPaths: Set<IndexPath>) {
            dragStarted = true
        }
        func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, dragOperation operation: NSDragOperation) {
            endDragSession()
        }
        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .withinApplication ? .copy : []
        }
        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            endDragSession()
        }
        @MainActor private func endDragSession() {
            dragPayload = nil
            TrackDrag.end()
            draggedTileIDs.removeAll()
            interactionBlocked = false
            guard let collectionView else { return }
            for item in collectionView.visibleItems() {
                guard let tile = item as? AlbumTile else { continue }
                tile.setDraggingHidden(false)
                tile.setInteractionBlocked(false)
            }
        }
        @MainActor func beginDrag(for path: IndexPath, event: NSEvent, in collectionView: NSCollectionView) {
            self.collectionView = collectionView
            let index = path.item + (path.section == 0 ? 0 : split)
            guard albums.indices.contains(index) else { return }
            let clicked = albums[index]
            let draggedAlbums = selectedIDs.contains(clicked.id)
                ? albums.filter { selectedIDs.contains($0.id) }
                : [clicked]
            let trackIDs = draggedAlbums.flatMap { $0.rows.map(\.id) }
            guard let payload = TrackDrag.begin(trackIDs) else { return }
            dragPayload = payload
            dragStarted = true
            interactionBlocked = true
            draggedTileIDs = Set(draggedAlbums.map(\.id))
            for item in collectionView.visibleItems() {
                guard let tile = item as? AlbumTile,
                      let tilePath = collectionView.indexPath(for: tile),
                      let id = albumID(at: tilePath) else { continue }
                tile.setInteractionBlocked(true)
                if draggedTileIDs.contains(id) {
                    tile.setDraggingHidden(true)
                }
            }
            let item = NSPasteboardItem()
            item.setString(payload, forType: .string)
            let draggingItem = NSDraggingItem(pasteboardWriter: item)
            let frame = collectionView.layoutAttributesForItem(at: path)?.frame ?? NSRect(x: 0, y: 0, width: artworkSize, height: artworkSize)
            let preview = dragPreviewImage(for: draggedAlbums, clickedTile: collectionView.item(at: path) as? AlbumTile)
            let previewSize = preview.size
            let origin = NSPoint(x: frame.midX - previewSize.width / 2, y: frame.minY + (artworkSize - previewSize.height) / 2)
            draggingItem.setDraggingFrame(NSRect(origin: origin, size: previewSize), contents: preview)
            collectionView.beginDraggingSession(with: [draggingItem], event: event, source: self)
        }
        @MainActor private func artworkImage(for album: AlbumInfo, fallbackTile: AlbumTile?) -> NSImage {
            if let tileImage = fallbackTile?.displayedArtwork?.1 { return tileImage }
            if let key = album.artworkKey, let folder {
                let url = folder.appendingPathComponent(key + ".jpg")
                if let cached = visibleArtwork[url] ?? ThumbnailStore.shared.cached(url, pixels: 344) {
                    return cached
                }
            }
            return systemSymbol("square.stack", pointSize: 45) ?? NSImage()
        }
        @MainActor private func dragPreviewImage(for draggedAlbums: [AlbumInfo], clickedTile: AlbumTile?) -> NSImage {
            let side = round(artworkSize * 0.82)
            if draggedAlbums.count <= 1 {
                let source = draggedAlbums.first.map { artworkImage(for: $0, fallbackTile: clickedTile) } ?? NSImage()
                return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
                    NSGraphicsContext.current?.imageInterpolation = .high
                    let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
                    path.addClip()
                    source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.78)
                    return true
                }
            }
            let stackAlbums = Array(draggedAlbums.prefix(3))
            let canvasSize = NSSize(width: side + 28, height: side + 28)
            return NSImage(size: canvasSize, flipped: false) { _ in
                NSGraphicsContext.current?.imageInterpolation = .high
                let offsets: [(CGFloat, CGFloat, CGFloat)] = [(-6, 10, -4), (6, 4, 4), (0, 0, 0)]
                let start = max(0, offsets.count - stackAlbums.count)
                for (idx, album) in stackAlbums.enumerated().reversed() {
                    let (dx, dy, angle) = offsets[start + idx]
                    let img = self.artworkImage(for: album, fallbackTile: idx == 0 ? clickedTile : nil)
                    NSGraphicsContext.saveGraphicsState()
                    let center = NSPoint(x: canvasSize.width / 2 + dx, y: canvasSize.height / 2 + dy)
                    let xform = NSAffineTransform()
                    xform.translateX(by: center.x, yBy: center.y)
                    xform.rotate(byDegrees: angle)
                    xform.translateX(by: -side / 2, yBy: -side / 2)
                    xform.concat()
                    let rect = NSRect(x: 0, y: 0, width: side, height: side)
                    NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).addClip()
                    img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.85)
                    NSColor.white.withAlphaComponent(0.35).setStroke()
                    let border = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
                    border.lineWidth = 1
                    border.stroke()
                    NSGraphicsContext.restoreGraphicsState()
                }
                let badgeText = "\(draggedAlbums.count)" as NSString
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 12, weight: .bold),
                    .foregroundColor: NSColor.white
                ]
                let textSize = badgeText.size(withAttributes: attrs)
                let badgeW = max(22, textSize.width + 12)
                let badgeRect = NSRect(x: canvasSize.width - badgeW - 2, y: canvasSize.height - 24, width: badgeW, height: 22)
                NSColor.controlAccentColor.setFill()
                NSBezierPath(roundedRect: badgeRect, xRadius: 11, yRadius: 11).fill()
                badgeText.draw(at: NSPoint(x: badgeRect.midX - textSize.width / 2, y: badgeRect.midY - textSize.height / 2), withAttributes: attrs)
                return true
            }
        }
        func collectionView(_ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout, referenceSizeForFooterInSection section: Int) -> NSSize {
            guard section == 0, let album = selectedAlbum else { return .zero }
            return NSSize(width: collectionView.bounds.width, height: CGFloat(max(230, min(560, 100 + album.rows.count * 30))))
        }
        func collectionView(_ collectionView: NSCollectionView, viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind, at indexPath: IndexPath) -> NSView {
            let detail = collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: .init("detail"), for: indexPath) as! AlbumExpansion
            if let album = selectedAlbum { detail.show(album, folder: folder, onPlay: onPlay) }
            if let id = NativePlaybackReveal.pendingAlbumID, detail.revealPlaybackTrack(id) { NativePlaybackReveal.completeAlbum() }
            return detail
        }
    }
}

private final class SelectionMarqueeView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.16).cgColor
        layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.75).cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 2
    }
    required init?(coder: NSCoder) { fatalError() }
}

private final class AlbumCollectionView: NSCollectionView {
    weak var coordinator: AlbumBrowser.Coordinator?
    private lazy var marqueeView: SelectionMarqueeView = {
        let v = SelectionMarqueeView()
        v.isHidden = true
        addSubview(v)
        return v
    }()
    override var acceptsFirstResponder: Bool { true }
    override func selectAll(_ sender: Any?) {
        coordinator?.selectAll(in: self)
    }
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
        window?.makeFirstResponder(self)
        let startPoint = convert(event.locationInWindow, from: nil)
        guard let coordinator, let window else {
            super.mouseDown(with: event); return
        }
        // MUS-15: play button on hover starts/toggles playback without opening detail or changing selection.
        for item in visibleItems() {
            if let tile = item as? AlbumTile, tile.hitTestPlayButton(startPoint, in: self) {
                tile.setPlayButtonPressed(true)
                while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
                    let point = convert(next.locationInWindow, from: nil)
                    let inside = tile.hitTestPlayButton(point, in: self)
                    if next.type == .leftMouseDragged {
                        tile.setPlayButtonPressed(inside)
                    } else if next.type == .leftMouseUp {
                        tile.setPlayButtonPressed(false)
                        if inside { tile.onPlayAlbum() }
                        let currentPt = convert(window.mouseLocationOutsideOfEventStream, from: nil)
                        if !tile.containsArtworkPoint(currentPt, in: self) {
                            tile.forceMouseExited()
                        }
                        return
                    }
                }
                tile.setPlayButtonPressed(false)
                return
            }
        }
        let cmdHeld = event.modifierFlags.contains(.command)
        if let path = indexPathForItem(at: startPoint) {
            // Track click vs drag explicitly so NSCollectionView's internal tracking never swallows
            // clicks with small pointer jitter.
            while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
                let point = convert(next.locationInWindow, from: nil)
                if next.type == .leftMouseUp {
                    if indexPathForItem(at: point) == path {
                        if cmdHeld {
                            coordinator.toggleSelection(path, in: self)
                        } else if next.clickCount >= 2 {
                            coordinator.playAlbum(at: path)
                        } else {
                            coordinator.activate(path, in: self)
                        }
                    }
                    return
                }
                if hypot(point.x - startPoint.x, point.y - startPoint.y) >= 5 {
                    coordinator.beginDrag(for: path, event: event, in: self)
                    return
                }
            }
            return
        }
        // MUS-14: rubber-band selection starting in empty grid space.
        let initialSelected = cmdHeld ? coordinator.selectedIDs : []
        coordinator.setInteractionBlocked(true, in: self)
        var dragged = false
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let point = convert(next.locationInWindow, from: nil)
            if next.type == .leftMouseDragged {
                if !dragged && hypot(point.x - startPoint.x, point.y - startPoint.y) >= 4 {
                    dragged = true
                }
                if dragged {
                    let rect = NSRect(
                        x: min(startPoint.x, point.x),
                        y: min(startPoint.y, point.y),
                        width: abs(point.x - startPoint.x),
                        height: abs(point.y - startPoint.y)
                    )
                    marqueeView.frame = rect
                    marqueeView.isHidden = false
                    addSubview(marqueeView, positioned: .above, relativeTo: nil)
                    let attrs = collectionViewLayout?.layoutAttributesForElements(in: rect) ?? []
                    var hitIDs = Set<String>()
                    for attr in attrs where attr.representedElementCategory == .item {
                        if let path = attr.indexPath, let id = coordinator.albumID(at: path) {
                            hitIDs.insert(id)
                        }
                    }
                    coordinator.setSelectedIDs(initialSelected.union(hitIDs), in: self)
                }
            } else if next.type == .leftMouseUp {
                marqueeView.isHidden = true
                coordinator.setInteractionBlocked(false, in: self)
                if !dragged && !cmdHeld {
                    coordinator.setSelectedIDs([], in: self)
                }
                return
            }
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

@MainActor
private final class BlurredArtworkCache {
    static let shared = BlurredArtworkCache()
    private var cache: [URL: NSImage] = [:]
    private var inFlight: [URL: Task<Void, Never>] = [:]
    private nonisolated static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    func cached(_ url: URL) -> NSImage? { cache[url] }

    func image(for url: URL) async -> NSImage? {
        if let existing = cache[url] { return existing }
        if let existingTask = inFlight[url] {
            await existingTask.value
            return cache[url]
        }
        let task = Task<Void, Never> {
            guard let source = await ThumbnailStore.shared.image(url, pixels: 344),
                  let tiff = source.tiffRepresentation else {
                inFlight[url] = nil
                return
            }
            let result = await Task.detached(priority: .utility) { () -> (CGImage, NSSize)? in
                guard let ciImage = CIImage(data: tiff) else { return nil }
                let extent = ciImage.extent
                let clamped = ciImage.clampedToExtent()
                guard let blurFilter = CIFilter(name: "CIGaussianBlur") else { return nil }
                blurFilter.setValue(clamped, forKey: kCIInputImageKey)
                blurFilter.setValue(10.0, forKey: kCIInputRadiusKey)
                guard let output = blurFilter.outputImage?.cropped(to: extent),
                      let cgImage = BlurredArtworkCache.ciContext.createCGImage(output, from: extent) else {
                    return nil
                }
                return (cgImage, extent.size)
            }.value
            if let result {
                if cache.count >= 48 { cache.removeAll(keepingCapacity: true) }
                cache[url] = NSImage(cgImage: result.0, size: result.1)
            }
            inFlight[url] = nil
        }
        inFlight[url] = task
        await task.value
        return cache[url]
    }
}

private final class AlbumExpansion: NSView, NSCollectionViewElement {
    private let backgroundArtwork = NSImageView()
    private let artworkMask = CAGradientLayer()
    private let veil = NSView()
    private let title = NSTextField(labelWithString: "")
    private let artist = NSTextField(labelWithString: "")
    private let scroll = NSScrollView()
    private let table = MusicTrackTable()
    private let tableCoordinator = TrackTable.Coordinator()
    private var album: AlbumInfo?
    private var artworkURL: URL?
    private var blurTask: Task<Void, Never>?
    private var hasArtwork = false
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        backgroundArtwork.imageScaling = .scaleProportionallyUpOrDown
        backgroundArtwork.imageAlignment = .alignLeft
        backgroundArtwork.wantsLayer = true
        backgroundArtwork.layer?.masksToBounds = true
        backgroundArtwork.alphaValue = 0.62
        artworkMask.colors = [NSColor.white.cgColor, NSColor.white.cgColor, NSColor.clear.cgColor]
        artworkMask.locations = [0.0, 0.45, 1.0]
        artworkMask.startPoint = CGPoint(x: 0.0, y: 0.5)
        artworkMask.endPoint = CGPoint(x: 1.0, y: 0.5)
        backgroundArtwork.layer?.mask = artworkMask
        veil.wantsLayer = true
        addSubview(backgroundArtwork)
        addSubview(veil)
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
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.setDraggingSourceOperationMask(.copy, forLocal: true)
        tableCoordinator.showsArtwork = false
        table.coordinator = tableCoordinator
        table.dataSource = tableCoordinator; table.delegate = tableCoordinator
        table.target = tableCoordinator; table.doubleAction = #selector(TrackTable.Coordinator.playSelected(_:))
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = false; scroll.drawsBackground = false
        addSubview(scroll)
        applyAppearance()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }
    private func applyAppearance() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if hasArtwork {
            veil.layer?.backgroundColor = (isDark ? NSColor.black.withAlphaComponent(0.58) : NSColor.white.withAlphaComponent(0.68)).cgColor
        } else {
            veil.layer?.backgroundColor = (isDark ? NSColor.black.withAlphaComponent(0.24) : NSColor.black.withAlphaComponent(0.06)).cgColor
        }
    }
    override func layout() {
        super.layout()
        let artWidth = min(bounds.width, bounds.height)
        backgroundArtwork.frame = NSRect(x: 0, y: 0, width: artWidth, height: bounds.height)
        artworkMask.frame = backgroundArtwork.bounds
        veil.frame = bounds
        let x: CGFloat = 24
        title.frame = NSRect(x: x, y: bounds.height - 54, width: max(0, bounds.width - x - 24), height: 30)
        artist.frame = NSRect(x: x, y: bounds.height - 78, width: max(0, bounds.width - x - 24), height: 22)
        scroll.frame = NSRect(x: x, y: 20, width: max(0, bounds.width - x - 24), height: max(0, bounds.height - 110))
        scroll.layoutSubtreeIfNeeded()
        let available = max(120, scroll.contentView.bounds.width)
        let trackColW: CGFloat = 36
        let timeColW: CGFloat = 56
        let spacing = table.intercellSpacing.width * 2
        table.tableColumns[0].width = trackColW
        table.tableColumns[5].width = timeColW
        table.tableColumns[1].width = max(50, available - trackColW - timeColW - spacing - 8)
        table.frame.size.width = available
    }
    @discardableResult func revealPlaybackTrack(_ id: String) -> Bool {
        guard let index = tableCoordinator.rows.firstIndex(where: { $0.id == id }) else { return false }
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        table.scrollRowToVisible(index)
        return true
    }
    func show(_ album: AlbumInfo, folder: URL?, onPlay: @escaping (TrackRow, [TrackRow]) -> Void) {
        self.album = album; tableCoordinator.onPlay = onPlay; tableCoordinator.artworkFolder = folder
        title.stringValue = album.title
        artist.stringValue = album.year.isEmpty ? album.artist : "\(album.artist) · \(album.year)"
        tableCoordinator.setRows(album.rows, in: table)
        blurTask?.cancel()
        guard let key = album.artworkKey, let folder else {
            artworkURL = nil; hasArtwork = false; backgroundArtwork.image = nil; applyAppearance()
            return
        }
        let url = folder.appendingPathComponent(key + ".jpg")
        artworkURL = url
        if let cached = BlurredArtworkCache.shared.cached(url) {
            hasArtwork = true; backgroundArtwork.image = cached; applyAppearance()
            return
        }
        hasArtwork = false; backgroundArtwork.image = nil; applyAppearance()
        blurTask = Task { [weak self] in
            let blurred = await BlurredArtworkCache.shared.image(for: url)
            guard !Task.isCancelled, self?.artworkURL == url, let blurred else { return }
            self?.hasArtwork = true
            self?.backgroundArtwork.image = blurred
            self?.applyAppearance()
        }
    }
}


private final class AccessibleAlbumTileView: NSView {
    var onPress: () -> Void = {}
    var onUpdateTrackingAreas: () -> Void = {}
    override func accessibilityPerformPress() -> Bool { onPress(); return true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        onUpdateTrackingAreas()
    }
}

private final class AlbumPlayButton: NSVisualEffectView {
    private let tintOverlay = NSView()
    private let accentOverlay = NSView()
    private let playIcon = NSImageView()
    private let pauseIcon = NSImageView()
    private var hoverTrackingArea: NSTrackingArea?
    private var isPlaying = false
    private var isPressed = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.masksToBounds = true

        tintOverlay.wantsLayer = true
        tintOverlay.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.24).cgColor
        accentOverlay.wantsLayer = true
        accentOverlay.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.92).cgColor
        accentOverlay.alphaValue = 0

        playIcon.image = systemSymbol("play.fill", pointSize: 13)
        playIcon.contentTintColor = .white
        playIcon.wantsLayer = true

        pauseIcon.image = systemSymbol("pause.fill", pointSize: 13)
        pauseIcon.contentTintColor = .white
        pauseIcon.wantsLayer = true
        pauseIcon.alphaValue = 0

        for child in [tintOverlay, accentOverlay, playIcon, pauseIcon] {
            addSubview(child)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.width / 2
        tintOverlay.frame = bounds
        accentOverlay.frame = bounds
        let iconSide = max(12, round(bounds.width * 0.48))
        let originY = round((bounds.height - iconSide) / 2)
        let originX = round((bounds.width - iconSide) / 2)
        playIcon.frame = NSRect(x: originX + 1, y: originY, width: iconSide, height: iconSide)
        pauseIcon.frame = NSRect(x: originX, y: originY, width: iconSide, height: iconSide)
        playIcon.layer?.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        playIcon.layer?.position = CGPoint(x: playIcon.frame.midX, y: playIcon.frame.midY)
        pauseIcon.layer?.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        pauseIcon.layer?.position = CGPoint(x: pauseIcon.frame.midX, y: pauseIcon.frame.midY)
        if hoverTrackingArea?.rect != bounds {
            if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeAlways],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            hoverTrackingArea = area
        }
    }

    override func mouseEntered(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.07
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            accentOverlay.animator().alphaValue = 1
        }
    }

    override func mouseExited(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.10
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            accentOverlay.animator().alphaValue = 0
        }
    }

    func resetHover() {
        accentOverlay.alphaValue = 0
    }

    func setPressed(_ pressed: Bool) {
        guard isPressed != pressed, let layer else { return }
        isPressed = pressed
        let center = CGPoint(x: frame.midX, y: frame.midY)
        if layer.anchorPoint != CGPoint(x: 0.5, y: 0.5) {
            layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            layer.position = center
        }
        let targetScale: CGFloat = pressed ? 0.94 : 1.0
        let anim = CABasicAnimation(keyPath: "transform.scale")
        anim.fromValue = (layer.presentation()?.value(forKeyPath: "transform.scale") as? CGFloat) ?? (pressed ? 1.0 : 0.94)
        anim.toValue = targetScale
        anim.duration = pressed ? 0.07 : 0.12
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.transform = CATransform3DMakeScale(targetScale, targetScale, 1)
        layer.add(anim, forKey: "pressScale")
    }

    func setPlaying(_ playing: Bool, animated: Bool) {
        guard isPlaying != playing || !animated else { return }
        isPlaying = playing
        let showView = playing ? pauseIcon : playIcon
        let hideView = playing ? playIcon : pauseIcon
        if !animated {
            showView.alphaValue = 1
            showView.layer?.transform = CATransform3DIdentity
            hideView.alphaValue = 0
            hideView.layer?.transform = CATransform3DIdentity
            return
        }
        showView.layer?.transform = CATransform3DMakeScale(0.65, 0.65, 1)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            showView.animator().alphaValue = 1
            hideView.animator().alphaValue = 0
            let grow = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue = 0.65
            grow.toValue = 1.0
            grow.duration = 0.18
            grow.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            showView.layer?.transform = CATransform3DIdentity
            showView.layer?.add(grow, forKey: "symbolReplace")
            let shrink = CABasicAnimation(keyPath: "transform.scale")
            shrink.fromValue = 1.0
            shrink.toValue = 0.65
            shrink.duration = 0.18
            shrink.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            hideView.layer?.transform = CATransform3DMakeScale(0.65, 0.65, 1)
            hideView.layer?.add(shrink, forKey: "symbolReplace")
        }
    }

    func reset() {
        isPressed = false
        isPlaying = false
        accentOverlay.alphaValue = 0
        layer?.removeAllAnimations()
        layer?.transform = CATransform3DIdentity
        playIcon.alphaValue = 1
        playIcon.layer?.transform = CATransform3DIdentity
        pauseIcon.alphaValue = 0
        pauseIcon.layer?.transform = CATransform3DIdentity
    }
}

private final class AlbumTile: NSCollectionViewItem {
    var onActivate: () -> Void = {}
    var onPlayAlbum: () -> Void = {}
    private let selectionRing = NSView()
    private let shadow = NSView()
    private let cover = NSImageView()
    private let playButton = AlbumPlayButton()
    private let albumTitle = NSTextField(labelWithString: "")
    private let artist = NSTextField(labelWithString: "")
    private var task: Task<Void, Never>?
    private var trackingArea: NSTrackingArea?
    private var albumID = ""
    private var artworkURL: URL?
    private var hasRealArtwork = false
    private var canPlay = false
    private var tileSelected = false
    private var isHovered = false
    private var interactionBlocked = false
    private var isDraggingHidden = false
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
        selectionRing.frame = NSRect(x: 0, y: 50, width: width, height: width)
        shadow.frame = selectionRing.frame.insetBy(dx: 3, dy: 3)
        cover.frame = shadow.bounds
        shadow.layer?.shadowPath = CGPath(roundedRect: shadow.bounds, cornerWidth: 3, cornerHeight: 3, transform: nil)
        let btnSize = min(32, max(24, round(shadow.frame.width * 0.165)))
        playButton.frame = NSRect(
            x: shadow.frame.minX + 7,
            y: shadow.frame.minY + 7,
            width: btnSize,
            height: btnSize
        )
        albumTitle.frame = NSRect(x: 0, y: 25, width: width, height: 19)
        artist.frame = NSRect(x: 0, y: 6, width: width, height: 17)
        refreshTrackingArea()
    }
    private func refreshTrackingArea() {
        guard trackingArea?.rect != shadow.frame else { return }
        if let trackingArea { view.removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: shadow.frame,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        view.addTrackingArea(area)
        trackingArea = area
    }
    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updatePlayButtonVisibility(animated: true)
    }
    override func mouseExited(with event: NSEvent) {
        isHovered = false
        playButton.resetHover()
        updatePlayButtonVisibility(animated: true)
    }
    private func cursorInsideArtwork() -> Bool {
        guard let window = view.window else { return false }
        let pt = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return shadow.frame.contains(pt)
    }
    func containsArtworkPoint(_ pointInCollectionView: NSPoint, in collectionView: NSCollectionView) -> Bool {
        let pt = view.convert(pointInCollectionView, from: collectionView)
        return shadow.frame.contains(pt)
    }
    func forceMouseExited() {
        isHovered = false
        playButton.resetHover()
        updatePlayButtonVisibility(animated: true)
    }
    func hitTestPlayButton(_ pointInCollectionView: NSPoint, in collectionView: NSCollectionView) -> Bool {
        guard canPlay && !interactionBlocked && !isDraggingHidden && playButton.alphaValue > 0.05 else { return false }
        let pt = view.convert(pointInCollectionView, from: collectionView)
        return playButton.frame.insetBy(dx: -4, dy: -4).contains(pt)
    }
    func setPlayButtonPressed(_ pressed: Bool) {
        playButton.setPressed(pressed)
    }
    func setAlbumPlaying(_ playing: Bool, animated: Bool) {
        playButton.setPlaying(playing, animated: animated)
    }
    func setSelected(_ selected: Bool) {
        tileSelected = selected
        view.setAccessibilitySelected(selected)
        view.setAccessibilityExpanded(selected)
        updateTileAppearance(animated: false)
    }
    func setInteractionBlocked(_ blocked: Bool) {
        interactionBlocked = blocked
        updatePlayButtonVisibility(animated: false)
    }
    func setDraggingHidden(_ hidden: Bool) {
        isDraggingHidden = hidden
        updateTileAppearance(animated: true)
        updatePlayButtonVisibility(animated: false)
    }
    private func updatePlayButtonVisibility(animated: Bool) {
        let show = isHovered && canPlay && !interactionBlocked && !isDraggingHidden
        let target: CGFloat = show ? 1 : 0
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.14
                playButton.animator().alphaValue = target
            }
        } else {
            playButton.alphaValue = target
        }
    }
    private func updateTileAppearance(animated: Bool) {
        let showBorder = tileSelected && !isDraggingHidden
        let ringAlpha: CGFloat = showBorder ? 1 : 0
        selectionRing.layer?.borderColor = NSColor.controlAccentColor.cgColor
        let textAlpha: CGFloat = isDraggingHidden ? 0 : 1
        let coverAlpha: CGFloat = isDraggingHidden ? 0.35 : 1
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.14
                selectionRing.animator().alphaValue = ringAlpha
                albumTitle.animator().alphaValue = textAlpha
                artist.animator().alphaValue = textAlpha
                shadow.animator().alphaValue = coverAlpha
            }
        } else {
            selectionRing.alphaValue = ringAlpha
            albumTitle.alphaValue = textAlpha
            artist.alphaValue = textAlpha
            shadow.alphaValue = coverAlpha
        }
    }
    override func loadView() {
        let accessibleView = AccessibleAlbumTileView(frame: NSRect(x: 0, y: 0, width: 172, height: 222))
        accessibleView.setAccessibilityElement(true)
        accessibleView.setAccessibilityRole(.button)
        accessibleView.onPress = { [weak self] in self?.onActivate() }
        accessibleView.onUpdateTrackingAreas = { [weak self] in self?.refreshTrackingArea() }
        view = accessibleView
        selectionRing.frame = NSRect(x: 0, y: 50, width: 172, height: 172)
        selectionRing.wantsLayer = true
        selectionRing.layer?.cornerRadius = 6
        selectionRing.layer?.borderWidth = 3
        selectionRing.layer?.borderColor = NSColor.controlAccentColor.cgColor
        selectionRing.alphaValue = 0
        cover.frame = NSRect(x: 0, y: 0, width: 166, height: 166)
        cover.imageScaling = .scaleProportionallyUpOrDown
        shadow.wantsLayer = true
        shadow.layer?.shadowColor = NSColor.black.cgColor; shadow.layer?.shadowOpacity = 0.28
        shadow.layer?.shadowRadius = 4; shadow.layer?.shadowOffset = CGSize(width: 0, height: -2)
        cover.wantsLayer = true; cover.layer?.cornerRadius = 3; cover.layer?.masksToBounds = true
        shadow.addSubview(cover)
        playButton.alphaValue = 0
        albumTitle.frame = NSRect(x: 0, y: 25, width: 172, height: 19)
        artist.frame = NSRect(x: 0, y: 6, width: 172, height: 17)
        albumTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        artist.font = .systemFont(ofSize: 12); artist.textColor = .secondaryLabelColor
        for field in [albumTitle, artist] { field.lineBreakMode = .byTruncatingTail }
        for child in [selectionRing, shadow, playButton, albumTitle, artist] { view.addSubview(child) }
    }
    func show(
        _ album: AlbumInfo,
        folder: URL?,
        selected: Bool,
        isPlaying: Bool = false,
        interactionBlocked: Bool = false,
        draggingHidden: Bool = false,
        retained: NSImage? = nil
    ) {
        _ = view
        albumID = album.id; task?.cancel()
        canPlay = !album.rows.isEmpty
        tileSelected = selected
        isHovered = cursorInsideArtwork()
        self.interactionBlocked = interactionBlocked
        isDraggingHidden = draggingHidden
        playButton.setPlaying(isPlaying, animated: false)
        updateTileAppearance(animated: false)
        updatePlayButtonVisibility(animated: false)
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
    override func prepareForReuse() {
        super.prepareForReuse()
        task?.cancel()
        albumID = ""
        artworkURL = nil
        hasRealArtwork = false
        canPlay = false
        tileSelected = false
        isHovered = false
        interactionBlocked = false
        isDraggingHidden = false
        playButton.alphaValue = 0
        playButton.reset()
        albumTitle.alphaValue = 1
        artist.alphaValue = 1
        shadow.alphaValue = 1
        selectionRing.alphaValue = 0
        cover.image = nil
    }
}
@MainActor func checkNativeAlbumGrid() {
    let coordinator = AlbumBrowser.Coordinator()
    coordinator.albums = [AlbumInfo(id: "check", title: "Album", year: "2026", rows: [], durationMs: 0)]
    let scroll = AlbumBrowser.makeScroll(coordinator: coordinator)
    let collection = scroll.documentView as! NSCollectionView
    let tile = coordinator.collectionView(collection, itemForRepresentedObjectAt: IndexPath(item: 0, section: 0))
    func includesArtwork(_ view: NSView) -> Bool { view is NSImageView || view.subviews.contains(where: includesArtwork) }
    precondition(includesArtwork(tile.view), "Album tiles must retain their artwork view")
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
    coordinator.albums = coordinator.filterAlbums(coordinator.albums, query: "Album", sameSource: false)
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
