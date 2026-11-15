import Foundation
import iPodKit

/// The icon favorites are drawn with, chosen in Settings.
enum FavoriteIcon: String, CaseIterable {
    case heart, star

    var title: String { self == .heart ? "Heart" : "Star" }
    /// SF Symbol of a favorite, and of a song that isn't one.
    var filled: String { rawValue + ".fill" }
    var outline: String { rawValue }
    /// Plain characters, for rows drawn as one line of text.
    var filledCharacter: String { self == .heart ? "♥" : "★" }
}

/// What every list view shares: the favorite icon, the visible columns and the favorites being
/// written. Event-driven: the native tables subscribe and refresh only their visible cells, so a
/// change never re-renders the SwiftCrossUI tree or re-indexes the library. Values are read from
/// `settings.json` once per library (by `SettingsController`) and written through
/// `PortablePreferences`.
@MainActor
final class ListAppearance {
    static let shared = ListAppearance()

    private(set) var favoriteIcon = FavoriteIcon.heart
    /// Identifiers of the hidden columns (see `trackColumns`).
    private(set) var hiddenColumns: Set<String> = ListAppearance.defaultHiddenColumns
    /// Columns hidden until the user asks for them.
    static let defaultHiddenColumns: Set<String> = ["dateAdded"]

    /// Favorites clicked but not saved yet: shown at once, dropped when the write ends.
    private var pendingFavorites: [String: Bool] = [:]
    private var favoriteWrites = 0

    private var store: PortableLibraryStore?
    private var loadedStore: URL?
    private var observers: [(owner: () -> AnyObject?, action: @MainActor () -> Void)] = []

    /// Runs `action` after each change, for as long as `owner` lives.
    func observe(_ owner: AnyObject, _ action: @escaping @MainActor () -> Void) {
        observers.removeAll { $0.owner() == nil }
        observers.append(({ [weak owner] in owner }, action))
    }

    private func notify() {
        observers.removeAll { $0.owner() == nil }
        for observer in observers { observer.action() }
    }

    /// The library's saved choices. Only the first read of a library counts: later ones could be
    /// older than a change still waiting to be written.
    func load(_ settings: PortableSettings?, store: PortableLibraryStore) {
        self.store = store
        guard loadedStore != store.data.url else { return }
        loadedStore = store.data.url
        let icon = FavoriteIcon(rawValue: settings?.favoriteIcon ?? "") ?? .heart
        let hidden = settings?.hiddenTrackColumns.map(Set.init) ?? Self.defaultHiddenColumns
        guard icon != favoriteIcon || hidden != hiddenColumns else { return }
        favoriteIcon = icon
        hiddenColumns = hidden
        notify()
    }

    func setFavoriteIcon(_ icon: FavoriteIcon) {
        guard icon != favoriteIcon else { return }
        favoriteIcon = icon
        if let store { PortablePreferences.shared.stageFavoriteIcon(icon.rawValue, store: store) }
        notify()
    }

    func setColumn(_ id: String, hidden: Bool) {
        guard hidden != hiddenColumns.contains(id) else { return }
        if hidden { hiddenColumns.insert(id) } else { hiddenColumns.remove(id) }
        if let store { PortablePreferences.shared.stageHiddenTrackColumns(hiddenColumns.sorted(), store: store) }
        notify()
    }

    // MARK: Favorites being written

    func isFavorite(_ row: TrackRow) -> Bool { pendingFavorites[row.id] ?? row.isFavorite }

    /// Shows the new state right away; `endFavoriteWrite` follows once the library is saved.
    func beginFavoriteWrite(_ ids: [String], favorite: Bool) {
        favoriteWrites += 1
        for id in ids { pendingFavorites[id] = favorite }
        notify()
    }

    /// After a successful write the reindexed rows carry the state and reload the tables by
    /// themselves; after a failed one the cells go back to what is saved.
    func endFavoriteWrite(saved: Bool) {
        favoriteWrites = max(0, favoriteWrites - 1)
        guard favoriteWrites == 0, !pendingFavorites.isEmpty else { return }
        pendingFavorites.removeAll()
        if !saved { notify() }
    }
}
