import Foundation
import iPodKit

/// The root of the iPod the app was started from, or of `Build/`, which has the same layout
/// (Docs/Données/Sur l'iPod.md). What's saved there, in `iPod Pro Max/Persistent Data/`, is shared by
/// the macOS, Windows and Linux apps.
///
/// In order: `--portable-root <path>` (passed by the launcher, which runs the app from the iPod),
/// `IPPM_PORTABLE_ROOT`, then the app's own location when it runs straight from
/// `<root>/iPod Pro Max/Applications/…`. Nil when the app runs from anywhere else.
enum PortableRoot {
    static let url: URL? = resolve(arguments: CommandLine.arguments)

    static func resolve(arguments: [String]) -> URL? {
        if let i = arguments.firstIndex(of: "--portable-root"), i + 1 < arguments.count {
            return URL(fileURLWithPath: arguments[i + 1], isDirectory: true)
        }
        if let env = ProcessInfo.processInfo.environment["IPPM_PORTABLE_ROOT"], !env.isEmpty {
            return URL(fileURLWithPath: env, isDirectory: true)
        }
        let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: arguments.first ?? "")
        #if os(Windows)
            // No resolvingSymlinksInPath: it overflows the stack on network paths (\\Mac\Home\…).
            var dir = executable.standardizedFileURL.deletingLastPathComponent()
        #else
            var dir = executable.resolvingSymlinksInPath().deletingLastPathComponent()
        #endif
        // Applications/macOS/iPod Pro Max.app/Contents/MacOS is the deepest: five levels.
        for _ in 0..<6 {
            if dir.lastPathComponent == "Applications", dir.deletingLastPathComponent().lastPathComponent == "iPod Pro Max" {
                return dir.deletingLastPathComponent().deletingLastPathComponent()
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }

    /// The root as an iPod, when it has an `iPod_Control` folder and isn't a mounted iPod already
    /// (`Build/` on the development machine). Touches the disk.
    static func simulatedIPod(besides mounted: [IPodDevice]) -> IPodDevice? {
        guard let url else { return nil }
        let path = FileOps.canonicalPath(url)
        guard !mounted.contains(where: { FileOps.canonicalPath($0.mountPoint) == path }) else { return nil }
        return IPodDevice.detect(volume: url, simulated: true)
    }
}

/// An iPod's sync choices, in `iPod Pro Max/Persistent Data/device.json` on that iPod: they travel
/// with it, so every computer and every OS shows the same ones.
struct DeviceOptions: Codable, Equatable, Sendable {
    static let fileName = "device.json"

    var syncAllMusic = true
    var selectedPlaylistIDs: [String] = []
    var syncPodcasts = true
    var syncVideos = true
    var syncAudiobooks = true
    var syncPhotos = true
    var removeUnknownTracks = false
    var useAlbumArtistForGrouping = true
}
