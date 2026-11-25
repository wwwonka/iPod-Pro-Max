import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import PluginKit

/// PlaylistSource (+ authenticated reordering / editing / browsing) implementation for YouTube Music over InnerTube (`WEB_REMIX`).
public actor YouTubeMusicSource: PlaylistReorderable, PlaylistEditable, PlaylistBrowsable, PluginConfigurable, PluginAccountHandling {
    private let transport: any HTTPTransport
    private let tokenManager: YTMusicTokenManager
    private var config = InnerTube.Config()
    private var runtimeContext: (any PluginRuntimeContext)?
    private var apiChangedReported = false

    public init(transport: any HTTPTransport = URLSessionTransport()) {
        self.transport = transport
        self.tokenManager = YTMusicTokenManager(transport: transport)
    }

    // MARK: - PluginConfigurable

    public func initialize(params: PluginInitializeParams, context: any PluginRuntimeContext) async throws {
        self.runtimeContext = context
        self.config = InnerTube.Config.from(initializeConfig: params.config)
        await tokenManager.configureStorage(dataDirectory: params.paths.data)
        await tokenManager.configure(
            userAgent: config.userAgent,
            defaultClientVersion: config.clientVersion,
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
        // Account session updates arrive through `account/login` and `account/logout`.
    }

    // MARK: - PluginAccountHandling

    public func login(key: String, fields: [String: String]) async throws -> PluginAccountStatus {
        let rawCookie = fields["cookie"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var displayName = fields["displayName"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let authUser = fields["authUser"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let delegatedSessionID = fields["delegatedSessionID"]?.trimmingCharacters(in: .whitespacesAndNewlines)

        // When invoked via Sign In button without fields, request the interactive browser/WebView flow.
        if rawCookie.isEmpty {
            return PluginAccountStatus(
                status: "waiting",
                openURL: "https://accounts.google.com/ServiceLogin?service=youtube&continue=https%3A%2F%2Fmusic.youtube.com%2F"
            )
        }

        let parsed = YTMusicCookieHelper.parseCookies(rawCookie)
        guard YTMusicCookieHelper.hasAuthCookie(parsed) else {
            throw PluginError(
                code: .unauthorized,
                message: "Cookie header does not contain YouTube Music authentication cookies (SAPISID / __Secure-3PAPISID)."
            )
        }

        let previousSession = await tokenManager.currentUserSession()
        let resolvedAuthUser: String = {
            if let authUser, !authUser.isEmpty { return authUser }
            if let prev = previousSession?.authUser, !prev.isEmpty { return prev }
            return "0"
        }()
        let resolvedDelegated = (delegatedSessionID?.isEmpty == false)
            ? delegatedSessionID
            : previousSession?.delegatedSessionID
        if Self.needsAccountNameResolution(displayName),
           let prevName = previousSession?.displayName,
           !Self.needsAccountNameResolution(prevName) {
            displayName = prevName
        }
        let candidate = YTMusicUserSession(
            cookieHeader: rawCookie,
            displayName: displayName,
            authUser: resolvedAuthUser,
            delegatedSessionID: resolvedDelegated
        )
        if Self.needsAccountNameResolution(displayName) {
            if let fetched = await fetchAccountDisplayName(session: candidate), !fetched.isEmpty {
                displayName = fetched
            }
        }

        let resolvedSession = YTMusicUserSession(
            cookieHeader: rawCookie,
            displayName: (displayName?.isEmpty == false) ? displayName : "YouTube Music Web",
            authUser: resolvedAuthUser,
            delegatedSessionID: resolvedDelegated
        )
        await tokenManager.setUserSession(resolvedSession)
        await tokenManager.invalidateClientConfig()
        let st = await tokenManager.currentAccountStatus()
        await runtimeContext?.reportAccountStatus(st)
        return st
    }

    public func logout() async throws -> PluginAccountStatus {
        await tokenManager.clearUserSession()
        await tokenManager.invalidateClientConfig()
        let st = PluginAccountStatus(status: "signedOut")
        await runtimeContext?.reportAccountStatus(st)
        return st
    }

    public func status() async throws -> PluginAccountStatus {
        if var cur = await tokenManager.currentUserSession(),
           cur.isSignedIn,
           Self.needsAccountNameResolution(cur.displayName),
           let fetched = await fetchAccountDisplayName(session: cur),
           !fetched.isEmpty {
            cur.displayName = fetched
            await tokenManager.setUserSession(cur)
        }
        return await tokenManager.currentAccountStatus()
    }

    private static func needsAccountNameResolution(_ raw: String?) -> Bool {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty || trimmed == "YouTube Music Web" || trimmed == "Account"
    }

    private func fetchAccountDisplayName(session: YTMusicUserSession) async -> String? {
        guard let clientCfg = try? await tokenManager.getClientConfig(),
              let req = InnerTube.makeAPIRequest(
                endpoint: "account/account_menu",
                payload: ["deviceTheme": "DEVICE_THEME_SELECTED"],
                clientConfig: clientCfg,
                userAgent: config.userAgent,
                session: session
              ),
              let resp = try? await transport.send(req),
              resp.statusCode == 200,
              let json = (try? JSONSerialization.jsonObject(with: resp.body)) else {
            return nil
        }

        return YTMusicParsers.extractAccountDisplayName(from: json)
    }

    // MARK: - PlaylistSource

    public func fetch(url: URL) async throws -> PlaylistFetchResult {
        try Task.checkCancellation()
        let target = try YouTubeMusicURL.parse(url.absoluteString)
        let session = await tokenManager.currentUserSession()
        var clientCfg = try await tokenManager.getClientConfig()

        let initialData = try await sendInnerTubeWithRetry(
            endpoint: "browse",
            payload: ["browseId": target.browseID],
            clientConfig: &clientCfg,
            session: session,
            allowAnonymousRetryOnConfig: true
        )

        let firstPage: ParsedBrowsePage
        do {
            firstPage = try YTMusicParsers.parseBrowseInitial(data: initialData, target: target)
        } catch let err as PluginError where err.code == .notFound {
            if YTMusicParsers.isLoggedOutResponse(data: initialData) {
                throw PluginError(code: .unauthorized, message: "YouTube Music session expired.")
            }
            guard session?.isSignedIn == true else {
                throw err
            }
            // Refresh client config once (updates DELEGATED_SESSION_ID / SESSION_INDEX / VISITOR_DATA) and retry browse.
            var retriedPage: ParsedBrowsePage?
            await tokenManager.invalidateClientConfig()
            if var refreshedCfg = try? await tokenManager.getClientConfig(forceRefresh: true) {
                clientCfg = refreshedCfg
                if let retryData = try? await sendInnerTubeWithRetry(
                    endpoint: "browse",
                    payload: ["browseId": target.browseID],
                    clientConfig: &refreshedCfg,
                    session: session,
                    allowAnonymousRetryOnConfig: false
                ) {
                    if let parsed = try? YTMusicParsers.parseBrowseInitial(data: retryData, target: target) {
                        clientCfg = refreshedCfg
                        retriedPage = parsed
                    } else if YTMusicParsers.isLoggedOutResponse(data: retryData) {
                        throw PluginError(code: .unauthorized, message: "YouTube Music session expired.")
                    }
                }
            }
            // Final signed-in HTML check on music.youtube.com/playlist?list=... (detects expired session vs truly private/missing).
            if retriedPage == nil, let cookieHeader = session?.cookieHeader {
                let path = (target.kind == .album && target.browseID.hasPrefix("MPREb_"))
                    ? "/browse/\(target.browseID)"
                    : "/playlist?list=\(target.id)"
                let htmlReq = InnerTube.makeBrowsePageRequest(
                    path: path,
                    userAgent: config.userAgent,
                    cookieHeader: cookieHeader,
                    authUser: session?.authUser ?? clientCfg.sessionIndex,
                    delegatedSessionID: clientCfg.delegatedSessionID ?? session?.delegatedSessionID
                )
                if let htmlResp = try? await transport.send(htmlReq),
                   (200..<300).contains(htmlResp.statusCode),
                   let html = String(data: htmlResp.body, encoding: .utf8) {
                    if YTMusicParsers.isHTMLPageLoggedOut(html) {
                        throw PluginError(code: .unauthorized, message: "YouTube Music session expired.")
                    }
                    if let htmlPage = YTMusicParsers.parsePlaylistHTML(html: html, target: target) {
                        retriedPage = htmlPage
                    }
                }
            }
            guard let resolved = retriedPage else {
                throw err
            }
            firstPage = resolved
        }
        let headerInfo = YTMusicParsers.headerInfo(from: firstPage, target: target)
        var allTracks = firstPage.tracks
        var continuation = firstPage.continuationToken
        var pageCount = 1

        while let token = continuation, !token.isEmpty {
            try Task.checkCancellation()
            if pageCount >= InnerTube.maxPages {
                await runtimeContext?.log(.warning, "YouTube Music playlist reached 100 pages (10,000 tracks); truncating.")
                break
            }
            let pageData = try await sendInnerTubeWithRetry(
                endpoint: "browse",
                payload: ["continuation": token],
                clientConfig: &clientCfg,
                session: session,
                allowAnonymousRetryOnConfig: true
            )
            let nextPage = try YTMusicParsers.parseBrowseContinuation(
                data: pageData,
                target: target,
                headerInfo: headerInfo,
                trackIndexOffset: allTracks.count
            )
            allTracks.append(contentsOf: nextPage.tracks)
            continuation = nextPage.continuationToken
            pageCount += 1
        }

        let revision = YTMusicParsers.computeRevision(
            title: firstPage.title,
            trackIDs: allTracks.map(\.sourceID)
        )
        let playlist = Playlist(
            source: "youtube-music",
            sourceID: target.id,
            title: firstPage.title,
            owner: firstPage.owner,
            artworkURL: firstPage.artworkURL,
            revision: revision
        )

        if apiChangedReported {
            apiChangedReported = false
            await runtimeContext?.reportStatus(.ready, message: nil)
        }
        return PlaylistFetchResult(playlist: playlist, tracks: allTracks)
    }

    // MARK: - PlaylistReorderable

    public func reorder(request: PlaylistReorderRequest) async throws {
        try Task.checkCancellation()
        let cleanID = YouTubeMusicURL.stripVLPrefix(request.playlistID)
        guard !cleanID.isEmpty else {
            throw PluginError(code: .unsupported, message: "Missing YouTube Music playlist ID.")
        }

        let session = try await tokenManager.requireUserSession()
        var clientCfg = try await tokenManager.getClientConfig()

        // InnerTube ACTION_MOVE_VIDEO_BEFORE needs exact `setVideoId`s and (when not moving to end) the successor `setVideoId`.
        let needsFetchForUIDs = request.movedItemUIDs.isEmpty
            || (request.beforeItemUID == nil && !request.atEnd)
        let fetched: PlaylistFetchResult? = needsFetchForUIDs
            ? (try? await fetch(url: URL(string: "https://music.youtube.com/playlist?list=\(cleanID)")!))
            : nil
        let fetchedUIDs = fetched?.tracks.compactMap(\.remoteItemUID) ?? []

        var movedUIDs = request.movedItemUIDs
        if movedUIDs.isEmpty, let tracks = fetched?.tracks,
           request.rangeStart >= 0,
           request.rangeStart + request.rangeLength <= tracks.count {
            movedUIDs = Array(tracks[request.rangeStart..<(request.rangeStart + request.rangeLength)]).compactMap(\.remoteItemUID)
        }
        guard !movedUIDs.isEmpty else {
            throw PluginError(code: .unsupported, message: "Could not resolve playlist item IDs to reorder on YouTube Music.")
        }

        let movedSet = Set(movedUIDs)
        var successorUID: String? = request.beforeItemUID
        if successorUID == nil && request.atStart {
            successorUID = fetchedUIDs.first(where: { !movedSet.contains($0) })
        } else if request.atEnd {
            successorUID = nil
        }

        var actions: [[String: Any]] = []
        for uid in movedUIDs {
            var act: [String: Any] = [
                "action": "ACTION_MOVE_VIDEO_BEFORE",
                "setVideoId": uid,
            ]
            if let successorUID, !successorUID.isEmpty {
                act["movedSetVideoIdSuccessor"] = successorUID
            }
            actions.append(act)
        }

        try await sendEditPlaylist(
            playlistID: cleanID,
            actions: actions,
            clientConfig: &clientCfg,
            session: session,
            failureMessage: "Order changed manually (local only). Only playlists that you own can be modified on YouTube Music."
        )
    }

    // MARK: - PlaylistEditable

    /// Searches YouTube Music for each input track in bounded parallel workers and appends via `ACTION_ADD_VIDEO`.
    public func addTracks(request: PlaylistAddTracksRequest) async throws -> PlaylistAddTracksResult {
        try Task.checkCancellation()
        let cleanID = YouTubeMusicURL.stripVLPrefix(request.playlistID)
        guard !cleanID.isEmpty else {
            throw PluginError(code: .unsupported, message: "Missing YouTube Music playlist ID.")
        }
        guard !request.tracks.isEmpty else {
            return PlaylistAddTracksResult(added: [], notFoundTitles: [])
        }

        let session = try await tokenManager.requireUserSession()
        var clientCfg = try await tokenManager.getClientConfig()

        let tracks = request.tracks
        let maxWorkers = min(min(4, max(1, ProcessInfo.processInfo.activeProcessorCount)), tracks.count)
        var matchesByIndex = [TrackRef?](repeating: nil, count: tracks.count)

        let cfgSnapshot = clientCfg
        try await withThrowingTaskGroup(of: (Int, TrackRef?).self) { group in
            var nextIndex = 0
            for _ in 0..<maxWorkers {
                let idx = nextIndex
                nextIndex += 1
                let input = tracks[idx]
                group.addTask {
                    let match = try await self.searchBestTrack(input: input, clientConfig: cfgSnapshot, session: session)
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
                        let nextMatch = try await self.searchBestTrack(input: input, clientConfig: cfgSnapshot, session: session)
                        return (idxToQueue, nextMatch)
                    }
                }
            }
        }

        var added: [PlaylistAddedTrackResult] = []
        var actions: [[String: Any]] = []
        var notFound: [String] = []
        for (index, input) in tracks.enumerated() {
            if let match = matchesByIndex[index], !match.sourceID.isEmpty {
                added.append(PlaylistAddedTrackResult(index: index, matchedTrack: match))
                actions.append([
                    "action": "ACTION_ADD_VIDEO",
                    "addedVideoId": match.sourceID,
                ])
            } else {
                notFound.append(input.title)
            }
        }

        guard !actions.isEmpty else {
            throw PluginError(code: .notFound, message: "Could not find matching tracks on YouTube Music.")
        }

        var cursor = 0
        var assignedSetIDs: [String] = []
        while cursor < actions.count {
            let chunk = Array(actions[cursor..<min(cursor + 50, actions.count)])
            cursor += chunk.count
            let respJSON = try await sendEditPlaylist(
                playlistID: cleanID,
                actions: chunk,
                clientConfig: &clientCfg,
                session: session,
                failureMessage: "Only playlists that you own can be modified on YouTube Music."
            )
            if let results = respJSON["playlistEditResults"] as? [[String: Any]] {
                for r in results {
                    if let addedData = r["playlistEditVideoAddedResultData"] as? [String: Any],
                       let setID = addedData["setVideoId"] as? String {
                        assignedSetIDs.append(setID)
                    }
                }
            }
        }

        if assignedSetIDs.count == added.count {
            for i in added.indices {
                added[i].matchedTrack.remoteItemUID = assignedSetIDs[i]
            }
        }

        return PlaylistAddTracksResult(added: added, notFoundTitles: notFound)
    }

    public func removeTracks(request: PlaylistRemoveTracksRequest) async throws {
        try Task.checkCancellation()
        let cleanID = YouTubeMusicURL.stripVLPrefix(request.playlistID)
        guard !cleanID.isEmpty else {
            throw PluginError(code: .unsupported, message: "Missing YouTube Music playlist ID.")
        }

        let cleanIDs = request.trackIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !cleanIDs.isEmpty else { return }

        let session = try await tokenManager.requireUserSession()
        var clientCfg = try await tokenManager.getClientConfig()

        var pairs: [(videoID: String, setVideoID: String)] = []
        if request.itemUIDs.count == cleanIDs.count && !request.itemUIDs.contains(where: { $0.isEmpty }) {
            pairs = zip(cleanIDs, request.itemUIDs).map { ($0.0, $0.1) }
        } else {
            // Resolve missing `setVideoId`s on demand via a browse call.
            let fetched = try await fetch(url: URL(string: "https://music.youtube.com/playlist?list=\(cleanID)")!)
            var availableByVideo: [String: [String]] = [:]
            for t in fetched.tracks {
                if let uid = t.remoteItemUID, !uid.isEmpty {
                    availableByVideo[t.sourceID, default: []].append(uid)
                }
            }
            for (idx, vid) in cleanIDs.enumerated() {
                if idx < request.itemUIDs.count, !request.itemUIDs[idx].isEmpty {
                    pairs.append((vid, request.itemUIDs[idx]))
                } else if var queue = availableByVideo[vid], !queue.isEmpty {
                    let uid = queue.removeFirst()
                    availableByVideo[vid] = queue
                    pairs.append((vid, uid))
                }
            }
        }

        guard !pairs.isEmpty else {
            throw PluginError(code: .notFound, message: "Could not match tracks to remove from YouTube Music playlist.")
        }

        var cursor = 0
        while cursor < pairs.count {
            let chunk = Array(pairs[cursor..<min(cursor + 50, pairs.count)])
            cursor += chunk.count
            let actions: [[String: Any]] = chunk.map { pair in
                [
                    "action": "ACTION_REMOVE_VIDEO",
                    "removedVideoId": pair.videoID,
                    "setVideoId": pair.setVideoID,
                ]
            }
            try await sendEditPlaylist(
                playlistID: cleanID,
                actions: actions,
                clientConfig: &clientCfg,
                session: session,
                failureMessage: "Only playlists that you own can be modified on YouTube Music."
            )
        }
    }

    public func renamePlaylist(request: PlaylistRenameRequest) async throws {
        try Task.checkCancellation()
        let cleanID = YouTubeMusicURL.stripVLPrefix(request.playlistID)
        let trimmed = request.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanID.isEmpty, !trimmed.isEmpty else {
            throw PluginError(code: .unsupported, message: "Playlist name cannot be empty.")
        }

        let session = try await tokenManager.requireUserSession()
        var clientCfg = try await tokenManager.getClientConfig()

        try await sendEditPlaylist(
            playlistID: cleanID,
            actions: [[
                "action": "ACTION_SET_PLAYLIST_NAME",
                "playlistName": trimmed,
            ]],
            clientConfig: &clientCfg,
            session: session,
            failureMessage: "Only playlists that you own can be renamed on YouTube Music."
        )
    }

    public func createPlaylist(request: PlaylistCreateRequest) async throws -> PlaylistCreateResult {
        try Task.checkCancellation()
        let trimmed = request.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw PluginError(code: .unsupported, message: "Playlist name cannot be empty.")
        }

        let session = try await tokenManager.requireUserSession()
        var clientCfg = try await tokenManager.getClientConfig()

        var payload: [String: Any] = [
            "title": trimmed,
            "privacyStatus": "PRIVATE",
        ]
        if let desc = request.description?.trimmingCharacters(in: .whitespacesAndNewlines), !desc.isEmpty {
            payload["description"] = desc
        }

        let data = try await sendInnerTubeWithRetry(
            endpoint: "playlist/create",
            payload: payload,
            clientConfig: &clientCfg,
            session: session,
            allowAnonymousRetryOnConfig: false
        )

        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let playlistID = json["playlistId"] as? String, !playlistID.isEmpty else {
            throw PluginError(code: .apiChanged, message: "YouTube Music did not return a created playlist ID.")
        }

        let cleanID = YouTubeMusicURL.stripVLPrefix(playlistID)
        let playlist = Playlist(
            source: "youtube-music",
            sourceID: cleanID,
            title: trimmed,
            owner: session.displayName,
            artworkURL: nil,
            revision: YTMusicParsers.computeRevision(title: trimmed, trackIDs: [])
        )
        let webURL = URL(string: "https://music.youtube.com/playlist?list=\(cleanID)")!
        return PlaylistCreateResult(playlist: playlist, url: webURL)
    }

    public func setPlaylistArtwork(request: PlaylistArtworkRequest) async throws {
        try Task.checkCancellation()
        let cleanID = YouTubeMusicURL.stripVLPrefix(request.playlistID)
        guard !cleanID.isEmpty else {
            throw PluginError(code: .unsupported, message: "Missing YouTube Music playlist ID.")
        }
        guard let jpegData = request.jpegData, !jpegData.isEmpty else {
            throw PluginError(code: .unsupported, message: "YouTube Music requires an image to update playlist cover art.")
        }

        let session = try await tokenManager.requireUserSession()
        var clientCfg = try await tokenManager.getClientConfig()

        guard let startReq = InnerTube.makeUploadStartRequest(
            byteCount: jpegData.count,
            clientConfig: clientCfg,
            userAgent: config.userAgent,
            session: session
        ) else {
            throw PluginError(code: .internal, message: "Failed to construct YouTube Music upload request.")
        }

        let startResp = try await transport.send(startReq)
        if startResp.statusCode == 403 {
            throw PluginError(
                code: .unsupported,
                message: "YouTube requires verifying your phone number before adding custom playlist covers (youtube.com/verify)."
            )
        }
        try checkWriteHTTPStatus(startResp, operation: "uploading playlist cover")
        guard let uploadURLString = startResp.headerValue("X-Goog-Upload-URL"),
              let uploadSessionURL = URL(string: uploadURLString) else {
            throw PluginError(
                code: .unsupported,
                message: "YouTube Music rejected custom cover upload. Verify your phone number on YouTube first (youtube.com/verify), then try again."
            )
        }

        let finalizeReq = InnerTube.makeUploadFinalizeRequest(
            uploadSessionURL: uploadSessionURL,
            jpegData: jpegData,
            userAgent: config.userAgent,
            session: session
        )
        let finalizeResp = try await transport.send(finalizeReq)
        if finalizeResp.statusCode == 403 {
            throw PluginError(
                code: .unsupported,
                message: "YouTube requires verifying your phone number before adding custom playlist covers (youtube.com/verify)."
            )
        }
        try checkWriteHTTPStatus(finalizeResp, operation: "finalizing playlist cover")

        guard let finalizeJSON = (try? JSONSerialization.jsonObject(with: finalizeResp.body)) as? [String: Any],
              let blobID = (finalizeJSON["encryptedBlobId"] as? String)
                ?? (finalizeJSON["playlistScottyEncryptedBlobId"] as? String),
              !blobID.isEmpty else {
            throw PluginError(code: .apiChanged, message: "YouTube Music did not return a cover blob identifier.")
        }

        try await sendEditPlaylist(
            playlistID: cleanID,
            actions: [[
                "action": "ACTION_SET_CUSTOM_THUMBNAIL",
                "addedCustomThumbnail": [
                    "playlistScottyEncryptedBlobId": blobID,
                ],
            ]],
            clientConfig: &clientCfg,
            session: session,
            failureMessage: "Only playlists that you own on a phone-verified YouTube account can use custom covers (youtube.com/verify)."
        )
    }

    // MARK: - PlaylistBrowsable

    public func listUserPlaylists() async throws -> [RemotePlaylistSummary] {
        try Task.checkCancellation()
        let session = try await tokenManager.requireUserSession()
        var clientCfg = try await tokenManager.getClientConfig()
        let displayName = session.displayName

        var collected: [RemotePlaylistSummary] = []
        var seenIDs = Set<String>()

        func appendBrowseFeed(browseID: String, requireAuthenticated: Bool) async throws {
            let initialData = try await sendInnerTubeWithRetry(
                endpoint: "browse",
                payload: ["browseId": browseID],
                clientConfig: &clientCfg,
                session: session,
                allowAnonymousRetryOnConfig: false
            )
            if YTMusicParsers.isLoggedOutResponse(data: initialData) {
                if requireAuthenticated {
                    throw PluginError(code: .unauthorized, message: "YouTube Music session expired.")
                }
                return
            }

            let firstPage = try YTMusicParsers.parseUserPlaylistsInitial(data: initialData, currentDisplayName: displayName)
            for item in firstPage.playlists where seenIDs.insert(item.id).inserted {
                collected.append(item)
            }

            var continuation = firstPage.continuationToken
            var pageCount = 1
            while let token = continuation, !token.isEmpty, pageCount < 20 {
                try Task.checkCancellation()
                pageCount += 1
                let pageData = try await sendInnerTubeWithRetry(
                    endpoint: "browse",
                    payload: ["continuation": token],
                    clientConfig: &clientCfg,
                    session: session,
                    allowAnonymousRetryOnConfig: false
                )
                let nextPage = try YTMusicParsers.parseUserPlaylistsContinuation(data: pageData, currentDisplayName: displayName)
                for item in nextPage.playlists where seenIDs.insert(item.id).inserted {
                    collected.append(item)
                }
                continuation = nextPage.continuationToken
            }
        }

        try await appendBrowseFeed(browseID: "FEmusic_liked_playlists", requireAuthenticated: true)

        if collected.isEmpty || !seenIDs.contains("LM") {
            try? await appendBrowseFeed(browseID: "FEmusic_library_landing", requireAuthenticated: false)
        }

        // Also inspect https://music.youtube.com/library/playlists HTML directly when InnerTube misses items or delegated channel info.
        var htmlSawLoggedOut = false
        if (collected.isEmpty || !seenIDs.contains("LM")), let cookieHeader = session.cookieHeader {
            let htmlReq = InnerTube.makeBrowsePageRequest(
                path: "/library/playlists",
                userAgent: config.userAgent,
                cookieHeader: cookieHeader,
                authUser: session.authUser ?? clientCfg.sessionIndex,
                delegatedSessionID: clientCfg.delegatedSessionID ?? session.delegatedSessionID
            )
            if let htmlResp = try? await transport.send(htmlReq),
               (200..<300).contains(htmlResp.statusCode),
               let html = String(data: htmlResp.body, encoding: .utf8) {
                htmlSawLoggedOut = YTMusicParsers.isHTMLPageLoggedOut(html)
                if let pageCfg = try? InnerTube.extractClientConfig(fromHTML: html, fallbackClientVersion: config.clientVersion) {
                    var updatedCfg = false
                    if clientCfg.delegatedSessionID == nil, let del = pageCfg.delegatedSessionID {
                        clientCfg.delegatedSessionID = del
                        updatedCfg = true
                    }
                    if clientCfg.sessionIndex == nil, let idx = pageCfg.sessionIndex {
                        clientCfg.sessionIndex = idx
                        updatedCfg = true
                    }
                    if let loggedIn = pageCfg.loggedIn {
                        clientCfg.loggedIn = loggedIn
                    }
                    if updatedCfg && collected.isEmpty {
                        try? await appendBrowseFeed(browseID: "FEmusic_liked_playlists", requireAuthenticated: false)
                    }
                }
                if let htmlPage = YTMusicParsers.parseLibraryHTMLPlaylists(html: html, currentDisplayName: displayName) {
                    for item in htmlPage.playlists where seenIDs.insert(item.id).inserted {
                        collected.append(item)
                    }
                }
            }
        }

        // Always include the user's "Liked Music" auto-playlist (`list=LM` / `VLLM`) and enrich its track count.
        if !seenIDs.contains("LM") || collected.first(where: { $0.id == "LM" })?.trackCount == nil {
            for likesBrowseID in ["VLLM", "FEmusic_liked_videos"] {
                guard let likesData = try? await sendInnerTubeWithRetry(
                    endpoint: "browse",
                    payload: ["browseId": likesBrowseID],
                    clientConfig: &clientCfg,
                    session: session,
                    allowAnonymousRetryOnConfig: false
                ),
                let likesSummary = YTMusicParsers.parseLikedMusicSummary(data: likesData, currentDisplayName: displayName) else {
                    continue
                }
                if let idx = collected.firstIndex(where: { $0.id == "LM" }) {
                    if collected[idx].trackCount == nil { collected[idx].trackCount = likesSummary.trackCount }
                    if collected[idx].artworkURL == nil { collected[idx].artworkURL = likesSummary.artworkURL }
                    collected[idx].isLikedSongs = true
                    collected[idx].isOwned = true
                } else {
                    seenIDs.insert(likesSummary.id)
                    collected.insert(likesSummary, at: 0)
                }
                break
            }
        }

        if collected.isEmpty && (clientCfg.loggedIn == false || htmlSawLoggedOut) {
            throw PluginError(code: .unauthorized, message: "YouTube Music session expired.")
        }

        // Enrich playlists missing track count or ownership (bounded parallel browse, max 12).
        let enrichTargets = collected.indices.filter {
            !collected[$0].isLikedSongs && (collected[$0].trackCount == nil || collected[$0].isOwned == nil)
        }.prefix(12)
        if !enrichTargets.isEmpty {
            let pairs = enrichTargets.map { ($0, collected[$0].id) }
            let cfgSnapshot = clientCfg
            let maxWorkers = min(min(6, max(1, ProcessInfo.processInfo.activeProcessorCount)), pairs.count)
            var updates: [(Int, RemotePlaylistSummary)] = []
            await withTaskGroup(of: (Int, RemotePlaylistSummary)?.self) { group in
                var cursor = 0
                func submit(_ pair: (Int, String)) {
                    let (idx, pid) = pair
                    group.addTask {
                        var localCfg = cfgSnapshot
                        guard let data = try? await self.sendInnerTubeWithRetry(
                            endpoint: "browse",
                            payload: ["browseId": "VL\(pid)"],
                            clientConfig: &localCfg,
                            session: session,
                            allowAnonymousRetryOnConfig: false
                        ),
                        let summary = YTMusicParsers.parsePlaylistSummaryFromBrowse(id: pid, data: data, currentDisplayName: displayName) else {
                            return nil
                        }
                        return (idx, summary)
                    }
                }
                for _ in 0..<maxWorkers {
                    submit(pairs[cursor])
                    cursor += 1
                }
                for await res in group {
                    if let res { updates.append(res) }
                    if cursor < pairs.count {
                        submit(pairs[cursor])
                        cursor += 1
                    }
                }
            }
            for (idx, enriched) in updates {
                if collected[idx].trackCount == nil { collected[idx].trackCount = enriched.trackCount }
                if collected[idx].isOwned == nil { collected[idx].isOwned = enriched.isOwned }
                if collected[idx].owner == nil { collected[idx].owner = enriched.owner }
            }
        }

        await runtimeContext?.log(.info, "YouTube Music listUserPlaylists found \(collected.count) playlists.")
        return RemotePlaylistSummary.sortedForDisplay(collected)
    }

    // MARK: - Search & InnerTube Helpers

    private func searchBestTrack(
        input: PlaylistAddTrackInput,
        clientConfig: InnerTubeClientConfig,
        session: YTMusicUserSession
    ) async throws -> TrackRef? {
        try Task.checkCancellation()
        var cfg = clientConfig
        let rawQuery = [input.title, input.artist]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !rawQuery.isEmpty else { return nil }

        // First search filtered to YouTube Music Songs; fall back to unfiltered search if needed.
        for params in [InnerTube.songsSearchParams, nil] as [String?] {
            var payload: [String: Any] = ["query": rawQuery]
            if let params { payload["params"] = params }
            let data = try await sendInnerTubeWithRetry(
                endpoint: "search",
                payload: payload,
                clientConfig: &cfg,
                session: session,
                allowAnonymousRetryOnConfig: true
            )
            let candidates = (try? YTMusicParsers.parseSearchTracks(data: data)) ?? []
            if let best = YTMusicParsers.selectBestMatch(candidates: candidates, input: input) {
                return best
            }
        }
        return nil
    }

    @discardableResult
    private func sendEditPlaylist(
        playlistID: String,
        actions: [[String: Any]],
        clientConfig: inout InnerTubeClientConfig,
        session: YTMusicUserSession,
        failureMessage: String
    ) async throws -> [String: Any] {
        let data = try await sendInnerTubeWithRetry(
            endpoint: "browse/edit_playlist",
            payload: [
                "playlistId": playlistID,
                "actions": actions,
            ],
            clientConfig: &clientConfig,
            session: session,
            allowAnonymousRetryOnConfig: false
        )
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw PluginError(code: .apiChanged, message: "YouTube Music edit_playlist returned invalid JSON.")
        }
        if let status = json["status"] as? String,
           status.localizedCaseInsensitiveContains("FAILED") {
            throw PluginError(code: .unsupported, message: failureMessage)
        }
        return json
    }

    private func sendInnerTubeWithRetry(
        endpoint: String,
        payload: [String: Any],
        clientConfig: inout InnerTubeClientConfig,
        session: YTMusicUserSession?,
        allowAnonymousRetryOnConfig: Bool
    ) async throws -> Data {
        var didRefreshConfig = false
        for attempt in 0..<3 {
            try Task.checkCancellation()
            guard let req = InnerTube.makeAPIRequest(
                endpoint: endpoint,
                payload: payload,
                clientConfig: clientConfig,
                userAgent: config.userAgent,
                session: session
            ) else {
                throw PluginError(code: .internal, message: "Failed to build YouTube Music request for \(endpoint).")
            }

            let response = try await transport.send(req)
            if (200..<300).contains(response.statusCode) {
                return response.body
            }

            if response.statusCode == 429 {
                let retryAfter = min(30, max(1, response.headerValue("Retry-After").flatMap(Int.init) ?? 2))
                if attempt < 2 {
                    try await Task.sleep(nanoseconds: UInt64(retryAfter) * 1_000_000_000)
                    continue
                }
                throw PluginError(code: .rateLimited, message: "YouTube Music is limiting requests.", retryAfterSeconds: retryAfter)
            }

            if response.statusCode == 401 || response.statusCode == 403 {
                if allowAnonymousRetryOnConfig && !didRefreshConfig {
                    didRefreshConfig = true
                    await tokenManager.invalidateClientConfig()
                    clientConfig = try await tokenManager.getClientConfig(forceRefresh: true)
                    continue
                }
                if response.statusCode == 401 {
                    throw PluginError(code: .unauthorized, message: "YouTube Music session expired.")
                }
                throw PluginError(
                    code: .unsupported,
                    message: "Only playlists that you own can be modified on YouTube Music."
                )
            }

            if response.statusCode == 404 {
                throw PluginError(code: .notFound, message: "This playlist doesn't exist or is private.")
            }

            throw PluginError(code: .network, message: "YouTube Music \(endpoint) returned HTTP \(response.statusCode).")
        }
        throw PluginError(code: .network, message: "YouTube Music \(endpoint) failed after retries.")
    }

    private func checkWriteHTTPStatus(_ response: HTTPResponseData, operation: String) throws {
        if (200..<300).contains(response.statusCode) { return }
        if response.statusCode == 401 {
            throw PluginError(code: .unauthorized, message: "YouTube Music session expired while \(operation).")
        }
        if response.statusCode == 403 {
            throw PluginError(code: .unsupported, message: "Permission denied while \(operation) on YouTube Music.")
        }
        if response.statusCode == 429 {
            let retry = min(30, max(1, response.headerValue("Retry-After").flatMap(Int.init) ?? 15))
            throw PluginError(code: .rateLimited, message: "YouTube Music is limiting requests.", retryAfterSeconds: retry)
        }
        throw PluginError(code: .network, message: "YouTube Music returned HTTP \(response.statusCode) while \(operation).")
    }

    private func markAPIChanged(_ msg: String) async {
        apiChangedReported = true
        await runtimeContext?.reportStatus(.error, message: msg)
    }
}
