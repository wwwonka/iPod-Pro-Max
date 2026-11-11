#if canImport(WinUIBackend)
import Foundation
import SwiftCrossUI
import UWP
import WinUI
import WinUIBackend
import WindowsFoundation

/// One virtualized list item per row of covers; the expanded album is one extra list item.
struct AlbumBrowser: WinUIElementRepresentable {
    var albums: [AlbumInfo]
    var artworkFolder: URL?
    var query: String
    var onSelect: (String) -> Void
    var artworkSize: Double = 172
    var onArtworkSize: (Double) -> Void = { _ in }
    var onArtworkCommit: (Double) -> Void = { _ in }
    var onPlay: (TrackRow, [TrackRow]) -> Void = { _, _ in }

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeWinUIElement(context: Context) -> WinUI.ListView {
        let list = WinUI.ListView()
        list.selectionMode = .none
        let c = context.coordinator
        c.list = list
        list.containerContentChanging.addHandler { [weak c] _, args in
            MainActor.assumeIsolated {
                guard let c, let args, !args.inRecycleQueue, args.itemIndex >= 0 else { return }
                let row = Int(args.itemIndex)
                guard c.rows.indices.contains(row) else { return }
                switch c.rows[row] {
                case .covers(let start): args.itemContainer.content = c.makeCoverRow(start: start)
                case .detail(let id): args.itemContainer.content = c.makeDetail(id: id)
                }
                args.itemContainer.horizontalContentAlignment = .stretch
                args.handled = true
            }
        }
        list.sizeChanged.addHandler { [weak c, weak list] _, _ in
            MainActor.assumeIsolated {
                guard let c, let list else { return }
                c.width = list.actualWidth
                c.updateColumns()
            }
        }
        // Precision touchpads emit Ctrl+wheel for pinch on Windows. Keep ordinary wheel scrolling intact.
        list.pointerWheelChanged.addHandler { [weak c, weak list] _, args in
            MainActor.assumeIsolated {
                guard let c, let list, let args,
                      (args.keyModifiers.rawValue & UWP.VirtualKeyModifiers.control.rawValue) != 0,
                      let point = try? args.getCurrentPoint(list), let properties = point.properties else { return }
                let delta = Double(properties.mouseWheelDelta)
                guard delta != 0 else { return }
                c.setSize(c.artworkSize * pow(1.0015, delta))
                args.handled = true
            }
        }
        return list
    }
    func updateWinUIElement(_ list: WinUI.ListView, context: Context) {
        let c = context.coordinator
        c.onSelect = onSelect; c.onArtworkSize = onArtworkSize; c.onPlay = onPlay
        let changed = !c.source.sameStorage(as: albums) || c.query != query || c.folder != artworkFolder
        let sizeChanged = abs(c.artworkSize - artworkSize) > 0.5
        guard changed || sizeChanged else { return }
        if changed {
            c.source = albums; c.query = query; c.folder = artworkFolder
            let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
            c.albums = text.isEmpty ? albums : albums.filter { $0.title.localizedCaseInsensitiveContains(text) || $0.artist.localizedCaseInsensitiveContains(text) }
            if let id = c.selectedID, !c.albums.contains(where: { $0.id == id }) { c.selectedID = nil }
        }
        c.artworkSize = min(280, max(110, artworkSize))
        if changed { c.reload() } else { c.updateColumns(); c.updateVisibleSizes() }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, winUIElement: WinUI.ListView, context: Context) -> ViewSize {
        ViewSize(proposal.width ?? 600, proposal.height ?? 400)
    }

    final class Coordinator {
        enum Row { case covers(Int), detail(String) }
        final class Tile {
            let id: String
            let content: StackPanel
            let image: WinUI.Image
            let border: Border
            init(id: String, content: StackPanel, image: WinUI.Image, border: Border) {
                self.id = id; self.content = content; self.image = image; self.border = border
            }
        }
        var source: [AlbumInfo] = [], albums: [AlbumInfo] = []
        var rows: [Row] = []
        var query = ""
        var folder: URL?
        var width = 600.0, artworkSize = 172.0
        var columns = 3
        var selectedID: String?
        weak var list: WinUI.ListView?
        var onSelect: (String) -> Void = { _ in }
        var onArtworkSize: (Double) -> Void = { _ in }
        var onPlay: (TrackRow, [TrackRow]) -> Void = { _, _ in }
        private var tiles: [Tile] = []
        // Keep a small bounded cache so a rebuilt visible row doesn't flash its placeholder.
        private var bitmaps: [String: BitmapImage] = [:]
        private var bitmapOrder: [String] = []

        func setSize(_ raw: Double) {
            let size = min(280, max(110, raw))
            guard abs(size - artworkSize) >= 0.1 else { return }
            artworkSize = size
            updateColumns()
            updateVisibleSizes()
            onArtworkSize(size)
        }
        func updateColumns() {
            let count = max(1, Int(max(0, width - 24) / (artworkSize + 28)))
            guard count != columns else { return }
            columns = count; reload()
        }
        func updateVisibleSizes() {
            for tile in tiles {
                tile.content.width = artworkSize
                tile.image.width = artworkSize; tile.image.height = artworkSize
                tile.border.width = artworkSize; tile.border.height = artworkSize
            }
        }
        private func scrollViewer(_ element: DependencyObject) -> ScrollViewer? {
            if let scroll = element as? ScrollViewer { return scroll }
            for index in 0..<VisualTreeHelper.getChildrenCount(element) {
                if let child = VisualTreeHelper.getChild(element, index), let scroll = scrollViewer(child) { return scroll }
            }
            return nil
        }
        func reload() {
            guard let list else { return }
            let scroll = scrollViewer(list)
            let offset = scroll?.verticalOffset
            rows.removeAll(keepingCapacity: true)
            for start in stride(from: 0, to: albums.count, by: columns) {
                rows.append(.covers(start))
                if let id = selectedID, albums[start..<min(start + columns, albums.count)].contains(where: { $0.id == id }) {
                    rows.append(.detail(id))
                }
            }
            tiles.removeAll(keepingCapacity: true)
            list.items.clear()
            for index in rows.indices { list.items.append("album-row:\(index)") }
            if let scroll, let offset, let queue = list.dispatcherQueue {
                _ = try? queue.tryEnqueue(.low) { [weak scroll] in
                    _ = try? queue.tryEnqueue(.low) { [weak scroll] in
                        guard let scroll else { return }
                        _ = try? scroll.changeView(nil, offset, nil, true)
                    }
                }
            }
        }
        private func paintSelection(_ tile: Tile) {
            let selected = tile.id == selectedID
            let color = (try? UWP.UISettings().getColorValue(.accent)) ?? UWP.Color(a: 255, r: 0, g: 122, b: 255)
            let brush = SolidColorBrush(); brush.color = color
            tile.border.borderBrush = selected ? brush : nil
            let edge = selected ? 3.0 : 0.0
            tile.border.borderThickness = Thickness(left: edge, top: edge, right: edge, bottom: edge)
        }
        private func selectAlbum(_ id: String) {
            guard let list, let albumIndex = albums.firstIndex(where: { $0.id == id }) else { return }
            let next = selectedID == id ? nil : id
            if let old = rows.firstIndex(where: { if case .detail = $0 { return true }; return false }) {
                rows.remove(at: old); list.items.removeAt(UInt32(old))
            }
            selectedID = next
            if let next {
                let insertion = min(rows.count, albumIndex / columns + 1)
                rows.insert(.detail(next), at: insertion)
                list.items.insertAt(UInt32(insertion), "album-detail:\(next)")
            }
            for tile in tiles { paintSelection(tile) }
        }
        private func bitmap(for url: URL) -> BitmapImage {
            let key = url.absoluteString
            if let image = bitmaps[key] { return image }
            let image = BitmapImage(WindowsFoundation.Uri(key))
            image.decodePixelWidth = 344
            bitmaps[key] = image; bitmapOrder.append(key)
            if bitmapOrder.count > 80 { bitmaps.removeValue(forKey: bitmapOrder.removeFirst()) }
            return image
        }
        func makeCoverRow(start: Int) -> WinUI.Grid {
            let row = WinUI.Grid(); row.columnSpacing = 20
            for index in 0..<columns {
                let definition = ColumnDefinition()
                definition.width = GridLength(value: 1, gridUnitType: .star)
                row.columnDefinitions.append(definition)
                guard start + index < albums.count else { continue }
                let album = albums[start + index]
                let content = StackPanel(); content.spacing = 6; content.width = artworkSize
                let image = WinUI.Image(); image.width = artworkSize; image.height = artworkSize
                let hasArtwork = folder != nil && album.artworkKey != nil
                if let folder, let key = album.artworkKey {
                    image.source = bitmap(for: folder.appendingPathComponent(key + ".jpg"))
                }
                let border = Border(); border.width = artworkSize; border.height = artworkSize
                border.cornerRadius = CornerRadius(topLeft: 3, topRight: 3, bottomRight: 3, bottomLeft: 3)
                if hasArtwork { border.child = image }
                else {
                    let placeholder = TextBlock(); placeholder.text = "♪"; placeholder.fontSize = 48
                    placeholder.horizontalAlignment = .center; placeholder.verticalAlignment = .center
                    placeholder.opacity = 0.5; border.child = placeholder
                }
                content.children.append(border)
                let name = TextBlock(); name.text = album.title; name.textTrimming = .characterEllipsis
                let artist = TextBlock(); artist.text = album.artist; artist.fontSize = 12; artist.opacity = 0.65
                content.children.append(name); content.children.append(artist)
                let button = WinUI.Button(); button.content = content
                button.margin = Thickness(left: 4, top: 12, right: 4, bottom: 12)
                button.click.addHandler { [weak self] _, _ in MainActor.assumeIsolated {
                    guard let self else { return }
                    self.selectAlbum(album.id)
                } }
                button.canDrag = true
                button.dragStarting.addHandler { _, args in
                    MainActor.assumeIsolated {
                        guard let args, let token = TrackDrag.begin(album.rows.map(\.id)) else { args?.cancel = true; return }
                        do { try args.data.setText(token) } catch { args.cancel = true; TrackDrag.end(); return }
                        args.allowedOperations = .copy
                    }
                }
                button.dropCompleted.addHandler { _, _ in MainActor.assumeIsolated { TrackDrag.end() } }
                WinUI.Grid.setColumn(button, Int32(index)); row.children.append(button)
                let tile = Tile(id: album.id, content: content, image: image, border: border)
                paintSelection(tile)
                tiles.append(tile)
                // Bound retained wrappers even when the user scrolls through a huge library.
                if tiles.count > 64 { tiles.removeFirst(tiles.count - 64) }
            }
            return row
        }
        func makeDetail(id: String) -> StackPanel {
            let detail = StackPanel(); detail.spacing = 8
            detail.margin = Thickness(left: 24, top: 12, right: 24, bottom: 20)
            guard let album = albums.first(where: { $0.id == id }) else { return detail }
            let title = TextBlock(); title.text = album.title; title.fontSize = 23
            let artist = TextBlock(); artist.text = album.artist; artist.opacity = 0.7
            detail.children.append(title); detail.children.append(artist)
            let songs = WinUI.ListView(); songs.selectionMode = .multiple
            songs.height = min(460, max(80, Double(album.rows.count) * 38))
            for track in album.rows { songs.items.append("\(track.number)    \(track.title)    \(track.duration)") }
            songs.doubleTapped.addHandler { [weak self, weak songs] _, _ in
                MainActor.assumeIsolated {
                    guard let self, let songs else { return }
                    let index = Int(songs.selectedIndex)
                    guard album.rows.indices.contains(index), album.rows[index].path != nil else { return }
                    self.onPlay(album.rows[index], album.rows)
                }
            }
            songs.canDragItems = true
            songs.dragItemsStarting.addHandler { [weak songs] _, args in
                MainActor.assumeIsolated {
                    guard let songs, let args else { return }
                    var ids: [String] = []
                    for index in 0..<songs.selectedRanges.size {
                        guard let range = songs.selectedRanges.getAt(index), range.firstIndex >= 0,
                              Int(range.firstIndex) < album.rows.count else { continue }
                        let end = min(Int(range.lastIndex), album.rows.count - 1)
                        if end >= Int(range.firstIndex) {
                            ids.append(contentsOf: album.rows[Int(range.firstIndex)...end].map(\.id))
                        }
                    }
                    guard let payload = TrackDrag.begin(ids) else { args.cancel = true; return }
                    do { try args.data.setText(payload) } catch { args.cancel = true; TrackDrag.end(); return }
                    args.data.properties.title = "\(ids.count) songs"
                    args.data.requestedOperation = .copy
                }
            }
            songs.dragItemsCompleted.addHandler { _, _ in MainActor.assumeIsolated { TrackDrag.end() } }
            detail.children.append(songs)
            return detail
        }
    }
}
#endif
