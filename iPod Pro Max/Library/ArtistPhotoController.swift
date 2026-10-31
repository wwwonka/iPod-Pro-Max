import Foundation
import iPodKit
import MediaKit

/// The artist photos of the launching iPod's library: loaded from disk, then the missing ones fetched
/// from Deezer once, in the background. Event-driven: runs after a library load, never on a timer.
@MainActor
final class ArtistPhotoController {
    static let shared = ArtistPhotoController()

    private var store: ArtistPhotoStore?
    private var photos: [String: URL] = [:]
    /// Called on the main actor whenever photos were added.
    var onChange: () -> Void = {}

    func load(store portable: PortableLibraryStore) async {
        // In Persistent Data itself: the photos belong to the iPod, not to one computer.
        let folder = portable.data.url.appendingPathComponent("Artist Photos", isDirectory: true)
        let earlier = portable.hostFolder.url.appendingPathComponent("Artist Photos", isDirectory: true)
        let loaded = await Task.detached(priority: .utility) { () -> ArtistPhotoStore in
            // Photos kept per computer until now move up one level.
            let fm = FileManager.default
            if fm.fileExists(atPath: earlier.path), !fm.fileExists(atPath: folder.path) {
                try? fm.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.moveItem(at: earlier, to: folder)
            }
            return ArtistPhotoStore(folder: folder)
        }.value
        store = loaded
        photos = await loaded.photos()
    }

    func url(for artist: String) -> URL? { photos[ArtistPhotoStore.normalize(artist)] }

    /// Replaces an artist's photo with a picture file.
    func setCustomPhoto(_ image: URL, for artist: String) async -> Bool {
        guard let store, await store.setCustomPhoto(image, for: artist) else { return false }
        photos = await store.photos()
        onChange()
        return true
    }

    /// Looks up the artists that have no photo yet. Overlapping calls are ignored by the store.
    func fetchMissing(_ artists: [String]) {
        guard let store else { return }
        Task {
            await store.fetchMissing(artists) { [weak self] in
                Task { @MainActor in
                    guard let self, let store = self.store else { return }
                    self.photos = await store.photos()
                    self.onChange()
                }
            }
            photos = await store.photos()
            onChange()
        }
    }
}
