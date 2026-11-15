//
//  LyricsProvider.swift
//  iPod Pro Max
//
//  Protocol-based lyrics lookup: LRCLIB by default (free, no key), Musixmatch optional (with key).
//

import Foundation

public struct LyricsQuery: Sendable {
    public var title: String
    public var artist: String?
    public var album: String?
    public var durationSeconds: Int?

    public init(title: String, artist: String? = nil, album: String? = nil, durationSeconds: Int? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
        self.durationSeconds = durationSeconds
    }
}

public struct LyricsMatch: Sendable {
    public let source: String
    public let plainLyrics: String?
    public let syncedLyrics: String?
    public let instrumental: Bool

    public var bestText: String? {
        if let plain = plainLyrics?.trimmingCharacters(in: .whitespacesAndNewlines), !plain.isEmpty {
            return plain
        }
        if let synced = syncedLyrics?.trimmingCharacters(in: .whitespacesAndNewlines), !synced.isEmpty {
            return synced
        }
        return nil
    }
}

public protocol LyricsLookupProvider: Sendable {
    var name: String { get }
    func fetchLyrics(query: LyricsQuery) async throws -> LyricsMatch?
}

// MARK: - LRCLIB (Default, Free, No API Key)

public struct LRCLIBProvider: LyricsLookupProvider {
    public let name = "LRCLIB"
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetchLyrics(query: LyricsQuery) async throws -> LyricsMatch? {
        let title = query.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }

        if let artist = query.artist?.trimmingCharacters(in: .whitespacesAndNewlines), !artist.isEmpty {
            var items = [
                URLQueryItem(name: "track_name", value: title),
                URLQueryItem(name: "artist_name", value: artist),
            ]
            if let album = query.album?.trimmingCharacters(in: .whitespacesAndNewlines), !album.isEmpty {
                items.append(URLQueryItem(name: "album_name", value: album))
            }
            if let duration = query.durationSeconds, duration > 0 {
                items.append(URLQueryItem(name: "duration", value: "\(duration)"))
            }
            if let direct = try await requestSingle(endpoint: "https://lrclib.net/api/get", queryItems: items) {
                return direct
            }
        }

        let searchTerm = [query.artist, title]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        var components = URLComponents(string: "https://lrclib.net/api/search")!
        components.queryItems = [URLQueryItem(name: "q", value: searchTerm)]
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("iPodProMax/1.0 (https://github.com/wwwonka/iPod-Pro-Max)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return nil
        }
        let entries = try JSONDecoder().decode([LRCLIBEntry].self, from: data)
        guard let first = entries.first(where: { !($0.plainLyrics ?? "").isEmpty || !($0.syncedLyrics ?? "").isEmpty }) else {
            return nil
        }
        return LyricsMatch(
            source: name,
            plainLyrics: first.plainLyrics,
            syncedLyrics: first.syncedLyrics,
            instrumental: first.instrumental ?? false
        )
    }

    private func requestSingle(endpoint: String, queryItems: [URLQueryItem]) async throws -> LyricsMatch? {
        var components = URLComponents(string: endpoint)!
        components.queryItems = queryItems
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("iPodProMax/1.0 (https://github.com/wwwonka/iPod-Pro-Max)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return nil
        }
        let entry = try JSONDecoder().decode(LRCLIBEntry.self, from: data)
        let match = LyricsMatch(
            source: name,
            plainLyrics: entry.plainLyrics,
            syncedLyrics: entry.syncedLyrics,
            instrumental: entry.instrumental ?? false
        )
        return match.bestText != nil ? match : nil
    }
}

private struct LRCLIBEntry: Decodable {
    let plainLyrics: String?
    let syncedLyrics: String?
    let instrumental: Bool?
}

// MARK: - Musixmatch (Optional, requires user API key)

public struct MusixmatchProvider: LyricsLookupProvider {
    public let name = "Musixmatch"
    private let apiKey: String?
    private let session: URLSession

    public init(apiKey: String? = ProcessInfo.processInfo.environment["IPODPROMAX_MUSIXMATCH_KEY"], session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    public func fetchLyrics(query: LyricsQuery) async throws -> LyricsMatch? {
        guard let apiKey, !apiKey.isEmpty else { return nil }
        let title = query.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }

        var components = URLComponents(string: "https://api.musixmatch.com/ws/1.1/matcher.lyrics.get")!
        var items = [
            URLQueryItem(name: "q_track", value: title),
            URLQueryItem(name: "apikey", value: apiKey),
        ]
        if let artist = query.artist?.trimmingCharacters(in: .whitespacesAndNewlines), !artist.isEmpty {
            items.append(URLQueryItem(name: "q_artist", value: artist))
        }
        components.queryItems = items
        guard let url = components.url else { return nil }

        let (data, response) = try await session.data(for: URLRequest(url: url, timeoutInterval: 10))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return nil
        }
        let decoded = try JSONDecoder().decode(MusixmatchResponse.self, from: data)
        guard let body = decoded.message.body?.lyrics?.lyricsBody, !body.isEmpty else { return nil }
        return LyricsMatch(source: name, plainLyrics: body, syncedLyrics: nil, instrumental: false)
    }
}

private struct MusixmatchResponse: Decodable {
    let message: MusixmatchMessage
}

private struct MusixmatchMessage: Decodable {
    let body: MusixmatchBody?
}

private struct MusixmatchBody: Decodable {
    let lyrics: MusixmatchLyrics?
}

private struct MusixmatchLyrics: Decodable {
    let lyricsBody: String?

    enum CodingKeys: String, CodingKey {
        case lyricsBody = "lyrics_body"
    }
}

// MARK: - Orchestrator

public final class LyricsService: Sendable {
    public static let shared = LyricsService()

    private let providers: [any LyricsLookupProvider]

    public init(providers: [any LyricsLookupProvider] = [
        LRCLIBProvider(),
        MusixmatchProvider(),
    ]) {
        self.providers = providers
    }

    public func fetchLyrics(query: LyricsQuery) async -> LyricsMatch? {
        for provider in providers {
            if let match = try? await provider.fetchLyrics(query: query), match.bestText != nil {
                return match
            }
        }
        return nil
    }
}
