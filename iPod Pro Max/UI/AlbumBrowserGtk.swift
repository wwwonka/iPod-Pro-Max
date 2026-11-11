#if canImport(GtkBackend)
import CGtk
import Foundation
import Gtk
import GtkBackend
import SwiftCrossUI

/// Rows rather than individual albums are virtualized so a full-width detail can be inserted
/// directly below the selected row without constructing widgets for the rest of the library.
struct AlbumBrowser: GtkWidgetRepresentable {
    var albums: [AlbumInfo]
    var artworkFolder: URL?
    var query: String
    var onSelect: (String) -> Void
    var artworkSize: Double = 172
    var onArtworkSize: (Double) -> Void = { _ in }
    var onArtworkCommit: (Double) -> Void = { _ in }
    var onPlay: (TrackRow, [TrackRow]) -> Void = { _, _ in }

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeGtkWidget(context: Context) -> Gtk.Widget {
        let c = context.coordinator
        let factory = gtk_signal_list_item_factory_new()!
        g_signal_connect_data(cast(factory), "setup", unsafeBitCast(albumRowSetup, to: GCallback.self), nil, nil, GConnectFlags(rawValue: 0))
        g_signal_connect_data(cast(factory), "bind", unsafeBitCast(albumRowBind, to: GCallback.self), AlbumCoordinatorBinding.retained(c), releaseAlbumCoordinator, GConnectFlags(rawValue: 0))
        g_object_ref(cast(c.model))
        let selection = gtk_no_selection_new(cast(c.model))!
        let list = gtk_list_view_new(cast(selection), cast(factory))!
        gtk_widget_set_hexpand(list, 1)
        let scroll = gtk_scrolled_window_new()!
        c.scroll = scroll
        g_object_ref(cast(scroll))
        gtk_scrolled_window_set_policy(cast(scroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_child(cast(scroll), list)
        gtk_widget_set_vexpand(scroll, 1); gtk_widget_set_hexpand(scroll, 1)

        // A transparent drawing area receives GTK's resize signal only when allocation changes.
        // It does no drawing and causes no polling or work while idle.
        let overlay = gtk_overlay_new()!
        gtk_overlay_set_child(cast(overlay), scroll)
        let resizeProbe = gtk_drawing_area_new()!
        gtk_widget_set_can_target(resizeProbe, 0)
        gtk_widget_set_opacity(resizeProbe, 0)
        gtk_widget_set_hexpand(resizeProbe, 1); gtk_widget_set_vexpand(resizeProbe, 1)
        gtk_overlay_add_overlay(cast(overlay), resizeProbe)
        g_signal_connect_data(cast(resizeProbe), "resize", unsafeBitCast(albumResize, to: GCallback.self), AlbumCoordinatorBinding.retained(c), releaseAlbumCoordinator, GConnectFlags(rawValue: 0))
        let zoom = gtk_gesture_zoom_new()!
        g_signal_connect_data(cast(zoom), "begin", unsafeBitCast(albumZoomBegin, to: GCallback.self), AlbumCoordinatorBinding.retained(c), releaseAlbumCoordinator, GConnectFlags(rawValue: 0))
        g_signal_connect_data(cast(zoom), "scale-changed", unsafeBitCast(albumZoomChanged, to: GCallback.self), AlbumCoordinatorBinding.retained(c), releaseAlbumCoordinator, GConnectFlags(rawValue: 0))
        gtk_widget_add_controller(overlay, cast(zoom))
        return Gtk.Widget(overlay)
    }
    func updateGtkWidget(_ widget: Gtk.Widget, context: Context) {
        let c = context.coordinator
        c.onArtworkSize = onArtworkSize; c.onPlay = onPlay
        let changed = !c.source.sameStorage(as: albums) || c.query != query || c.folder != artworkFolder
        let sizeChanged = abs(c.artworkSize - artworkSize) > 0.5
        guard changed || sizeChanged else { return }
        c.source = albums; c.query = query; c.folder = artworkFolder
        c.artworkSize = min(280, max(110, artworkSize))
        if changed {
            let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
            c.albums = needle.isEmpty ? albums : albums.filter { $0.title.localizedCaseInsensitiveContains(needle) || $0.artist.localizedCaseInsensitiveContains(needle) }
            if let id = c.selectedID, !c.albums.contains(where: { $0.id == id }) { c.selectedID = nil }
        }
        c.reload()
    }

    final class Coordinator {
        let model = gtk_string_list_new(nil)!
        var source: [AlbumInfo] = [], albums: [AlbumInfo] = []
        var query = ""
        var folder: URL?
        var selectedID: String?
        var artworkSize = 172.0
        var zoomStart = 172.0
        var columns = 3
        var width = 0
        var pendingReload = false
        var scroll: UnsafeMutablePointer<GtkWidget>?
        var pendingScrollRestore = false
        var preservedScroll = 0.0
        var onArtworkSize: (Double) -> Void = { _ in }
        var onPlay: (TrackRow, [TrackRow]) -> Void = { _, _ in }
        var selectedRow: Int? { selectedID.flatMap { id in albums.firstIndex { $0.id == id } }.map { $0 / columns } }
        var count: Int { (albums.count + columns - 1) / columns + (selectedRow == nil ? 0 : 1) }
        func albumRow(_ position: Int) -> Int? {
            if let selectedRow, position == selectedRow + 1 { return nil }
            return position - ((selectedRow.map { position > $0 + 1 } ?? false) ? 1 : 0)
        }
        func reload() {
            if !pendingScrollRestore, let scroll, let adjustment = gtk_scrolled_window_get_vadjustment(cast(scroll)) {
                preservedScroll = gtk_adjustment_get_value(adjustment)
                pendingScrollRestore = true
                g_idle_add_full(300, { data in
                    guard let data else { return 0 }
                    let c = Unmanaged<Coordinator>.fromOpaque(data).takeUnretainedValue()
                    if let scroll = c.scroll, let adjustment = gtk_scrolled_window_get_vadjustment(cast(scroll)) {
                        gtk_adjustment_set_value(adjustment, c.preservedScroll)
                    }
                    c.pendingScrollRestore = false
                    return 0
                }, Unmanaged.passRetained(self).toOpaque(), { data in
                    if let data { Unmanaged<Coordinator>.fromOpaque(data).release() }
                })
            }
            let old = Int(g_list_model_get_n_items(cast(model)))
            let blank = strdup(""); defer { free(blank) }
            var strings = [UnsafePointer<CChar>?](repeating: UnsafePointer(blank), count: count); strings.append(nil)
            strings.withUnsafeMutableBufferPointer { gtk_string_list_splice(model, 0, UInt32(old), $0.baseAddress) }
        }
        func scheduleResize(_ width: Int) {
            self.width = width
            let next = max(1, min(8, Int((Double(max(0, width - 32)) + 20) / (artworkSize + 20))))
            guard next != columns else { return }
            columns = next
            // Avoid mutating the list during GTK allocation.
            guard !pendingReload else { return }
            pendingReload = true
            g_idle_add_full(200, { data in
                guard let data else { return 0 }
                let c = Unmanaged<Coordinator>.fromOpaque(data).takeUnretainedValue()
                c.pendingReload = false; c.reload()
                return 0
            }, Unmanaged.passRetained(self).toOpaque(), { data in
                if let data { Unmanaged<Coordinator>.fromOpaque(data).release() }
            })
        }
        deinit {
            if let scroll { g_object_unref(cast(scroll)) }
            g_object_unref(cast(model))
        }
    }
}

/// GTK owns each signal binding; a late signal after view teardown cannot retain or access a dead coordinator.
private final class AlbumCoordinatorBinding {
    weak var coordinator: AlbumBrowser.Coordinator?
    init(_ coordinator: AlbumBrowser.Coordinator) { self.coordinator = coordinator }
    static func retained(_ coordinator: AlbumBrowser.Coordinator) -> gpointer {
        Unmanaged.passRetained(AlbumCoordinatorBinding(coordinator)).toOpaque()
    }
}
private let releaseAlbumCoordinator: @convention(c) (gpointer?, UnsafeMutablePointer<GClosure>?) -> Void = { data, _ in
    if let data { Unmanaged<AlbumCoordinatorBinding>.fromOpaque(data).release() }
}
private func boundAlbumCoordinator(_ data: gpointer) -> AlbumBrowser.Coordinator? {
    Unmanaged<AlbumCoordinatorBinding>.fromOpaque(data).takeUnretainedValue().coordinator
}
private final class AlbumAction {
    weak var coordinator: AlbumBrowser.Coordinator?
    let id: String
    init(_ coordinator: AlbumBrowser.Coordinator, _ id: String) { self.coordinator = coordinator; self.id = id }
}
private let releaseAlbumAction: @convention(c) (gpointer?, UnsafeMutablePointer<GClosure>?) -> Void = { data, _ in
    if let data { Unmanaged<AlbumAction>.fromOpaque(data).release() }
}
private let albumRowSetup: @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { _, item, _ in
    gtk_list_item_set_child(cast(item), gtk_box_new(GTK_ORIENTATION_VERTICAL, 0))
}
private let albumRowBind: @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { _, item, data in
    guard let data else { return }
    MainActor.assumeIsolated {
        guard let c = boundAlbumCoordinator(data) else { return }
        let position = Int(gtk_list_item_get_position(cast(item)))
        guard let box = gtk_list_item_get_child(cast(item)) else { return }
        while let child = gtk_widget_get_first_child(box) { gtk_box_remove(cast(box), child) }
        guard let row = c.albumRow(position) else {
            guard let id = c.selectedID, let album = c.albums.first(where: { $0.id == id }) else { return }
            let detail = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6)!
            gtk_widget_set_margin_start(detail, 24); gtk_widget_set_margin_end(detail, 24)
            gtk_widget_set_margin_top(detail, 16); gtk_widget_set_margin_bottom(detail, 16)
            let heading = gtk_label_new("\(album.title) — \(album.artist)")!
            gtk_label_set_xalign(cast(heading), 0); gtk_widget_add_css_class(heading, "title-2")
            gtk_box_append(cast(detail), heading)
            let tracks = gtk_string_list_new(nil)!
            for track in album.rows { gtk_string_list_append(tracks, "\(track.number)   \(track.title)   \(track.duration)") }
            let selection = gtk_multi_selection_new(cast(tracks))!
            let factory = gtk_signal_list_item_factory_new()!
            g_signal_connect_data(cast(factory), "setup", unsafeBitCast(albumTrackSetup, to: GCallback.self), nil, nil, GConnectFlags(rawValue: 0))
            g_signal_connect_data(cast(factory), "bind", unsafeBitCast(albumTrackBind, to: GCallback.self), nil, nil, GConnectFlags(rawValue: 0))
            let list = gtk_list_view_new(cast(selection), cast(factory))!
            g_signal_connect_data(cast(list), "activate", unsafeBitCast(albumTrackActivate, to: GCallback.self),
                Unmanaged.passRetained(AlbumAction(c, id)).toOpaque(), releaseAlbumAction, GConnectFlags(rawValue: 0))
            let drag = gtk_drag_source_new()!
            gtk_drag_source_set_actions(drag, GDK_ACTION_COPY)
            g_signal_connect_data(cast(drag), "prepare", unsafeBitCast(albumTracksDragPrepare, to: GCallback.self),
                Unmanaged.passRetained(AlbumTrackDrag(c, id, selection)).toOpaque(), releaseAlbumTrackDrag, GConnectFlags(rawValue: 0))
            g_signal_connect_data(cast(drag), "drag-end", unsafeBitCast(albumDragEnd, to: GCallback.self), nil, nil, GConnectFlags(rawValue: 0))
            gtk_widget_add_controller(list, cast(drag))
            let scroll = gtk_scrolled_window_new()!
            gtk_scrolled_window_set_child(cast(scroll), list)
            gtk_widget_set_size_request(scroll, -1, Int32(max(100, min(450, album.rows.count * 34))))
            gtk_box_append(cast(detail), scroll); gtk_box_append(cast(box), detail)
            return
        }
        let line = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 20)!
        gtk_widget_set_margin_start(line, 16); gtk_widget_set_margin_end(line, 16)
        gtk_widget_set_margin_top(line, 12); gtk_widget_set_margin_bottom(line, 12)
        let start = row * c.columns
        guard start < c.albums.count else { return }
        for index in start..<min(start + c.columns, c.albums.count) {
            let album = c.albums[index]
            let button = gtk_button_new()!
            gtk_widget_add_css_class(button, "flat")
            if album.id == c.selectedID { gtk_widget_add_css_class(button, "suggested-action") }
            let tile = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4)!
            let image = gtk_image_new_from_icon_name("media-optical-symbolic")!
            let size = Int32(c.artworkSize.rounded())
            gtk_widget_set_size_request(image, size, size); gtk_image_set_pixel_size(cast(image), size)
            if let folder = c.folder, let key = album.artworkKey {
                let url = folder.appendingPathComponent(key + ".jpg")
                if let cached = GtkThumbnailStore.shared.cached(url, pixels: 344) { gtk_image_set_from_paintable(cast(image), cast(cached.pointer)) }
                else {
                    g_object_ref(cast(image))
                    Task {
                        defer { g_object_unref(cast(image)) }
                        if let texture = await GtkThumbnailStore.shared.image(url, pixels: 344) {
                            gtk_image_set_from_paintable(cast(image), cast(texture.pointer))
                        }
                    }
                }
            }
            gtk_box_append(cast(tile), image)
            let title = gtk_label_new(album.title)!
            gtk_label_set_xalign(cast(title), 0); gtk_label_set_ellipsize(cast(title), PANGO_ELLIPSIZE_END)
            gtk_widget_set_size_request(title, size, -1); gtk_box_append(cast(tile), title)
            let artist = gtk_label_new(album.artist)!
            gtk_label_set_xalign(cast(artist), 0); gtk_label_set_ellipsize(cast(artist), PANGO_ELLIPSIZE_END)
            gtk_widget_add_css_class(artist, "dim-label"); gtk_widget_set_size_request(artist, size, -1)
            gtk_box_append(cast(tile), artist); gtk_button_set_child(cast(button), tile)
            g_signal_connect_data(cast(button), "clicked", unsafeBitCast(albumClicked, to: GCallback.self),
                Unmanaged.passRetained(AlbumAction(c, album.id)).toOpaque(), releaseAlbumAction, GConnectFlags(rawValue: 0))
            let drag = gtk_drag_source_new()!
            gtk_drag_source_set_actions(drag, GDK_ACTION_COPY)
            g_signal_connect_data(cast(drag), "prepare", unsafeBitCast(albumDragPrepare, to: GCallback.self),
                Unmanaged.passRetained(AlbumAction(c, album.id)).toOpaque(), releaseAlbumAction, GConnectFlags(rawValue: 0))
            g_signal_connect_data(cast(drag), "drag-end", unsafeBitCast(albumDragEnd, to: GCallback.self), nil, nil, GConnectFlags(rawValue: 0))
            gtk_widget_add_controller(button, cast(drag)); gtk_box_append(cast(line), button)
        }
        gtk_box_append(cast(box), line)
    }
}
private let albumClicked: @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, data in
    guard let data else { return }
    MainActor.assumeIsolated {
        let action = Unmanaged<AlbumAction>.fromOpaque(data).takeUnretainedValue()
        guard let c = action.coordinator else { return }
        c.selectedID = c.selectedID == action.id ? nil : action.id; c.reload()
    }
}
private let albumDragPrepare: @convention(c) (OpaquePointer?, Double, Double, gpointer?) -> UnsafeMutablePointer<GdkContentProvider>? = { _, _, _, data in
    guard let data else { return nil }
    return MainActor.assumeIsolated {
        let action = Unmanaged<AlbumAction>.fromOpaque(data).takeUnretainedValue()
        guard let album = action.coordinator?.albums.first(where: { $0.id == action.id }), let text = TrackDrag.begin(album.rows.map(\.id)) else { return nil }
        var value = GValue(); g_value_init(&value, g_type_from_name("gchararray")); g_value_set_string(&value, text)
        defer { g_value_unset(&value) }
        return gdk_content_provider_new_for_value(&value)
    }
}
private final class AlbumTrackDrag {
    weak var coordinator: AlbumBrowser.Coordinator?
    let id: String
    let selection: OpaquePointer
    init(_ coordinator: AlbumBrowser.Coordinator, _ id: String, _ selection: OpaquePointer) {
        self.coordinator = coordinator; self.id = id; self.selection = selection
    }
}
private let releaseAlbumTrackDrag: @convention(c) (gpointer?, UnsafeMutablePointer<GClosure>?) -> Void = { data, _ in
    if let data { Unmanaged<AlbumTrackDrag>.fromOpaque(data).release() }
}
private let albumTracksDragPrepare: @convention(c) (OpaquePointer?, Double, Double, gpointer?) -> UnsafeMutablePointer<GdkContentProvider>? = { _, _, _, data in
    guard let data else { return nil }
    return MainActor.assumeIsolated {
        let binding = Unmanaged<AlbumTrackDrag>.fromOpaque(data).takeUnretainedValue()
        guard let album = binding.coordinator?.albums.first(where: { $0.id == binding.id }) else { return nil }
        let ids = album.rows.indices.filter { gtk_selection_model_is_selected(cast(binding.selection), UInt32($0)) != 0 }.map { album.rows[$0].id }
        guard let text = TrackDrag.begin(ids) else { return nil }
        var value = GValue(); g_value_init(&value, g_type_from_name("gchararray")); g_value_set_string(&value, text)
        defer { g_value_unset(&value) }
        return gdk_content_provider_new_for_value(&value)
    }
}
private let albumDragEnd: @convention(c) (OpaquePointer?, OpaquePointer?, gboolean, gpointer?) -> Void = { _, _, _, _ in
    MainActor.assumeIsolated { TrackDrag.end() }
}
private let albumTrackSetup: @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { _, item, _ in
    let label = gtk_label_new(nil)!; gtk_label_set_xalign(cast(label), 0)
    gtk_widget_set_margin_top(label, 6); gtk_widget_set_margin_bottom(label, 6)
    gtk_list_item_set_child(cast(item), label)
}
private let albumTrackBind: @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { _, item, _ in
    guard let object = gtk_list_item_get_item(cast(item)), let label = gtk_list_item_get_child(cast(item)) else { return }
    gtk_label_set_text(cast(label), gtk_string_object_get_string(cast(object)))
}
private let albumTrackActivate: @convention(c) (OpaquePointer?, UInt32, gpointer?) -> Void = { _, position, data in
    guard let data else { return }
    MainActor.assumeIsolated {
        let action = Unmanaged<AlbumAction>.fromOpaque(data).takeUnretainedValue()
        guard let c = action.coordinator, let album = c.albums.first(where: { $0.id == action.id }), album.rows.indices.contains(Int(position)) else { return }
        c.onPlay(album.rows[Int(position)], album.rows)
    }
}
private let albumResize: @convention(c) (OpaquePointer?, Int32, Int32, gpointer?) -> Void = { _, width, _, data in
    guard let data else { return }
    MainActor.assumeIsolated { boundAlbumCoordinator(data)?.scheduleResize(Int(width)) }
}
private let albumZoomBegin: @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { _, _, data in
    guard let data else { return }
    MainActor.assumeIsolated { if let c = boundAlbumCoordinator(data) { c.zoomStart = c.artworkSize } }
}
private let albumZoomChanged: @convention(c) (OpaquePointer?, Double, gpointer?) -> Void = { _, scale, data in
    guard let data, scale.isFinite else { return }
    MainActor.assumeIsolated {
        guard let c = boundAlbumCoordinator(data) else { return }
        let size = max(110, min(280, c.zoomStart * (1 + (scale - 1) * 2.4)))
        guard abs(size - c.artworkSize) >= 1 else { return }
        c.artworkSize = size
        let next = max(1, min(8, Int((Double(max(0, c.width - 32)) + 20) / (size + 20))))
        c.columns = next; c.reload(); c.onArtworkSize(size)
    }
}
/// Exercises the native callbacks without touching a real iPod or user library.
@MainActor func checkGtkAlbumGrid() {
    let ids = [UUID().uuidString, UUID().uuidString]
    let rows = ids.map { TrackRow(id: $0, title: "Track", artist: "Artist", album: "Album", number: "1", year: "", duration: "1:00") }
    let c = AlbumBrowser.Coordinator()
    c.columns = 3; c.width = 650
    c.albums = (0..<6).map { AlbumInfo(id: "album-\($0)", title: "Album", year: "", rows: rows, durationMs: 0) }
    c.reload()
    precondition(c.count == 2 && c.albumRow(0) == 0 && c.albumRow(1) == 1)
    let action = AlbumAction(c, "album-4")
    let data = Unmanaged.passUnretained(action).toOpaque()
    albumClicked(nil, data)
    precondition(c.selectedID == "album-4" && c.count == 3 && c.albumRow(2) == nil)
    albumClicked(nil, data)
    precondition(c.selectedID == nil && c.count == 2)
    var saved = 0.0; c.onArtworkSize = { saved = $0 }
    let binding = AlbumCoordinatorBinding(c)
    let context = Unmanaged.passUnretained(binding).toOpaque()
    albumZoomBegin(nil, nil, context); albumZoomChanged(nil, 1.1, context)
    precondition(c.artworkSize > 172 && saved == c.artworkSize)
    guard let provider = albumDragPrepare(nil, 0, 0, data) else { fatalError("Album drag did not create a provider") }
    precondition(Set(TrackDrag.ids) == Set(ids))
    g_object_unref(cast(provider)); TrackDrag.end()
    let tracks = gtk_string_list_new(nil)!
    gtk_string_list_append(tracks, "one"); gtk_string_list_append(tracks, "two")
    let selectedTracks = gtk_multi_selection_new(cast(tracks))!
    gtk_selection_model_select_item(cast(selectedTracks), 1, 0)
    let drag = AlbumTrackDrag(c, "album-4", selectedTracks)
    guard let trackProvider = albumTracksDragPrepare(nil, 0, 0, Unmanaged.passUnretained(drag).toOpaque()) else { fatalError("Track drag did not create a provider") }
    precondition(TrackDrag.ids == [ids[1]])
    g_object_unref(cast(trackProvider)); TrackDrag.end(); g_object_unref(cast(selectedTracks))
    log("PASS: GTK album selection, zoom, album drag and track drag")
}
#endif
