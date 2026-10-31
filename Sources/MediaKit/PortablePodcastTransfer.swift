//
//  PortablePodcastTransfer.swift
//  iPod Pro Max
//
//  Puts the downloaded podcast episodes on a portable iPod, additively like the music transfer: the
//  transfer manifest (shared by every computer that uses this iPod) remembers which episode is which
//  file, so an episode is never copied twice, not even from another computer subscribed to the same feed.
//

import Foundation
import iPodKit

public enum PortablePodcastTransfer {
    /// The manifest identity of an episode: the same on every computer, unlike the episode's own id.
    static func fingerprint(show: PodcastShow, episode: PodcastEpisode) -> String {
        "podcast:\(show.feedURL.absoluteString)#\(episode.guid)"
    }

    /// What to copy for the episodes `show.episodesToSync()` selects and that are downloaded.
    /// `reused` counts the ones already on the iPod.
    public static func prepare(shows: [PodcastShow], device: IPodDevice, store: PortableLibraryStore) throws -> PortableMusicTransfer.Prepared {
        let folder = DeviceDataFolder(mountPoint: device.mountPoint)
        try folder.requireAvailableStorage()
        var manifest = try folder.readChecked(TransferManifest.self, from: "manifest.json") ?? TransferManifest()
        guard manifest.version == 1 else { throw IPodDBError.unsupported("Unsupported manifest.json version") }
        let originalManifest = manifest
        var indexByFingerprint = Dictionary(manifest.tracks.enumerated().map { ($0.element.fingerprint, $0.offset) }, uniquingKeysWith: { a, _ in a })
        let db = try device.readDatabase()
        let present = Set(db.tracks.filter { $0.fileURL(mountPoint: device.mountPoint).map { FileManager.default.fileExists(atPath: $0.path) } ?? false }.map(\.dbid))

        var record = DeviceSyncRecord(deviceID: device.id, deviceName: device.volumeName)
        var scheduled: [PodcastShow] = []
        var reused = 0
        var scheduledDBIDs = Set<UInt64>()
        for show in shows {
            var selected = show
            selected.episodes = []
            let wanted = Set(show.episodesToSync().filter(\.isDownloaded).map(\.id))
            for episode in show.episodes {
                // Every episode with a known file on the iPod is mapped, so its played state comes back.
                let key = fingerprint(show: show, episode: episode)
                let reference = store.hostID + ":" + episode.id.uuidString
                if let i = indexByFingerprint[key] {
                    if wanted.contains(episode.id), !manifest.tracks[i].references.contains(reference) { manifest.tracks[i].references.append(reference) }
                    record.episodeDBIDs[episode.id] = manifest.tracks[i].dbid
                    if present.contains(manifest.tracks[i].dbid) {
                        if wanted.contains(episode.id) { reused += 1 }
                        selected.episodes.append(episode)
                        continue
                    }
                } else if wanted.contains(episode.id) {
                    let dbid = IPodTrack.randomDBID()
                    indexByFingerprint[key] = manifest.tracks.count
                    manifest.tracks.append(.init(dbid: dbid, owner: store.hostID, sourceID: episode.id, fingerprint: key, references: [reference]))
                    record.episodeDBIDs[episode.id] = dbid
                } else { continue }
                guard wanted.contains(episode.id), let dbid = record.episodeDBIDs[episode.id] else { continue }
                if scheduledDBIDs.insert(dbid).inserted { selected.episodes.append(episode) } else { reused += 1 }
            }
            if !selected.episodes.isEmpty {
                // Exactly these episodes: the show's own "keep the latest N" rule was applied above.
                selected.syncEnabled = true
                for i in selected.episodes.indices { selected.episodes[i].syncOverride = true }
                scheduled.append(selected)
            }
        }
        if manifest != originalManifest { try folder.requireAvailableStorage(); try folder.write(manifest, to: "manifest.json") }

        var options = SyncOptions()
        options.additiveOnly = true; options.removeUnknownTracks = false
        options.syncPhotos = false; options.syncPodcasts = true
        options.writeArtwork = store.data.read(PortableSettings.self, from: "settings.json")?.syncArtwork ?? true
        let request = SyncRequest(device: device, record: record, tracks: [], playlists: [], shows: scheduled,
            artworkDir: store.artwork, transcodeDir: store.transcodes, photoCacheDir: store.hostFolder.url.appendingPathComponent("PhotoCache"),
            photoSelection: PhotoSelection(), options: options, media: MediaServices())
        return PortableMusicTransfer.Prepared(request: request, manifest: manifest, reused: reused)
    }
}
