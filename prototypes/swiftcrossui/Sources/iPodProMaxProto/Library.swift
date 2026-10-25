import Foundation

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
}

struct Playlist: Decodable, Identifiable {
    var id: String
    var name: String
    var trackIDs: [String]
}

private struct LibraryDocument: Decodable {
    var tracks: [Track]
    var playlists: [Playlist]?
}

/// Preformatted row for `Table`, whose columns only take `String` key paths.
struct TrackRow {
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
}

/// Everything the views need, computed once off the main thread so a render never regroups.
struct Library {
    var source: String
    var allRows: [TrackRow]
    var artists: [NamedGroup]
    var albums: [NamedGroup]
    var rowsByArtist: [String: [TrackRow]]
    var rowsByAlbum: [String: [TrackRow]]
    var playlists: [Playlist]
    var rowsByPlaylist: [String: [TrackRow]]
    var loadMs: Int
    var indexMs: Int

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
                print("Could not decode \(url.path): \(error)")
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
        func key(_ t: Track) -> (String, String, Int, Int) {
            let artist: String = t.albumArtist ?? t.artist ?? ""
            return (artist, t.album ?? "", t.discNumber ?? 0, t.trackNumber ?? 0)
        }
        let sorted = tracks.map { (key($0), $0) }.sorted { $0.0 < $1.0 }.map(\.1)
        var all: [TrackRow] = []
        all.reserveCapacity(sorted.count)
        var byArtist: [String: [TrackRow]] = [:]
        var byAlbum: [String: [TrackRow]] = [:]
        var byID: [String: TrackRow] = [:]
        byID.reserveCapacity(sorted.count)
        for t in sorted {
            let row = TrackRow(
                title: t.title,
                artist: t.artist ?? "Artiste inconnu",
                album: t.album ?? "Album inconnu",
                number: (t.trackNumber ?? 0) > 0 ? "\(t.trackNumber!)" : "",
                year: (t.year ?? 0) > 0 ? "\(t.year!)" : "",
                duration: formatDuration(t.durationMs ?? 0)
            )
            all.append(row)
            byArtist[t.albumArtist ?? row.artist, default: []].append(row)
            byAlbum[row.album, default: []].append(row)
            byID[t.id] = row
        }
        let playlists = document.playlists ?? []
        var byPlaylist: [String: [TrackRow]] = [:]
        for p in playlists {
            byPlaylist[p.id] = p.trackIDs.compactMap { byID[$0] }
        }
        func groups(_ d: [String: [TrackRow]]) -> [NamedGroup] {
            d.map { NamedGroup(id: $0.key, count: $0.value.count) }
                .sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
        }
        return Library(source: source, allRows: all,
                       artists: groups(byArtist), albums: groups(byAlbum),
                       rowsByArtist: byArtist, rowsByAlbum: byAlbum,
                       playlists: playlists, rowsByPlaylist: byPlaylist,
                       loadMs: 0, indexMs: 0)
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
