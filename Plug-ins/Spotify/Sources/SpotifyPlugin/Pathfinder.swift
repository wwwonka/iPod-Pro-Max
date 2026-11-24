import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import PluginKit

/// Spotify Pathfinder persisted GraphQL operations and response classification (`SPO-4`, `SPO-8`).
public enum Pathfinder {
    public static let endpoint = "https://api-partner.spotify.com/pathfinder/v1/query"
    public static let mutationEndpointV2 = "https://api-partner.spotify.com/pathfinder/v2/query"
    public static let spclientPlaylistBase = "https://spclient.wg.spotify.com/playlist/v2/playlist"
    public static let spclientRootlistBase = "https://spclient.wg.spotify.com/playlist/v2/user"
    public static let playlistUploadImageURL = "https://image-upload.spotify.com/v4/playlist"
    public static let playlistPageLimit = 100
    public static let albumPageLimit = 50
    public static let maxPages = 100

    public struct Config: Sendable, Equatable {
        public var fetchPlaylistHash: String
        public var getAlbumHash: String
        public var moveItemsInPlaylistHash: String
        public var searchDesktopHash: String
        public var userAgent: String

        public init(
            fetchPlaylistHash: String = "a65e12194ed5fc443a1cdebed5fabe33ca5b07b987185d63c72483867ad13cb4",
            getAlbumHash: String = "b9bfabef66ed756e5e13f68a942deb60bd4125ec1f1be8cc42769dc0259b4b10",
            moveItemsInPlaylistHash: String = "b907ad6b088d5bf7680fa81198996d58398c2d55dfcdf59fcc959e0be98a418a",
            searchDesktopHash: String = "db61238974d27839a136c9dc02bfdbe3fab7635f21cf85976ebff9a1ee281345",
            userAgent: String = TokenManager.defaultUserAgent
        ) {
            self.fetchPlaylistHash = fetchPlaylistHash
            self.getAlbumHash = getAlbumHash
            self.moveItemsInPlaylistHash = moveItemsInPlaylistHash
            self.searchDesktopHash = searchDesktopHash
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
                if let sdHash = pf["searchDesktop"]?.objectValue?["sha256"]?.stringValue, !sdHash.isEmpty {
                    cfg.searchDesktopHash = sdHash
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

    public static func makeWebAPIUpdatePlaylistRequest(
        playlistID: String,
        name: String,
        token: String,
        clientToken: String?,
        userAgent: String
    ) -> URLRequest? {
        guard let url = URL(string: "https://api.spotify.com/v1/playlists/\(playlistID)") else { return nil }
        let payload: [String: Any] = ["name": name]
        guard let body = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return nil }
        var req = makeAuthorizedRequest(url: url, token: token, clientToken: clientToken, userAgent: userAgent)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        return req
    }

    public static func makeSpClientChangesRequest(
        playlistID: String,
        ops: [[String: Any]],
        token: String,
        clientToken: String?,
        userAgent: String
    ) -> URLRequest? {
        guard let url = URL(string: "\(spclientPlaylistBase)/\(playlistID)/changes") else { return nil }
        return makeSpClientDeltaPostRequest(url: url, ops: ops, wantSyncResult: true, token: token, clientToken: clientToken, userAgent: userAgent)
    }

    private static func makeSpClientDeltaPostRequest(
        url: URL,
        ops: [[String: Any]],
        wantSyncResult: Bool,
        token: String,
        clientToken: String?,
        userAgent: String
    ) -> URLRequest? {
        var payload: [String: Any] = [
            "deltas": [
                [
                    "ops": ops,
                    "info": [
                        "source": [
                            "client": "WEBPLAYER",
                        ]
                    ],
                ]
            ],
        ]
        if wantSyncResult {
            payload["wantSyncResult"] = true
        }
        guard let body = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return nil }
        return makeAuthorizedPostRequest(
            url: url,
            token: token,
            clientToken: clientToken,
            userAgent: userAgent,
            body: body
        )
    }

    public static func makeSpClientRenamePlaylistRequest(
        playlistID: String,
        name: String,
        token: String,
        clientToken: String?,
        userAgent: String
    ) -> URLRequest? {
        makeSpClientChangesRequest(
            playlistID: playlistID,
            ops: [updateListAttributesOp(values: ["name": name])],
            token: token,
            clientToken: clientToken,
            userAgent: userAgent
        )
    }

    public static func updateListAttributesOp(values: [String: Any], cleared: [String] = []) -> [String: Any] {
        var fullValues: [String: Any] = [
            "formatAttributes": [Any](),
            "pictureSize": [Any](),
        ]
        for (k, v) in values {
            fullValues[k] = v
        }
        return [
            "kind": "UPDATE_LIST_ATTRIBUTES",
            "updateListAttributes": [
                "newAttributes": [
                    "values": fullValues,
                    "noValue": cleared,
                ]
            ],
        ]
    }

    public static func makeSpClientAddItemsRequest(
        playlistID: String,
        uris: [String],
        token: String,
        clientToken: String?,
        userAgent: String
    ) -> URLRequest? {
        let items: [[String: Any]] = uris.map { ["uri": $0, "attributes": [String: Any]()] }
        let op: [String: Any] = [
            "kind": "ADD",
            "add": [
                "items": items,
                "addLast": true,
            ],
        ]
        return makeSpClientChangesRequest(playlistID: playlistID, ops: [op], token: token, clientToken: clientToken, userAgent: userAgent)
    }

    public static func makeSpClientRemoveItemsRequest(
        playlistID: String,
        uris: [String],
        token: String,
        clientToken: String?,
        userAgent: String
    ) -> URLRequest? {
        let items: [[String: Any]] = uris.map { ["uri": $0] }
        let op: [String: Any] = [
            "kind": "REM",
            "rem": [
                "items": items,
                "itemsAsKey": true,
            ],
        ]
        return makeSpClientChangesRequest(playlistID: playlistID, ops: [op], token: token, clientToken: clientToken, userAgent: userAgent)
    }

    public static func makeWebAPIRemoveItemsRequest(
        playlistID: String,
        uris: [String],
        token: String,
        clientToken: String?,
        userAgent: String
    ) -> URLRequest? {
        guard let url = URL(string: "https://api.spotify.com/v1/playlists/\(playlistID)/tracks") else { return nil }
        let tracks: [[String: Any]] = uris.map { ["uri": $0] }
        let payload: [String: Any] = ["tracks": tracks]
        guard let body = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return nil }
        var req = makeAuthorizedRequest(url: url, token: token, clientToken: clientToken, userAgent: userAgent)
        req.httpMethod = "DELETE"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        return req
    }

    public static func makeSpClientCreatePlaylistRequest(
        name: String,
        description: String?,
        token: String,
        clientToken: String?,
        userAgent: String
    ) -> URLRequest? {
        guard let url = URL(string: spclientPlaylistBase) else { return nil }
        var values: [String: Any] = ["name": name]
        if let description, !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            values["description"] = description.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let payload: [String: Any] = [
            "ops": [updateListAttributesOp(values: values)]
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return nil }
        return makeAuthorizedPostRequest(url: url, token: token, clientToken: clientToken, userAgent: userAgent, body: body)
    }

    public static func makeSpClientAddToRootlistRequest(
        username: String,
        playlistURI: String,
        timestampMs: Int64,
        token: String,
        clientToken: String?,
        userAgent: String
    ) -> URLRequest? {
        let encodedUser = username.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? username
        guard let url = URL(string: "\(spclientRootlistBase)/\(encodedUser)/rootlist/changes") else { return nil }
        let op: [String: Any] = [
            "kind": "ADD",
            "add": [
                "items": [
                    [
                        "uri": playlistURI,
                        "attributes": [
                            "timestamp": String(timestampMs),
                        ],
                    ]
                ],
                "addFirst": true,
            ],
        ]
        return makeSpClientDeltaPostRequest(url: url, ops: [op], wantSyncResult: false, token: token, clientToken: clientToken, userAgent: userAgent)
    }

    public static func makeUploadPlaylistImageRequest(
        jpegData: Data,
        token: String,
        clientToken: String?,
        userAgent: String
    ) -> URLRequest? {
        guard let url = URL(string: playlistUploadImageURL) else { return nil }
        var req = makeAuthorizedRequest(url: url, token: token, clientToken: clientToken, userAgent: userAgent)
        req.httpMethod = "POST"
        req.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        req.httpBody = jpegData
        return req
    }

    public static func makeRegisterPlaylistImageRequest(
        playlistID: String,
        uploadToken: String,
        token: String,
        clientToken: String?,
        userAgent: String
    ) -> URLRequest? {
        guard let url = URL(string: "\(spclientPlaylistBase)/\(playlistID)/register-image") else { return nil }
        let payload: [String: Any] = ["uploadToken": uploadToken]
        guard let body = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return nil }
        return makeAuthorizedPostRequest(url: url, token: token, clientToken: clientToken, userAgent: userAgent, body: body)
    }

    public static func buildSearchDesktopBody(
        query: String,
        limit: Int = 10,
        sha256Hash: String
    ) -> Data? {
        let payload: [String: Any] = [
            "operationName": "searchDesktop",
            "variables": [
                "searchTerm": query,
                "offset": 0,
                "limit": min(max(limit, 1), 20),
                "numberOfTopResults": 5,
                "includeAudiobooks": false,
                "includeArtistHasConcertsField": false,
                "includePreReleases": false,
                "includeAlbumPreReleases": false,
                "includeAuthors": false,
                "includeEpisodeContentRatingsV2": false,
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

    public static func buildRemoveItemsBody(
        playlistID: String,
        uids: [String],
        sha256Hash: String
    ) -> Data? {
        buildPersistedMutationBody(
            operationName: "removeItemsFromPlaylist",
            variables: [
                "playlistUri": "spotify:playlist:\(playlistID)",
                "uids": uids,
            ],
            sha256Hash: sha256Hash
        )
    }

    public static func buildPersistedMutationBody(
        operationName: String,
        variables: [String: Any],
        sha256Hash: String
    ) -> Data? {
        let payload: [String: Any] = [
            "operationName": operationName,
            "variables": variables,
            "extensions": [
                "persistedQuery": [
                    "version": 1,
                    "sha256Hash": sha256Hash,
                ]
            ],
        ]
        return try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }

    public static func extractQueryHashes(fromJS source: String) -> [String: String] {
        guard let regex = try? NSRegularExpression(pattern: #""([^"]+)"\s*,\s*"(?:query|mutation)"\s*,\s*"([0-9a-f]{64})""#) else {
            return [:]
        }
        let nsRange = NSRange(source.startIndex..<source.endIndex, in: source)
        var out: [String: String] = [:]
        for match in regex.matches(in: source, range: nsRange) {
            guard match.numberOfRanges == 3,
                  let nameRange = Range(match.range(at: 1), in: source),
                  let hashRange = Range(match.range(at: 2), in: source) else { continue }
            out[String(source[nameRange])] = String(source[hashRange])
        }
        return out
    }

    /// Extracts `<script src="…">` JS bundle URLs from Spotify Web Player HTML (`https://…` or root-relative `/…`).
    public static func extractJSBundleURLs(fromHTML html: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: #"(?:https?:)?//[^"'\s<>]*spotify[^"'\s<>]*\.js(?:\?[^"'\s<>]*)?|["'](/assets/[^"'\s<>]+\.js(?:\?[^"'\s<>]*)?)["']"#,
            options: [.caseInsensitive]
        ) else {
            return []
        }
        let nsRange = NSRange(html.startIndex..<html.endIndex, in: html)
        var seen = Set<String>()
        var urls: [String] = []
        for match in regex.matches(in: html, range: nsRange) {
            let raw: String
            if match.numberOfRanges > 1,
               match.range(at: 1).location != NSNotFound,
               let relRange = Range(match.range(at: 1), in: html) {
                raw = "https://open.spotify.com" + String(html[relRange])
            } else if let range = Range(match.range, in: html) {
                let matched = String(html[range])
                raw = matched.hasPrefix("//") ? "https:" + matched : matched
            } else {
                continue
            }
            if seen.insert(raw).inserted {
                urls.append(raw)
            }
        }
        return urls
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
