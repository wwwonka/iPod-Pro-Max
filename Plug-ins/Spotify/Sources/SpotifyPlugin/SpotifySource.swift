import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import PluginKit

/// PlaylistSource (+ optional authenticated reordering / editing / browsing) implementation for Spotify over Pathfinder.
public actor SpotifySource: PlaylistReorderable, PlaylistEditable, PlaylistBrowsable, PluginConfigurable, PluginAccountHandling {
    private let transport: any HTTPTransport
    private let tokenManager: TokenManager
    private var config = Pathfinder.Config()
    private var runtimeContext: (any PluginRuntimeContext)?
    private var apiChangedReported = false
    private var discoveredHashes: [String: String] = [:]
    private var scannedBundleURLs: Set<String> = []
    private var inFlightHashDiscovery: Task<Void, Never>?
    private var hashesFileURL: URL?

    public init(transport: any HTTPTransport = URLSessionTransport()) {
        self.transport = transport
        self.tokenManager = TokenManager(transport: transport)
    }

    // MARK: - PluginConfigurable

    public func initialize(params: PluginInitializeParams, context: any PluginRuntimeContext) async throws {
        self.runtimeContext = context
        self.config = Pathfinder.Config.from(initializeConfig: params.config)
        if !params.paths.data.isEmpty {
            let dataDir = URL(fileURLWithPath: params.paths.data, isDirectory: true)
            self.hashesFileURL = dataDir.appendingPathComponent(".spotify-hashes.json")
            loadPersistedHashes()
        }
        await tokenManager.configureStorage(dataDirectory: params.paths.data)
        await tokenManager.configure(
            userAgent: config.userAgent,
            log: { level, msg in
                await context.log(level, msg)
            },
            onAPIChanged: { [weak self] msg in
                await self?.markAPIChanged(msg)
            }
        )
        let acc = await tokenManager.currentAccountStatus()
        await context.reportAccountStatus(acc)
    }

    public func settingsChanged(_ settings: [String: JSONValue]) async {
        // No extra configurable settings beyond account session.
    }

    // MARK: - PluginAccountHandling

    public func login(key: String, fields: [String: String]) async throws -> PluginAccountStatus {
        let accessToken = fields["accessToken"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let clientToken = fields["clientToken"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let spDC = fields["sp_dc"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let expiresAtMs = fields["expiresAtMs"].flatMap { Int64($0) } ?? 0
        var displayName = fields["displayName"]?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let rawHashes = fields["pathfinderHashesJSON"]?.data(using: .utf8),
           let decodedHashes = try? JSONDecoder().decode([String: String].self, from: rawHashes) {
            var updated = false
            for (op, hash) in decodedHashes where !op.isEmpty && !hash.isEmpty {
                if discoveredHashes[op] != hash {
                    discoveredHashes[op] = hash
                    updated = true
                }
            }
            if updated {
                persistDiscoveredHashes()
            }
        }

        // When invoked via Sign In button without fields, request the interactive browser/WebView login flow.
        if accessToken.isEmpty && (spDC?.isEmpty ?? true) {
            return PluginAccountStatus(
                status: "waiting",
                openURL: "https://accounts.spotify.com/login?continue=https%3A%2F%2Fopen.spotify.com%2F"
            )
        }

        let resolvedInputName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        var resolvedUsername = fields["username"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if !accessToken.isEmpty && (Self.needsAccountNameResolution(resolvedInputName) || (resolvedUsername?.isEmpty ?? true)) {
            let profile = await fetchProfileInfo(accessToken: accessToken, clientToken: clientToken)
            if let uname = profile.username, !uname.isEmpty {
                resolvedUsername = uname
            }
            if Self.needsAccountNameResolution(resolvedInputName),
               let fetched = profile.displayName, !fetched.isEmpty {
                displayName = fetched
            }
        }

        let previousSession = await tokenManager.currentUserSession()
        let mergedSpDC = (spDC?.isEmpty == false) ? spDC : previousSession?.spDC
        let mergedClientToken = (clientToken?.isEmpty == false) ? clientToken : previousSession?.clientToken
        let mergedUsername = resolvedUsername?.isEmpty == false ? resolvedUsername : previousSession?.username
        let resolvedName = (displayName?.isEmpty == false) ? displayName! : (previousSession?.displayName ?? "Spotify Web")
        let webSession = UserWebSession(
            spDC: mergedSpDC,
            username: mergedUsername,
            displayName: resolvedName,
            accessToken: accessToken.isEmpty ? nil : accessToken,
            clientToken: mergedClientToken,
            expiresAtMs: expiresAtMs
        )
        await tokenManager.setUserSession(webSession)
        let st = await tokenManager.currentAccountStatus()
        await runtimeContext?.reportAccountStatus(st)
        return st
    }

    public func logout() async throws -> PluginAccountStatus {
        await tokenManager.clearUserSession()
        let st = PluginAccountStatus(status: "signedOut")
        await runtimeContext?.reportAccountStatus(st)
        return st
    }

    public func status() async throws -> PluginAccountStatus {
        if var cur = await tokenManager.currentUserSession(),
           cur.isSignedIn,
           (Self.needsAccountNameResolution(cur.displayName) || (cur.username?.isEmpty ?? true)),
           let tok = cur.accessToken, !tok.isEmpty {
            let profile = await fetchProfileInfo(accessToken: tok, clientToken: cur.clientToken)
            var updated = false
            if let uname = profile.username, !uname.isEmpty, cur.username != uname {
                cur.username = uname
                updated = true
            }
            if Self.needsAccountNameResolution(cur.displayName),
               let dname = profile.displayName, !dname.isEmpty {
                cur.displayName = dname
                updated = true
            }
            if updated {
                await tokenManager.setUserSession(cur)
            }
        }
        return await tokenManager.currentAccountStatus()
    }

    private static func needsAccountNameResolution(_ raw: String?) -> Bool {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty || trimmed == "Spotify Web" || trimmed == "Account" {
            return true
        }
        // Spotify assigns 22-28 char lowercase alphanumeric internal user IDs to non-legacy accounts.
        if trimmed.count >= 20, trimmed.allSatisfy({ ($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9") }) {
            return true
        }
        return false
    }

    private func fetchProfileInfo(accessToken: String, clientToken: String?) async -> (username: String?, displayName: String?) {
        if let url = URL(string: "https://api.spotify.com/v1/me") {
            let attempts: [URLRequest] = [
                Pathfinder.makeAuthorizedRequest(
                    url: url,
                    token: accessToken,
                    clientToken: clientToken,
                    userAgent: config.userAgent
                ),
                {
                    var req = URLRequest(url: url, timeoutInterval: 15)
                    req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
                    req.setValue("application/json", forHTTPHeaderField: "Accept")
                    req.setValue(config.userAgent, forHTTPHeaderField: "User-Agent")
                    return req
                }(),
            ]
            for req in attempts {
                guard let res = try? await transport.send(req) else { continue }
                guard res.statusCode == 200 else {
                    await runtimeContext?.log(.warning, "Spotify /v1/me returned HTTP \(res.statusCode).")
                    continue
                }
                guard let json = (try? JSONSerialization.jsonObject(with: res.body)) as? [String: Any] else {
                    continue
                }
                let id = (json["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let dname = (json["display_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                if (id?.isEmpty == false) || (dname?.isEmpty == false) {
                    return (
                        username: (id?.isEmpty == false) ? id : nil,
                        displayName: (dname?.isEmpty == false) ? dname : ((id?.isEmpty == false) ? id : nil)
                    )
                }
            }
        }

        // Fallback via Pathfinder profileAttributes if already known and /v1/me is rate-limited (never block on JS bundle scans here).
        if let hash = await resolvePersistedHash(operationName: "profileAttributes", defaultHash: "", allowBundleDiscovery: false),
           !hash.isEmpty,
           let body = Pathfinder.buildPersistedMutationBody(operationName: "profileAttributes", variables: [:], sha256Hash: hash),
           let pfURL = URL(string: Pathfinder.mutationEndpointV2) {
            let req = Pathfinder.makeAuthorizedPostRequest(
                url: pfURL,
                token: accessToken,
                clientToken: clientToken,
                userAgent: config.userAgent,
                body: body
            )
            if let res = try? await transport.send(req),
               res.statusCode == 200,
               let json = (try? JSONSerialization.jsonObject(with: res.body)) as? [String: Any],
               let data = json["data"] as? [String: Any],
               let profile = (data["me"] as? [String: Any])?["profile"] as? [String: Any]
                    ?? (data["profile"] as? [String: Any]) {
                let uname = (profile["username"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let name = (profile["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                return (
                    username: (uname?.isEmpty == false) ? uname : nil,
                    displayName: (name?.isEmpty == false) ? name : ((uname?.isEmpty == false) ? uname : nil)
                )
            }
        }

        return (nil, nil)
    }

    private func resolveCanonicalUsername(accessToken: String, clientToken: String?) async -> String? {
        if let cached = await tokenManager.currentUserSession()?.username?.trimmingCharacters(in: .whitespacesAndNewlines),
           !cached.isEmpty {
            return cached
        }
        let info = await fetchProfileInfo(accessToken: accessToken, clientToken: clientToken)
        if let uname = info.username, !uname.isEmpty {
            await tokenManager.setResolvedAccountInfo(username: uname, displayName: info.displayName)
            return uname
        }
        return nil
    }

    // MARK: - PlaylistReorderable

    public func reorder(request: PlaylistReorderRequest) async throws {
        try Task.checkCancellation()
        guard !request.playlistID.isEmpty else {
            throw PluginError(code: .unsupported, message: "Missing Spotify playlist ID.")
        }

        let creds = try await tokenManager.getUserWriteCredentials()

        if !request.movedItemUIDs.isEmpty,
           let v2URL = URL(string: Pathfinder.mutationEndpointV2),
           let v1URL = URL(string: Pathfinder.endpoint) {
            let initialHash = await resolvePersistedHash(
                operationName: "moveItemsInPlaylist",
                defaultHash: config.moveItemsInPlaylistHash,
                allowBundleDiscovery: true
            ) ?? config.moveItemsInPlaylistHash

            var attemptedHashes = [initialHash]
            var idx = 0
            while idx < attemptedHashes.count {
                let hash = attemptedHashes[idx]
                idx += 1
                guard let body = Pathfinder.buildMoveItemsBody(request: request, sha256Hash: hash) else { continue }
                var sawNotFoundHash = false

                for endpointURL in [v2URL, v1URL] {
                    let req = Pathfinder.makeAuthorizedPostRequest(
                        url: endpointURL,
                        token: creds.accessToken,
                        clientToken: creds.clientToken,
                        userAgent: config.userAgent,
                        body: body
                    )
                    let resp = try await transport.send(req)
                    try await handleCommonWriteErrors(response: resp, operation: "reordering playlist")
                    if (200..<300).contains(resp.statusCode),
                       let json = (try? JSONSerialization.jsonObject(with: resp.body)) as? [String: Any] {
                        if let errors = json["errors"] as? [[String: Any]], !errors.isEmpty {
                            let msg = errors.compactMap { $0["message"] as? String }.joined(separator: "; ")
                            await runtimeContext?.log(.warning, "Pathfinder moveItemsInPlaylist warning (\(endpointURL.path)): \(msg)")
                            if msg.contains("PersistedQueryNotFound") {
                                sawNotFoundHash = true
                                continue
                            }
                            if msg.localizedCaseInsensitiveContains("permission") || msg.localizedCaseInsensitiveContains("unauthorized") {
                                throw PluginError(code: .unsupported, message: "Order changed manually (local only). Only playlists that you own can be modified on Spotify.")
                            }
                        } else if let moveObj = (json["data"] as? [String: Any])?["moveItemsInPlaylist"] as? [String: Any],
                                  let typename = moveObj["__typename"] as? String,
                                  typename.contains("Error") {
                            await runtimeContext?.log(.warning, "Pathfinder moveItemsInPlaylist union error (\(endpointURL.path)): \(typename)")
                            continue
                        } else {
                            return
                        }
                    } else {
                        let snippet = String(data: resp.body.prefix(200), encoding: .utf8) ?? ""
                        await runtimeContext?.log(.warning, "Pathfinder moveItemsInPlaylist HTTP \(resp.statusCode) (\(endpointURL.path)): \(snippet)")
                    }
                }

                if sawNotFoundHash && attemptedHashes.count == 1,
                   let freshHash = await resolvePersistedHash(
                    operationName: "moveItemsInPlaylist",
                    defaultHash: "",
                    allowBundleDiscovery: true,
                    forceRefresh: true
                   ), !freshHash.isEmpty && !attemptedHashes.contains(freshHash) {
                    attemptedHashes.append(freshHash)
                }
            }
        }

        // Fallback 1: spclient MOV delta (same transport used for add/remove/rename/cover)
        if request.rangeLength > 0,
           let movReq = Pathfinder.makeSpClientMoveItemsRequest(
            playlistID: request.playlistID,
            rangeStart: request.rangeStart,
            rangeLength: request.rangeLength,
            insertBefore: request.insertBefore,
            token: creds.accessToken,
            clientToken: creds.clientToken,
            userAgent: config.userAgent
           ) {
            let movResp = try await transport.send(movReq)
            try await handleCommonWriteErrors(response: movResp, operation: "reordering playlist")
            if (200..<300).contains(movResp.statusCode) {
                if let json = (try? JSONSerialization.jsonObject(with: movResp.body)) as? [String: Any],
                   let errors = json["errors"] as? [[String: Any]], !errors.isEmpty {
                    let msg = errors.compactMap { $0["message"] as? String }.joined(separator: "; ")
                    await runtimeContext?.log(.warning, "spclient MOV warning: \(msg)")
                } else {
                    return
                }
            } else {
                let snippet = String(data: movResp.body.prefix(200), encoding: .utf8) ?? ""
                await runtimeContext?.log(.warning, "spclient MOV returned HTTP \(movResp.statusCode): \(snippet)")
            }
        }

        // Fallback 2: Web API PUT /v1/playlists/{id}/tracks (then /items)
        var lastStatus = 0
        for suffix in ["tracks", "items"] {
            guard let putReq = Pathfinder.makeWebAPIPutRequest(
                playlistID: request.playlistID,
                pathSuffix: suffix,
                token: creds.accessToken,
                clientToken: creds.clientToken,
                userAgent: config.userAgent,
                rangeStart: request.rangeStart,
                rangeLength: request.rangeLength,
                insertBefore: request.insertBefore
            ) else {
                throw PluginError(code: .internal, message: "Failed to construct Spotify reorder request.")
            }
            let resp = try await transport.send(putReq)
            try await handleCommonWriteErrors(response: resp, operation: "reordering playlist")
            if (200..<300).contains(resp.statusCode) {
                return
            }
            lastStatus = resp.statusCode
            let snippet = String(data: resp.body.prefix(200), encoding: .utf8) ?? ""
            await runtimeContext?.log(.warning, "Spotify PUT /v1/playlists/\(request.playlistID)/\(suffix) returned HTTP \(resp.statusCode): \(snippet)")
            if !(resp.statusCode == 404 || resp.statusCode == 405) {
                break
            }
        }
        throw PluginError(code: .network, message: "Spotify reorder returned HTTP \(lastStatus).")
    }

    // MARK: - PlaylistEditable

    /// Searches Spotify for each input track in bounded parallel batches and appends matching URIs via `spclient`.
    public func addTracks(request: PlaylistAddTracksRequest) async throws -> PlaylistAddTracksResult {
        try Task.checkCancellation()
        guard !request.playlistID.isEmpty else {
            throw PluginError(code: .unsupported, message: "Missing Spotify playlist ID.")
        }
        guard !request.tracks.isEmpty else {
            return PlaylistAddTracksResult(added: [], notFoundTitles: [])
        }

        let creds = try await tokenManager.getUserWriteCredentials()
        let searchHash = await resolvePersistedHash(
            operationName: "searchDesktop",
            defaultHash: config.searchDesktopHash,
            allowBundleDiscovery: true
        ) ?? config.searchDesktopHash

        // Keep concurrency bounded to active cores (max 4) to utilize cores cleanly without triggering Spotify 429s.
        let tracks = request.tracks
        let maxWorkers = min(min(4, max(1, ProcessInfo.processInfo.activeProcessorCount)), tracks.count)
        var matchesByIndex = [TrackRef?](repeating: nil, count: tracks.count)

        try await withThrowingTaskGroup(of: (Int, TrackRef?).self) { group in
            var nextIndex = 0
            for _ in 0..<maxWorkers {
                let idx = nextIndex
                nextIndex += 1
                let input = tracks[idx]
                group.addTask {
                    let match = try await self.searchBestTrack(
                        input: input,
                        accessToken: creds.accessToken,
                        clientToken: creds.clientToken,
                        preResolvedSearchHash: searchHash
                    )
                    return (idx, match)
                }
            }
            for try await (idx, match) in group {
                matchesByIndex[idx] = match
                if nextIndex < tracks.count {
                    let idxToQueue = nextIndex
                    nextIndex += 1
                    let input = tracks[idxToQueue]
                    group.addTask {
                        let nextMatch = try await self.searchBestTrack(
                            input: input,
                            accessToken: creds.accessToken,
                            clientToken: creds.clientToken,
                            preResolvedSearchHash: searchHash
                        )
                        return (idxToQueue, nextMatch)
                    }
                }
            }
        }

        var added: [PlaylistAddedTrackResult] = []
        var urisToAdd: [String] = []
        var notFound: [String] = []
        for (index, input) in tracks.enumerated() {
            if let match = matchesByIndex[index], !match.sourceID.isEmpty {
                added.append(PlaylistAddedTrackResult(index: index, matchedTrack: match))
                urisToAdd.append("spotify:track:\(match.sourceID)")
            } else {
                notFound.append(input.title)
            }
        }

        guard !urisToAdd.isEmpty else {
            throw PluginError(code: .notFound, message: "Could not find matching tracks on Spotify.")
        }

        // Spotify allows up to 100 URIs per delta/POST.
        var cursor = 0
        while cursor < urisToAdd.count {
            let chunk = Array(urisToAdd[cursor..<min(cursor + 100, urisToAdd.count)])
            cursor += chunk.count
            try await postAddPlaylistItems(
                playlistID: request.playlistID,
                uris: chunk,
                accessToken: creds.accessToken,
                clientToken: creds.clientToken
            )
        }

        return PlaylistAddTracksResult(added: added, notFoundTitles: notFound)
    }

    public func removeTracks(request: PlaylistRemoveTracksRequest) async throws {
        try Task.checkCancellation()
        guard !request.playlistID.isEmpty else {
            throw PluginError(code: .unsupported, message: "Missing Spotify playlist ID.")
        }

        let uris: [String] = request.trackIDs.compactMap { raw in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if trimmed.hasPrefix("spotify:track:") { return trimmed }
            let id = SpotifyURL.idFromURI(trimmed)
            return id.isEmpty ? nil : "spotify:track:\(id)"
        }
        guard !uris.isEmpty || !request.itemUIDs.isEmpty else { return }

        let creds = try await tokenManager.getUserWriteCredentials()

        // Use Pathfinder `removeItemsFromPlaylist` only when its hash is already cached (never block Delete scanning 24 JS bundles).
        if !request.itemUIDs.isEmpty && request.itemUIDs.count == uris.count,
           let hash = await resolvePersistedHash(operationName: "removeItemsFromPlaylist", defaultHash: "", allowBundleDiscovery: false),
           !hash.isEmpty,
           let body = Pathfinder.buildRemoveItemsBody(playlistID: request.playlistID, uids: request.itemUIDs, sha256Hash: hash),
           let v2URL = URL(string: Pathfinder.mutationEndpointV2) {
            let req = Pathfinder.makeAuthorizedPostRequest(
                url: v2URL,
                token: creds.accessToken,
                clientToken: creds.clientToken,
                userAgent: config.userAgent,
                body: body
            )
            let resp = try await transport.send(req)
            try await handleCommonWriteErrors(response: resp, operation: "removing tracks")
            if (200..<300).contains(resp.statusCode),
               !isPersistedQueryNotFound(resp.body) {
                if let json = (try? JSONSerialization.jsonObject(with: resp.body)) as? [String: Any],
                   let data = json["data"] as? [String: Any],
                   let payload = data["removeItemsFromPlaylist"] as? [String: Any],
                   (payload["__typename"] as? String) == "RemoveItemsFromPlaylistPayload" {
                    return
                }
            }
        }

        var cursor = 0
        while cursor < uris.count {
            let chunk = Array(uris[cursor..<min(cursor + 100, uris.count)])
            cursor += chunk.count
            try await sendSpClientPlaylistChanges(
                playlistID: request.playlistID,
                requestBuilder: {
                    Pathfinder.makeSpClientRemoveItemsRequest(
                        playlistID: request.playlistID,
                        uris: chunk,
                        token: creds.accessToken,
                        clientToken: creds.clientToken,
                        userAgent: config.userAgent
                    )
                },
                operation: "removing tracks",
                fallback: {
                    guard let fallbackReq = Pathfinder.makeWebAPIRemoveItemsRequest(
                        playlistID: request.playlistID,
                        uris: chunk,
                        token: creds.accessToken,
                        clientToken: creds.clientToken,
                        userAgent: self.config.userAgent
                    ) else {
                        throw PluginError(code: .internal, message: "Failed to construct Spotify remove-tracks request.")
                    }
                    let resp = try await self.transport.send(fallbackReq)
                    try await self.handleCommonWriteErrors(response: resp, operation: "removing tracks")
                    guard (200..<300).contains(resp.statusCode) else {
                        throw PluginError(code: .network, message: "Spotify remove tracks returned HTTP \(resp.statusCode).")
                    }
                }
            )
        }
    }

    public func renamePlaylist(request: PlaylistRenameRequest) async throws {
        try Task.checkCancellation()
        let trimmed = request.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw PluginError(code: .unsupported, message: "Playlist name cannot be empty.")
        }

        let creds = try await tokenManager.getUserWriteCredentials()
        try await sendSpClientPlaylistChanges(
            playlistID: request.playlistID,
            requestBuilder: {
                Pathfinder.makeSpClientRenamePlaylistRequest(
                    playlistID: request.playlistID,
                    name: trimmed,
                    token: creds.accessToken,
                    clientToken: creds.clientToken,
                    userAgent: config.userAgent
                )
            },
            operation: "renaming playlists",
            fallback: {
                guard let req = Pathfinder.makeWebAPIUpdatePlaylistRequest(
                    playlistID: request.playlistID,
                    name: trimmed,
                    token: creds.accessToken,
                    clientToken: creds.clientToken,
                    userAgent: self.config.userAgent
                ) else {
                    throw PluginError(code: .internal, message: "Failed to construct Spotify rename fallback request.")
                }
                let resp = try await self.transport.send(req)
                try await self.handleCommonWriteErrors(response: resp, operation: "renaming playlists")
                guard (200..<300).contains(resp.statusCode) else {
                    throw PluginError(code: .network, message: "Spotify rename playlist returned HTTP \(resp.statusCode).")
                }
            }
        )
    }

    /// Creates a new Spotify playlist and registers it at the top of the user's library rootlist.
    /// Resolves the canonical username beforehand so any expired token fails before creating an upstream playlist.
    public func createPlaylist(request: PlaylistCreateRequest) async throws -> PlaylistCreateResult {
        try Task.checkCancellation()
        let trimmed = request.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw PluginError(code: .unsupported, message: "Playlist name cannot be empty.")
        }

        let creds = try await tokenManager.getUserWriteCredentials()
        let username = await resolveCanonicalUsername(accessToken: creds.accessToken, clientToken: creds.clientToken)

        guard let createReq = Pathfinder.makeSpClientCreatePlaylistRequest(
            name: trimmed,
            description: request.description,
            token: creds.accessToken,
            clientToken: creds.clientToken,
            userAgent: config.userAgent
        ) else {
            throw PluginError(code: .internal, message: "Failed to construct Spotify create-playlist request.")
        }

        let createResp = try await transport.send(createReq)
        try await handleCommonWriteErrors(response: createResp, operation: "creating playlists")
        guard (200..<300).contains(createResp.statusCode),
              let createJSON = (try? JSONSerialization.jsonObject(with: createResp.body)) as? [String: Any],
              let uri = createJSON["uri"] as? String, !uri.isEmpty else {
            throw PluginError(code: .network, message: "Spotify create playlist returned HTTP \(createResp.statusCode).")
        }

        let newID = SpotifyURL.idFromURI(uri)
        guard SpotifyURL.isValidSpotifyID(newID) else {
            throw PluginError(code: .apiChanged, message: "Spotify returned an unrecognized playlist URI: \(uri)")
        }

        // Adding to rootlist is best-effort after playlist creation: never re-throw `.unauthorized` or `.network`
        // so the host retry wrapper cannot accidentally create a second duplicate playlist on Spotify.
        if let username,
           let rootReq = Pathfinder.makeSpClientAddToRootlistRequest(
               username: username,
               playlistURI: uri,
               timestampMs: Int64(Date().timeIntervalSince1970 * 1000),
               token: creds.accessToken,
               clientToken: creds.clientToken,
               userAgent: config.userAgent
           ) {
            if let rootResp = try? await transport.send(rootReq), !(200..<300).contains(rootResp.statusCode) {
                await runtimeContext?.log(.warning, "Spotify rootlist add returned HTTP \(rootResp.statusCode) for \(uri).")
            }
        } else {
            await runtimeContext?.log(.warning, "Could not resolve Spotify canonical username; playlist \(uri) created without rootlist link.")
        }

        let session = await tokenManager.currentUserSession()
        let ownerName = session?.displayName ?? session?.username
        let playlist = Playlist(
            source: "spotify",
            sourceID: newID,
            title: trimmed,
            owner: ownerName,
            artworkURL: nil,
            revision: SpotifyParsers.computeRevision(title: trimmed, trackIDs: [])
        )
        let webURL = URL(string: "https://open.spotify.com/playlist/\(newID)")!
        return PlaylistCreateResult(playlist: playlist, url: webURL)
    }

    public func setPlaylistArtwork(request: PlaylistArtworkRequest) async throws {
        try Task.checkCancellation()
        guard !request.playlistID.isEmpty else {
            throw PluginError(code: .unsupported, message: "Missing Spotify playlist ID.")
        }

        let creds = try await tokenManager.getUserWriteCredentials()
        let op: [String: Any]
        if let jpegData = request.jpegData, !jpegData.isEmpty {
            guard let uploadReq = Pathfinder.makeUploadPlaylistImageRequest(
                jpegData: jpegData,
                token: creds.accessToken,
                clientToken: creds.clientToken,
                userAgent: config.userAgent
            ) else {
                throw PluginError(code: .internal, message: "Failed to construct Spotify image upload request.")
            }
            let uploadResp = try await transport.send(uploadReq)
            try await handleCommonWriteErrors(response: uploadResp, operation: "uploading playlist cover")
            guard (200..<300).contains(uploadResp.statusCode),
                  let uploadJSON = (try? JSONSerialization.jsonObject(with: uploadResp.body)) as? [String: Any],
                  let uploadToken = uploadJSON["uploadToken"] as? String, !uploadToken.isEmpty else {
                throw PluginError(code: .network, message: "Spotify cover upload returned HTTP \(uploadResp.statusCode).")
            }

            guard let regReq = Pathfinder.makeRegisterPlaylistImageRequest(
                playlistID: request.playlistID,
                uploadToken: uploadToken,
                token: creds.accessToken,
                clientToken: creds.clientToken,
                userAgent: config.userAgent
            ) else {
                throw PluginError(code: .internal, message: "Failed to construct Spotify register-image request.")
            }
            let regResp = try await transport.send(regReq)
            try await handleCommonWriteErrors(response: regResp, operation: "registering playlist cover")
            guard (200..<300).contains(regResp.statusCode),
                  let regJSON = (try? JSONSerialization.jsonObject(with: regResp.body)) as? [String: Any],
                  let picture = regJSON["picture"] as? String, !picture.isEmpty else {
                throw PluginError(code: .network, message: "Spotify register image returned HTTP \(regResp.statusCode).")
            }
            op = Pathfinder.updateListAttributesOp(values: ["picture": picture])
        } else {
            op = Pathfinder.updateListAttributesOp(values: [:], cleared: ["LIST_PICTURE"])
        }

        try await sendSpClientPlaylistChanges(
            playlistID: request.playlistID,
            requestBuilder: {
                Pathfinder.makeSpClientChangesRequest(
                    playlistID: request.playlistID,
                    ops: [op],
                    token: creds.accessToken,
                    clientToken: creds.clientToken,
                    userAgent: config.userAgent
                )
            },
            operation: "updating playlist cover",
            fallback: nil
        )
    }

    // MARK: - PlaylistBrowsable

    public func listUserPlaylists() async throws -> [RemotePlaylistSummary] {
        try Task.checkCancellation()
        let creds = try await tokenManager.getUserWriteCredentials()
        let currentSession = await tokenManager.currentUserSession()
        let currentUsername = await resolveCanonicalUsername(accessToken: creds.accessToken, clientToken: creds.clientToken)
        let currentDisplayName = currentSession?.displayName

        var collected: [RemotePlaylistSummary] = []
        var seenIDs = Set<String>()

        func appendUnique(_ items: [RemotePlaylistSummary]) {
            for item in items where seenIDs.insert(item.id).inserted {
                collected.append(item)
            }
        }

        // 1. Primary: Pathfinder `libraryV3` (exact `open.spotify.com` left sidebar Your Library › Playlists feed,
        //    including folders & Liked Songs). Uses hashes captured by WebView or discovered in open.spotify.com JS bundles.
        if let pfItems = try await fetchUserPlaylistsViaLibraryV3(
            accessToken: creds.accessToken,
            clientToken: creds.clientToken,
            currentUsername: currentUsername,
            currentDisplayName: currentDisplayName
        ), !pfItems.isEmpty {
            appendUnique(pfItems)
            await runtimeContext?.log(.info, "Spotify libraryV3 returned \(collected.count) sidebar playlist(s).")
        }

        // 2. Fallback or fast track-count/ownership enrichment: Web API `/v1/me/playlists` (+ `/v1/me/tracks?limit=1`).
        let needsWebAPIForList = collected.isEmpty
        let needsTrackCountEnrich = collected.contains { !$0.isLikedSongs && $0.trackCount == nil }
        var webAPIError: PluginError?
        if needsWebAPIForList || needsTrackCountEnrich {
            do {
                let webItems = try await fetchUserPlaylistsViaWebAPI(
                    accessToken: creds.accessToken,
                    clientToken: creds.clientToken,
                    currentUsername: currentUsername,
                    currentDisplayName: currentDisplayName,
                    retryOnRateLimit: needsWebAPIForList,
                    maxPages: needsWebAPIForList ? 20 : 4
                )
                if needsWebAPIForList {
                    appendUnique(webItems)
                } else {
                    let webByID = Dictionary(webItems.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                    for i in collected.indices {
                        guard let match = webByID[collected[i].id] else { continue }
                        if collected[i].trackCount == nil { collected[i].trackCount = match.trackCount }
                        if collected[i].owner == nil { collected[i].owner = match.owner }
                        if collected[i].isOwned == nil { collected[i].isOwned = match.isOwned }
                    }
                }
            } catch let pErr as PluginError {
                if pErr.code == .unauthorized && needsWebAPIForList { throw pErr }
                webAPIError = pErr
                await runtimeContext?.log(.warning, "Spotify /v1/me/playlists failed: \(pErr.message)")
            }
        }

        // Ensure Liked Songs (`collection/tracks`) is always included (with track count) if available.
        if !seenIDs.contains("collection-tracks"),
           let likedSummary = await fetchLikedSongsSummaryViaWebAPI(
            accessToken: creds.accessToken,
            clientToken: creds.clientToken,
            currentDisplayName: currentDisplayName
           ) {
            seenIDs.insert(likedSummary.id)
            collected.insert(likedSummary, at: 0)
        } else if let idx = collected.firstIndex(where: { $0.id == "collection-tracks" }),
                  collected[idx].trackCount == nil,
                  let likedSummary = await fetchLikedSongsSummaryViaWebAPI(
                    accessToken: creds.accessToken,
                    clientToken: creds.clientToken,
                    currentDisplayName: currentDisplayName
                  ) {
            collected[idx].trackCount = likedSummary.trackCount
        }

        // 3. Final list fallback: spclient rootlist (`spclient.wg.spotify.com/playlist/v2/user/<username>/rootlist`)
        if collected.isEmpty {
            let rootlistItems = await fetchUserPlaylistsViaSpClientRootlist(
                accessToken: creds.accessToken,
                clientToken: creds.clientToken,
                currentUsername: currentUsername,
                currentDisplayName: currentDisplayName
            )
            appendUnique(rootlistItems)
            if !collected.isEmpty {
                await runtimeContext?.log(.info, "Spotify spclient rootlist returned \(collected.count) playlist(s).")
            } else if let webAPIError {
                throw webAPIError
            }
        }

        return RemotePlaylistSummary.sortedForDisplay(collected)
    }

    private func fetchUserPlaylistsViaLibraryV3(
        accessToken: String,
        clientToken: String?,
        currentUsername: String?,
        currentDisplayName: String?
    ) async throws -> [RemotePlaylistSummary]? {
        guard var hash = await resolvePersistedHash(
            operationName: "libraryV3",
            defaultHash: "",
            allowBundleDiscovery: true
        ), !hash.isEmpty else {
            return nil
        }

        var items: [RemotePlaylistSummary] = []
        var offset = 0
        var pageCount = 0
        var didRefreshHash = false

        while pageCount < 20 {
            try Task.checkCancellation()
            pageCount += 1

            var pageResponse: SpotifyParsers.ParsedUserPlaylistsPage?
            var sawNotFoundHash = false

            for base in [Pathfinder.mutationEndpointV2, Pathfinder.endpoint] {
                guard let url = Pathfinder.buildLibraryV3URL(
                    offset: offset,
                    limit: 50,
                    sha256Hash: hash,
                    endpointBase: base
                ) else { continue }
                let req = Pathfinder.makeAuthorizedRequest(
                    url: url,
                    token: accessToken,
                    clientToken: clientToken,
                    userAgent: config.userAgent
                )
                let resp = try await transport.send(req)
                if resp.statusCode == 401 {
                    await tokenManager.invalidate(isUserToken: true)
                    throw PluginError(code: .unauthorized, message: "Spotify session expired.")
                }
                if resp.statusCode == 429 {
                    let retryAfter = min(30, max(1, resp.headerValue("Retry-After").flatMap(Int.init) ?? 2))
                    throw PluginError(code: .rateLimited, message: "Spotify rate-limited requests (HTTP 429).", retryAfterSeconds: retryAfter)
                }
                guard (200..<300).contains(resp.statusCode),
                      let json = (try? JSONSerialization.jsonObject(with: resp.body)) as? [String: Any] else {
                    continue
                }
                if let errors = json["errors"] as? [[String: Any]], !errors.isEmpty {
                    let msg = errors.compactMap { $0["message"] as? String }.joined(separator: "; ")
                    if msg.contains("PersistedQueryNotFound") {
                        sawNotFoundHash = true
                    }
                    await runtimeContext?.log(.warning, "Spotify libraryV3 (\(base)) error: \(msg)")
                    continue
                }
                if let data = json["data"] as? [String: Any],
                   let parsed = try? SpotifyParsers.parseLibraryV3PlaylistsPage(
                    data: data,
                    currentUsername: currentUsername,
                    currentDisplayName: currentDisplayName
                   ) {
                    pageResponse = parsed
                    break
                }
            }

            if pageResponse == nil && sawNotFoundHash && !didRefreshHash {
                didRefreshHash = true
                if let freshHash = await resolvePersistedHash(
                    operationName: "libraryV3",
                    defaultHash: "",
                    allowBundleDiscovery: true,
                    forceRefresh: true
                ), !freshHash.isEmpty {
                    hash = freshHash
                    pageCount -= 1
                    continue
                }
            }

            guard let pageResponse else {
                return items.isEmpty ? nil : items
            }
            items.append(contentsOf: pageResponse.playlists)
            guard let nextOffset = pageResponse.nextOffset else { break }
            offset = nextOffset
        }
        return items
    }

    private func fetchUserPlaylistsViaWebAPI(
        accessToken: String,
        clientToken: String?,
        currentUsername: String?,
        currentDisplayName: String?,
        retryOnRateLimit: Bool = true,
        maxPages: Int = 20
    ) async throws -> [RemotePlaylistSummary] {
        var nextURL = Pathfinder.makeMePlaylistsURL(offset: 0, limit: 50)
        var collected: [RemotePlaylistSummary] = []
        var pageCount = 0

        while let url = nextURL, pageCount < maxPages {
            try Task.checkCancellation()
            pageCount += 1

            var rateLimitAttempts = 0
            var pageData: Data?
            while pageData == nil {
                try Task.checkCancellation()
                let req = Pathfinder.makeAuthorizedRequest(
                    url: url,
                    token: accessToken,
                    clientToken: clientToken,
                    userAgent: config.userAgent
                )
                let resp = try await transport.send(req)
                if resp.statusCode == 401 {
                    await tokenManager.invalidate(isUserToken: true)
                    throw PluginError(code: .unauthorized, message: "Spotify session expired.")
                }
                if resp.statusCode == 429 {
                    rateLimitAttempts += 1
                    let retryAfter = min(30, max(1, resp.headerValue("Retry-After").flatMap(Int.init) ?? 2))
                    if retryOnRateLimit && rateLimitAttempts <= 2 {
                        try await Task.sleep(nanoseconds: UInt64(retryAfter) * 1_000_000_000)
                        continue
                    }
                    throw PluginError(code: .rateLimited, message: "Spotify rate-limited requests (HTTP 429).", retryAfterSeconds: retryAfter)
                }
                guard (200..<300).contains(resp.statusCode) else {
                    throw PluginError(code: .network, message: "Spotify playlists returned HTTP \(resp.statusCode).")
                }
                pageData = resp.body
            }

            if let data = pageData {
                let page = try SpotifyParsers.parseMePlaylistsPage(
                    data: data,
                    currentUsername: currentUsername,
                    currentDisplayName: currentDisplayName
                )
                collected.append(contentsOf: page.playlists)
                nextURL = page.nextURL
            }
        }
        return collected
    }

    private func fetchLikedSongsSummaryViaWebAPI(
        accessToken: String,
        clientToken: String?,
        currentDisplayName: String?
    ) async -> RemotePlaylistSummary? {
        guard let url = Pathfinder.makeMeTracksURL(offset: 0, limit: 1),
              let likedURL = URL(string: "https://open.spotify.com/collection/tracks") else {
            return nil
        }
        let req = Pathfinder.makeAuthorizedRequest(
            url: url,
            token: accessToken,
            clientToken: clientToken,
            userAgent: config.userAgent
        )
        guard let resp = try? await transport.send(req),
              (200..<300).contains(resp.statusCode),
              let json = (try? JSONSerialization.jsonObject(with: resp.body)) as? [String: Any],
              let total = (json["total"] as? NSNumber)?.intValue,
              total > 0 else {
            return nil
        }
        return RemotePlaylistSummary(
            id: "collection-tracks",
            title: "Liked Songs",
            owner: currentDisplayName,
            trackCount: total,
            artworkURL: nil,
            url: likedURL,
            isLikedSongs: true,
            isOwned: true
        )
    }

    private func fetchUserPlaylistsViaSpClientRootlist(
        accessToken: String,
        clientToken: String?,
        currentUsername: String?,
        currentDisplayName: String?
    ) async -> [RemotePlaylistSummary] {
        guard let username = currentUsername, !username.isEmpty else {
            return []
        }
        let encodedUser = username.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? username
        guard let rootURL = URL(string: "\(Pathfinder.spclientRootlistBase)/\(encodedUser)/rootlist?decorate=attributes") else {
            return []
        }
        let req = Pathfinder.makeAuthorizedRequest(
            url: rootURL,
            token: accessToken,
            clientToken: clientToken,
            userAgent: config.userAgent
        )
        guard let resp = try? await transport.send(req),
              (200..<300).contains(resp.statusCode),
              let json = (try? JSONSerialization.jsonObject(with: resp.body)) as? [String: Any],
              let contents = json["contents"] as? [String: Any],
              let items = contents["items"] as? [[String: Any]] else {
            return []
        }

        var playlistIDs: [String] = []
        var seen = Set<String>()
        for entry in items {
            guard let uri = entry["uri"] as? String, uri.hasPrefix("spotify:playlist:") else { continue }
            let pid = SpotifyURL.idFromURI(uri)
            if SpotifyURL.isValidSpotifyID(pid), seen.insert(pid).inserted {
                playlistIDs.append(pid)
            }
        }
        guard !playlistIDs.isEmpty else { return [] }

        let limit = min(playlistIDs.count, 100)
        let targetIDs = Array(playlistIDs.prefix(limit))
        let maxWorkers = min(min(4, max(1, ProcessInfo.processInfo.activeProcessorCount)), targetIDs.count)
        var summaries = [RemotePlaylistSummary?](repeating: nil, count: targetIDs.count)

        await withTaskGroup(of: (Int, RemotePlaylistSummary?).self) { group in
            var nextIdx = 0
            func submit(_ i: Int) {
                let pid = targetIDs[i]
                group.addTask {
                    guard let plURL = URL(string: "https://open.spotify.com/playlist/\(pid)") else {
                        return (i, nil)
                    }
                    guard let fetched = try? await self.fetchFullPlaylist(id: pid) else {
                        return (i, nil)
                    }
                    let isOwned: Bool? = {
                        if let o = fetched.playlist.owner {
                            if o.caseInsensitiveCompare(username) == .orderedSame { return true }
                            if let cd = currentDisplayName, o.caseInsensitiveCompare(cd) == .orderedSame { return true }
                            return false
                        }
                        return nil
                    }()
                    return (i, RemotePlaylistSummary(
                        id: pid,
                        title: fetched.playlist.title,
                        owner: fetched.playlist.owner,
                        trackCount: fetched.tracks.count,
                        artworkURL: fetched.playlist.artworkURL,
                        url: plURL,
                        isLikedSongs: false,
                        isOwned: isOwned
                    ))
                }
            }
            for _ in 0..<maxWorkers {
                let i = nextIdx
                nextIdx += 1
                submit(i)
            }
            for await (i, summary) in group {
                summaries[i] = summary
                if nextIdx < targetIDs.count {
                    let nxt = nextIdx
                    nextIdx += 1
                    submit(nxt)
                }
            }
        }
        return summaries.compactMap { $0 }
    }

    private func sendSpClientPlaylistChanges(
        playlistID: String,
        requestBuilder: () -> URLRequest?,
        operation: String,
        fallback: (() async throws -> Void)?
    ) async throws {
        guard let spReq = requestBuilder() else {
            throw PluginError(code: .internal, message: "Failed to construct Spotify request for \(operation).")
        }
        let spResp = try await transport.send(spReq)
        try await handleCommonWriteErrors(response: spResp, operation: operation)
        if (200..<300).contains(spResp.statusCode) {
            if let json = (try? JSONSerialization.jsonObject(with: spResp.body)) as? [String: Any],
               let errors = json["errors"] as? [[String: Any]], !errors.isEmpty {
                let msg = errors.compactMap { $0["message"] as? String }.joined(separator: "; ")
                throw PluginError(code: .network, message: msg.isEmpty ? "Spotify rejected playlist change." : msg)
            }
            return
        }

        if let fallback, [404, 405, 415, 501].contains(spResp.statusCode) {
            try await fallback()
            return
        }
        throw PluginError(code: .network, message: "Spotify \(operation) returned HTTP \(spResp.statusCode).")
    }

    /// Searches Spotify using Pathfinder `searchDesktop` first, falling back to `/v1/search`.
    /// Propagates `.unauthorized` immediately and surfaces `.rateLimited` if all search backends rate-limit.
    private func searchBestTrack(
        input: PlaylistAddTrackInput,
        accessToken: String,
        clientToken: String?,
        preResolvedSearchHash: String? = nil
    ) async throws -> TrackRef? {
        var queries: [String] = []
        if let isrc = input.isrc?.trimmingCharacters(in: .whitespacesAndNewlines), !isrc.isEmpty {
            queries.append("isrc:\(isrc)")
        }
        let cleanTitle = input.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanArtist = input.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanTitle.isEmpty && !cleanArtist.isEmpty {
            queries.append("\(cleanTitle) \(cleanArtist)")
        } else if !cleanTitle.isEmpty {
            queries.append(cleanTitle)
        }

        var lastRateLimitError: PluginError?

        // 1. Prefer Pathfinder `searchDesktop` (Web Player endpoint; avoids /v1/search 429 quotas).
        var hash: String
        if let preResolvedSearchHash {
            hash = preResolvedSearchHash
        } else {
            hash = await resolvePersistedHash(
                operationName: "searchDesktop",
                defaultHash: config.searchDesktopHash,
                allowBundleDiscovery: true
            ) ?? config.searchDesktopHash
        }
        var didRefreshHash = false

        if !hash.isEmpty, let pfURL = URL(string: Pathfinder.mutationEndpointV2) {
            for query in queries {
                guard let body = Pathfinder.buildSearchDesktopBody(query: query, limit: 10, sha256Hash: hash) else { continue }
                let req = Pathfinder.makeAuthorizedPostRequest(
                    url: pfURL,
                    token: accessToken,
                    clientToken: clientToken,
                    userAgent: config.userAgent,
                    body: body
                )
                let res = try await transport.send(req)
                if res.statusCode == 401 {
                    await tokenManager.invalidate(isUserToken: true)
                    throw PluginError(code: .unauthorized, message: "Spotify session expired.")
                }
                if res.statusCode == 429 {
                    lastRateLimitError = Self.rateLimitError(from: res, operation: "searching Spotify")
                    await runtimeContext?.log(.warning, "Spotify searchDesktop returned HTTP 429 for query: \(query)")
                    continue
                }
                if res.statusCode == 200,
                   isPersistedQueryNotFound(res.body),
                   !didRefreshHash {
                    didRefreshHash = true
                    if let updatedHash = await resolvePersistedHash(
                        operationName: "searchDesktop",
                        defaultHash: "",
                        allowBundleDiscovery: true,
                        forceRefresh: true
                    ), !updatedHash.isEmpty {
                        hash = updatedHash
                        if let retryBody = Pathfinder.buildSearchDesktopBody(query: query, limit: 10, sha256Hash: hash) {
                            let retryReq = Pathfinder.makeAuthorizedPostRequest(
                                url: pfURL,
                                token: accessToken,
                                clientToken: clientToken,
                                userAgent: config.userAgent,
                                body: retryBody
                            )
                            let retryRes = try await transport.send(retryReq)
                            if retryRes.statusCode == 429 {
                                lastRateLimitError = Self.rateLimitError(from: retryRes, operation: "searching Spotify")
                                continue
                            }
                            if retryRes.statusCode == 200,
                               let json = (try? JSONSerialization.jsonObject(with: retryRes.body)) as? [String: Any],
                               let data = json["data"] as? [String: Any] {
                                let candidates = SpotifyParsers.parseSearchDesktopTracks(data: data)
                                if let best = pickBestTrackMatch(candidates: candidates, input: input) {
                                    return best
                                }
                            }
                        }
                    }
                    continue
                }
                if res.statusCode == 200,
                   let json = (try? JSONSerialization.jsonObject(with: res.body)) as? [String: Any],
                   let data = json["data"] as? [String: Any] {
                    let candidates = SpotifyParsers.parseSearchDesktopTracks(data: data)
                    if let best = pickBestTrackMatch(candidates: candidates, input: input) {
                        return best
                    }
                }
            }
        }

        // 2. Fallback: Web API /v1/search (structured track/artist filters + offline test mocks).
        var webQueries = queries
        if !cleanTitle.isEmpty && !cleanArtist.isEmpty {
            webQueries.insert("track:\"\(cleanTitle)\" artist:\"\(cleanArtist)\"", at: 0)
        }
        for query in webQueries {
            guard let req = Pathfinder.makeSearchTracksRequest(
                query: query,
                limit: 10,
                token: accessToken,
                clientToken: clientToken,
                userAgent: config.userAgent
            ) else { continue }
            let res = try await transport.send(req)
            if res.statusCode == 401 {
                await tokenManager.invalidate(isUserToken: true)
                throw PluginError(code: .unauthorized, message: "Spotify session expired.")
            }
            if res.statusCode == 429 {
                lastRateLimitError = Self.rateLimitError(from: res, operation: "searching Spotify")
                await runtimeContext?.log(.warning, "Spotify /v1/search returned HTTP 429 for query: \(query)")
                continue
            }
            if res.statusCode == 403 {
                await runtimeContext?.log(.warning, "Spotify /v1/search returned HTTP 403 for query: \(query)")
                continue
            }
            guard res.statusCode == 200,
                  let json = (try? JSONSerialization.jsonObject(with: res.body)) as? [String: Any],
                  let tracksObj = json["tracks"] as? [String: Any],
                  let items = tracksObj["items"] as? [[String: Any]], !items.isEmpty else {
                continue
            }
            let candidates = items.compactMap(Self.trackRefFromWebAPISearchItem)
            if let best = pickBestTrackMatch(candidates: candidates, input: input) {
                return best
            }
        }
        if let lastRateLimitError {
            throw lastRateLimitError
        }
        return nil
    }

    private static func trackRefFromWebAPISearchItem(_ item: [String: Any]) -> TrackRef? {
        guard let title = item["name"] as? String, !title.isEmpty else { return nil }
        let uri = (item["uri"] as? String) ?? ""
        let rawID = (item["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? SpotifyURL.idFromURI(uri)
        guard !rawID.isEmpty else { return nil }
        let artists = (item["artists"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        let albumObj = item["album"] as? [String: Any]
        let albumName = albumObj?["name"] as? String
        let releaseDate = albumObj?["release_date"] as? String
        let durationMs = (item["duration_ms"] as? NSNumber)?.intValue
        let trackNum = (item["track_number"] as? NSNumber)?.intValue
        let discNum = (item["disc_number"] as? NSNumber)?.intValue
        let isrc = (item["external_ids"] as? [String: Any])?["isrc"] as? String
        let explicit = (item["explicit"] as? Bool) ?? false
        let artworkURL = ((albumObj?["images"] as? [[String: Any]])?
            .max { (($0["width"] as? NSNumber)?.intValue ?? 0) < (($1["width"] as? NSNumber)?.intValue ?? 0) }?["url"] as? String)
            .flatMap(URL.init(string:))

        return TrackRef(
            source: "spotify",
            sourceID: rawID,
            title: title,
            artists: artists,
            album: albumName,
            albumArtist: artists.first,
            trackNumber: trackNum,
            discNumber: discNum,
            durationMs: durationMs,
            isrc: isrc,
            releaseDate: releaseDate,
            artworkURL: artworkURL,
            explicit: explicit
        )
    }

    private func pickBestTrackMatch(candidates: [TrackRef], input: PlaylistAddTrackInput) -> TrackRef? {
        let targetTitle = Self.normalizeSearchText(input.title)
        let targetArtist = Self.normalizeSearchText(input.artist)
        let targetAlbum = Self.normalizeSearchText(input.album ?? "")

        var bestScore = -1
        var bestRef: TrackRef?

        for ref in candidates {
            let normTitle = Self.normalizeSearchText(ref.title)
            let normArtists = Self.normalizeSearchText(ref.artists.joined(separator: " "))
            let normAlbum = Self.normalizeSearchText(ref.album ?? "")

            var score = 0
            if let inputISRC = input.isrc?.lowercased(), let isrc = ref.isrc?.lowercased(), !inputISRC.isEmpty, inputISRC == isrc {
                score += 100
            }
            if normTitle == targetTitle {
                score += 50
            } else if !targetTitle.isEmpty && (normTitle.contains(targetTitle) || targetTitle.contains(normTitle)) {
                score += 25
            }
            if !targetArtist.isEmpty {
                if normArtists == targetArtist || normArtists.contains(targetArtist) || targetArtist.contains(normArtists) {
                    score += 40
                } else {
                    let tokens = targetArtist.split(separator: " ").filter { $0.count >= 2 }
                    if tokens.contains(where: { normArtists.contains(String($0)) }) {
                        score += 20
                    }
                }
            }
            if !targetAlbum.isEmpty && (normAlbum == targetAlbum || normAlbum.contains(targetAlbum)) {
                score += 10
            }
            if let expectedDur = input.durationMs, expectedDur > 0, let actualDur = ref.durationMs, actualDur > 0 {
                let diff = abs(expectedDur - actualDur)
                if diff <= 3000 { score += 15 }
                else if diff <= 8000 { score += 5 }
                else if diff > 25000 { score -= 15 }
            }

            if score > bestScore {
                bestScore = score
                bestRef = ref
            }
        }
        return bestScore >= 25 ? bestRef : nil
    }

    private func postAddPlaylistItems(
        playlistID: String,
        uris: [String],
        accessToken: String,
        clientToken: String?
    ) async throws {
        try await sendSpClientPlaylistChanges(
            playlistID: playlistID,
            requestBuilder: {
                Pathfinder.makeSpClientAddItemsRequest(
                    playlistID: playlistID,
                    uris: uris,
                    token: accessToken,
                    clientToken: clientToken,
                    userAgent: config.userAgent
                )
            },
            operation: "adding tracks",
            fallback: {
                for suffix in ["items", "tracks"] {
                    guard let req = Pathfinder.makeWebAPIAddItemsRequest(
                        playlistID: playlistID,
                        uris: uris,
                        pathSuffix: suffix,
                        token: accessToken,
                        clientToken: clientToken,
                        userAgent: self.config.userAgent
                    ) else {
                        throw PluginError(code: .internal, message: "Failed to construct Spotify add-tracks request.")
                    }
                    let resp = try await self.transport.send(req)
                    try await self.handleCommonWriteErrors(response: resp, operation: "adding tracks")
                    if (resp.statusCode == 404 || resp.statusCode == 405) && suffix == "items" {
                        continue
                    }
                    guard (200..<300).contains(resp.statusCode) else {
                        throw PluginError(code: .network, message: "Spotify add tracks returned HTTP \(resp.statusCode).")
                    }
                    return
                }
            }
        )
    }

    private func isPersistedQueryNotFound(_ body: Data) -> Bool {
        guard let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let errors = json["errors"] as? [[String: Any]] else { return false }
        return errors.contains { ($0["message"] as? String) == "PersistedQueryNotFound" }
    }

    /// Resolves a persisted GraphQL SHA-256 hash by checking cache, config defaults, then Spotify's live JS bundles.
    /// Concurrent callers share one in-flight discovery task so bundles are never downloaded redundantly.
    private func resolvePersistedHash(
        operationName: String,
        defaultHash: String,
        allowBundleDiscovery: Bool,
        forceRefresh: Bool = false
    ) async -> String? {
        if !forceRefresh, let cached = discoveredHashes[operationName], !cached.isEmpty {
            return cached
        }
        if !forceRefresh, !defaultHash.isEmpty {
            return defaultHash
        }
        guard allowBundleDiscovery else {
            return defaultHash.isEmpty ? nil : defaultHash
        }

        if let existing = inFlightHashDiscovery {
            await existing.value
            if let hit = discoveredHashes[operationName], !hit.isEmpty {
                return hit
            }
            if !forceRefresh {
                return defaultHash.isEmpty ? nil : defaultHash
            }
        }

        let targetOp = operationName
        let discovery = Task<Void, Never> {
            await self.fetchBundleHashes(stoppingOnceFound: targetOp, rescanAll: forceRefresh)
        }
        inFlightHashDiscovery = discovery
        await discovery.value
        inFlightHashDiscovery = nil

        if let hit = discoveredHashes[operationName], !hit.isEmpty {
            return hit
        }
        return defaultHash.isEmpty ? nil : defaultHash
    }

    private func loadPersistedHashes() {
        guard let url = hashesFileURL,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            return
        }
        for (op, hash) in decoded where !op.isEmpty && !hash.isEmpty {
            discoveredHashes[op] = hash
        }
    }

    private func persistDiscoveredHashes() {
        guard let url = hashesFileURL, !discoveredHashes.isEmpty else { return }
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(discoveredHashes) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func bundlePriority(_ urlString: String) -> Int {
        if urlString.contains("your-library") || urlString.contains("library") { return 0 }
        if urlString.contains("web-player") { return 1 }
        if urlString.contains("xpui") { return 2 }
        return 3
    }

    private func fetchBundleHashes(stoppingOnceFound targetOp: String, rescanAll: Bool) async {
        guard let homeURL = URL(string: "https://open.spotify.com/") else { return }
        var homeReq = URLRequest(url: homeURL, timeoutInterval: 15)
        homeReq.setValue(config.userAgent, forHTTPHeaderField: "User-Agent")
        guard let homeResp = try? await transport.send(homeReq),
              homeResp.statusCode == 200,
              let html = String(data: homeResp.body, encoding: .utf8) else { return }

        let jsURLs = Array(
            Pathfinder.extractJSBundleURLs(fromHTML: html)
                .filter { rescanAll || !scannedBundleURLs.contains($0) }
                .sorted { Self.bundlePriority($0) < Self.bundlePriority($1) }
                .prefix(24)
        )
        guard !jsURLs.isEmpty else { return }

        let maxWorkers = min(min(6, max(1, ProcessInfo.processInfo.activeProcessorCount)), jsURLs.count)
        let ua = config.userAgent
        var addedAnyHash = false

        await withTaskGroup(of: (String, [String: String]).self) { group in
            var cursor = 0
            func submit(_ jsURLString: String) {
                scannedBundleURLs.insert(jsURLString)
                group.addTask { [transport] in
                    guard let jsURL = URL(string: jsURLString) else { return (jsURLString, [:]) }
                    var jsReq = URLRequest(url: jsURL, timeoutInterval: 12)
                    jsReq.setValue(ua, forHTTPHeaderField: "User-Agent")
                    guard let jsResp = try? await transport.send(jsReq),
                          jsResp.statusCode == 200,
                          let jsSource = String(data: jsResp.body, encoding: .utf8) else {
                        return (jsURLString, [:])
                    }
                    return (jsURLString, Pathfinder.extractQueryHashes(fromJS: jsSource))
                }
            }
            for _ in 0..<maxWorkers {
                submit(jsURLs[cursor])
                cursor += 1
            }
            for await (_, hashes) in group {
                for (k, v) in hashes where !k.isEmpty && !v.isEmpty {
                    if discoveredHashes[k] != v {
                        discoveredHashes[k] = v
                        addedAnyHash = true
                    }
                }
                if let hit = discoveredHashes[targetOp], !hit.isEmpty {
                    group.cancelAll()
                    break
                }
                if cursor < jsURLs.count {
                    submit(jsURLs[cursor])
                    cursor += 1
                }
            }
        }
        if addedAnyHash {
            persistDiscoveredHashes()
        }
    }

    private func handleCommonWriteErrors(response: HTTPResponseData, operation: String) async throws {
        if response.statusCode == 401 {
            await tokenManager.invalidate(isUserToken: true)
            throw PluginError(code: .unauthorized, message: "Spotify session expired.")
        }
        if response.statusCode == 403 {
            throw PluginError(code: .unsupported, message: "Only playlists that you own can be modified on Spotify.")
        }
        if response.statusCode == 429 {
            throw Self.rateLimitError(from: response, operation: operation)
        }
    }

    private static func rateLimitError(from response: HTTPResponseData, operation: String) -> PluginError {
        let raw = response.headerValue("Retry-After").flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 5
        let clamped = min(max(raw, 1), 30)
        return PluginError(
            code: .rateLimited,
            message: "Spotify rate-limited \(operation) (HTTP 429). Please wait a moment and try again.",
            retryAfterSeconds: clamped
        )
    }

    private static func normalizeSearchText(_ raw: String) -> String {
        raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - PlaylistSource

    public func fetch(url: URL) async throws -> PlaylistFetchResult {
        try Task.checkCancellation()

        // Support offline conformance suite (`ipodpromax plugin test Plug-ins/Spotify --offline`).
        if let offline = try await handleOfflineOrCancelModeIfActive(requestedURL: url) {
            return offline
        }

        let target = try SpotifyURL.parse(url.absoluteString)

        switch target.kind {
        case .playlist:
            return try await fetchFullPlaylist(id: target.id)
        case .album:
            return try await fetchFullAlbum(id: target.id)
        case .collection:
            return try await fetchLikedSongs()
        }
    }

    private func fetchLikedSongs() async throws -> PlaylistFetchResult {
        let creds = try await tokenManager.getUserWriteCredentials()
        let owner = await tokenManager.currentUserSession()?.displayName
        var allTracks: [TrackRef] = []

        // 1. Try Pathfinder `fetchLibraryTracks` when hash is available.
        if var hash = await resolvePersistedHash(operationName: "fetchLibraryTracks", defaultHash: "", allowBundleDiscovery: true),
           !hash.isEmpty {
            var offset = 0
            var pageCount = 0
            var didRefresh = false
            while pageCount < Pathfinder.maxPages && allTracks.count < 10_000 {
                try Task.checkCancellation()
                pageCount += 1
                var parsedPage: SpotifyParsers.ParsedTracksPage?
                var sawNotFound = false
                for base in [Pathfinder.mutationEndpointV2, Pathfinder.endpoint] {
                    guard let pageURL = Pathfinder.buildFetchLibraryTracksURL(
                        offset: offset,
                        limit: 50,
                        sha256Hash: hash,
                        endpointBase: base
                    ) else { continue }
                    let req = Pathfinder.makeAuthorizedRequest(
                        url: pageURL,
                        token: creds.accessToken,
                        clientToken: creds.clientToken,
                        userAgent: config.userAgent
                    )
                    let resp = try await transport.send(req)
                    if resp.statusCode == 401 {
                        await tokenManager.invalidate(isUserToken: true)
                        throw PluginError(code: .unauthorized, message: "Spotify session expired.")
                    }
                    guard (200..<300).contains(resp.statusCode),
                          let json = (try? JSONSerialization.jsonObject(with: resp.body)) as? [String: Any] else { continue }
                    if let errors = json["errors"] as? [[String: Any]], !errors.isEmpty {
                        if errors.contains(where: { ($0["message"] as? String) == "PersistedQueryNotFound" }) {
                            sawNotFound = true
                        }
                        continue
                    }
                    if let data = json["data"] as? [String: Any],
                       let parsed = try? SpotifyParsers.parseLibraryTracksPage(data: data) {
                        parsedPage = parsed
                        break
                    }
                }
                if parsedPage == nil && sawNotFound && !didRefresh {
                    didRefresh = true
                    if let fresh = await resolvePersistedHash(operationName: "fetchLibraryTracks", defaultHash: "", allowBundleDiscovery: true, forceRefresh: true), !fresh.isEmpty {
                        hash = fresh
                        pageCount -= 1
                        continue
                    }
                }
                guard let parsedPage else { break }
                allTracks.append(contentsOf: parsedPage.tracks)
                guard let nextOffset = parsedPage.nextOffset else { break }
                offset = nextOffset
            }
        }

        // 2. Fallback: Web API `/v1/me/tracks` if Pathfinder `fetchLibraryTracks` produced nothing.
        if allTracks.isEmpty {
            var nextURL = Pathfinder.makeMeTracksURL(offset: 0, limit: 50)
            var pageCount = 0
            while let url = nextURL, pageCount < Pathfinder.maxPages && allTracks.count < 10_000 {
                try Task.checkCancellation()
                pageCount += 1
                let req = Pathfinder.makeAuthorizedRequest(
                    url: url,
                    token: creds.accessToken,
                    clientToken: creds.clientToken,
                    userAgent: config.userAgent
                )
                let resp = try await transport.send(req)
                if resp.statusCode == 401 {
                    await tokenManager.invalidate(isUserToken: true)
                    throw PluginError(code: .unauthorized, message: "Spotify session expired.")
                }
                guard (200..<300).contains(resp.statusCode),
                      let json = (try? JSONSerialization.jsonObject(with: resp.body)) as? [String: Any],
                      let rawItems = json["items"] as? [[String: Any]] else {
                    if allTracks.isEmpty {
                        throw PluginError(code: .network, message: "Could not read Spotify Liked Songs (HTTP \(resp.statusCode)).")
                    }
                    break
                }
                for entry in rawItems {
                    if let trackObj = entry["track"] as? [String: Any],
                       let ref = Self.trackRefFromWebAPISearchItem(trackObj) {
                        allTracks.append(ref)
                    }
                }
                nextURL = (json["next"] as? String).flatMap(URL.init(string:))
            }
        }

        let revision = SpotifyParsers.computeRevision(title: "Liked Songs", trackIDs: allTracks.map(\.sourceID))
        let playlist = Playlist(
            source: "spotify",
            sourceID: "collection-tracks",
            title: "Liked Songs",
            owner: owner,
            artworkURL: nil,
            revision: revision
        )
        return PlaylistFetchResult(playlist: playlist, tracks: allTracks)
    }

    // MARK: - Pagination & Retry (`SPO-6`, `SPO-8`)

    private func fetchFullPlaylist(id: String) async throws -> PlaylistFetchResult {
        guard let initialURL = Pathfinder.buildPlaylistRequestURL(
            playlistID: id,
            offset: 0,
            limit: Pathfinder.playlistPageLimit,
            sha256Hash: config.fetchPlaylistHash
        ) else {
            throw PluginError(code: .internal, message: "Could not build Pathfinder URL.")
        }

        let initialData = try await pathfinderGet(url: initialURL, preferredBootstrapID: id)
        let parsedInitial: SpotifyParsers.ParsedPlaylistPage
        do {
            parsedInitial = try SpotifyParsers.parsePlaylistInitial(data: initialData, requestedID: id)
        } catch let pErr as PluginError {
            if pErr.code == .apiChanged {
                await markAPIChanged(pErr.message)
            }
            throw pErr
        }

        await logWarnings(parsedInitial.warnings)

        var allTracks = parsedInitial.tracks
        var nextOffset = parsedInitial.nextOffset
        var pagesFetched = 1

        // Single request at a time, capped at 100 pages / 10,000 tracks (`SPO-6`).
        while let offset = nextOffset, pagesFetched < Pathfinder.maxPages, allTracks.count < 10_000 {
            try Task.checkCancellation()
            pagesFetched += 1

            guard let pageURL = Pathfinder.buildPlaylistRequestURL(
                playlistID: id,
                offset: offset,
                limit: Pathfinder.playlistPageLimit,
                sha256Hash: config.fetchPlaylistHash
            ) else { break }

            let pageData = try await pathfinderGet(url: pageURL, preferredBootstrapID: id)
            let page = try SpotifyParsers.parsePlaylistContinuation(data: pageData)
            await logWarnings(page.warnings)

            let remaining = 10_000 - allTracks.count
            if page.tracks.count > remaining {
                allTracks.append(contentsOf: page.tracks.prefix(remaining))
                await runtimeContext?.log(.warning, "Spotify playlist exceeded 10,000 tracks; truncated to 10,000.")
                nextOffset = nil
                break
            }
            allTracks.append(contentsOf: page.tracks)
            nextOffset = page.nextOffset
        }

        if nextOffset != nil && allTracks.count >= 10_000 {
            await runtimeContext?.log(.warning, "Spotify playlist exceeded 10,000 tracks; truncated to 10,000.")
        }

        let revision = SpotifyParsers.computeRevision(title: parsedInitial.title, trackIDs: allTracks.map(\.sourceID))
        let playlist = Playlist(
            source: "spotify",
            sourceID: parsedInitial.sourceID,
            title: parsedInitial.title,
            owner: parsedInitial.owner,
            artworkURL: parsedInitial.artworkURL,
            revision: revision
        )
        return PlaylistFetchResult(playlist: playlist, tracks: allTracks)
    }

    private func fetchFullAlbum(id: String) async throws -> PlaylistFetchResult {
        guard let initialURL = Pathfinder.buildAlbumRequestURL(
            albumID: id,
            offset: 0,
            limit: Pathfinder.albumPageLimit,
            sha256Hash: config.getAlbumHash
        ) else {
            throw PluginError(code: .internal, message: "Could not build Pathfinder album URL.")
        }

        let initialData = try await pathfinderGet(url: initialURL, preferredBootstrapID: nil)
        let parsedInitial: SpotifyParsers.ParsedPlaylistPage
        do {
            parsedInitial = try SpotifyParsers.parseAlbumInitial(data: initialData, requestedID: id)
        } catch let pErr as PluginError {
            if pErr.code == .apiChanged {
                await markAPIChanged(pErr.message)
            }
            throw pErr
        }

        await logWarnings(parsedInitial.warnings)

        var allTracks = parsedInitial.tracks
        var nextOffset = parsedInitial.nextOffset
        var pagesFetched = 1
        let albumReleaseDate = allTracks.first?.releaseDate

        while let offset = nextOffset, pagesFetched < Pathfinder.maxPages, allTracks.count < 10_000 {
            try Task.checkCancellation()
            pagesFetched += 1

            guard let pageURL = Pathfinder.buildAlbumRequestURL(
                albumID: id,
                offset: offset,
                limit: Pathfinder.albumPageLimit,
                sha256Hash: config.getAlbumHash
            ) else { break }

            let pageData = try await pathfinderGet(url: pageURL, preferredBootstrapID: nil)
            let page = try SpotifyParsers.parseAlbumContinuation(
                data: pageData,
                albumName: parsedInitial.title,
                albumArtist: parsedInitial.owner,
                artworkURL: parsedInitial.artworkURL,
                releaseDate: albumReleaseDate
            )
            await logWarnings(page.warnings)

            let remaining = 10_000 - allTracks.count
            if page.tracks.count > remaining {
                allTracks.append(contentsOf: page.tracks.prefix(remaining))
                await runtimeContext?.log(.warning, "Spotify album exceeded 10,000 tracks; truncated to 10,000.")
                nextOffset = nil
                break
            }
            allTracks.append(contentsOf: page.tracks)
            nextOffset = page.nextOffset
        }

        let revision = SpotifyParsers.computeRevision(title: parsedInitial.title, trackIDs: allTracks.map(\.sourceID))
        let playlist = Playlist(
            source: "spotify",
            sourceID: parsedInitial.sourceID,
            title: parsedInitial.title,
            owner: parsedInitial.owner,
            artworkURL: parsedInitial.artworkURL,
            revision: revision
        )
        return PlaylistFetchResult(playlist: playlist, tracks: allTracks)
    }

    private func pathfinderGet(url: URL, preferredBootstrapID: String?) async throws -> [String: Any] {
        var didRefresh401 = false
        var rateLimitAttempts = 0

        while true {
            try Task.checkCancellation()
            let auth = try await tokenManager.getPreferredAuth(preferredPlaylistID: preferredBootstrapID)
            let request = Pathfinder.makeAuthorizedRequest(
                url: url,
                token: auth.accessToken,
                clientToken: auth.clientToken,
                userAgent: config.userAgent
            )
            let response = try await transport.send(request)

            switch Pathfinder.classifyResponse(response) {
            case .success(let data):
                if apiChangedReported {
                    apiChangedReported = false
                    await runtimeContext?.reportStatus(.ready, message: nil)
                }
                return data

            case .unauthorized:
                guard !didRefresh401 else {
                    throw PluginError(code: .unauthorized, message: "Spotify rejected the refreshed anonymous token (HTTP 401).")
                }
                didRefresh401 = true
                await tokenManager.invalidate(isUserToken: auth.isUserToken)
                continue

            case .rateLimited(let retryAfter):
                rateLimitAttempts += 1
                if rateLimitAttempts > 3 {
                    throw PluginError(
                        code: .rateLimited,
                        message: "Spotify rate-limited requests (HTTP 429).",
                        retryAfterSeconds: retryAfter
                    )
                }
                await runtimeContext?.log(.warning, "Spotify rate-limited (HTTP 429); retrying in \(retryAfter)s.")
                try await Task.sleep(nanoseconds: UInt64(retryAfter) * 1_000_000_000)
                continue

            case .error(let err, let isAPIChanged, let detail):
                await runtimeContext?.log(.error, detail)
                if isAPIChanged {
                    await markAPIChanged(err.message)
                }
                throw err
            }
        }
    }

    private func markAPIChanged(_ message: String) async {
        apiChangedReported = true
        await runtimeContext?.reportStatus(.error, message: message)
    }

    private func logWarnings(_ warnings: [String]) async {
        for msg in warnings {
            await runtimeContext?.log(.warning, msg)
        }
    }

    // MARK: - Conformance Offline / Cancellation Support (`SPO-10`, `PLG-15`)

    private func handleOfflineOrCancelModeIfActive(requestedURL: URL) async throws -> PlaylistFetchResult? {
        let env = ProcessInfo.processInfo.environment
        if env["IPPM_PLUGIN_TEST_CANCEL"] == "1" {
            for _ in 0..<50 {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }

        if env["IPPM_PLUGIN_OFFLINE"] == "1",
           let fixturePath = env["IPPM_PLUGIN_FIXTURES"],
           !fixturePath.isEmpty {
            _ = try SpotifyURL.parse(requestedURL.absoluteString)
            let data = try Data(contentsOf: URL(fileURLWithPath: fixturePath))
            let fixtures = try JSONDecoder().decode(PluginTestFixtures.self, from: data)
            if let result = fixtures.playlistSource?.offlineResponse {
                return result
            }
        }
        return nil
    }
}
