import Foundation
import iPodKit
import MediaKit

/// The subset of the real app's `LibraryTrack` the prototype needs. Unknown keys in
/// `library.json` are ignored, so the real file decodes as is.
struct Track: Decodable {
    var id: String
    var title: String
    var path: String? = nil
    var artist: String?
    var album: String?
    var albumArtist: String?
    var year: Int?
    var trackNumber: Int?
    var discNumber: Int?
    var durationMs: Int?
    var genre: String?
    var artworkKey: String?
    var lyrics: String? = nil
    var hasLyrics: Bool? = nil
    var dateAdded: Date? = nil
    var isFavorite: Bool? = nil
}

struct Playlist: Decodable, Identifiable, Equatable {
    var id: String
    var name: String
    var trackIDs: [String]
    var isFolder: Bool = false
    var parentID: String? = nil
    var subscriptionID: String? = nil
}

extension Playlist: PlaylistTreeNode {
    var isSubscribed: Bool { subscriptionID != nil }
}

private struct LibraryFavoriteRef: Decodable {
    var id: String
}

private struct LibraryDocument: Decodable {
    var tracks: [Track]
    var playlists: [Playlist]?
    var favoriteReferences: [LibraryFavoriteRef]?
}

/// Preformatted row for `Table`, whose columns only take `String` key paths.
enum PlaybackContentKind: String, Sendable { case music, podcast, audiobook }

struct TrackRow: Equatable {
    var id: String = ""
    var title: String
    var artist: String
    var album: String
    var number: String
    var year: String
    var duration: String
    var path: String? = nil
    var lyrics: String? = nil
    var playbackTitle: String? = nil
    var playbackSubtitle: String? = nil
    var playbackKind: PlaybackContentKind = .music
    var hasLyrics = false
    var artworkKey: String? = nil
    var dateAdded: Date? = nil
    var isFavorite = false
    /// Non-nil only for rows belonging to a subscribed playlist (`SUB-6`).
    var subscriptionKey: String? = nil
}

struct NamedGroup: Identifiable {
    var id: String
    var count: Int
    var albumCount = 0
    /// Optional presentation for other native list clients (podcast subscriptions).
    var displayName: String?
    var subtitle: String?
    var artworkKey: String?
    /// The first album's cover, when there is one.
    var cover: URL?
    /// What the lists and the page show: the artist's Deezer photo, else the cover.
    var photo: URL?
}

/// One album of an artist, with its songs in disc and track order.
/// Album shelves shown under Albums in the sidebar, picked from the album's genre tag.
enum AlbumShelf: CaseIterable {
    case soundtracks, classical

    static func of(genre: String?) -> AlbumShelf? {
        guard let genre = genre?.lowercased(), !genre.isEmpty else { return nil }
        let soundtrack = ["soundtrack", "score", "bande originale", "bande-originale", "ost", "film", "movie", "musical", "video game"]
        let classical = ["classical", "classique", "opera", "opéra", "baroque", "symphon", "orchestral", "chamber", "concerto"]
        if soundtrack.contains(where: { genre.contains($0) }) { return .soundtracks }
        if classical.contains(where: { genre.contains($0) }) { return .classical }
        return nil
    }
}

struct AlbumInfo: Identifiable {
    var id: String
    var title: String
    /// "" when unknown.
    var year: String
    var genre: String?
    var artworkKey: String?
    var rows: [TrackRow]
    var durationMs: Int
    var artist: String = ""
}

/// Fast UTF-8 folded substring matching shared by track, album, and artist search caches.
enum FastSearch {
    static func fold(_ text: String) -> String {
        if text.utf8.allSatisfy({ $0 < 0x80 }) {
            var bytes = ContiguousArray(text.utf8)
            var changed = false
            for i in bytes.indices where bytes[i] >= 65 && bytes[i] <= 90 {
                bytes[i] &+= 32
                changed = true
            }
            return changed ? String(decoding: bytes, as: UTF8.self) : text
        }
        return text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    static func rowKey(_ row: TrackRow) -> String {
        fold(row.title) + "\0" + fold(row.artist) + "\0" + fold(row.album)
    }

    static func albumKey(_ album: AlbumInfo) -> String {
        fold(album.title) + "\0" + fold(album.artist)
    }

    static func containsUTF8(_ haystack: String, needle: String) -> Bool {
        guard !needle.isEmpty else { return true }
        var result: Bool?
        haystack.utf8.withContiguousStorageIfAvailable { h in
            needle.utf8.withContiguousStorageIfAvailable { n in
                result = containsBytes(h, needle: n)
            }
        }
        return result ?? haystack.contains(needle)
    }

    private static func containsBytes(_ h: UnsafeBufferPointer<UInt8>, needle n: UnsafeBufferPointer<UInt8>) -> Bool {
        let nCount = n.count
        let hCount = h.count
        guard nCount > 0 else { return true }
        guard hCount >= nCount else { return false }
        let first = n[0]
        let limit = hCount - nCount
        var i = 0
        while i <= limit {
            if h[i] == first {
                var j = 1
                while j < nCount && h[i + j] == n[j] {
                    j += 1
                }
                if j == nCount { return true }
            }
            i += 1
        }
        return false
    }
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
    var videoPlaylists: [Playlist] = []
    var videoRows: [TrackRow] = []
    var videoRowsByCategory: [VideoCategory: [TrackRow]] = [:]
    var rowsByVideoPlaylist: [String: [TrackRow]] = [:]
    var trackIDs: Set<String> = []
    var loadMs: Int
    var indexMs: Int
    var favoriteRows: [TrackRow] = []
    var recentRows: [TrackRow] = []
    var albums: [AlbumInfo] = []
    /// Albums per shelf (Soundtracks, Classical), worked out once while indexing.
    var shelfAlbums: [AlbumShelf: [AlbumInfo]] = [:]
    var recentAlbums: [AlbumInfo] = []

    static func portable(_ cache: PortableLibraryCache, source: String, artworkFolder: URL? = nil) -> Library {
        let tracks = cache.tracks.filter { $0.kind == nil || $0.kind == .song }.map {
            Track(id: $0.id.uuidString, title: $0.title, path: $0.path, artist: $0.artist, album: $0.album,
                  albumArtist: $0.albumArtist, year: $0.year, trackNumber: $0.trackNumber,
                  discNumber: $0.discNumber, durationMs: $0.durationMs, genre: $0.genre, artworkKey: $0.artworkKey, lyrics: $0.lyrics, hasLyrics: $0.hasLyrics, dateAdded: $0.dateAdded, isFavorite: $0.isFavorite)
        }
        let playlists = cache.playlists.map {
            Playlist(
                id: $0.id.uuidString,
                name: $0.name,
                trackIDs: $0.trackIDs.map(\.uuidString),
                isFolder: $0.isFolder,
                parentID: $0.parentID?.uuidString,
                subscriptionID: $0.subscriptionID?.uuidString
            )
        }
        let videoPlaylists = cache.videoPlaylists.map { Playlist(id: $0.id.uuidString, name: $0.name, trackIDs: $0.trackIDs.map(\.uuidString)) }
        var library = index(LibraryDocument(tracks: tracks, playlists: playlists), source: source)
        library.videoPlaylists = videoPlaylists
        let videos = cache.tracks.filter { $0.kind == .video }.map { track in
            TrackRow(id: track.id.uuidString, title: track.title,
                     artist: track.artist ?? "", album: track.album ?? "",
                     number: track.trackNumber > 0 ? "\(track.trackNumber)" : "",
                     year: track.year > 0 ? "\(track.year)" : "",
                     duration: formatDuration(track.durationMs), path: track.path,
                     artworkKey: track.artworkKey, dateAdded: track.dateAdded)
        }
        library.videoRows = videos
        let categoryByID = Dictionary(uniqueKeysWithValues: cache.tracks.filter { $0.kind == .video }.map {
            ($0.id.uuidString, $0.videoCategory ?? ($0.sourcePluginID != nil ? .webVideo : .movie))
        })
        library.videoRowsByCategory = Dictionary(grouping: videos) { categoryByID[$0.id] ?? .movie }
        let videoByID = Dictionary(uniqueKeysWithValues: videos.map { ($0.id, $0) })
        library.rowsByVideoPlaylist = Dictionary(uniqueKeysWithValues: videoPlaylists.map { playlist in
            let playlistRows = playlist.trackIDs.compactMap { videoByID[$0] }.enumerated().map { idx, row in
                var copy = row
                copy.number = "\(idx + 1)"
                return copy
            }
            return (playlist.id, playlistRows)
        })
        library.artworkFolder = artworkFolder
        if let artworkFolder {
            library.artists = library.artists.map { artist in
                var artist = artist
                if let key = artist.artworkKey {
                    let url = artworkFolder.appendingPathComponent("\(key).jpg")
                    if FileManager.default.fileExists(atPath: url.path) { artist.cover = url; artist.photo = url }
                }
                return artist
            }
        }
        library.trackIDs = Set(library.allRows.map(\.id))
        return library
    }

    /// After an edit that only touched playlists: rebuilds the playlist lists and their rows from the
    /// rows already indexed, without re-sorting the tracks or checking artwork on disk. O(tracks).
    func reindexingPlaylists(from cache: PortableLibraryCache) -> Library {
        var library = self
        library.playlists = cache.playlists.map {
            Playlist(id: $0.id.uuidString, name: $0.name, trackIDs: $0.trackIDs.map(\.uuidString),
                     isFolder: $0.isFolder, parentID: $0.parentID?.uuidString, subscriptionID: $0.subscriptionID?.uuidString)
        }
        library.videoPlaylists = cache.videoPlaylists.map { Playlist(id: $0.id.uuidString, name: $0.name, trackIDs: $0.trackIDs.map(\.uuidString)) }
        func numbered(_ playlists: [Playlist], _ rows: [TrackRow]) -> [String: [TrackRow]] {
            let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            return Dictionary(playlists.map { playlist in
                (playlist.id, playlist.trackIDs.compactMap { byID[$0] }.enumerated().map { index, row in
                    var copy = row
                    copy.number = "\(index + 1)"
                    return copy
                })
            }, uniquingKeysWith: { first, _ in first })
        }
        library.rowsByPlaylist = numbered(library.playlists, allRows)
        library.rowsByVideoPlaylist = numbered(library.videoPlaylists, videoRows)
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
                let decoder = JSONDecoder()
                let iso = ISO8601DateFormatter()
                let fractionalISO = ISO8601DateFormatter()
                fractionalISO.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                decoder.dateDecodingStrategy = .custom { decoder in
                    let value = try decoder.singleValueContainer()
                    if let number = try? value.decode(Double.self) { return Date(timeIntervalSinceReferenceDate: number) }
                    let string = try value.decode(String.self)
                    if let date = iso.date(from: string) ?? fractionalISO.date(from: string) { return date }
                    throw DecodingError.dataCorruptedError(in: value, debugDescription: "Invalid track date")
                }
                let document = try decoder.decode(LibraryDocument.self, from: data)
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
                duration: formatDuration(t.durationMs ?? 0), path: t.path, lyrics: t.lyrics, hasLyrics: t.hasLyrics ?? false, artworkKey: t.artworkKey, dateAdded: t.dateAdded, isFavorite: t.isFavorite ?? false
            )
            all.append(row)
            byArtist[t.albumArtist ?? row.artist, default: []].append(row)
            tracksByArtist[t.albumArtist ?? row.artist, default: []].append(t)
            byID[t.id] = row
        }
        let playlists = document.playlists ?? []
        var byPlaylist: [String: [TrackRow]] = [:]
        for p in playlists {
            byPlaylist[p.id] = p.trackIDs.compactMap { byID[$0] }.enumerated().map { idx, row in
                var copy = row
                copy.number = "\(idx + 1)"
                return copy
            }
        }
        let albums = tracksByArtist.mapValues(albumInfos)
        func groups(_ d: [String: [TrackRow]]) -> [NamedGroup] {
            d.map { name, rows in
                let list = albums[name] ?? []
                return NamedGroup(id: name, count: rows.count, albumCount: list.count, artworkKey: list.first { $0.artworkKey != nil }?.artworkKey)
            }
            .sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
        }
        var library = Library(source: source, allRows: all,
                       artists: groups(byArtist), rowsByArtist: byArtist,
                       albumsByArtist: albums, artworkFolder: nil,
                       playlists: playlists, rowsByPlaylist: byPlaylist,
                       loadMs: 0, indexMs: 0)
        if let refs = document.favoriteReferences, !refs.isEmpty {
            let refIDs = Set(refs.map(\.id))
            library.favoriteRows = refs.compactMap { byID[$0.id] }.filter(\.isFavorite)
                + all.filter { $0.isFavorite && !refIDs.contains($0.id) }
        } else {
            library.favoriteRows = all.filter(\.isFavorite)
        }
        // Newest day first; within a day, the library's own order (artist, album, disc, track), so
        // an album imported in one go stays together whatever order its files were read in.
        let calendar = Calendar.current
        let days: [Date] = all.map { row in row.dateAdded.map { calendar.startOfDay(for: $0) } ?? .distantPast }
        let recentOrder: [Int] = all.indices.sorted { a, b in days[a] == days[b] ? a < b : days[a] > days[b] }
        library.recentRows = recentOrder.map { all[$0] }
        library.albums = albums.keys.sorted().flatMap { artist in
            (albums[artist] ?? []).map { album in
                var album = album
                album.artist = artist
                album.id = "\(artist.utf8.count):\(artist)\(album.id)"
                return album
            }
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        library.shelfAlbums = Dictionary(grouping: library.albums.filter { AlbumShelf.of(genre: $0.genre) != nil }) { AlbumShelf.of(genre: $0.genre)! }
        // Compute recency once during indexing, never while the view renders.
        var datedAlbums: [(index: Int, album: AlbumInfo, latest: Date)] = library.albums.enumerated().map { index, album in
            (index, album, album.rows.compactMap(\.dateAdded).max() ?? Date.distantPast)
        }
        datedAlbums.sort { $0.latest == $1.latest ? $0.index < $1.index : $0.latest > $1.latest }
        library.recentAlbums = datedAlbums.map { $0.album }
        library.trackIDs = Set(library.allRows.map(\.id))
        return library
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
            let year = songs.compactMap(\.year).filter { $0 > 0 }.min()
            return AlbumInfo(
                id: name, title: name.isEmpty ? "Unknown Album" : name, year: year.map(String.init) ?? "",
                genre: songs.compactMap(\.genre).first { !$0.isEmpty },
                artworkKey: songs.compactMap(\.artworkKey).first,
                rows: songs.map { t in
                    TrackRow(id: t.id, title: t.title, artist: t.artist ?? "Unknown Artist", album: t.album ?? "Unknown Album",
                             number: (t.trackNumber ?? 0) > 0 ? "\(t.trackNumber!)" : "", year: "", duration: formatDuration(t.durationMs ?? 0), path: t.path, lyrics: t.lyrics, hasLyrics: t.hasLyrics ?? false, artworkKey: t.artworkKey, dateAdded: t.dateAdded, isFavorite: t.isFavorite ?? false)
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

func formatDuration(_ ms: Int) -> String {
    let s = ms / 1000
    return "\(s / 60):" + (s % 60 < 10 ? "0" : "") + "\(s % 60)"
}
