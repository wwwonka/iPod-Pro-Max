//
//  OHdioFeed.swift
//  iPod Pro Max
//
//  Native client for Radio-Canada's OHdio "balados" (the private GraphQL API behind ohdio.radio-canada.ca
//  — the same one apps like ohdieux reverse-engineered), so a pasted OHdio show link can be subscribed
//  to directly, no external converter or self-hosted service required. Produces the same ParsedFeed the
//  RSS parser does, so the rest of the podcast pipeline (storage, UI, sync, download) is unchanged.
//
//  Episode audio isn't a plain URL up front — OHdio requires a second call per episode to resolve a
//  playable stream — so episodes carry a synthetic "ohdio://media/<id>" enclosure that's resolved to a
//  real CDN URL lazily, right before download (see `resolveMediaURL`).
//

import Foundation

enum OHdioFeed {
    private static let baseURL = "https://services.radio-canada.ca"
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"
    /// Persisted GraphQL query hash for "programmeById" on a Balado (regular podcast show).
    private static let baladoQueryHash = "3b505d1f3b3935981802bccab9c9ee63bbf6c5c55a0b996287fb789e1a90e660"
    private static let maxPages = 20 // ~500 episodes, comfortably more than any show has

    static func isOHdioURL(_ url: URL) -> Bool {
        (url.host?.lowercased().hasSuffix("radio-canada.ca") ?? false) && programmeID(from: url) != nil
    }

    /// Matches .../ohdio/balados/<id>/<slug>.
    static func programmeID(from url: URL) -> Int? {
        let comps = url.pathComponents
        guard let idx = comps.firstIndex(of: "balados"), idx + 1 < comps.count else { return nil }
        return Int(comps[idx + 1])
    }

    static func fetch(url: URL) async throws -> ParsedFeed {
        guard let id = programmeID(from: url) else {
            throw IPodDBError.io("This doesn't look like an OHdio balado link.")
        }
        var feed = ParsedFeed()
        var page = 1
        var total = Int.max
        while page <= maxPages, feed.episodes.count < total {
            let data = try await graphQLRequest(id: id, page: page)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let programme = (root["data"] as? [String: Any])?["programmeById"] as? [String: Any] else {
                throw IPodDBError.io("OHdio returned an unexpected response for this show.")
            }
            if page == 1, let header = programme["header"] as? [String: Any] {
                feed.title = header["title"] as? String ?? ""
                feed.author = header["subtitle"] as? String
                feed.summary = (header["summary"] as? String).map(PodcastFeedParser.stripHTML)
                if let pattern = (header["picture"] as? [String: Any])?["pattern"] as? String {
                    feed.imageURL = imageURL(fromPattern: pattern)
                }
            }
            guard let detail = (programme["content"] as? [String: Any])?["contentDetail"] as? [String: Any] else { break }
            total = (detail["pagedConfiguration"] as? [String: Any])?["totalNumberOfItems"] as? Int ?? feed.episodes.count
            let items = (detail["items"] as? [[String: Any]]) ?? []
            guard !items.isEmpty else { break }
            feed.episodes += items.compactMap(episode(from:))
            page += 1
        }
        if feed.title.isEmpty { throw IPodDBError.io("This doesn't look like an OHdio balado.") }
        return feed
    }

    /// Resolves a synthetic "ohdio://media/<id>" enclosure into the real, directly downloadable CDN URL.
    static func resolveMediaURL(from synthetic: URL) async throws -> URL {
        var comps = URLComponents(string: "\(baseURL)/media/validation/v2")!
        comps.queryItems = [
            URLQueryItem(name: "appCode", value: "medianet"),
            URLQueryItem(name: "connectionType", value: "hd"),
            URLQueryItem(name: "deviceType", value: "ipad"),
            URLQueryItem(name: "idMedia", value: synthetic.lastPathComponent),
            URLQueryItem(name: "multibitrate", value: "true"),
            URLQueryItem(name: "output", value: "json"),
            URLQueryItem(name: "tech", value: "progressive"),
        ]
        var request = URLRequest(url: comps.url!)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw IPodDBError.io("OHdio returned status \(http.statusCode) while resolving the audio stream.")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let urlString = obj["url"] as? String, let url = URL(string: urlString) else {
            throw IPodDBError.io("OHdio didn't return a playable stream for this episode.")
        }
        return url
    }

    // MARK: - Parsing

    private static func episode(from item: [String: Any]) -> ParsedEpisode? {
        guard let playlistItemId = item["playlistItemId"] as? [String: Any],
              let mediaId = playlistItemId["mediaId"] as? String,
              let globalId = (playlistItemId["globalId2"] as? [String: Any])?["id"] as? String,
              let title = (item["share"] as? [String: Any])?["title"] as? String else { return nil }
        var ep = ParsedEpisode(guid: globalId, title: title, enclosureURL: URL(string: "ohdio://media/\(mediaId)"))
        ep.summary = (item["summary"] as? String).map(PodcastFeedParser.stripHTML)
        if let seconds = (item["duration"] as? [String: Any])?["durationInSeconds"] as? Int { ep.durationMs = seconds * 1000 }
        if let broadcast = item["broadcastedFirstTimeAt"] as? String { ep.publishedAt = isoFormatter.date(from: broadcast) }
        return ep
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// The picture URL is a template like ".../{ratio}/image.jpg?w={width}"; fill in a square thumbnail.
    private static func imageURL(fromPattern pattern: String) -> URL? {
        URL(string: pattern.replacingOccurrences(of: "{width}", with: "600").replacingOccurrences(of: "{ratio}", with: "1x1"))
    }

    /// Radio-Canada's GraphQL gateway sometimes needs a couple of hits before its persisted-query
    /// cache has this hash warm, briefly answering "PersistedQueryNotFound" even though the hash is
    /// valid — not a bug here, just an eventually-consistent cache. A couple of retries ride over it.
    private static func graphQLRequest(id: Int, page: Int) async throws -> Data {
        let extensions: [String: Any] = ["persistedQuery": ["version": 1, "sha256Hash": baladoQueryHash]]
        let variables: [String: Any] = ["params": ["context": "web", "forceWithoutCueSheet": true, "id": id, "pageNumber": page]]
        var comps = URLComponents(string: "\(baseURL)/bff/audio/graphql")!
        comps.queryItems = [
            URLQueryItem(name: "opname", value: "programmeById"),
            URLQueryItem(name: "extensions", value: try jsonString(extensions)),
            URLQueryItem(name: "variables", value: try jsonString(variables)),
        ]
        var request = URLRequest(url: comps.url!)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("true", forHTTPHeaderField: "apollo-require-preflight")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        // A fresh session per attempt avoids reusing the same keep-alive connection (and so the same
        // backend node) on retry, which is what actually gets past a cold cache on a different node.
        let maxAttempts = 10
        for attempt in 1...maxAttempts {
            let session = URLSession(configuration: .ephemeral)
            defer { session.finishTasksAndInvalidate() }
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw IPodDBError.io("OHdio returned status \(http.statusCode).")
            }
            if let text = String(data: data, encoding: .utf8), text.contains("PersistedQueryNotFound") {
                if attempt < maxAttempts { try await Task.sleep(for: .milliseconds(150 * attempt)) }
                continue
            }
            return data
        }
        throw IPodDBError.io("OHdio's server didn't recognize this request after several tries. Try again in a moment.")
    }

    private static func jsonString(_ obj: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
