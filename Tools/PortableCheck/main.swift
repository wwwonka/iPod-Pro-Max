import Foundation
import iPodKit
import MediaKit

@main
struct PortableCheck {
    @MainActor static func main() async throws {
        guard let i = CommandLine.arguments.firstIndex(of: "--music-folder"), i + 1 < CommandLine.arguments.count,
              let root = PortableRoot.url else { fatalError("--music-folder <path> --portable-root <scratch iPod>") }
        let source = URL(fileURLWithPath: CommandLine.arguments[i + 1])
        try IPodDevice.createSimulatedIPod(at: root)
        let start = Date()
        let initial = try await PortableLoading.load(folder: source, refresh: true)
        print("Initial scan: \(initial.cache.tracks.count) tracks, \(Date().timeIntervalSince(start)) s")
        let cacheStart = Date()
        let cached = try await PortableLoading.load()
        print("Cache load + availability check: \(Date().timeIntervalSince(cacheStart)) s")
        let refreshStart = Date()
        var refreshed = try await PortableLoading.load(refresh: true)
        print("Incremental scan: \(Date().timeIntervalSince(refreshStart)) s")
        guard cached.cache.tracks.map(\.id) == refreshed.cache.tracks.map(\.id) else { fatalError("IDs changed") }
        var selected = Array(refreshed.cache.tracks.filter { !$0.needsTranscode }.prefix(2))
        if let convertible = refreshed.cache.tracks.first(where: { $0.needsTranscode }), !selected.isEmpty {
            selected = [selected[0], convertible]
            print("Testing compatible audio plus \(convertible.fileExtension) → AAC conversion")
        }
        guard selected.count == 2 else { fatalError("Need two music files") }
        guard let device = IPodDevice.detect(volume: root, simulated: true) else { fatalError("Device missing") }
        selected[0].artist = "Track artist"; selected[0].albumArtist = "Album artist"
        if let index = refreshed.cache.tracks.firstIndex(where: { $0.id == selected[0].id }) { refreshed.cache.tracks[index] = selected[0] }
        var preferences = DeviceOptions(); preferences.useAlbumArtistForGrouping = false
        DevicePageCache.shared.stage(preferences, for: device)
        PortablePreferences.shared.stageMusicMode("By Artist", store: refreshed.store)
        MusicTransfer.shared.beforeTransfer = { _ in
            try await PortablePreferences.shared.flush()
            try await DevicePageCache.shared.flushAll()
        }
        var activity: [Set<String>] = []
        var contentChanges = 0
        MusicTransfer.shared.onActivityChanged = { activity.append($0) }
        MusicTransfer.shared.onDeviceFinished = { _ in contentChanges += 1 }
        MusicTransfer.shared.onStatus = { print($0) }
        MusicTransfer.shared.onDrop = { ids, target in
            guard target == device.id else { return false }
            MusicTransfer.shared.enqueue(ids: ids.compactMap(UUID.init(uuidString:)), device: device, loaded: refreshed)
            return true
        }
        await withCheckedContinuation { continuation in
            MusicTransfer.shared.onFinished = { continuation.resume() }
            let payload = TrackDrag.begin(selected.map { $0.id.uuidString })
            guard !TrackDrag.accept("external text", device: device.id),
                  !TrackDrag.accept(payload, device: "wrong device"),
                  TrackDrag.accept(payload, device: device.id) else { fatalError("Drag endpoint failed") }
            guard MusicTransfer.shared.isRunning(device), !MusicTransfer.shared.beginEject(device) else { fatalError("Transfer allowed eject") }
            TrackDrag.end()
        }
        let firstDB = try device.readDatabase()
        guard firstDB.tracks.count == 2, firstDB.tracks.first(where: { $0.title == selected[0].title })?.artist == "Track artist" else { fatalError("First transfer or pending options flush failed") }
        guard refreshed.store.data.read(PortableSettings.self, from: "settings.json")?.musicViewMode == "By Artist" else { fatalError("Settings not flushed before transfer") }
        guard MusicTransfer.shared.beginEject(device) else { fatalError("Idle device cannot reserve eject") }
        MusicTransfer.shared.enqueue(ids: selected.map(\.id), device: device, loaded: refreshed)
        guard !MusicTransfer.shared.isRunning(device) else { fatalError("Transfer started during eject") }
        MusicTransfer.shared.endEject(device)
        await withCheckedContinuation { continuation in
            MusicTransfer.shared.onFinished = { continuation.resume() }
            MusicTransfer.shared.enqueue(ids: selected.map(\.id), device: device, loaded: refreshed)
        }
        guard try device.readDatabase().tracks.count == 2 else { fatalError("Repeat duplicated tracks") }
        guard activity.count == 4, activity[0] == [device.id], activity[1].isEmpty,
              activity[2] == [device.id], activity[3].isEmpty, contentChanges == 1 else { fatalError("Activity lifecycle or unnecessary cache invalidation") }
        #if os(macOS)
        let migrationRoot = root.appendingPathComponent("LegacyCheck")
        try IPodDevice.createSimulatedIPod(at: migrationRoot)
        let legacyFolder = root.appendingPathComponent("LegacySource")
        try FileManager.default.createDirectory(at: legacyFolder, withIntermediateDirectories: true)
        let legacySong = legacyFolder.appendingPathComponent("song.mp3")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: selected[0].path), to: legacySong)
        var legacyTrack = selected[0]; legacyTrack.path = legacySong.path
        let playlist = LibraryPlaylist(name: "Legacy", trackIDs: [legacyTrack.id])
        var legacy = iPodKit.LibraryDocument(tracks: [legacyTrack], playlists: [playlist]); legacy.musicFolderPath = legacyFolder.path
        let legacyFile = root.appendingPathComponent("legacy-library.json")
        let legacyBytes = try JSONEncoder().encode(legacy)
        try legacyBytes.write(to: legacyFile)
        let migrated = try await PortableLoading.load(root: migrationRoot, legacyLibraryURL: legacyFile)
        let rescanned = try await PortableLoading.load(refresh: true, root: migrationRoot, legacyLibraryURL: legacyFile)
        guard migrated.cache.tracks.map(\.id) == [legacyTrack.id], rescanned.cache.tracks.map(\.id) == [legacyTrack.id],
            rescanned.cache.playlists.first?.trackIDs == [legacyTrack.id], try Data(contentsOf: legacyFile) == legacyBytes else { fatalError("Legacy migration lost identities or modified original") }
        print("PASS: nonempty legacy migration and subsequent scan preserve track/playlist IDs, source and original JSON")
        #endif
        print("PASS: portable library, transfer/repeat, preference flush, busy lifecycle, eject exclusion and no-op cache retention")
    }
}
