//
//  PortablePhotoTransfer.swift
//  iPod Pro Max
//
//  Puts this computer's chosen photos on a portable iPod. The iPod's Photo Database is rebuilt from the
//  chosen sources each time (as the former app did): what is chosen is what the Photos menu shows. Music,
//  podcasts and everything else on the iPod are left exactly as they are.
//

import Foundation
import iPodKit

public enum PortablePhotoTransfer {
    /// The sources of this computer: its picked folders, and on a Mac the Photos app.
    public static func library(store: PortableLibraryStore) -> CompositePhotoLibrary {
        var sources: [any PhotoLibrarySource] = []
        let folders = store.sources(of: .photos).map { URL(fileURLWithPath: $0.path) }
        if !folders.isEmpty { sources.append(FolderPhotoLibrary(folders: folders)) }
        #if canImport(Photos) && canImport(AppKit)
        sources.append(PhotosAppLibrary())
        #endif
        return CompositePhotoLibrary(sources: sources)
    }

    public static func prepare(device: IPodDevice, store: PortableLibraryStore, library: any PhotoLibrarySource,
                               selection: PhotoSelection) throws -> PortableMusicTransfer.Prepared {
        guard device.generation.supportsPhotos else { throw IPodDBError.unsupported("This iPod has no color screen for photos.") }
        let folder = DeviceDataFolder(mountPoint: device.mountPoint)
        try folder.requireAvailableStorage()
        let manifest = try folder.readChecked(TransferManifest.self, from: "manifest.json") ?? TransferManifest()
        guard manifest.version == 1 else { throw IPodDBError.unsupported("Unsupported manifest.json version") }
        var options = SyncOptions()
        options.additiveOnly = true; options.removeUnknownTracks = false
        options.syncPodcasts = false; options.syncPhotos = true
        options.writeArtwork = store.data.read(PortableSettings.self, from: "settings.json")?.syncArtwork ?? true
        let request = SyncRequest(device: device, record: DeviceSyncRecord(deviceID: device.id, deviceName: device.volumeName),
            tracks: [], playlists: [], shows: [], artworkDir: store.artwork, transcodeDir: store.transcodes,
            photoCacheDir: store.photoCache, photoSelection: selection, options: options, media: MediaServices(), photoLibrary: library)
        var prepared = PortableMusicTransfer.Prepared(request: request, manifest: manifest, reused: 0)
        prepared.alwaysRuns = true
        return prepared
    }
}
