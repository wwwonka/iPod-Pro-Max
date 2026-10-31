import Foundation
import MediaKit

struct PodcastSearchResult: Identifiable, Decodable {
    var id: Int { collectionId }
    let collectionId: Int
    let collectionName: String?
    let artistName: String?
    let feedUrl: String?

    var name: String { collectionName ?? "Untitled" }
    var artist: String { artistName ?? "" }
    var feedURL: URL? { feedUrl.flatMap { URL(string: $0) } }
}

/// The Apple Podcasts directory, which needs no account.
enum PodcastSearch {
    private struct Response: Decodable { let results: [PodcastSearchResult] }

    static func search(_ term: String) async throws -> [PodcastSearchResult] {
        var comps = URLComponents(string: "https://itunes.apple.com/search")!
        comps.queryItems = [URLQueryItem(name: "media", value: "podcast"), URLQueryItem(name: "limit", value: "25"), URLQueryItem(name: "term", value: term)]
        let data = try await PodcastHTTP.data(PodcastHTTP.request(comps.url!))
        return try JSONDecoder().decode(Response.self, from: data).results.filter { $0.feedURL != nil }
    }
}
