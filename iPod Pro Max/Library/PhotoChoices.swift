import Foundation
import iPodKit

/// Which Photos-app albums this computer sends to iPods, kept in `photos.json` on the launching iPod.
/// Changes are saved in order, off the main actor; `flush` waits for the last one (before a transfer
/// and when the app closes).
@MainActor
final class PhotoChoices {
    static let shared = PhotoChoices()
    private(set) var selection = PhotoSelection()
    var onError: (String) -> Void = { _ in }
    private var store: PortableLibraryStore?
    private var chain: Task<Void, Never>?

    func load(store: PortableLibraryStore) async {
        self.store = store
        selection = await Task.detached(priority: .userInitiated) { store.loadPhotoSelection() }.value
    }

    func update(_ new: PhotoSelection) {
        guard new != selection, let store else { return }
        selection = new
        let previous = chain
        chain = Task.detached(priority: .utility) { [onError] in
            await previous?.value
            do { try store.savePhotoSelection(new) }
            catch { await MainActor.run { onError("Couldn't save the photo choices: \(error.localizedDescription)") } }
        }
    }

    func flush() async { await chain?.value }
}
