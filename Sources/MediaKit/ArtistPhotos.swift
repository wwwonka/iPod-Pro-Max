//
//  ArtistPhotos.swift
//  iPod Pro Max
//
//  Artist photos for the Music page, fetched once per artist from Deezer's public API (no key) and
//  kept in an "Artist Photos" folder of the launching iPod's data. Same code on every OS. The iPod
//  itself never shows them: this is only for browsing the library.
//

import Foundation
import iPodKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Spaces Deezer requests so a big first pass stays under its limit (50 requests per 5 s).
private actor DeezerPacer {
    static let shared = DeezerPacer()
    private var next = Date()
    private let interval = 0.12

    func wait() async {
        let now = Date()
        let slot = max(now, next)
        next = slot.addingTimeInterval(interval)
        if slot > now { try? await Task.sleep(nanoseconds: UInt64(slot.timeIntervalSince(now) * 1e9)) }
    }
}

public actor ArtistPhotoStore {
    public let folder: URL
    private let indexURL: URL
    /// Normalized artist name → entry. A nil `file` is a lookup that found nothing, retried after 30 days.
    private var index: [String: Entry] = [:]
    private var fetching = false

    private struct Entry: Codable {
        var file: String?
        var checked: Date
        var custom: Bool = false
    }

    private static let missRetryInterval: TimeInterval = 30 * 24 * 3600

    public init(folder: URL) {
        self.folder = folder
        indexURL = folder.appendingPathComponent("index.json")
        if let data = try? Data(contentsOf: indexURL), let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            index = decoded
        }
    }

    /// The photo files known so far, by normalized artist name.
    public func photos() -> [String: URL] {
        var result: [String: URL] = [:]
        for (key, entry) in index {
            if let file = entry.file { result[key] = folder.appendingPathComponent(file) }
        }
        return result
    }

    /// Looks up every artist without a photo (or whose last miss is old), a few at a time, then stops:
    /// nothing is polled. `onProgress` is called at most once a second while photos arrive, and once at the end.
    public func fetchMissing(_ artists: [String], onProgress: @escaping @Sendable () -> Void) async {
        guard !fetching else { return }
        let now = Date()
        var seen = Set<String>()
        let todo = artists.filter { name in
            let key = Self.normalize(name)
            guard !key.isEmpty, key != Self.normalize("Unknown Artist"), seen.insert(key).inserted else { return false }
            guard let entry = index[key] else { return true }
            return entry.file == nil && !entry.custom && now.timeIntervalSince(entry.checked) > Self.missRetryInterval
        }
        guard !todo.isEmpty else { return }
        fetching = true
        defer { fetching = false }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let folder = self.folder
        // Network-bound, and Deezer allows ~50 requests per 5 s: a small fixed pool, not one per core.
        await withTaskGroup(of: (String, Lookup).self) { group in
            var iterator = todo.makeIterator()
            func addNext() {
                guard let name = iterator.next() else { return }
                group.addTask(priority: .utility) { (name, await Self.download(artist: name, into: folder)) }
            }
            for _ in 0..<4 { addNext() }
            var pendingSave = 0
            var unpublished = false
            var lastPublish = Date()
            while let (name, lookup) = await group.next() {
                switch lookup {
                case .found(let file):
                    index[Self.normalize(name)] = Entry(file: file, checked: Date())
                    unpublished = true
                case .notFound:
                    index[Self.normalize(name)] = Entry(file: nil, checked: Date())
                case .failed:
                    break  // left unrecorded: the next pass tries again
                }
                if unpublished, Date().timeIntervalSince(lastPublish) > 1 {
                    onProgress()
                    unpublished = false
                    lastPublish = Date()
                }
                pendingSave += 1
                if pendingSave >= 25 { saveIndex(); pendingSave = 0 }
                if !Task.isCancelled { addNext() }
            }
            if unpublished { onProgress() }
        }
        saveIndex()
    }

    /// Uses a picture the user picked instead of Deezer's (e.g. when Deezer matched a namesake). The file
    /// gets a new name each time, so nothing that cached the old picture shows it again.
    public func setCustomPhoto(_ image: URL, for artist: String) -> Bool {
        let key = Self.normalize(artist)
        guard !key.isEmpty, let data = try? Data(contentsOf: image),
              let jpeg = ImageLoading.jpegData(from: data, maxDimension: 400) else { return false }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = String(Self.fileName(for: key).dropLast(4)) + "-\(Int(Date().timeIntervalSince1970)).jpg"
        guard (try? jpeg.write(to: folder.appendingPathComponent(name), options: .atomic)) != nil else { return false }
        if let old = index[key]?.file { try? FileManager.default.removeItem(at: folder.appendingPathComponent(old)) }
        index[key] = Entry(file: name, checked: Date(), custom: true)
        saveIndex()
        return true
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

    /// Only a definite answer is remembered: a network error or Deezer's quota must never be recorded
    /// as "this artist has no photo" for the next 30 days.
    private enum Lookup: Sendable { case found(String), notFound, failed }

    /// A collaboration ("A & B", "A Featuring B") falls back to its first named artist's photo.
    private static func download(artist: String, into folder: URL) async -> Lookup {
        let key = normalize(artist)
        guard !["variousartists", "various", "artistesdivers"].contains(key) else { return .notFound }
        var candidates = [artist]
        if let lead = leadArtist(of: artist), lead != artist { candidates.append(lead) }
        for name in candidates {
            switch await pictureURL(for: name) {
            case .failed: return .failed
            case .notFound: continue
            case .found(let picture):
                guard let url = URL(string: picture), let data = try? await PodcastHTTP.data(PodcastHTTP.request(url)) else { return .failed }
                return store(data, as: fileName(for: key), in: folder).map(Lookup.found) ?? .failed
            }
        }
        return .notFound
    }

    /// Only an exact (case-, accent- and punctuation-insensitive) name match is accepted, so a wrong
    /// artist's face never shows up.
    private static func pictureURL(for artist: String) async -> Lookup {
        var comps = URLComponents(string: "https://api.deezer.com/search/artist")!
        comps.queryItems = [URLQueryItem(name: "q", value: artist), URLQueryItem(name: "limit", value: "5")]
        guard let url = comps.url else { return .notFound }
        for attempt in 0..<3 {
            await DeezerPacer.shared.wait()
            guard let data = try? await PodcastHTTP.data(PodcastHTTP.request(url)),
                  let response = try? JSONDecoder().decode(SearchResponse.self, from: data) else { return .failed }
            if response.error?.code == 4 {  // quota exceeded: the window is 5 s, so wait it out
                try? await Task.sleep(nanoseconds: UInt64(5_000_000_000 * (attempt + 1)))
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

    private static func leadArtist(of name: String) -> String? {
        let separators = [" & ", " / ", " Featuring ", " featuring ", " feat. ", " Feat. ", " ft. ", " x ", ", ", " and ", " et "]
        var lead = name
        for s in separators {
            if let r = lead.range(of: s) { lead = String(lead[..<r.lowerBound]) }
        }
        lead = lead.trimmingCharacters(in: .whitespaces)
        return lead.isEmpty ? nil : lead
    }

    private static func store(_ data: Data, as name: String, in folder: URL) -> String? {
        // Bounded: the list and the header decode these on screen.
        guard let jpeg = ImageLoading.jpegData(from: data, maxDimension: 400) else { return nil }
        guard (try? jpeg.write(to: folder.appendingPathComponent(name), options: .atomic)) != nil else { return nil }
        return name
    }

    private static func fileName(for key: String) -> String {
        var digest = SHA1()
        digest.update(data: Data(key.utf8))
        return digest.finalize().prefix(10).map { String(format: "%02x", $0) }.joined() + ".jpg"
    }

    /// Case, accents and punctuation never get in the way of a match.
    public static func normalize(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init).joined()
    }
}
