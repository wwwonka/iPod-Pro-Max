import Foundation
#if os(Windows)
import WinSDK
#endif

/// Names of mounted iPods (volumes with an `iPod_Control` folder), read once at launch. The real
/// app reacts to mount events; the prototype only needs the sidebar to show what's plugged in.
func connectedIPods() -> [String] {
    let fm = FileManager.default
    var roots: [String] = []
    #if os(macOS)
    roots = (try? fm.contentsOfDirectory(atPath: "/Volumes"))?.map { "/Volumes/" + $0 } ?? []
    #elseif os(Windows)
    // An empty card reader would otherwise show a "No disk" dialog while probing.
    let previousMode = SetErrorMode(UINT(SEM_FAILCRITICALERRORS))
    defer { SetErrorMode(previousMode) }
    // Plain strings: Foundation's URL traps on some drive roots (e.g. Parallels' Z: share).
    return "DEFGHIJKLMNOPQRSTUVWXYZ".compactMap { letter in
        fm.fileExists(atPath: "\(letter):\\iPod_Control") ? "\(letter):" : nil
    }
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
