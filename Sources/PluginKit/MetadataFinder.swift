//
//  MetadataFinder.swift
//  iPod Pro Max
//
//  Protocol-based metadata & cover art lookup (MusicBrainz, Cover Art Archive, AcoustID, iTunes Search).
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct MetadataQuery: Codable, Equatable, Sendable {
    public var title: String
    public var artist: String?
    public var album: String?
    public var durationMs: Int?
    public var filePath: String?

    public init(title: String, artist: String? = nil, album: String? = nil, durationMs: Int? = nil, filePath: String? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
        self.durationMs = durationMs
        self.filePath = filePath
    }
}

public struct MetadataMatch: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let source: String
    public let score: Double
    public let title: String
    public let artist: String?
    public let album: String?
    public let albumArtist: String?
    public let year: Int?
    public let trackNumber: Int?
    public let trackCount: Int?
    public let discNumber: Int?
    public let discCount: Int?
    public let genre: String?
    public let musicBrainzReleaseID: String?
    public let artworkURL: URL?

    public init(
        id: String,
        source: String,
        score: Double,
        title: String,
        artist: String?,
        album: String?,
        albumArtist: String?,
        year: Int?,
        trackNumber: Int?,
        trackCount: Int?,
        discNumber: Int?,
        discCount: Int?,
        genre: String?,
        musicBrainzReleaseID: String?,
        artworkURL: URL?
    ) {
        self.id = id
        self.source = source
        self.score = score
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
        self.year = year
        self.trackNumber = trackNumber
        self.trackCount = trackCount
        self.discNumber = discNumber
        self.discCount = discCount
        self.genre = genre
        self.musicBrainzReleaseID = musicBrainzReleaseID
        self.artworkURL = artworkURL
    }

    public var summaryLabel: String {
        var parts = [title]
        if let artist, !artist.isEmpty { parts.append(artist) }
        if let album, !album.isEmpty { parts.append(album) }
        if let year, year > 0 { parts.append("(\(year))") }
        return "[\(source)] " + parts.joined(separator: " — ")
    }
}

public protocol MetadataLookupProvider: PluginRoleHandler {
    var name: String { get }
    func search(query: MetadataQuery) async throws -> [MetadataMatch]
}

// MARK: - MusicBrainz + Cover Art Archive

public struct MusicBrainzProvider: MetadataLookupProvider {
    public let name = "MusicBrainz"
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func search(query: MetadataQuery) async throws -> [MetadataMatch] {
        var terms: [String] = []
        let cleanTitle = query.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanTitle.isEmpty {
            terms.append("recording:\"\(escapeLucene(cleanTitle))\"")
        }
        if let artist = query.artist?.trimmingCharacters(in: .whitespacesAndNewlines), !artist.isEmpty {
            terms.append("artist:\"\(escapeLucene(artist))\"")
        }
        if let album = query.album?.trimmingCharacters(in: .whitespacesAndNewlines), !album.isEmpty {
            terms.append("release:\"\(escapeLucene(album))\"")
        }
        guard !terms.isEmpty else { return [] }

        var components = URLComponents(string: "https://musicbrainz.org/ws/2/recording")!
        components.queryItems = [
            URLQueryItem(name: "query", value: terms.joined(separator: " AND ")),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: "8"),
        ]
        guard let url = components.url else { return [] }

        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("iPodProMax/1.0 (https://github.com/wwwonka/iPod-Pro-Max)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.portableData(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return []
        }

        let decoded = try JSONDecoder().decode(MBSearchResponse.self, from: data)
        return parseRecordings(decoded.recordings, source: name)
    }

    func lookupRecording(id: String) async throws -> [MetadataMatch] {
        var components = URLComponents(string: "https://musicbrainz.org/ws/2/recording/\(id)")!
        components.queryItems = [
            URLQueryItem(name: "inc", value: "artists+releases+media+tags"),
            URLQueryItem(name: "fmt", value: "json"),
        ]
        guard let url = components.url else { return [] }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("iPodProMax/1.0 (https://github.com/wwwonka/iPod-Pro-Max)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.portableData(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return []
        }
        let rec = try JSONDecoder().decode(MBRecording.self, from: data)
        return parseRecordings([rec], source: "AcoustID")
    }

    private func parseRecordings(_ recordings: [MBRecording], source: String) -> [MetadataMatch] {
        recordings.compactMap { rec in
            let artistName = rec.artistCredit?.compactMap { ($0.name ?? $0.artist?.name ?? "") + ($0.joinphrase ?? "") }.joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let release = rec.releases?.first(where: { $0.status == "Official" }) ?? rec.releases?.first
            let releaseID = release?.id
            let year = release?.date.flatMap { Int($0.prefix(4)) }
            let media = release?.media?.first
            let trackNumber = media?.track?.first?.number.flatMap { Int($0) }
            let trackCount = media?.trackCount
            let discNumber = media?.position
            let discCount = release?.media?.count
            let genre = rec.tags?.sorted(by: { ($0.count ?? 0) > ($1.count ?? 0) }).first?.name.capitalized
            let artworkURL = releaseID.flatMap { URL(string: "https://coverartarchive.org/release/\($0)/front-500") }

            return MetadataMatch(
                id: "\(source):\(rec.id)",
                source: source,
                score: Double(rec.score ?? 85) / 100.0,
                title: rec.title,
                artist: artistName?.isEmpty == false ? artistName : nil,
                album: release?.title,
                albumArtist: nil,
                year: year,
                trackNumber: trackNumber,
                trackCount: trackCount,
                discNumber: discNumber,
                discCount: discCount,
                genre: genre,
                musicBrainzReleaseID: releaseID,
                artworkURL: artworkURL
            )
        }
    }

    private func escapeLucene(_ text: String) -> String {
        let specials = CharacterSet(charactersIn: "+-&|!(){}[]^\"~*?:\\/")
        var out = ""
        for scalar in text.unicodeScalars {
            if specials.contains(scalar) { out.append("\\") }
            out.unicodeScalars.append(scalar)
        }
        return out
    }
}

private struct MBSearchResponse: Decodable {
    let recordings: [MBRecording]
}

private struct MBRecording: Decodable {
    let id: String
    let score: Int?
    let title: String
    let artistCredit: [MBArtistCredit]?
    let releases: [MBRelease]?
    let tags: [MBTag]?

    enum CodingKeys: String, CodingKey {
        case id, score, title, releases, tags
        case artistCredit = "artist-credit"
    }
}

private struct MBArtistCredit: Decodable {
    let name: String?
    let joinphrase: String?
    let artist: MBArtist?
}

private struct MBArtist: Decodable {
    let name: String?
}

private struct MBRelease: Decodable {
    let id: String
    let title: String
    let status: String?
    let date: String?
    let media: [MBMedia]?
}

private struct MBMedia: Decodable {
    let position: Int?
    let trackCount: Int?
    let track: [MBTrack]?

    enum CodingKeys: String, CodingKey {
        case position, track
        case trackCount = "track-count"
    }
}

private struct MBTrack: Decodable {
    let number: String?
}

private struct MBTag: Decodable {
    let count: Int?
    let name: String
}

// MARK: - AcoustID (Audio Fingerprint)

public struct AcoustIDProvider: MetadataLookupProvider {
    public let name = "AcoustID"
    private let apiKey: String?
    private let session: URLSession

    public init(apiKey: String? = ProcessInfo.processInfo.environment["IPODPROMAX_ACOUSTID_KEY"], session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    public func search(query: MetadataQuery) async throws -> [MetadataMatch] {
        guard let apiKey, !apiKey.isEmpty,
              let filePath = query.filePath,
              FileManager.default.fileExists(atPath: filePath),
              let fpcalc = Self.fpcalcBinaryPath(),
              let fp = await Self.computeFingerprint(fpcalc: fpcalc, filePath: filePath) else {
            return []
        }

        var components = URLComponents(string: "https://api.acoustid.org/v2/lookup")!
        components.queryItems = [
            URLQueryItem(name: "client", value: apiKey),
            URLQueryItem(name: "meta", value: "recordings+releasegroups+compress"),
            URLQueryItem(name: "duration", value: "\(fp.duration)"),
            URLQueryItem(name: "fingerprint", value: fp.fingerprint),
        ]
        guard let url = components.url else { return [] }
        let (data, response) = try await session.portableData(for: URLRequest(url: url, timeoutInterval: 10))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return []
        }
        let decoded = try JSONDecoder().decode(AcoustIDResponse.self, from: data)
        let recordingIDs = decoded.results.flatMap { $0.recordings ?? [] }.map(\.id)
        guard let firstID = recordingIDs.first else { return [] }
        return try await MusicBrainzProvider(session: session).lookupRecording(id: firstID)
    }

    static func fpcalcBinaryPath() -> String? {
        let fm = FileManager.default
        if let env = ProcessInfo.processInfo.environment["IPODPROMAX_FPCALC"], fm.isExecutableFile(atPath: env) {
            return env
        }
        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        #if os(Windows)
        let bin = "fpcalc.exe"
        #else
        let bin = "fpcalc"
        #endif
        for dir in pathDirs {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent(bin).path
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    private static func computeFingerprint(fpcalc: String, filePath: String) async -> (duration: Int, fingerprint: String)? {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: fpcalc)
            process.arguments = ["-json", filePath]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { return nil }
                let parsed = try JSONDecoder().decode(FpcalcOutput.self, from: data)
                return (Int(parsed.duration.rounded()), parsed.fingerprint)
            } catch {
                return nil
            }
        }.value
    }
}

private struct FpcalcOutput: Decodable {
    let duration: Double
    let fingerprint: String
}

private struct AcoustIDResponse: Decodable {
    let results: [AcoustIDResult]
}

private struct AcoustIDResult: Decodable {
    let recordings: [AcoustIDRecording]?
}

private struct AcoustIDRecording: Decodable {
    let id: String
}

// MARK: - iTunes Search API

public struct ITunesLookupProvider: MetadataLookupProvider {
    public let name = "iTunes"
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func search(query: MetadataQuery) async throws -> [MetadataMatch] {
        let term = [query.artist, query.title, query.album]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !term.isEmpty else { return [] }

        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "6"),
        ]
        guard let url = components.url else { return [] }

        let (data, response) = try await session.portableData(for: URLRequest(url: url, timeoutInterval: 10))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return []
        }

        let decoded = try JSONDecoder().decode(ITunesSearchResponse.self, from: data)
        return decoded.results.compactMap { item in
            guard let title = item.trackName, !title.isEmpty else { return nil }
            let year = item.releaseDate.flatMap { Int($0.prefix(4)) }
            let highResArtwork = item.artworkUrl100?
                .replacingOccurrences(of: "100x100bb", with: "600x600bb")
            return MetadataMatch(
                id: "iTunes:\(item.trackId ?? Int.random(in: 1...999_999))",
                source: name,
                score: 0.8,
                title: title,
                artist: item.artistName,
                album: item.collectionName,
                albumArtist: item.collectionArtistName ?? item.artistName,
                year: year,
                trackNumber: item.trackNumber,
                trackCount: item.trackCount,
                discNumber: item.discNumber,
                discCount: item.discCount,
                genre: item.primaryGenreName,
                musicBrainzReleaseID: nil,
                artworkURL: highResArtwork.flatMap(URL.init(string:))
            )
        }
    }
}

private struct ITunesSearchResponse: Decodable {
    let results: [ITunesTrack]
}

private struct ITunesTrack: Decodable {
    let trackId: Int?
    let trackName: String?
    let artistName: String?
    let collectionName: String?
    let collectionArtistName: String?
    let primaryGenreName: String?
    let releaseDate: String?
    let trackNumber: Int?
    let trackCount: Int?
    let discNumber: Int?
    let discCount: Int?
    let artworkUrl100: String?
}

// MARK: - Orchestrator

public final class MetadataFinderService: Sendable {
    public static let shared = MetadataFinderService()

    private let providers: [any MetadataLookupProvider]
    private let session: URLSession

    public init(
        providers: [any MetadataLookupProvider] = [
            AcoustIDProvider(),
            MusicBrainzProvider(),
            ITunesLookupProvider(),
        ],
        session: URLSession = .shared
    ) {
        self.providers = providers
        self.session = session
    }

    public func search(query: MetadataQuery) async -> [MetadataMatch] {
        await withTaskGroup(of: [MetadataMatch].self) { group in
            for provider in providers {
                group.addTask {
                    (try? await provider.search(query: query)) ?? []
                }
            }
            var combined: [MetadataMatch] = []
            for await matches in group {
                combined.append(contentsOf: matches)
            }
            return combined.sorted { $0.score > $1.score }
        }
    }

    public func fetchArtworkData(from url: URL) async -> Data? {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("iPodProMax/1.0 (https://github.com/wwwonka/iPod-Pro-Max)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.portableData(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              !data.isEmpty else {
            return nil
        }
        return data
    }
}
