import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import PluginKit

/// Spotify Pathfinder persisted GraphQL operations and response classification (`SPO-4`, `SPO-8`).
public enum Pathfinder {
    public static let endpoint = "https://api-partner.spotify.com/pathfinder/v1/query"
    public static let mutationEndpointV2 = "https://api-partner.spotify.com/pathfinder/v2/query"
    public static let playlistPageLimit = 100
    public static let albumPageLimit = 50
    public static let maxPages = 100

    public struct Config: Sendable, Equatable {
        public var fetchPlaylistHash: String
        public var getAlbumHash: String
        public var moveItemsInPlaylistHash: String
        public var userAgent: String

        public init(
            fetchPlaylistHash: String = "a65e12194ed5fc443a1cdebed5fabe33ca5b07b987185d63c72483867ad13cb4",
            getAlbumHash: String = "b9bfabef66ed756e5e13f68a942deb60bd4125ec1f1be8cc42769dc0259b4b10",
            moveItemsInPlaylistHash: String = "b907ad6b088d5bf7680fa81198996d58398c2d55dfcdf59fcc959e0be98a418a",
            userAgent: String = TokenManager.defaultUserAgent
        ) {
            self.fetchPlaylistHash = fetchPlaylistHash
            self.getAlbumHash = getAlbumHash
            self.moveItemsInPlaylistHash = moveItemsInPlaylistHash
            self.userAgent = userAgent
        }

        public static func from(initializeConfig: [String: JSONValue]) -> Config {
            var cfg = Config()
            if let ua = initializeConfig["userAgent"]?.stringValue, !ua.isEmpty {
                cfg.userAgent = ua
            }
            if let pf = initializeConfig["pathfinder"]?.objectValue {
                if let plHash = pf["fetchPlaylist"]?.objectValue?["sha256"]?.stringValue, !plHash.isEmpty {
                    cfg.fetchPlaylistHash = plHash
                }
                if let alHash = pf["getAlbum"]?.objectValue?["sha256"]?.stringValue, !alHash.isEmpty {
                    cfg.getAlbumHash = alHash
                }
                if let mvHash = pf["moveItemsInPlaylist"]?.objectValue?["sha256"]?.stringValue, !mvHash.isEmpty {
                    cfg.moveItemsInPlaylistHash = mvHash
                }
            }
            return cfg
        }
    }

    public static func buildPlaylistRequestURL(
        playlistID: String,
        offset: Int = 0,
        limit: Int = playlistPageLimit,
        sha256Hash: String
    ) -> URL? {
        let variables: [String: Any] = [
            "uri": "spotify:playlist:\(playlistID)",
            "offset": offset,
            "limit": limit,
            "enableWatchFeedEntrypoint": false,
        ]
        return buildQueryURL(operationName: "fetchPlaylist", variables: variables, sha256Hash: sha256Hash)
    }

    public static func buildAlbumRequestURL(
        albumID: String,
        offset: Int = 0,
        limit: Int = albumPageLimit,
        sha256Hash: String
    ) -> URL? {
        let variables: [String: Any] = [
            "uri": "spotify:album:\(albumID)",
            "locale": "",
            "offset": offset,
            "limit": limit,
        ]
        return buildQueryURL(operationName: "getAlbum", variables: variables, sha256Hash: sha256Hash)
    }

    public static func makeAuthorizedRequest(
        url: URL,
        token: String,
        clientToken: String? = nil,
        userAgent: String
    ) -> URLRequest {
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let clientToken, !clientToken.isEmpty {
            req.setValue(clientToken, forHTTPHeaderField: "client-token")
        }
        req.setValue("WebPlayer", forHTTPHeaderField: "app-platform")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("https://open.spotify.com", forHTTPHeaderField: "Origin")
        req.setValue("https://open.spotify.com/", forHTTPHeaderField: "Referer")
        return req
    }

    public static func makeAuthorizedPostRequest(
        url: URL,
        token: String,
        clientToken: String?,
        userAgent: String,
        body: Data
    ) -> URLRequest {
        var req = makeAuthorizedRequest(url: url, token: token, clientToken: clientToken, userAgent: userAgent)
        req.httpMethod = "POST"
        req.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        return req
    }

    public static func makeWebAPIPutRequest(
        playlistID: String,
        token: String,
        clientToken: String?,
        userAgent: String,
        rangeStart: Int,
        rangeLength: Int,
        insertBefore: Int
    ) -> URLRequest? {
        guard let url = URL(string: "https://api.spotify.com/v1/playlists/\(playlistID)/items") else { return nil }
        let payload: [String: Any] = [
            "range_start": rangeStart,
            "range_length": rangeLength,
            "insert_before": insertBefore,
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return nil }
        var req = makeAuthorizedRequest(url: url, token: token, clientToken: clientToken, userAgent: userAgent)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        return req
    }

    public static func makeWebAPIAddItemsRequest(
        playlistID: String,
        uris: [String],
        pathSuffix: String = "items",
        token: String,
        clientToken: String?,
        userAgent: String
    ) -> URLRequest? {
        guard let url = URL(string: "https://api.spotify.com/v1/playlists/\(playlistID)/\(pathSuffix)") else { return nil }
        let payload: [String: Any] = ["uris": uris]
        guard let body = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return nil }
        var req = makeAuthorizedRequest(url: url, token: token, clientToken: clientToken, userAgent: userAgent)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        return req
    }

    public static func makeSearchTracksRequest(
        query: String,
        limit: Int = 10,
        token: String,
        clientToken: String?,
        userAgent: String
    ) -> URLRequest? {
        guard var components = URLComponents(string: "https://api.spotify.com/v1/search") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "type", value: "track"),
            URLQueryItem(name: "limit", value: String(min(max(limit, 1), 20))),
        ]
        guard let url = components.url else { return nil }
        return makeAuthorizedRequest(url: url, token: token, clientToken: clientToken, userAgent: userAgent)
    }

    /// Encodes a GraphQL persisted mutation body for `moveItemsInPlaylist`.
    public static func buildMoveItemsBody(
        request: PlaylistReorderRequest,
        sha256Hash: String
    ) -> Data? {
        let newPosition: [String: Any]
        if request.atStart {
            newPosition = ["moveType": "TOP_OF_PLAYLIST", "fromUid": NSNull()]
        } else if let beforeUID = request.beforeItemUID, !beforeUID.isEmpty {
            newPosition = ["moveType": "BEFORE_UID", "fromUid": beforeUID]
        } else if let afterUID = request.afterItemUID, !afterUID.isEmpty {
            newPosition = ["moveType": "AFTER_UID", "fromUid": afterUID]
        } else {
            newPosition = ["moveType": "BOTTOM_OF_PLAYLIST", "fromUid": NSNull()]
        }

        let payload: [String: Any] = [
            "operationName": "moveItemsInPlaylist",
            "variables": [
                "playlistUri": "spotify:playlist:\(request.playlistID)",
                "uids": request.movedItemUIDs,
                "newPosition": newPosition,
            ],
            "extensions": [
                "persistedQuery": [
                    "version": 1,
                    "sha256Hash": sha256Hash,
                ]
            ],
        ]
        return try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }

    public enum ResponseClassification {
        case success([String: Any])
        case unauthorized
        case rateLimited(retryAfterSeconds: Int)
        case error(PluginError, isAPIChanged: Bool, logDetail: String)
    }

    /// Classifies an HTTP response from Pathfinder (`status == 401`, `429`, `PersistedQueryNotFound`,
    /// missing `data`, null union `notFound`).
    public static func classifyResponse(_ response: HTTPResponseData) -> ResponseClassification {
        if response.statusCode == 401 {
            return .unauthorized
        }

        if response.statusCode == 429 {
            let raw = response.headerValue("Retry-After").flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 5
            let clamped = min(max(raw, 1), 30)
            return .rateLimited(retryAfterSeconds: clamped)
        }

        if response.statusCode == 404 {
            return .error(
                PluginError(code: .notFound, message: "Spotify playlist or album not found or private."),
                isAPIChanged: false,
                logDetail: "Pathfinder returned HTTP 404"
            )
        }

        if response.statusCode >= 500 || (response.statusCode >= 400 && response.body.isEmpty) {
            return .error(
                PluginError(code: .network, message: "Spotify returned HTTP \(response.statusCode)."),
                isAPIChanged: false,
                logDetail: "Pathfinder HTTP \(response.statusCode)"
            )
        }

        guard let json = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] else {
            return .error(
                PluginError(code: .apiChanged, message: SpotifyMessages.apiChanged),
                isAPIChanged: true,
                logDetail: "Pathfinder returned non-JSON body (HTTP \(response.statusCode))"
            )
        }

        if let errors = json["errors"] as? [[String: Any]] {
            if errors.contains(where: { ($0["message"] as? String) == "PersistedQueryNotFound" }) {
                return .error(
                    PluginError(code: .apiChanged, message: SpotifyMessages.apiChanged),
                    isAPIChanged: true,
                    logDetail: "Pathfinder reported PersistedQueryNotFound (hash rotated)"
                )
            }
        }

        guard let data = json["data"] as? [String: Any] else {
            return .error(
                PluginError(code: .apiChanged, message: SpotifyMessages.apiChanged),
                isAPIChanged: true,
                logDetail: "Pathfinder response missing 'data' object (HTTP \(response.statusCode))"
            )
        }

        let allNull = !data.isEmpty && data.values.allSatisfy { $0 is NSNull }
        if allNull {
            return .error(
                PluginError(code: .notFound, message: "Spotify playlist or album was deleted or is private."),
                isAPIChanged: false,
                logDetail: "Pathfinder returned null entity union"
            )
        }

        return .success(data)
    }

    // MARK: - Query Serialization

    private static func buildQueryURL(
        operationName: String,
        variables: [String: Any],
        sha256Hash: String
    ) -> URL? {
        let extensions: [String: Any] = [
            "persistedQuery": [
                "version": 1,
                "sha256Hash": sha256Hash,
            ]
        ]

        guard let varsData = try? JSONSerialization.data(withJSONObject: variables, options: [.sortedKeys]),
              let extData = try? JSONSerialization.data(withJSONObject: extensions, options: [.sortedKeys]),
              let varsStr = String(data: varsData, encoding: .utf8),
              let extStr = String(data: extData, encoding: .utf8),
              var components = URLComponents(string: endpoint) else {
            return nil
        }

        components.queryItems = [
            URLQueryItem(name: "operationName", value: operationName),
            URLQueryItem(name: "variables", value: varsStr),
            URLQueryItem(name: "extensions", value: extStr),
        ]
        return components.url
    }
}
