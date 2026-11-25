import Foundation
import SwiftCrossUI
import iPodKit

/// A page shown as a cover grid. Each section is one configuration of the same page: only its
/// key (for the saved zoom), its cover shape and what a click does differ.
enum GridSection: String {
    case albums, games

    var key: String { rawValue }
    var defaultArtworkSize: Double { self == .games ? 200 : 172 }
    /// Cover height over width.
    var artworkAspect: Double { self == .games ? 0.75 : 1 }

    static let artworkSizeRange = 110.0...280.0
    func artworkSize(in sizes: [String: Double]) -> Double {
        min(max(sizes[key] ?? defaultArtworkSize, Self.artworkSizeRange.lowerBound), Self.artworkSizeRange.upperBound)
    }
}

/// What a click on a grid item does.
enum GridAction {
    /// Albums: a click unfolds the item's tracks below its row; they can be played.
    case expand(onSelect: (String) -> Void, onPlay: (TrackRow, [TrackRow]) -> Void)
    /// Games: a click selects, a double-click opens the item.
    case open((String) -> Void)
}

/// The cover grid of a section with everything every grid page shares: the pinch zoom and its
/// saving per section, Cmd-A and drag (in `AlbumBrowser`). The page around it draws the background.
struct GridPage: View {
    var section: GridSection
    var items: [AlbumInfo]
    var artworkFolder: URL?
    var query: String
    var artworkSizes: [String: Double]
    var store: PortableLibraryStore?
    var action: GridAction
    /// Keeps the app's copy of the sizes current once a pinch ends.
    var onArtworkSizesChange: ([String: Double]) -> Void

    var body: some View {
        browser
    }

    private var browser: AlbumBrowser {
        let key = section.key
        let commit: (Double) -> Void = { size in
            var sizes = artworkSizes; sizes[key] = size
            onArtworkSizesChange(sizes)
        }
        let onSelect: (String) -> Void, onPlay: (TrackRow, [TrackRow]) -> Void, onOpen: ((String) -> Void)?
        switch action {
        case .expand(let select, let play): onSelect = select; onPlay = play; onOpen = nil
        case .open(let open): onSelect = { _ in }; onPlay = { _, _ in }; onOpen = open
        }
        return AlbumBrowser(albums: items, artworkFolder: artworkFolder, query: query, onSelect: onSelect,
                            artworkSize: section.artworkSize(in: artworkSizes),
                            onArtworkSize: { size in
                                // AppKit resizes live during the pinch and reports the end in `onArtworkCommit`;
                                // the other backends only report through this one.
                                #if !canImport(AppKitBackend)
                                commit(size)
                                #endif
                                if let store { PortablePreferences.shared.stageGridArtworkSize(size, section: key, store: store) }
                            },
                            onArtworkCommit: commit, onPlay: onPlay,
                            artworkAspect: section.artworkAspect, onOpen: onOpen)
    }
}
