//
//  ArtistPhotos.swift
//  iPod Pro Max
//
//  Artist photos for the Music view, fetched once per artist from Deezer's public API (no key
//  needed) and kept in "Artist Photos" under Application Support. The iPod itself never shows
//  artist photos — this is purely for browsing the library in the app.
//

import Foundation
import Observation
import CryptoKit

/// Spaces Deezer API requests so a big first pass stays under its limit (50 requests per 5 s)
/// instead of tripping it and retrying.
actor DeezerPacer {
    static let shared = DeezerPacer()
    private var next = ContinuousClock.now
    private let interval = Duration.milliseconds(120)

    func wait() async {
        let now = ContinuousClock.now
        let slot = max(now, next)
        next = slot + interval
        if slot > now { try? await Task.sleep(until: slot, clock: .continuous) }
    }
}

@MainActor
@Observable
final class ArtistPhotoStore {
    /// Bumped whenever a photo is added or replaced, so views keyed on it refresh.
    private(set) var revision = 0

    let folder: URL
    private let indexURL: URL
    /// Normalized artist name → entry. A nil `file` records a lookup that found nothing, so it isn't
    /// repeated on every launch (it's retried after `missRetryInterval`).
    private var index: [String: Entry] = [:]
    private var fetching = false

    private struct Entry: Codable {
        var file: String?
        var checked: Date
        var custom: Bool = false
    }

    private static let missRetryInterval: TimeInterval = 30 * 24 * 3600

    init(baseDir: URL) {
        folder = baseDir.appendingPathComponent("Artist Photos", isDirectory: true)
        indexURL = folder.appendingPathComponent("index.json")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            index = decoded
        }
    }

    /// The photo for an artist, if one has been fetched or chosen. A dictionary lookup — cheap enough
    /// to call per row per render.
    func photoURL(for artist: String) -> URL? {
        guard let file = index[Self.normalize(artist)]?.file else { return nil }
        return folder.appendingPathComponent(file)
    }

    /// Starts `fetchMissing` in the background unless a pass is already running. Not tied to any
    /// view's lifetime, so library changes mid-pass don't cancel downloads half-way.
    func fetchMissingInBackground(_ artists: [String]) {
        guard !fetching else { return }
        Task { await fetchMissing(artists) }
    }

    /// Looks up every artist that has no photo yet (or whose last miss is old), a few at a time.
    /// Runs once and stops — nothing is polled. Safe to call repeatedly; overlapping calls are ignored.
    func fetchMissing(_ artists: [String]) async {
        guard !fetching else { return }
        let now = Date()
        var seen = Set<String>()
        let todo = artists.filter { name in
            let key = Self.normalize(name)
            guard !key.isEmpty, key != Self.normalize("Unknown Artist"), seen.insert(key).inserted else { return false }
            guard let e = index[key] else { return true }
            return e.file == nil && !e.custom && now.timeIntervalSince(e.checked) > Self.missRetryInterval
        }
        guard !todo.isEmpty else { return }
        fetching = true
        defer { fetching = false }

        let folder = self.folder
        // Network-bound and Deezer allows ~50 requests per 5 s, so a small fixed pool (not one per core)
        // is both fast and polite.
        await withTaskGroup(of: (String, Lookup).self) { group in
            var iterator = todo.makeIterator()
            func addNext() {
                guard let name = iterator.next() else { return }
                group.addTask(priority: .utility) { (name, await Self.download(artist: name, into: folder)) }
            }
            for _ in 0..<4 { addNext() }
            var pendingSave = 0
            var unpublished = false
            var lastPublish = ContinuousClock.now
            while let (name, lookup) = await group.next() {
                switch lookup {
                case .found(let file):
                    index[Self.normalize(name)] = Entry(file: file, checked: Date())
                    unpublished = true
                case .notFound:
                    index[Self.normalize(name)] = Entry(file: nil, checked: Date())
                case .failed:
                    break  // left unrecorded, so the next pass tries again
                }
                // Each bump redraws the artist list; at most once a second keeps a first big pass smooth.
                if unpublished, ContinuousClock.now - lastPublish > .seconds(1) {
                    revision &+= 1
                    unpublished = false
                    lastPublish = .now
                }
                pendingSave += 1
                if pendingSave >= 25 { saveIndex(); pendingSave = 0 }
                if !Task.isCancelled { addNext() }
            }
            if unpublished { revision &+= 1 }
        }
        saveIndex()
    }

    /// Uses a picture the user picked instead of Deezer's (e.g. when Deezer matched a namesake).
    /// Returns the stored photo's URL (callers drop any cached thumbnail of it).
    @discardableResult
    func setCustomPhoto(_ imageURL: URL, for artist: String) async -> URL? {
        let folder = self.folder
        let key = Self.normalize(artist)
        let file: String? = await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: imageURL) else { return nil }
            return Self.store(data, as: Self.fileName(for: key), in: folder)
        }.value
        guard let file else { return nil }
        index[key] = Entry(file: file, checked: Date(), custom: true)
        revision &+= 1
        saveIndex()
        return folder.appendingPathComponent(file)
    }

    private func saveIndex() {
        guard let data = try? JSONEncoder().encode(index) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    // MARK: - Deezer

    private struct SearchResponse: Decodable {
        struct Artist: Decodable { let name: String; let picture_xl: String? }
        struct APIError: Decodable { let code: Int? }
        let data: [Artist]?
        let error: APIError?
    }

    /// Searches Deezer for the artist and saves its picture. Only an exact (case-, accent- and
    /// punctuation-insensitive) name match is accepted, so a wrong artist's face never shows up.
    /// Outcome of one lookup. Only a definite answer is remembered: a network error or Deezer's quota
    /// must never be recorded as "this artist has no photo" for the next 30 days.
    private enum Lookup: Sendable { case found(String), notFound, failed }

    /// A collaboration ("A & B", "A Featuring B", "A / B") falls back to its first named artist's photo.
    nonisolated private static func download(artist: String, into folder: URL) async -> Lookup {
        let key = normalize(artist)
        guard !["variousartists", "various", "artistesdivers"].contains(key) else { return .notFound }
        var candidates = [artist]
        if let lead = leadArtist(of: artist), lead != artist { candidates.append(lead) }
        for name in candidates {
            switch await pictureURL(for: name) {
            case .failed: return .failed
            case .notFound: continue
            case .found(let picture):
                guard let url = URL(string: picture), let (imageData, _) = try? await URLSession.shared.data(from: url) else { return .failed }
                return store(imageData, as: fileName(for: key), in: folder).map(Lookup.found) ?? .failed
            }
        }
        return .notFound
    }

    nonisolated private static func pictureURL(for artist: String) async -> Lookup {
        var comps = URLComponents(string: "https://api.deezer.com/search/artist")!
        comps.queryItems = [URLQueryItem(name: "q", value: artist), URLQueryItem(name: "limit", value: "5")]
        guard let url = comps.url else { return .notFound }
        for attempt in 0..<3 {
            await DeezerPacer.shared.wait()
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let response = try? JSONDecoder().decode(SearchResponse.self, from: data) else { return .failed }
            if response.error?.code == 4 {  // quota exceeded: the window is 5 s, so wait it out
                try? await Task.sleep(for: .seconds(5 * (attempt + 1)))
                continue
            }
            let wanted = normalize(artist)
            guard let match = response.data?.first(where: { normalize($0.name) == wanted }),
                  let picture = match.picture_xl,
                  !picture.contains("/artist//") else { return .notFound }  // Deezer's generic silhouette
            return .found(picture)
        }
        return .failed
    }

    nonisolated private static func leadArtist(of name: String) -> String? {
        let separators = [" & ", " / ", " Featuring ", " featuring ", " feat. ", " Feat. ", " ft. ", " x ", ", ", " and ", " et "]
        var lead = name
        for s in separators {
            if let r = lead.range(of: s) { lead = String(lead[..<r.lowerBound]) }
        }
        lead = lead.trimmingCharacters(in: .whitespaces)
        return lead.isEmpty ? nil : lead
    }

    nonisolated private static func store(_ data: Data, as name: String, in folder: URL) -> String? {
        guard let image = ImageLoading.cgImage(from: data), let jpeg = ImageLoading.jpegData(from: image, maxDimension: 600) else { return nil }
        guard (try? jpeg.write(to: folder.appendingPathComponent(name), options: .atomic)) != nil else { return nil }
        return name
    }

    nonisolated private static func fileName(for key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined() + ".jpg"
    }

    /// "Amadou & Mariam", "AMADOU AND MARIAM" and "Amadou et Mariam" don't all match, but case,
    /// accents and punctuation never get in the way.
    nonisolated static func normalize(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init).joined()
    }
}
