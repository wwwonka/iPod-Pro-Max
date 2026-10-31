import Foundation

/// Private in-process drag. A fresh nonce prevents external text drops from triggering writes.
@MainActor
enum TrackDrag {
    static var payload: String?
    static var ids: [String] = []
    static func begin(_ tracks: [String]) -> String? {
        ids = Array(Set(tracks.filter { UUID(uuidString: $0) != nil }))
        guard !ids.isEmpty else { payload = nil; return nil }
        payload = "ipodpromax-tracks:" + UUID().uuidString
        return payload
    }
    static func end() { payload = nil; ids = [] }
    static func accept(_ text: String?, device: String) -> Bool {
        guard let text, text == payload, !ids.isEmpty else { return false }
        return MusicTransfer.shared.onDrop(ids, device)
    }
}

#if canImport(GtkBackend)
import CGtk
import GtkBackend

private final class GtkDropBinding {
    let name: String
    init(_ name: String) { self.name = name }
}

@MainActor
func installMusicDrop(on widget: UnsafeMutablePointer<GtkWidget>, device: String) {
    let target = gtk_drop_target_new(g_type_from_name("gchararray"), GDK_ACTION_COPY)!
    let binding = Unmanaged.passRetained(GtkDropBinding(device))
    g_signal_connect_data(cast(target), "drop", unsafeBitCast(musicDropped, to: GCallback.self), binding.toOpaque(), releaseMusicDrop, GConnectFlags(rawValue: 0))
    for signal in ["enter", "motion"] {
        g_signal_connect_data(cast(target), signal, unsafeBitCast(musicDragEntered, to: GCallback.self), nil, nil, GConnectFlags(rawValue: 0))
    }
    g_signal_connect_data(cast(target), "leave", unsafeBitCast(musicDragLeft, to: GCallback.self), nil, nil, GConnectFlags(rawValue: 0))
    gtk_widget_add_controller(widget, cast(target))
}
@MainActor
func showMusicDragCount(_ drag: OpaquePointer?) {
    guard let drag else { return }
    let icon = gtk_drag_icon_get_for_drag(cast(drag))
    let label = gtk_label_new("\(TrackDrag.ids.count) songs")
    gtk_widget_add_css_class(label, "card")
    gtk_drag_icon_set_child(cast(icon), label)
}
private let musicDragEntered: @convention(c) (OpaquePointer?, Double, Double, gpointer?) -> GdkDragAction = { target, _, _, _ in
    MainActor.assumeIsolated {
        guard TrackDrag.payload != nil, let widget = gtk_event_controller_get_widget(cast(target)) else { return GdkDragAction(rawValue: 0) }
        gtk_widget_add_css_class(widget, "ippm-drop-target")
        return GDK_ACTION_COPY
    }
}
private let musicDragLeft: @convention(c) (OpaquePointer?, gpointer?) -> Void = { target, _ in
    if let widget = gtk_event_controller_get_widget(cast(target)) { gtk_widget_remove_css_class(widget, "ippm-drop-target") }
}
private let releaseMusicDrop: @convention(c) (gpointer?, UnsafeMutablePointer<GClosure>?) -> Void = { data, _ in
    if let data { Unmanaged<GtkDropBinding>.fromOpaque(data).release() }
}
private let musicDropped: @convention(c) (OpaquePointer?, UnsafePointer<GValue>?, Double, Double, gpointer?) -> gboolean = { target, value, _, _, data in
    if let widget = gtk_event_controller_get_widget(cast(target)) { gtk_widget_remove_css_class(widget, "ippm-drop-target") }
    guard let value, let data, let text = g_value_get_string(value) else { return 0 }
    let name = Unmanaged<GtkDropBinding>.fromOpaque(data).takeUnretainedValue().name
    return MainActor.assumeIsolated { TrackDrag.accept(String(cString: text), device: name) ? 1 : 0 }
}
#endif

#if canImport(AppKitBackend)
import AppKit

/// AppKit can aggregate plain strings from multiple dragged rows. Read individual items instead.
@MainActor
func musicDragPayload(in pasteboard: NSPasteboard) -> String? {
    pasteboard.pasteboardItems?.compactMap { $0.string(forType: .string) }
        .first { $0 == TrackDrag.payload }
}
#endif
