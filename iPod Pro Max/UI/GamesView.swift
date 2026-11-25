import Foundation
import SwiftCrossUI
import iPodKit

/// The Games section: the click-wheel games (`.ipg`) of the chosen folders, in the shared cover grid.
struct GamesView: View {
    var store: PortableLibraryStore?
    var query: String
    var artworkSizes: [String: Double]
    var onArtworkSizesChange: ([String: Double]) -> Void
    var onAddFolder: (URL) async -> Bool
    var onRemoveFolder: (UUID) async -> Bool
    @Environment(\.chooseFile) private var chooseFile

    @State private var catalog = GameCatalog.Snapshot()
    @State private var loaded = false
    @State private var message = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(summary).foregroundColor(.gray)
                if !message.isEmpty { Text(message).font(.system(size: 11)).foregroundColor(MacColor.red) }
                Spacer()
                ForEach(catalog.folders, id: \.id) { folder in
                    Button("Remove \(URL(fileURLWithPath: folder.path).lastPathComponent)") { remove(folder) }
                }
                Button("Add Folder…") { Task { await addFolder() } }
            }
            .padding(8)
            Divider()
            if catalog.games.isEmpty {
                EmptyState(icon: "gamecontroller", title: loaded ? "No Games Yet" : "Loading…",
                           message: "Add a folder of iPod games (.ipg), such as iTunes Media/iPod Games. Each game shows its cover and publisher, like an album.")
            } else {
                GridPage(section: .games, items: catalog.games, artworkFolder: catalog.artworkFolder, query: query,
                         artworkSizes: artworkSizes, store: store, action: .open { id in openInstructions(id) },
                         onArtworkSizesChange: onArtworkSizesChange)
            }
        }
        .task {
            TrackDrag.onGamesDropped = { files, device in
                // Copying is easy; making the iPod run them is not: the games need the authorization
                // (IC-Info.sidb) that only iTunes writes. Say so instead of copying games that won't start.
                message = "\(files.count) game\(files.count == 1 ? "" : "s") for \(device): installing games on an iPod isn't possible yet."
                return false
            }
            await refresh()
        }
    }

    private var summary: String {
        let n = catalog.games.count
        return n == 0 ? "No games" : "\(n) game\(n == 1 ? "" : "s")"
    }

    private func refresh(force: Bool = false) async {
        guard let store else { return }
        let snapshot = await GameCatalog.shared.load(store, refresh: force)
        guard !Task.isCancelled else { return }
        catalog = snapshot
        loaded = true
    }

    /// Game ids are the archive paths.
    private func openInstructions(_ id: String) {
        Task {
            guard let page = await GameCatalog.instructions(URL(fileURLWithPath: id)) else {
                message = "This game has no instructions."; return
            }
            message = ""
            QuickPreview.shared.show(page, title: catalog.games.first { $0.id == id }?.title)
        }
    }

    private func addFolder() async {
        guard store != nil, let url = await chooseFile(title: "Choose a Folder of iPod Games", defaultButtonLabel: "Add Folder",
            allowSelectingFiles: false, allowSelectingDirectories: true) else { return }
        message = ""
        guard await onAddFolder(url) else { message = "Couldn't add the folder."; return }
        await refresh(force: true)
    }

    private func remove(_ folder: KnownSource) {
        Task {
            guard await onRemoveFolder(folder.id) else { message = "Couldn't remove the folder."; return }
            await refresh(force: true)
        }
    }
}
