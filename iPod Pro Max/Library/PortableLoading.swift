import Foundation
import iPodKit
import MediaKit
import DeviceKit

struct LoadedPortableLibrary {
    var store: PortableLibraryStore
    var cache: PortableLibraryCache
    var configured: Bool
    var audiobooksConfigured = false
}

enum PortableLoading {
    static func load(folder: URL? = nil, audiobooksFolder: URL? = nil, refresh: Bool = false, root overrideRoot: URL? = nil, legacyLibraryURL: URL? = nil) async throws -> LoadedPortableLibrary {
        try await Task.detached(priority: .userInitiated) {
            guard let root = overrideRoot ?? PortableRoot.url else { throw LoadingError.noRoot }
            guard let hostID = HostIdentity.current() else { throw LoadingError.noIdentity }
            let store = PortableLibraryStore(root: root, hostID: hostID)
            try store.data.requireAvailableStorage()
            var selectedFolder = folder
            var cache = store.cache()
            let originalCache = cache
            // One-time, read-only migration of this Mac's legacy library; never write back to it.
            #if os(macOS)
            if cache.tracks.isEmpty, store.data.read(KnownHosts.self, from: "known_hosts.json")?.hosts.contains(where: { $0.id == hostID }) != true {
                let legacy = legacyLibraryURL ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/iPod Pro Max/library.json")
                if let bytes = try? Data(contentsOf: legacy), let doc = try? JSONDecoder().decode(iPodKit.LibraryDocument.self, from: bytes) {
                    cache = PortableLibraryCache(tracks: doc.tracks, playlists: doc.playlists)
                    if selectedFolder == nil, let path = doc.musicFolderPath { selectedFolder = URL(fileURLWithPath: path) }
                    let oldArt = legacy.deletingLastPathComponent().appendingPathComponent("Artwork")
                    if FileManager.default.fileExists(atPath: oldArt.path), !FileManager.default.fileExists(atPath: store.artwork.path) {
                        try FileManager.default.createDirectory(at: store.hostFolder.url, withIntermediateDirectories: true)
                        try FileManager.default.copyItem(at: oldArt, to: store.artwork)
                    }
                }
            }
            #endif
            let host = try store.register(name: ProcessInfo.processInfo.hostName, musicFolder: selectedFolder, audiobooksFolder: audiobooksFolder)
            if try store.data.readChecked(PortableSettings.self, from: "settings.json") == nil { try store.data.write(PortableSettings(), to: "settings.json") }
            let scanBooks = refresh || audiobooksFolder != nil
            if scanBooks, host.sources.contains(where: { $0.kind == .audiobooks }) {
                var books: [LibraryTrack] = []
                for source in host.sources where source.kind == .audiobooks {
                    let scanned = await AudiobookScanner.scan(folder: URL(fileURLWithPath: source.path), artworkDir: store.artwork,
                        cached: cache.tracks.filter(\.isAudiobook), namespace: source.id.uuidString)
                    books.append(contentsOf: scanned.tracks)
                }
                cache.tracks = cache.tracks.filter { !$0.isAudiobook } + books
            }
            if (refresh || folder != nil), host.sources.contains(where: { $0.kind == .music }) {
                let books = cache.tracks.filter(\.isAudiobook)
                var tracks: [LibraryTrack] = []
                for source in host.sources where source.kind == .music {
                    let previousRoot = cache.sourcePaths?[source.id.uuidString]
                    let relocated = cache.tracks.map { track -> LibraryTrack in
                        var track = track
                        if let previousRoot, previousRoot != source.path, track.path.hasPrefix(previousRoot + "/") {
                            track.path = source.path + track.path.dropFirst(previousRoot.count)
                        }
                        return track
                    }
                    let scanned = await FolderImporter.scan(folder: URL(fileURLWithPath: source.path), artworkDir: store.artwork,
                        cached: relocated, namespace: source.id.uuidString, musicOnly: true)
                    tracks.append(contentsOf: scanned.tracks)
                }
                cache.tracks = tracks + books
                cache.sourcePaths = Dictionary(host.sources.map { ($0.id.uuidString, $0.path) }, uniquingKeysWith: { a, _ in a })
            } else {
                cache.tracks.removeAll { !FileManager.default.isReadableFile(atPath: $0.path) }
            }
            // Playlist membership is a saved choice. Missing tracks have no visible rows,
            // but keep their IDs so a reconnected source can populate the playlist again.
            if cache != originalCache { try store.save(cache) }
            return LoadedPortableLibrary(store: store, cache: cache, configured: host.sources.contains { $0.kind == .music },
                                         audiobooksConfigured: host.sources.contains { $0.kind == .audiobooks })
        }.value
    }
    enum LoadingError: LocalizedError {
        case noRoot, noIdentity
        var errorDescription: String? {
            switch self {
            case .noRoot: return "Launch the app from the iPod to use its portable library."
            case .noIdentity: return "This computer could not be identified. No local data was created."
            }
        }
    }
}
