import Foundation
import iPodKit

public enum PortableMusicTransfer {
    public struct Prepared {
        public var request: SyncRequest
        public var manifest: TransferManifest
        public var reused: Int
    }
    public static func prepare(tracks: [LibraryTrack], device: IPodDevice, store: PortableLibraryStore, albumArtistGrouping: Bool = true) async throws -> Prepared {
        let folder = DeviceDataFolder(mountPoint: device.mountPoint)
        var manifest = try folder.readChecked(TransferManifest.self, from: "manifest.json") ?? TransferManifest()
        guard manifest.version == 1 else { throw IPodDBError.unsupported("Unsupported manifest.json version") }
        let originalManifest = manifest
        var indexByFingerprint = Dictionary(manifest.tracks.enumerated().map { ($0.element.fingerprint, $0.offset) }, uniquingKeysWith: { a, _ in a })
        let db = try device.readDatabase()
        let present = Set(db.tracks.filter { $0.fileURL(mountPoint: device.mountPoint).map { FileManager.default.fileExists(atPath: $0.path) } ?? false }.map(\.dbid))
        var hashes: [UUID: String] = [:]
        // Bounded parallel reads, fewer workers on a disk-bound pass.
        try await withThrowingTaskGroup(of: (UUID, String).self) { group in
            var iterator = tracks.makeIterator()
            func next() {
                guard let track = iterator.next() else { return }
                group.addTask { (track.id, try FileFingerprint.read(URL(fileURLWithPath: track.path))) }
            }
            for _ in 0..<max(1, ProcessInfo.processInfo.activeProcessorCount / 2) { next() }
            for try await (id, hash) in group { hashes[id] = hash; next() }
        }
        var record = DeviceSyncRecord(deviceID: device.id, deviceName: device.volumeName)
        var additions: [LibraryTrack] = []; var reused = 0
        var scheduled = Set<UInt64>()
        for track in tracks {
            guard let hash = hashes[track.id] else { continue }
            let reference = store.hostID + ":" + track.id.uuidString
            if let i = indexByFingerprint[hash] {
                if !manifest.tracks[i].references.contains(reference) { manifest.tracks[i].references.append(reference) }
                record.trackDBIDs[track.id] = manifest.tracks[i].dbid
                if present.contains(manifest.tracks[i].dbid) { reused += 1; continue }
                // A pending transfer from an interrupted run reuses its reserved DBID.
            } else {
                let dbid = IPodTrack.randomDBID()
                indexByFingerprint[hash] = manifest.tracks.count
                manifest.tracks.append(.init(dbid: dbid, owner: store.hostID, sourceID: track.id, fingerprint: hash, references: [reference]))
                record.trackDBIDs[track.id] = dbid
            }
            if let dbid = record.trackDBIDs[track.id], scheduled.insert(dbid).inserted { additions.append(track) }
            else { reused += 1 }
        }
        // Durable intent makes a crash between iTunesDB publication and manifest publication recoverable.
        if manifest != originalManifest { try folder.write(manifest, to: "manifest.json") }
        var options = SyncOptions()
        options.additiveOnly = true; options.removeUnknownTracks = false
        options.syncPhotos = false; options.syncPodcasts = false
        options.writeArtwork = store.data.read(PortableSettings.self, from: "settings.json")?.syncArtwork ?? true
        options.useAlbumArtistForGrouping = albumArtistGrouping
        let request = SyncRequest(device: device, record: record, tracks: additions, playlists: [], shows: [],
            artworkDir: store.artwork, transcodeDir: store.transcodes, photoCacheDir: store.hostFolder.url.appendingPathComponent("PhotoCache"),
            photoSelection: PhotoSelection(), options: options, media: MediaServices())
        return Prepared(request: request, manifest: manifest, reused: reused)
    }
}
