import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import PluginKit

/// PlaylistSource (+ optional authenticated reordering / editing) implementation for Spotify over Pathfinder.
public actor SpotifySource: PlaylistReorderable, PlaylistEditable, PluginConfigurable, PluginAccountHandling {
    private let transport: any HTTPTransport
    private let tokenManager: TokenManager
    private var config = Pathfinder.Config()
    private var runtimeContext: (any PluginRuntimeContext)?
    private var apiChangedReported = false

    public init(transport: any HTTPTransport = URLSessionTransport()) {
        self.transport = transport
        self.tokenManager = TokenManager(transport: transport)
    }

    // MARK: - PluginConfigurable

    public func initialize(params: PluginInitializeParams, context: any PluginRuntimeContext) async throws {
        self.runtimeContext = context
        self.config = Pathfinder.Config.from(initializeConfig: params.config)
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

        // When invoked via Sign In button without fields, request the interactive browser/WebView login flow.
        if accessToken.isEmpty && (spDC?.isEmpty ?? true) {
            return PluginAccountStatus(
                status: "waiting",
                openURL: "https://accounts.spotify.com/login?continue=https%3A%2F%2Fopen.spotify.com%2F"
            )
        }

        let resolvedInputName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.needsAccountNameResolution(resolvedInputName), !accessToken.isEmpty {
            if let fetched = await fetchProfileDisplayName(accessToken: accessToken, clientToken: clientToken) {
                displayName = fetched
            }
        }

        let resolvedName = (displayName?.isEmpty == false) ? displayName! : "Spotify Web"
        let webSession = UserWebSession(
            spDC: spDC?.isEmpty == false ? spDC : nil,
            displayName: resolvedName,
            accessToken: accessToken.isEmpty ? nil : accessToken,
            clientToken: clientToken?.isEmpty == false ? clientToken : nil,
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
           Self.needsAccountNameResolution(cur.displayName),
           let tok = cur.accessToken, !tok.isEmpty {
            if let uname = await fetchProfileDisplayName(accessToken: tok, clientToken: cur.clientToken), !uname.isEmpty {
                cur.displayName = uname
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

    private func fetchProfileDisplayName(accessToken: String, clientToken: String?) async -> String? {
        guard let url = URL(string: "https://api.spotify.com/v1/me") else { return nil }
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
            if let name = (json["display_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                return name
            }
            if let id = (json["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
                return id
            }
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
           let body = Pathfinder.buildMoveItemsBody(request: request, sha256Hash: config.moveItemsInPlaylistHash),
           let v2URL = URL(string: Pathfinder.mutationEndpointV2),
           let v1URL = URL(string: Pathfinder.endpoint) {
            for endpointURL in [v2URL, v1URL] {
                let req = Pathfinder.makeAuthorizedPostRequest(
                    url: endpointURL,
                    token: creds.accessToken,
                    clientToken: creds.clientToken,
                    userAgent: config.userAgent,
                    body: body
                )
                let resp = try await transport.send(req)
                if resp.statusCode == 401 {
                    await tokenManager.invalidate(isUserToken: true)
                    throw PluginError(code: .unauthorized, message: "Spotify session expired.")
                }
                if resp.statusCode == 403 {
                    throw PluginError(code: .unsupported, message: "Order changed manually (local only). Only playlists that you own can be modified on Spotify.")
                }
                if (200..<300).contains(resp.statusCode) {
                    if let json = (try? JSONSerialization.jsonObject(with: resp.body)) as? [String: Any],
                       let errors = json["errors"] as? [[String: Any]], !errors.isEmpty {
                        let msg = errors.compactMap { $0["message"] as? String }.joined(separator: "; ")
                        await runtimeContext?.log(.warning, "Pathfinder moveItemsInPlaylist warning (\(endpointURL.path)): \(msg)")
                        if msg.contains("PersistedQueryNotFound") {
                            continue
                        }
                        if msg.localizedCaseInsensitiveContains("permission") || msg.localizedCaseInsensitiveContains("unauthorized") {
                            throw PluginError(code: .unsupported, message: "Order changed manually (local only). Only playlists that you own can be modified on Spotify.")
                        }
                    } else {
                        return
                    }
                }
            }
        }

        // Fallback: Web API PUT /v1/playlists/{id}/items
        guard let putReq = Pathfinder.makeWebAPIPutRequest(
            playlistID: request.playlistID,
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
        if resp.statusCode == 401 {
            await tokenManager.invalidate(isUserToken: true)
            throw PluginError(code: .unauthorized, message: "Spotify session expired.")
        }
        if resp.statusCode == 403 {
            throw PluginError(code: .unsupported, message: "Order changed manually (local only). Only playlists that you own can be modified on Spotify.")
        }
        guard (200..<300).contains(resp.statusCode) else {
            throw PluginError(code: .network, message: "Spotify reorder returned HTTP \(resp.statusCode).")
        }
    }

    // MARK: - PlaylistEditable

    public func addTracks(request: PlaylistAddTracksRequest) async throws -> PlaylistAddTracksResult {
        try Task.checkCancellation()
        guard !request.playlistID.isEmpty else {
            throw PluginError(code: .unsupported, message: "Missing Spotify playlist ID.")
        }
        guard !request.tracks.isEmpty else {
            return PlaylistAddTracksResult(added: [], notFoundTitles: [])
        }

        let creds = try await tokenManager.getUserWriteCredentials()
        var added: [PlaylistAddedTrackResult] = []
        var urisToAdd: [String] = []
        var notFound: [String] = []

        for (index, input) in request.tracks.enumerated() {
            try Task.checkCancellation()
            if let match = try await searchBestTrack(input: input, accessToken: creds.accessToken, clientToken: creds.clientToken),
               !match.sourceID.isEmpty {
                added.append(PlaylistAddedTrackResult(index: index, matchedTrack: match))
                urisToAdd.append("spotify:track:\(match.sourceID)")
            } else {
                notFound.append(input.title)
            }
        }

        guard !urisToAdd.isEmpty else {
            throw PluginError(code: .notFound, message: "Could not find matching tracks on Spotify.")
        }

        // Spotify allows up to 100 URIs per POST.
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

    private func searchBestTrack(
        input: PlaylistAddTrackInput,
        accessToken: String,
        clientToken: String?
    ) async throws -> TrackRef? {
        var queries: [String] = []
        if let isrc = input.isrc?.trimmingCharacters(in: .whitespacesAndNewlines), !isrc.isEmpty {
            queries.append("isrc:\(isrc)")
        }
        let cleanTitle = input.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanArtist = input.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanTitle.isEmpty && !cleanArtist.isEmpty {
            queries.append("track:\"\(cleanTitle)\" artist:\"\(cleanArtist)\"")
            queries.append("\(cleanTitle) \(cleanArtist)")
        } else if !cleanTitle.isEmpty {
            queries.append(cleanTitle)
        }

        for query in queries {
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
            if let best = pickBestSearchMatch(items: items, input: input) {
                return best
            }
        }
        return nil
    }

    private func pickBestSearchMatch(items: [[String: Any]], input: PlaylistAddTrackInput) -> TrackRef? {
        let targetTitle = Self.normalizeSearchText(input.title)
        let targetArtist = Self.normalizeSearchText(input.artist)
        let targetAlbum = Self.normalizeSearchText(input.album ?? "")

        var bestScore = -1
        var bestRef: TrackRef?

        for item in items {
            guard let title = item["name"] as? String, !title.isEmpty else { continue }
            let uri = (item["uri"] as? String) ?? ""
            let rawID = (item["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? SpotifyURL.idFromURI(uri)
            guard !rawID.isEmpty else { continue }
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

            let normTitle = Self.normalizeSearchText(title)
            let normArtists = Self.normalizeSearchText(artists.joined(separator: " "))
            let normAlbum = Self.normalizeSearchText(albumName ?? "")

            var score = 0
            if let inputISRC = input.isrc?.lowercased(), let isrc = isrc?.lowercased(), !inputISRC.isEmpty, inputISRC == isrc {
                score += 100
            }
            if normTitle == targetTitle {
                score += 50
            } else if normTitle.contains(targetTitle) || targetTitle.contains(normTitle) {
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
            if let expectedDur = input.durationMs, expectedDur > 0, let actualDur = durationMs, actualDur > 0 {
                let diff = abs(expectedDur - actualDur)
                if diff <= 3000 { score += 15 }
                else if diff <= 8000 { score += 5 }
                else if diff > 25000 { score -= 15 }
            }

            if score > bestScore {
                bestScore = score
                bestRef = TrackRef(
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
        }
        return bestScore >= 25 ? bestRef : nil
    }

    private func postAddPlaylistItems(
        playlistID: String,
        uris: [String],
        accessToken: String,
        clientToken: String?
    ) async throws {
        for suffix in ["items", "tracks"] {
            guard let req = Pathfinder.makeWebAPIAddItemsRequest(
                playlistID: playlistID,
                uris: uris,
                pathSuffix: suffix,
                token: accessToken,
                clientToken: clientToken,
                userAgent: config.userAgent
            ) else {
                throw PluginError(code: .internal, message: "Failed to construct Spotify add-tracks request.")
            }
            let resp = try await transport.send(req)
            if resp.statusCode == 401 {
                await tokenManager.invalidate(isUserToken: true)
                throw PluginError(code: .unauthorized, message: "Spotify session expired.")
            }
            if resp.statusCode == 403 {
                throw PluginError(code: .unsupported, message: "Only playlists that you own can be modified on Spotify.")
            }
            if (resp.statusCode == 404 || resp.statusCode == 405) && suffix == "items" {
                continue
            }
            guard (200..<300).contains(resp.statusCode) else {
                throw PluginError(code: .network, message: "Spotify add tracks returned HTTP \(resp.statusCode).")
            }
            return
        }
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
        }
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
