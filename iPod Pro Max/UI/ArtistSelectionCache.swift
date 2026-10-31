import Foundation
import SwiftCrossUI

/// Stable album buffers across status/progress redraws keep the native song selection intact.
final class ArtistSelectionCache: SwiftCrossUI.ObservableObject {
    struct Group {
        var artist: NamedGroup
        var albums: [AlbumInfo]
        var photoArtist: String?
    }
    private var selected: Set<String> = []
    private var rows: [TrackRow] = []
    private var artists: [NamedGroup] = []
    private var result: Group?

    func group(_ library: Library, selected: Set<String>) -> Group? {
        if self.selected == selected, rows.sameStorage(as: library.allRows), artists.sameStorage(as: library.artists) { return result }
        let names = library.artists.filter { selected.contains($0.id) }
        let changedAlbums = self.selected != selected || !rows.sameStorage(as: library.allRows)
        self.selected = selected
        rows = library.allRows
        artists = library.artists
        guard !names.isEmpty else { result = nil; return nil }
        let albums = changedAlbums || result == nil ? names.flatMap { library.albumsByArtist[$0.id] ?? [] } : result!.albums
        let artist = names.count == 1 ? names[0] : NamedGroup(id: "\(names.count) Artists", count: names.reduce(0) { $0 + $1.count }, albumCount: albums.count)
        result = Group(artist: artist, albums: albums, photoArtist: names.count == 1 ? names[0].id : nil)
        return result
    }
}
