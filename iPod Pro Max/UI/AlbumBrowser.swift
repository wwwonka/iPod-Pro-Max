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
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView { Self.makeScroll(coordinator: context.coordinator) }
    static func makeScroll(coordinator: Coordinator) -> NSScrollView {
        let collection = NSCollectionView()
        collection.backgroundColors = [.clear]
        collection.isSelectable = true
        collection.dataSource = coordinator; collection.delegate = coordinator
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 172, height: 222)
        layout.minimumInteritemSpacing = 20; layout.minimumLineSpacing = 20
        layout.sectionInset = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        collection.collectionViewLayout = layout
        // Assigning the first layout switches NSCollectionView out of legacy mode and clears registrations.
        collection.register(AlbumTile.self, forItemWithIdentifier: .init("album"))
        let scroll = NSScrollView(); scroll.documentView = collection
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.onSelect = onSelect
        guard !c.source.sameStorage(as: albums) || c.query != query || c.folder != artworkFolder else { return }
        c.source = albums; c.query = query; c.folder = artworkFolder
        c.albums = matchingAlbums(albums, query)
        (scroll.documentView as? NSCollectionView)?.reloadData()
    }
    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
        var source: [AlbumInfo] = [], albums: [AlbumInfo] = []
        var query = ""
        var folder: URL?
        var onSelect: (String) -> Void = { _ in }
        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { albums.count }
        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let tile = collectionView.makeItem(withIdentifier: .init("album"), for: indexPath) as! AlbumTile
            tile.show(albums[indexPath.item], folder: folder)
            return tile
        }
        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt paths: Set<IndexPath>) {
            guard let index = paths.first?.item, albums.indices.contains(index) else { return }
            onSelect(albums[index].id)
        }
    }
}

private final class AlbumTile: NSCollectionViewItem {
    private let cover = NSImageView()
    private let albumTitle = NSTextField(labelWithString: "")
    private let artist = NSTextField(labelWithString: "")
    private var task: Task<Void, Never>?
    private var albumID = ""
    override init(nibName nibNameOrNil: NSNib.Name?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 172, height: 222))
        cover.frame = NSRect(x: 0, y: 50, width: 172, height: 172)
        cover.imageScaling = .scaleProportionallyUpOrDown
        cover.wantsLayer = true; cover.layer?.cornerRadius = 12; cover.layer?.masksToBounds = true
        albumTitle.frame = NSRect(x: 0, y: 25, width: 172, height: 19)
        artist.frame = NSRect(x: 0, y: 6, width: 172, height: 17)
        albumTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        artist.font = .systemFont(ofSize: 12); artist.textColor = .secondaryLabelColor
        for field in [albumTitle, artist] { field.lineBreakMode = .byTruncatingTail }
        for child in [cover, albumTitle, artist] { view.addSubview(child) }
    }
    func show(_ album: AlbumInfo, folder: URL?) {
        _ = view
        albumID = album.id; task?.cancel()
        albumTitle.stringValue = album.title; artist.stringValue = album.artist
        view.setAccessibilityLabel("\(album.title), \(album.artist)")
        cover.image = systemSymbol("square.stack", pointSize: 55)
        guard let key = album.artworkKey, let folder else { return }
        task = Task { [weak self] in
            let image = await ThumbnailStore.shared.image(folder.appendingPathComponent(key + ".jpg"), pixels: 344)
            guard !Task.isCancelled, self?.albumID == album.id else { return }
            if let image { self?.cover.image = image }
        }
    }
    override func prepareForReuse() { super.prepareForReuse(); task?.cancel(); albumID = ""; cover.image = nil }
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
    window.orderOut(nil)
    log("PASS: native album grid registers and reuses a programmatic tile without a nib")
}

#elseif canImport(GtkBackend)
import CGtk
import Gtk
import GtkBackend

struct AlbumBrowser: GtkWidgetRepresentable {
    var albums: [AlbumInfo]
    var artworkFolder: URL?
    var query: String
    var onSelect: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeGtkWidget(context: Context) -> Gtk.Widget {
        let c = context.coordinator
        let factory = gtk_signal_list_item_factory_new()!
        let data = Unmanaged.passUnretained(c).toOpaque()
        g_signal_connect_data(cast(factory), "setup", unsafeBitCast(setupAlbum, to: GCallback.self), nil, nil, GConnectFlags(rawValue: 0))
        g_signal_connect_data(cast(factory), "bind", unsafeBitCast(bindAlbum, to: GCallback.self), data, nil, GConnectFlags(rawValue: 0))
        g_object_ref(cast(c.model))
        let selection = gtk_single_selection_new(cast(c.model))!
        let grid = gtk_grid_view_new(cast(selection), cast(factory))!
        gtk_grid_view_set_min_columns(cast(grid), 1); gtk_grid_view_set_max_columns(cast(grid), 8)
        g_signal_connect_data(cast(grid), "activate", unsafeBitCast(activateAlbum, to: GCallback.self), data, nil, GConnectFlags(rawValue: 0))
        let scroll = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_child(cast(scroll), grid)
        gtk_widget_set_vexpand(scroll, 1); gtk_widget_set_hexpand(scroll, 1)
        return Gtk.Widget(scroll)
    }
    func updateGtkWidget(_ widget: Gtk.Widget, context: Context) {
        let c = context.coordinator; c.onSelect = onSelect; c.folder = artworkFolder
        guard !c.source.sameStorage(as: albums) || c.query != query else { return }
        c.source = albums; c.query = query
        let old = c.albums.count; c.albums = matchingAlbums(albums, query)
        let empty = strdup(""); defer { free(empty) }
        var items = [UnsafePointer<CChar>?](repeating: UnsafePointer(empty), count: c.albums.count); items.append(nil)
        items.withUnsafeMutableBufferPointer { gtk_string_list_splice(c.model, 0, UInt32(old), $0.baseAddress) }
    }
    final class Coordinator {
        let model = gtk_string_list_new(nil)!
        var source: [AlbumInfo] = [], albums: [AlbumInfo] = []
        var query = ""
        var folder: URL?
        var onSelect: (String) -> Void = { _ in }
        deinit { g_object_unref(cast(model)) }
    }
}
private let setupAlbum: @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { _, item, _ in
    let box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8)!
    gtk_widget_set_margin_top(box, 16); gtk_widget_set_margin_bottom(box, 16)
    gtk_widget_set_margin_start(box, 12); gtk_widget_set_margin_end(box, 12)
    let image = gtk_image_new_from_icon_name("media-optical-symbolic")!
    gtk_image_set_pixel_size(cast(image), 144)
    gtk_widget_set_size_request(image, 160, 160)
    gtk_box_append(cast(box), image)
    let label = gtk_label_new(nil)!
    gtk_label_set_ellipsize(cast(label), PANGO_ELLIPSIZE_END)
    gtk_label_set_max_width_chars(cast(label), 22)
    gtk_box_append(cast(box), label)
    gtk_list_item_set_child(cast(item), box)
}
private let bindAlbum: @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { _, item, data in
    guard let data else { return }
    MainActor.assumeIsolated {
        let c = Unmanaged<AlbumBrowser.Coordinator>.fromOpaque(data).takeUnretainedValue()
        let index = Int(gtk_list_item_get_position(cast(item)))
        guard c.albums.indices.contains(index), let box = gtk_list_item_get_child(cast(item)),
              let image = gtk_widget_get_first_child(box), let label = gtk_widget_get_next_sibling(image) else { return }
        let album = c.albums[index]
        gtk_label_set_text(cast(label), "\(album.title)\n\(album.artist)")
        gtk_image_set_from_icon_name(cast(image), "media-optical-symbolic")
        guard let key = album.artworkKey, let folder = c.folder else { return }
        // Keep the list item alive while decoding; verify its current binding before applying.
        g_object_ref(cast(item))
        Task {
            defer { g_object_unref(cast(item)) }
            let texture = await GtkThumbnailStore.shared.image(folder.appendingPathComponent(key + ".jpg"), pixels: 320)
            guard gtk_list_item_get_position(cast(item)) == UInt32(index), c.albums.indices.contains(index),
                  c.albums[index].id == album.id, let texture else { return }
            gtk_image_set_from_paintable(cast(image), cast(texture.pointer))
        }
    }
}
private let activateAlbum: @convention(c) (OpaquePointer?, UInt32, gpointer?) -> Void = { _, index, data in
    guard let data else { return }
    MainActor.assumeIsolated {
        let c = Unmanaged<AlbumBrowser.Coordinator>.fromOpaque(data).takeUnretainedValue()
        if c.albums.indices.contains(Int(index)) { c.onSelect(c.albums[Int(index)].id) }
    }
}
#elseif canImport(WinUIBackend)
import WinUI
import WinUIBackend
import WindowsFoundation

/// The WinUI projection doesn't expose GridView. A virtualized ListView of tile rows
/// creates only the visible album cards, and reflows only when the column count changes.
struct AlbumBrowser: WinUIElementRepresentable {
    var albums: [AlbumInfo]
    var artworkFolder: URL?
    var query: String
    var onSelect: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeWinUIElement(context: Context) -> WinUI.ListView {
        let list = WinUI.ListView()
        list.selectionMode = .none
        let c = context.coordinator
        c.list = list
        list.containerContentChanging.addHandler { [weak c] _, args in
            MainActor.assumeIsolated {
                guard let c, let args, !args.inRecycleQueue, args.itemIndex >= 0 else { return }
                let start = Int(args.itemIndex) * c.columns
                guard start < c.albums.count else { return }
                let row = WinUI.Grid(); row.columnSpacing = 20
                for index in 0..<c.columns {
                    let definition = ColumnDefinition()
                    definition.width = GridLength(value: 1, gridUnitType: .star)
                    row.columnDefinitions.append(definition)
                    guard start + index < c.albums.count else { continue }
                    let album = c.albums[start + index]
                    let content = StackPanel(); content.spacing = 8; content.width = 172
                    if let folder = c.folder, let key = album.artworkKey {
                        let image = WinUI.Image(); image.width = 172; image.height = 172
                        let bitmap = BitmapImage(WindowsFoundation.Uri(folder.appendingPathComponent(key + ".jpg").absoluteString))
                        bitmap.decodePixelWidth = 344; image.source = bitmap
                        content.children.append(image)
                    }
                    let name = TextBlock(); name.text = album.title; name.textTrimming = .characterEllipsis
                    let artist = TextBlock(); artist.text = album.artist; artist.fontSize = 12; artist.opacity = 0.65
                    content.children.append(name); content.children.append(artist)
                    let button = WinUI.Button(); button.content = content
                    button.margin = Thickness(left: 4, top: 12, right: 4, bottom: 12)
                    button.click.addHandler { [weak c] _, _ in MainActor.assumeIsolated { c?.onSelect(album.id) } }
                    WinUI.Grid.setColumn(button, Int32(index)); row.children.append(button)
                }
                args.itemContainer.content = row
                args.handled = true
            }
        }
        list.sizeChanged.addHandler { [weak c, weak list] _, _ in
            MainActor.assumeIsolated {
                guard let c, let list else { return }
                let columns = max(1, Int(list.actualWidth / 210))
                guard columns != c.columns else { return }
                c.columns = columns; c.reload()
            }
        }
        return list
    }
    func updateWinUIElement(_ list: WinUI.ListView, context: Context) {
        let c = context.coordinator; c.onSelect = onSelect
        guard !c.source.sameStorage(as: albums) || c.query != query || c.folder != artworkFolder else { return }
        c.source = albums; c.query = query; c.folder = artworkFolder
        c.albums = matchingAlbums(albums, query); c.reload()
    }
    func sizeThatFits(_ proposal: ProposedViewSize, winUIElement: WinUI.ListView, context: Context) -> ViewSize {
        ViewSize(proposal.width ?? 600, proposal.height ?? 400)
    }
    final class Coordinator {
        var source: [AlbumInfo] = [], albums: [AlbumInfo] = []
        var query = ""
        var folder: URL?
        var columns = 3
        weak var list: WinUI.ListView?
        var onSelect: (String) -> Void = { _ in }
        func reload() {
            guard let list else { return }
            list.items.clear()
            for index in stride(from: 0, to: albums.count, by: columns) { list.items.append(albums[index].title) }
        }
    }
}
#endif
