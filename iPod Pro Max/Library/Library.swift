import Foundation
import iPodKit

/// The subset of the real app's `LibraryTrack` the prototype needs. Unknown keys in
/// `library.json` are ignored, so the real file decodes as is.
struct Track: Decodable {
    var id: String
    var title: String
    var artist: String?
    var album: String?
    var albumArtist: String?
    var year: Int?
    var trackNumber: Int?
    var discNumber: Int?
    var durationMs: Int?
    var genre: String?
    var artworkKey: String?
}

struct Playlist: Decodable, Identifiable, Equatable {
    var id: String
    var name: String
    var trackIDs: [String]
}

private struct LibraryDocument: Decodable {
    var tracks: [Track]
    var playlists: [Playlist]?
}

/// Preformatted row for `Table`, whose columns only take `String` key paths.
struct TrackRow: Equatable {
    var id: String = ""
    var title: String
    var artist: String
    var album: String
    var number: String
    var year: String
    var duration: String
}

struct NamedGroup: Identifiable {
    var id: String
    var count: Int
    var albumCount = 0
    var artworkKey: String?
}

/// One album of an artist, with its songs in disc and track order.
struct AlbumInfo: Identifiable {
    var id: String
    var title: String
    /// "" when unknown.
    var year: String
    var genre: String?
    var artworkKey: String?
    var rows: [TrackRow]
    var durationMs: Int
}

/// Everything the views need, computed once off the main thread so a render never regroups.
struct Library {
    var source: String
    var allRows: [TrackRow]
    var artists: [NamedGroup]
    var rowsByArtist: [String: [TrackRow]]
    var albumsByArtist: [String: [AlbumInfo]]
    /// Where the covers are kept (`<key>.jpg`); nil for a library without any.
    var artworkFolder: URL?
    var playlists: [Playlist]
    var rowsByPlaylist: [String: [TrackRow]]
    var loadMs: Int
    var indexMs: Int

    static func portable(_ cache: PortableLibraryCache, source: String, artworkFolder: URL? = nil) -> Library {
        let tracks = cache.tracks.filter { $0.kind == nil || $0.kind == .song }.map {
            Track(id: $0.id.uuidString, title: $0.title, artist: $0.artist, album: $0.album,
                  albumArtist: $0.albumArtist, year: $0.year, trackNumber: $0.trackNumber,
                  discNumber: $0.discNumber, durationMs: $0.durationMs, genre: $0.genre, artworkKey: $0.artworkKey)
        }
        let playlists = cache.playlists.map { Playlist(id: $0.id.uuidString, name: $0.name, trackIDs: $0.trackIDs.map(\.uuidString)) }
        var library = index(LibraryDocument(tracks: tracks, playlists: playlists), source: source)
        library.artworkFolder = artworkFolder
        return library
    }

    static func load(arguments: [String]) async -> Library {
        await Task.detached(priority: .userInitiated) {
            let start = Date()
            let (document, source) = readDocument(arguments: arguments)
            let loaded = Date()
            var library = index(document, source: source)
            library.loadMs = ms(start, loaded)
            library.indexMs = ms(loaded, Date())
            return library
        }.value
    }

    private static func readDocument(arguments: [String]) -> (LibraryDocument, String) {
        for url in candidateURLs(arguments: arguments) {
            guard let data = try? Data(contentsOf: url) else { continue }
            do {
                let document = try JSONDecoder().decode(LibraryDocument.self, from: data)
                // An empty library would leave nothing to scroll: fall through to the synthetic one.
                if !document.tracks.isEmpty { return (document, url.path) }
            } catch {
                log("Could not decode \(url.path): \(error)")
            }
        }
        return (synthetic(count: 5000), "5 000 pistes synthétiques (aucune bibliothèque trouvée)")
    }

    /// `--library <path>` or `IPPM_LIBRARY` first, then the real app's library on this Mac, then
    /// the Mac's home folder as Parallels shares it with Windows and Linux guests.
    private static func candidateURLs(arguments: [String]) -> [URL] {
        var paths: [String] = []
        if let i = arguments.firstIndex(of: "--library"), i + 1 < arguments.count {
            paths.append(arguments[i + 1])
        }
        if let env = ProcessInfo.processInfo.environment["IPPM_LIBRARY"] {
            paths.append(env)
        }
        let suffix = "Library/Application Support/iPod Pro Max/library.json"
        #if os(macOS)
        paths.append(NSHomeDirectory() + "/" + suffix)
        #elseif os(Windows)
        paths.append(#"\\Mac\Home\"# + suffix.replacingOccurrences(of: "/", with: #"\"#))
        #else
        paths.append("/media/psf/Home/" + suffix)
        #endif
        paths.append("library.json")
        return paths.map { URL(fileURLWithPath: $0) }
    }

    private static func index(_ document: LibraryDocument, source: String) -> Library {
        let tracks = document.tracks
        // Folded once per track: sorted without case or accents, like the artist list.
        func fold(_ s: String?) -> String { (s ?? "").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        func key(_ t: Track) -> (String, String, Int, Int) {
            (fold(t.albumArtist ?? t.artist), fold(t.album), t.discNumber ?? 0, t.trackNumber ?? 0)
        }
        let sorted = tracks.map { (key($0), $0) }.sorted { $0.0 < $1.0 }.map(\.1)
        var all: [TrackRow] = []
        all.reserveCapacity(sorted.count)
        var byArtist: [String: [TrackRow]] = [:]
        var tracksByArtist: [String: [Track]] = [:]
        var byID: [String: TrackRow] = [:]
        byID.reserveCapacity(sorted.count)
        for t in sorted {
            let row = TrackRow(
                id: t.id, title: t.title,
                artist: t.artist ?? "Unknown Artist",
                album: t.album ?? "Unknown Album",
                number: (t.trackNumber ?? 0) > 0 ? "\(t.trackNumber!)" : "",
                year: (t.year ?? 0) > 0 ? "\(t.year!)" : "",
                duration: formatDuration(t.durationMs ?? 0)
            )
            all.append(row)
            byArtist[t.albumArtist ?? row.artist, default: []].append(row)
            tracksByArtist[t.albumArtist ?? row.artist, default: []].append(t)
            byID[t.id] = row
        }
        let playlists = document.playlists ?? []
        var byPlaylist: [String: [TrackRow]] = [:]
        for p in playlists {
            byPlaylist[p.id] = p.trackIDs.compactMap { byID[$0] }
        }
        let albums = tracksByArtist.mapValues(albumInfos)
        func groups(_ d: [String: [TrackRow]]) -> [NamedGroup] {
            d.map { name, rows in
                let list = albums[name] ?? []
                return NamedGroup(id: name, count: rows.count, albumCount: list.count, artworkKey: list.first { $0.artworkKey != nil }?.artworkKey)
            }
            .sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
        }
        return Library(source: source, allRows: all,
                       artists: groups(byArtist), rowsByArtist: byArtist,
                       albumsByArtist: albums, artworkFolder: nil,
                       playlists: playlists, rowsByPlaylist: byPlaylist,
                       loadMs: 0, indexMs: 0)
    }

    /// An artist's albums, newest first like the iPod's own list; the songs arrive in album order.
    private static func albumInfos(_ tracks: [Track]) -> [AlbumInfo] {
        var order: [String] = []
        var byAlbum: [String: [Track]] = [:]
        for t in tracks {
            let name = t.album ?? ""
            if byAlbum[name] == nil { order.append(name) }
            byAlbum[name, default: []].append(t)
        }
        let albums = order.map { name -> AlbumInfo in
            let songs = byAlbum[name] ?? []
            let year = songs.compactMap(\.year).first { $0 > 0 }
            return AlbumInfo(
                id: name, title: name.isEmpty ? "Unknown Album" : name, year: year.map(String.init) ?? "",
                genre: songs.compactMap(\.genre).first { !$0.isEmpty },
                artworkKey: songs.compactMap(\.artworkKey).first,
                rows: songs.map { t in
                    TrackRow(id: t.id, title: t.title, artist: t.artist ?? "Unknown Artist", album: t.album ?? "Unknown Album",
                             number: (t.trackNumber ?? 0) > 0 ? "\(t.trackNumber!)" : "", year: "", duration: formatDuration(t.durationMs ?? 0))
                },
                durationMs: songs.reduce(0) { $0 + ($1.durationMs ?? 0) })
        }
        return albums.sorted { a, b in
            if a.year != b.year { return (Int(a.year) ?? 0) > (Int(b.year) ?? 0) }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }

    private static func synthetic(count: Int) -> LibraryDocument {
        let tracks = (0..<count).map { i in
            Track(id: "\(i)", title: "Morceau \(i % 12 + 1)", artist: "Artiste \(i / 120)",
                  album: "Album \(i / 12)", year: 1970 + i % 50, trackNumber: i % 12 + 1,
                  discNumber: 1, durationMs: 180_000 + (i * 7_919) % 240_000)
        }
        let playlists = [
            Playlist(id: "p1", name: "Favoris", trackIDs: stride(from: 0, to: count, by: 37).map { "\($0)" }),
            Playlist(id: "p2", name: "Pour courir", trackIDs: stride(from: 5, to: count, by: 53).map { "\($0)" }),
        ]
        return LibraryDocument(tracks: tracks, playlists: playlists)
    }
}

private func ms(_ a: Date, _ b: Date) -> Int { Int(b.timeIntervalSince(a) * 1000) }

private func formatDuration(_ ms: Int) -> String {
    let s = ms / 1000
    return "\(s / 60):" + (s % 60 < 10 ? "0" : "") + "\(s % 60)"
}
