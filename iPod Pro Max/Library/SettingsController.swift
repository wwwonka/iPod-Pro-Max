import Foundation
import iPodKit

/// State behind the Settings window, shared with the main window (a separate scene has no access to
/// `ContentView`'s state). Event-driven only: the main window attaches the open iPod's store, the
/// view re-renders on `onChange`; disk reads run off the main actor and writes go through
/// `PortablePreferences` (staged, flushed ~500 ms later).
@MainActor
final class SettingsController {
    static let shared = SettingsController()

    private(set) var syncArtwork = true
    struct Source: Hashable {
        var id: UUID
        var kind: String
        var path: String
    }
    /// Folders the library is built from.
    private(set) var sources: [Source] = []
    var onChange: () -> Void = {}

    private var store: PortableLibraryStore?
    private var loadTask: Task<Void, Never>?

    /// Called when the main window opens a library (or re-reads it after a folder was added).
    func attach(_ store: PortableLibraryStore?) {
        self.store = store
        loadTask?.cancel()
        guard let store else {
            sources = []
            onChange()
            return
        }
        loadTask = Task {
            let (settings, hosts) = await Task.detached(priority: .utility) {
                (store.data.read(PortableSettings.self, from: "settings.json"),
                 store.data.read(KnownHosts.self, from: "known_hosts.json"))
            }.value
            guard !Task.isCancelled else { return }
            syncArtwork = settings?.syncArtwork ?? true
            sources = hosts?.hosts.first { $0.id == store.hostID }?.sources.map { Source(id: $0.id, kind: $0.kind.rawValue, path: $0.path) } ?? []
            onChange()
        }
    }

    var hasLibrary: Bool { store != nil }

    func setSyncArtwork(_ value: Bool) {
        guard let store, value != syncArtwork else { return }
        syncArtwork = value
        PortablePreferences.shared.stageSyncArtwork(value, store: store)
        onChange()
    }
}
