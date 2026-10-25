import Foundation

/// Names of mounted iPods (volumes with an `iPod_Control` folder), read once at launch. The real
/// app reacts to mount events; the prototype only needs the sidebar to show what's plugged in.
func connectedIPods() -> [String] {
    let fm = FileManager.default
    var roots: [String] = []
    #if os(macOS)
    roots = (try? fm.contentsOfDirectory(atPath: "/Volumes"))?.map { "/Volumes/" + $0 } ?? []
    #elseif os(Windows)
    roots = "DEFGHIJKLMNOPQRSTUVWXYZ".map { "\($0):\\" }
    #else
    let user = ProcessInfo.processInfo.environment["USER"] ?? ""
    for base in ["/run/media/\(user)", "/media/\(user)"] {
        roots += ((try? fm.contentsOfDirectory(atPath: base)) ?? []).map { base + "/" + $0 }
    }
    #endif
    return roots
        .filter { fm.fileExists(atPath: URL(fileURLWithPath: $0).appendingPathComponent("iPod_Control").path) }
        .map { URL(fileURLWithPath: $0).lastPathComponent }
        .sorted()
}
