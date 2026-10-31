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
    gtk_widget_add_controller(widget, cast(target))
}
private let releaseMusicDrop: @convention(c) (gpointer?, UnsafeMutablePointer<GClosure>?) -> Void = { data, _ in
    if let data { Unmanaged<GtkDropBinding>.fromOpaque(data).release() }
}
private let musicDropped: @convention(c) (OpaquePointer?, UnsafePointer<GValue>?, Double, Double, gpointer?) -> gboolean = { _, value, _, _, data in
    guard let value, let data, let text = g_value_get_string(value) else { return 0 }
    let name = Unmanaged<GtkDropBinding>.fromOpaque(data).takeUnretainedValue().name
    return MainActor.assumeIsolated { TrackDrag.accept(String(cString: text), device: name) ? 1 : 0 }
}
#endif
