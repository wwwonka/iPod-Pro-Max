import Foundation
import SwiftCrossUI
import MediaKit
import iPodKit

/// Navigation reuses one inventory per portable store. Refresh and source changes explicitly
/// invalidate it; no scans or timers run while Photos is out of view or idle.
@MainActor final class PhotoInventory {
    static let shared = PhotoInventory()
    struct Snapshot {
        var folders: [KnownSource] = []
        var counts: [UUID: Int] = [:]
        #if canImport(Photos) && canImport(AppKit)
        var access: PhotosApp.Access = .notDetermined
        var albums: [PhotosAlbumInfo] = []
        var allCount: Int = 0
        #endif
    }
    private var snapshots: [URL: Snapshot] = [:]
    private var pending: [URL: (id: UUID, task: Task<Snapshot, Never>)] = [:]
    private(set) var scanCount = 0

    func load(_ store: PortableLibraryStore, refresh: Bool = false) async -> Snapshot {
        let key = store.hostFolder.url
        if refresh {
            snapshots[key] = nil
            pending[key] = nil
        }
        if let cached = snapshots[key] { return cached }
        if let pending = pending[key] { return await pending.task.value }
        scanCount += 1
        let task = Task.detached(priority: .utility) { () -> Snapshot in
            let folders = store.sources(of: .photos)
            let counts = await withTaskGroup(of: (UUID, Int).self) { group in
                var iterator = folders.makeIterator()
                var result: [UUID: Int] = [:]
                func next() {
                    guard let folder = iterator.next() else { return }
                    group.addTask {
                        (folder.id, FolderPhotoLibrary.images(in: URL(fileURLWithPath: folder.path)).count)
                    }
                }
                let width = max(1, ProcessInfo.processInfo.activeProcessorCount / 2)
                for _ in 0..<min(width, folders.count) { next() }
                for await (id, count) in group { result[id] = count; next() }
                return result
            }
            #if canImport(Photos) && canImport(AppKit)
            let access = PhotosApp.access
            return Snapshot(folders: folders, counts: counts, access: access,
                albums: access == .authorized ? PhotosApp.albums() : [],
                allCount: access == .authorized ? PhotosApp.allPhotosCount() : 0)
            #else
            return Snapshot(folders: folders, counts: counts)
            #endif
        }
        let id = UUID()
        pending[key] = (id, task)
        let result = await task.value
        // A source change/refresh may have started a newer generation while this scan ran.
        if pending[key]?.id == id {
            snapshots[key] = result
            pending[key] = nil
        } else if let newer = pending[key] {
            return await newer.task.value
        } else if let latest = snapshots[key] {
            return latest
        }
        return result
    }
}
