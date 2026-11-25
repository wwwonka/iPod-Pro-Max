import XCTest
import PluginKit
@testable import SpotifyPlugin
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class SpotifyPluginTests: XCTestCase {
    private static func repoRoot(file: String = #filePath) -> URL {
        URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    // MARK: - SPO-1: Manifest & urlPatterns

    func testSpotifyManifestURLPatternsAndConfig() throws {
        let pluginFolder = Self.repoRoot().appendingPathComponent("Plug-ins/Spotify", isDirectory: true)
        let manifestURL = pluginFolder.appendingPathComponent("plugin.json")
        let validated = try ManifestValidator.loadAndValidate(from: manifestURL)
        let manifest = validated.manifest

        XCTAssertEqual(manifest.id, "spotify")
        XCTAssertEqual(manifest.knownRoles, [.playlistSource])
        XCTAssertEqual(manifest.requiresConsent, .scraping)
        XCTAssertNotNil(manifest.config?["userAgent"]?.stringValue)
        XCTAssertNotNil(manifest.config?["pathfinder"]?.objectValue?["fetchPlaylist"]?.objectValue?["sha256"]?.stringValue)
        XCTAssertNotNil(manifest.config?["pathfinder"]?.objectValue?["getAlbum"]?.objectValue?["sha256"]?.stringValue)

        let accepted = [
            "https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M",
            "https://open.spotify.com/album/4aawyAB9vmqN3uQ7FjRGTy?si=xyz123",
            "https://open.spotify.com/intl-fr/playlist/37i9dQZF1DXcBWIGoYBM5M?pi=abc",
            "https://open.spotify.com/intl-pt-BR/album/4aawyAB9vmqN3uQ7FjRGTy",
            "https://play.spotify.com/embed/playlist/37i9dQZF1DXcBWIGoYBM5M",
            "open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M",
            "spotify:playlist:37i9dQZF1DXcBWIGoYBM5M",
            "spotify:album:4aawyAB9vmqN3uQ7FjRGTy",
        ]
        for url in accepted {
            XCTAssertTrue(manifest.matchesURL(url), "Expected manifest urlPatterns to accept '\(url)'")
        }

        let rejected = [
            "https://open.spotify.com/track/4cOdK2wGLETKBW3PvgPWqT",
            "https://open.spotify.com/artist/0TnOYISbd1XYRBk9myaseg",
            "https://open.spotify.com/episode/512ojhOuo1ktJprKbVcKyQ",
            "https://open.spotify.com/show/4rOoJ6Egrf8K2IrywzwOMk",
            "spotify:track:4cOdK2wGLETKBW3PvgPWqT",
            "https://spotify.link/short123",
            "https://spoti.fi/short123",
            "https://open.spotify.com/playlist/tooShort",
            "https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5Mextra",
        ]
        for url in rejected {
            XCTAssertFalse(manifest.matchesURL(url), "Expected manifest urlPatterns to reject '\(url)'")
        }
    }

    // MARK: - SPO-2: SpotifyURL Parser

    func testSpotifyURLParsing() throws {
        XCTAssertEqual(
            try SpotifyURL.parse("https://open.spotify.com/intl-fr/playlist/37i9dQZF1DXcBWIGoYBM5M?si=123"),
            SpotifyTarget(kind: .playlist, id: "37i9dQZF1DXcBWIGoYBM5M")
        )
        XCTAssertEqual(
            try SpotifyURL.parse("open.spotify.com/embed/album/4aawyAB9vmqN3uQ7FjRGTy"),
            SpotifyTarget(kind: .album, id: "4aawyAB9vmqN3uQ7FjRGTy")
        )
        XCTAssertEqual(
            try SpotifyURL.parse("spotify:playlist:37i9dQZF1DXcBWIGoYBM5M"),
            SpotifyTarget(kind: .playlist, id: "37i9dQZF1DXcBWIGoYBM5M")
        )
        XCTAssertEqual(
            try SpotifyURL.parse("spotify:album:4aawyAB9vmqN3uQ7FjRGTy"),
            SpotifyTarget(kind: .album, id: "4aawyAB9vmqN3uQ7FjRGTy")
        )

        for bad in [
            "https://open.spotify.com/track/4cOdK2wGLETKBW3PvgPWqT",
            "https://spotify.link/abc123",
            "https://open.spotify.com/playlist/invalid_id_len",
            "",
        ] {
            XCTAssertThrowsError(try SpotifyURL.parse(bad))
        }
    }

    // MARK: - SPO-3: TokenManager

    func testTokenManagerExtractionCoalescingAndExpiry() async throws {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let validHTML = Self.makeEmbedHTML(token: "anon-tok-1", expiresAtMs: nowMs + 300_000)

        let transport = MockHTTPTransport { request in
            XCTAssertTrue(request.url?.absoluteString.contains("open.spotify.com/embed/playlist/") == true)
            try? await Task.sleep(nanoseconds: 40_000_000)
            return HTTPResponseData(statusCode: 200, body: Data(validHTML.utf8))
        }

        let manager = TokenManager(transport: transport)
        // 5 concurrent callers share a single bootstrap HTTP request
        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<5 {
                group.addTask { try await manager.getToken(preferredPlaylistID: "37i9dQZF1DXcBWIGoYBM5M") }
            }
            var out: [String] = []
            for try await t in group { out.append(t) }
            return out
        }
        XCTAssertEqual(Set(tokens), ["anon-tok-1"])
        XCTAssertEqual(transport.callCount, 1)

        // Expiring token (<60s remaining) triggers clean refresh on next call
        let nearExpiryHTML = Self.makeEmbedHTML(token: "short-tok", expiresAtMs: nowMs + 30_000)
        let refreshedHTML = Self.makeEmbedHTML(token: "fresh-tok", expiresAtMs: nowMs + 600_000)
        let sequenceTransport = SequenceMockTransport(responses: [
            HTTPResponseData(statusCode: 200, body: Data(nearExpiryHTML.utf8)),
            HTTPResponseData(statusCode: 200, body: Data(refreshedHTML.utf8)),
        ])
        let m2 = TokenManager(transport: sequenceTransport)
        let first = try await m2.getToken()
        XCTAssertEqual(first, "short-tok")
        let second = try await m2.getToken()
        XCTAssertEqual(second, "fresh-tok")

        // Missing JSON path logs exact failing path
        do {
            _ = try TokenManager.extractSession(fromHTML: "<script id=\"__NEXT_DATA__\" type=\"application/json\">{\"props\":{}}</script>")
            XCTFail("Expected EmbedParsingFailure")
        } catch let fail as TokenManager.EmbedParsingFailure {
            XCTAssertTrue(fail.logDetail.contains("props.pageProps"))
        }
    }

    // MARK: - SPO-4, 5, 6, 7, 8: Playlist Pagination, 401 Retry, Parsing, Revision & API Errors

    func testSpotifySourceFetchPagination401AndRevision() async throws {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let embedHTML = Self.makeEmbedHTML(token: "tok-initial", expiresAtMs: nowMs + 300_000)
        let embedHTMLRefreshed = Self.makeEmbedHTML(token: "tok-refreshed", expiresAtMs: nowMs + 300_000)

        let page1JSON = Self.makePlaylistPageJSON(
            title: "My Mix",
            uri: "spotify:playlist:37i9dQZF1DXcBWIGoYBM5M",
            owner: "Julien",
            tracks: [
                (id: "4cOdK2wGLETKBW3PvgPWqT", name: "Track One", artist: "Artist A", duration: 180_000, playable: true, explicit: true),
                (id: "0VjIjW4GlUZAMYd2vXMi3b", name: "Track Two (Unplayable)", artist: "Artist B", duration: 200_000, playable: false, explicit: false),
            ],
            includeEpisodeAndLocal: true,
            nextOffset: 100
        )
        let page2JSON = Self.makePlaylistPageJSON(
            title: "My Mix",
            uri: "spotify:playlist:37i9dQZF1DXcBWIGoYBM5M",
            owner: "Julien",
            tracks: [
                // Duplicate of Track One intentionally preserved in order!
                (id: "4cOdK2wGLETKBW3PvgPWqT", name: "Track One", artist: "Artist A", duration: 180_000, playable: true, explicit: true),
            ],
            includeEpisodeAndLocal: false,
            nextOffset: nil
        )

        let pathfinderCalls = SendableCounter()
        let transport = MockHTTPTransport { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("open.spotify.com/embed/") {
                let html = pathfinderCalls.value == 0 ? embedHTML : embedHTMLRefreshed
                return HTTPResponseData(statusCode: 200, body: Data(html.utf8))
            }
            let callIndex = pathfinderCalls.increment()
            if callIndex == 1 {
                // Simulate initial 401 forcing single re-bootstrap
                return HTTPResponseData(statusCode: 401, body: Data())
            }
            if url.contains("%22offset%22:100") || url.contains("\"offset\":100") {
                return HTTPResponseData(statusCode: 200, body: Data(page2JSON.utf8))
            }
            return HTTPResponseData(statusCode: 200, body: Data(page1JSON.utf8))
        }

        let source = SpotifySource(transport: transport)
        let recorder = TestRuntimeRecorder()
        try await source.initialize(
            params: PluginInitializeParams(
                host: .current(),
                paths: PluginPaths(data: "/tmp", cache: "/tmp", temp: "/tmp")
            ),
            context: recorder
        )

        let res = try await source.fetch(url: URL(string: "https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M")!)
        XCTAssertEqual(res.playlist.title, "My Mix")
        XCTAssertEqual(res.playlist.owner, "Julien")
        XCTAssertEqual(res.playlist.sourceID, "37i9dQZF1DXcBWIGoYBM5M")
        XCTAssertEqual(res.tracks.count, 3) // episode + local skipped, duplicate & unplayable included
        XCTAssertEqual(res.tracks.map(\.sourceID), [
            "4cOdK2wGLETKBW3PvgPWqT",
            "0VjIjW4GlUZAMYd2vXMi3b",
            "4cOdK2wGLETKBW3PvgPWqT",
        ])
        XCTAssertEqual(res.tracks[0].explicit, true)
        XCTAssertEqual(res.tracks[0].releaseDate, "2020-03-20")
        XCTAssertEqual(res.tracks[0].artworkURL?.absoluteString, "https://i.scdn.co/image/large640")
        XCTAssertEqual(recorder.warnings.count, 1) // unplayable track logged!

        let expectedRevision = SpotifyParsers.computeRevision(
            title: "My Mix",
            trackIDs: res.tracks.map(\.sourceID)
        )
        XCTAssertEqual(res.playlist.revision, expectedRevision)
        XCTAssertEqual(res.playlist.revision.count, 64)
    }

    func testSpotifyPersistedQueryNotFoundTriggersAPIChangedAndStatus() async throws {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let embedHTML = Self.makeEmbedHTML(token: "tok", expiresAtMs: nowMs + 300_000)
        let errJSON = #"{"errors":[{"message":"PersistedQueryNotFound"}]}"#

        let transport = MockHTTPTransport { request in
            if request.url?.absoluteString.contains("embed/") == true {
                return HTTPResponseData(statusCode: 200, body: Data(embedHTML.utf8))
            }
            return HTTPResponseData(statusCode: 200, body: Data(errJSON.utf8))
        }

        let source = SpotifySource(transport: transport)
        let recorder = TestRuntimeRecorder()
        try await source.initialize(
            params: PluginInitializeParams(
                host: .current(),
                paths: PluginPaths(data: "/tmp", cache: "/tmp", temp: "/tmp")
            ),
            context: recorder
        )

        do {
            _ = try await source.fetch(url: URL(string: "https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M")!)
            XCTFail("Expected apiChanged")
        } catch let pErr as PluginError {
            XCTAssertEqual(pErr.code, .apiChanged)
            XCTAssertEqual(pErr.message, SpotifyMessages.apiChanged)
        }
        XCTAssertEqual(recorder.statuses.last?.state, .error)
        XCTAssertEqual(recorder.statuses.last?.message, SpotifyMessages.apiChanged)
    }

    // MARK: - SPO-10: Offline CLI Conformance Check

    func testSpotifyPluginOfflineConformance() async throws {
        let pluginFolder = Self.repoRoot().appendingPathComponent("Plug-ins/Spotify", isDirectory: true)
        let validated = try ManifestValidator.loadAndValidate(from: pluginFolder.appendingPathComponent("plugin.json"))
        guard let execRel = validated.executableRelativePath,
              FileManager.default.isExecutableFile(atPath: pluginFolder.appendingPathComponent(execRel).path) else {
            throw XCTSkip("Spotify plug-in binary not staged at \(validated.executableRelativePath ?? "")")
        }

        let report = await PluginCLI.runConformanceTests(folderURL: pluginFolder, offline: true)
        for check in report.results {
            XCTAssertTrue(check.passed, "Check '\(check.name)' failed: \(check.detail)")
        }
        XCTAssertTrue(report.allPassed)
    }

    // MARK: - Opt-in Live Network Test

    func testLivePublicPlaylistWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["IPPM_LIVE_SPOTIFY_TESTS"] == "1" else {
            throw XCTSkip("Live Spotify network test disabled (set IPPM_LIVE_SPOTIFY_TESTS=1 to run)")
        }
        let source = SpotifySource()
        let recorder = TestRuntimeRecorder()
        try await source.initialize(
            params: PluginInitializeParams(
                host: .current(),
                paths: PluginPaths(data: "/tmp", cache: "/tmp", temp: "/tmp")
            ),
            context: recorder
        )
        let res = try await source.fetch(url: URL(string: "https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M")!)
        XCTAssertFalse(res.playlist.title.isEmpty)
        XCTAssertFalse(res.tracks.isEmpty)
    }

    // MARK: - Fixture Builders

    func testAccountLoginReorderPathfinderAndUnauthorizedHandling() async throws {
        let recorder = RequestRecorder()
        let transport = MockHTTPTransport { req in
            await recorder.append(req)
            let url = req.url?.absoluteString ?? ""
            if url.contains("/v1/me") {
                return HTTPResponseData(statusCode: 200, body: Data(#"{"id":"julien","display_name":"Julien"}"#.utf8))
            }
            let callIndex = await recorder.mutationCount()
            if callIndex == 1 {
                return HTTPResponseData(statusCode: 200, body: Data(#"{"data":{"moveItemsInPlaylist":{"__typename":"MoveItemsInPlaylistPayload"}}}"#.utf8))
            }
            return HTTPResponseData(statusCode: 401, body: Data(#"{"error":{"status":401,"message":"The access token expired"}}"#.utf8))
        }

        let source = SpotifySource(transport: transport)
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("sp-acc-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        try await source.initialize(
            params: PluginInitializeParams(
                host: PluginHostInfo(os: "macos", arch: "arm64", appVersion: "1.0", onIPod: false),
                paths: PluginPaths(data: tmpDir.path, cache: tmpDir.path, temp: tmpDir.path)
            ),
            context: TestRuntimeRecorder()
        )

        let waiting = try await source.login(key: "account", fields: [:])
        XCTAssertEqual(waiting.status, "waiting")
        XCTAssertNotNil(waiting.openURL)

        let signedIn = try await source.login(key: "account", fields: [
            "accessToken": "user-tok-1",
            "clientToken": "client-tok-1",
            "sp_dc": "secret-dc",
            "expiresAtMs": String(Int64(Date().timeIntervalSince1970 * 1000) + 3_600_000),
        ])
        XCTAssertEqual(signedIn.status, "signedIn")
        XCTAssertEqual(signedIn.displayName, "Julien")

        try await source.reorder(request: PlaylistReorderRequest(
            playlistID: "3jiWifGSBvNmcMDMEQDaAr",
            movedItemUIDs: ["uid-track-2"],
            beforeItemUID: "uid-track-0",
            rangeStart: 2,
            rangeLength: 1,
            insertBefore: 0
        ))

        let rawPostReq = await recorder.lastMutationRequest()
        let postReq = try XCTUnwrap(rawPostReq)
        let rawBody = postReq.httpBody
        let postBodyData = try XCTUnwrap(rawBody)
        XCTAssertEqual(postReq.value(forHTTPHeaderField: "Authorization"), "Bearer user-tok-1")
        XCTAssertEqual(postReq.value(forHTTPHeaderField: "client-token"), "client-tok-1")
        let bodyObj = try JSONSerialization.jsonObject(with: postBodyData) as? [String: Any]
        XCTAssertEqual(bodyObj?["operationName"] as? String, "moveItemsInPlaylist")
        let vars = bodyObj?["variables"] as? [String: Any]
        XCTAssertEqual(vars?["playlistUri"] as? String, "spotify:playlist:3jiWifGSBvNmcMDMEQDaAr")
        XCTAssertEqual(vars?["uids"] as? [String], ["uid-track-2"])
        let pos = vars?["newPosition"] as? [String: Any]
        XCTAssertEqual(pos?["moveType"] as? String, "BEFORE_UID")
        XCTAssertEqual(pos?["fromUid"] as? String, "uid-track-0")

        do {
            try await source.reorder(request: PlaylistReorderRequest(
                playlistID: "3jiWifGSBvNmcMDMEQDaAr",
                movedItemUIDs: ["uid-track-2"],
                atStart: true,
                rangeStart: 2,
                rangeLength: 1,
                insertBefore: 0
            ))
            XCTFail("Expected .unauthorized on 401 response")
        } catch let err as PluginError {
            XCTAssertEqual(err.code, .unauthorized)
        }

        let loggedOut = try await source.logout()
        XCTAssertEqual(loggedOut.status, "signedOut")
    }

    func testSpotifyUsernamePreferenceAndAddLibraryTracksToPlaylist() async throws {
        let searchJSON = """
        {
          "tracks": {
            "items": [
              {
                "id": "track123",
                "uri": "spotify:track:track123",
                "name": "Digital Love",
                "duration_ms": 298000,
                "track_number": 4,
                "disc_number": 1,
                "artists": [{"name": "Daft Punk"}],
                "album": {"name": "Discovery", "images": [{"url": "https://i.scdn.co/image/disc", "width": 640, "height": 640}]},
                "external_ids": {"isrc": "GBDUW0000059"}
              }
            ]
          }
        }
        """

        let transport = MockHTTPTransport { req in
            let url = req.url?.absoluteString ?? ""
            if url.contains("/v1/me") {
                return HTTPResponseData(
                    statusCode: 200,
                    body: Data(#"{"id":"od192uo8ryp8qhvwlzwuu2u83","display_name":"wwwonka"}"#.utf8)
                )
            }
            if url.contains("/v1/search") {
                return HTTPResponseData(statusCode: 200, body: Data(searchJSON.utf8))
            }
            if req.httpMethod == "POST" && url.contains("/v1/playlists/plOwned/items") {
                return HTTPResponseData(statusCode: 201, body: Data(#"{"snapshot_id":"snap-1"}"#.utf8))
            }
            if req.httpMethod == "POST" && url.contains("/v1/playlists/plNotOwned/items") {
                return HTTPResponseData(statusCode: 403, body: Data())
            }
            return HTTPResponseData(statusCode: 404, body: Data())
        }

        let source = SpotifySource(transport: transport)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("spotify-add-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try await source.initialize(
            params: PluginInitializeParams(
                host: PluginHostInfo(os: "macos", arch: "arm64", appVersion: "0.1", onIPod: false),
                paths: PluginPaths(data: tmp.path, cache: tmp.path, temp: tmp.path)
            ),
            context: TestRuntimeRecorder()
        )

        let signedIn = try await source.login(key: "account", fields: [
            "accessToken": "tok-user",
            "clientToken": "ct-user",
            "expiresAtMs": String(Int64(Date().timeIntervalSince1970 * 1000) + 3_600_000),
        ])
        XCTAssertEqual(signedIn.status, "signedIn")
        XCTAssertEqual(signedIn.displayName, "wwwonka")

        let addedRes = try await source.addTracks(request: PlaylistAddTracksRequest(
            playlistID: "plOwned",
            tracks: [
                PlaylistAddTrackInput(title: "Digital Love", artist: "Daft Punk", album: "Discovery", durationMs: 298000),
            ]
        ))
        XCTAssertEqual(addedRes.added.count, 1)
        XCTAssertEqual(addedRes.added.first?.matchedTrack.sourceID, "track123")
        XCTAssertEqual(addedRes.notFoundTitles, [])

        do {
            _ = try await source.addTracks(request: PlaylistAddTracksRequest(
                playlistID: "plNotOwned",
                tracks: [PlaylistAddTrackInput(title: "Digital Love", artist: "Daft Punk")]
            ))
            XCTFail("Expected .unsupported on HTTP 403")
        } catch let err as PluginError {
            XCTAssertEqual(err.code, .unsupported)
            XCTAssertTrue(err.message.localizedCaseInsensitiveContains("own"))
        }
    }

    func testSpotifyRenamePlaylistOwnedUnauthorizedAndNotOwned() async throws {
        let state = SendableRenameState()
        let transport = MockHTTPTransport { req in
            let url = req.url?.absoluteString ?? ""
            if url.contains("/v1/me") {
                return HTTPResponseData(
                    statusCode: 200,
                    body: Data(#"{"id":"user1","display_name":"wwwonka"}"#.utf8)
                )
            }
            if req.httpMethod == "POST" && url.contains("spclient.wg.spotify.com/playlist/v2/playlist/plOwned/changes") {
                if let body = req.httpBody,
                   let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                    state.setSpClientBody(json)
                }
                return HTTPResponseData(statusCode: 200, body: Data(#"{"revision":"rev-2"}"#.utf8))
            }
            if req.httpMethod == "POST" && url.contains("spclient.wg.spotify.com/playlist/v2/playlist/plUnauthorized/changes") {
                return HTTPResponseData(statusCode: 401, body: Data())
            }
            if req.httpMethod == "POST" && url.contains("spclient.wg.spotify.com/playlist/v2/playlist/plNotOwned/changes") {
                return HTTPResponseData(statusCode: 403, body: Data())
            }
            if req.httpMethod == "POST" && url.contains("spclient.wg.spotify.com/playlist/v2/playlist/plRateLimited/changes") {
                return HTTPResponseData(statusCode: 429, headers: ["Retry-After": "12"], body: Data())
            }
            if req.httpMethod == "PUT" && url.contains("api.spotify.com/v1/playlists/plFallbackWebAPI") {
                if let body = req.httpBody,
                   let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                    state.setFallbackBody(json)
                }
                return HTTPResponseData(statusCode: 200, body: Data())
            }
            return HTTPResponseData(statusCode: 404, body: Data())
        }

        let source = SpotifySource(transport: transport)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("spotify-rename-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try await source.initialize(
            params: PluginInitializeParams(
                host: PluginHostInfo(os: "macos", arch: "arm64", appVersion: "0.1", onIPod: false),
                paths: PluginPaths(data: tmp.path, cache: tmp.path, temp: tmp.path)
            ),
            context: TestRuntimeRecorder()
        )
        _ = try await source.login(key: "account", fields: [
            "accessToken": "tok-user",
            "clientToken": "ct-user",
            "expiresAtMs": String(Int64(Date().timeIntervalSince1970 * 1000) + 3_600_000),
        ])

        try await source.renamePlaylist(request: PlaylistRenameRequest(playlistID: "plOwned", name: "  New Playlist Name  "))
        let capturedSpClientBody = state.spClientBody()
        XCTAssertEqual(capturedSpClientBody?["wantSyncResult"] as? Bool, true)
        let deltas = capturedSpClientBody?["deltas"] as? [[String: Any]]
        let ops = deltas?.first?["ops"] as? [[String: Any]]
        XCTAssertEqual(ops?.first?["kind"] as? String, "UPDATE_LIST_ATTRIBUTES")
        let updateAttrs = ops?.first?["updateListAttributes"] as? [String: Any]
        let newAttrs = updateAttrs?["newAttributes"] as? [String: Any]
        let values = newAttrs?["values"] as? [String: Any]
        XCTAssertEqual(values?["name"] as? String, "New Playlist Name")

        try await source.renamePlaylist(request: PlaylistRenameRequest(playlistID: "plFallbackWebAPI", name: "Fallback Name"))
        XCTAssertEqual(state.fallbackBody()?["name"] as? String, "Fallback Name")

        do {
            try await source.renamePlaylist(request: PlaylistRenameRequest(playlistID: "plNotOwned", name: "Other"))
            XCTFail("Expected .unsupported on HTTP 403")
        } catch let err as PluginError {
            XCTAssertEqual(err.code, .unsupported)
            XCTAssertTrue(err.message.localizedCaseInsensitiveContains("own"))
        }

        do {
            try await source.renamePlaylist(request: PlaylistRenameRequest(playlistID: "plRateLimited", name: "Other"))
            XCTFail("Expected .rateLimited on HTTP 429")
        } catch let err as PluginError {
            XCTAssertEqual(err.code, .rateLimited)
            XCTAssertEqual(err.retryAfterSeconds, 12)
        }

        do {
            try await source.renamePlaylist(request: PlaylistRenameRequest(playlistID: "plUnauthorized", name: "Other"))
            XCTFail("Expected .unauthorized on HTTP 401")
        } catch let err as PluginError {
            XCTAssertEqual(err.code, .unauthorized)
        }
    }

    func testSpotifySearchDesktopAddRemoveCreateAndCover() async throws {
        let opsState = SendableOpsState()

        let searchDesktopJSON = """
        {
          "data": {
            "searchV2": {
              "tracksV2": {
                "items": [
                  {
                    "item": {
                      "data": {
                        "__typename": "Track",
                        "uri": "spotify:track:1234567890123456789012",
                        "name": "One More Time",
                        "duration": {"totalMilliseconds": 320000},
                        "contentRating": {"label": "NONE"},
                        "artists": {"items": [{"profile": {"name": "Daft Punk"}}]},
                        "albumOfTrack": {
                          "name": "Discovery",
                          "coverArt": {"sources": [{"url": "https://i.scdn.co/image/disc640", "width": 640, "height": 640}]}
                        }
                      }
                    }
                  }
                ]
              }
            }
          }
        }
        """

        let transport = MockHTTPTransport { req in
            let url = req.url?.absoluteString ?? ""
            if url.contains("/v1/me") {
                return HTTPResponseData(statusCode: 200, body: Data(#"{"id":"usercanon123","display_name":"wwwonka"}"#.utf8))
            }
            if url.contains("pathfinder/v2/query"),
               let body = req.httpBody,
               let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
               (json["operationName"] as? String) == "searchDesktop" {
                if opsState.simulateSearchRateLimit {
                    return HTTPResponseData(statusCode: 429, headers: ["Retry-After": "9"], body: Data())
                }
                return HTTPResponseData(statusCode: 200, body: Data(searchDesktopJSON.utf8))
            }
            if url.contains("/v1/search") && opsState.simulateSearchRateLimit {
                return HTTPResponseData(statusCode: 429, headers: ["Retry-After": "9"], body: Data())
            }
            if req.httpMethod == "POST" && url.contains("spclient.wg.spotify.com/playlist/v2/playlist/plOwned/changes"),
               let body = req.httpBody,
               let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
               let deltas = json["deltas"] as? [[String: Any]],
               let ops = deltas.first?["ops"] as? [[String: Any]],
               let kind = ops.first?["kind"] as? String {
                if kind == "ADD" { opsState.markAdd() }
                if kind == "REM" { opsState.markRemove() }
                if kind == "UPDATE_LIST_ATTRIBUTES",
                   let update = ops.first?["updateListAttributes"] as? [String: Any],
                   let newAttrs = update["newAttributes"] as? [String: Any],
                   let values = newAttrs["values"] as? [String: Any],
                   let pic = values["picture"] as? String {
                    opsState.setPicture(pic)
                }
                return HTTPResponseData(statusCode: 200, body: Data(#"{"revision":"rev-ok"}"#.utf8))
            }
            if req.httpMethod == "POST" && url.contains("spclient.wg.spotify.com/playlist/v2/playlist/plNotOwned/changes") {
                return HTTPResponseData(statusCode: 403, body: Data())
            }
            if req.httpMethod == "POST" && url.hasSuffix("/playlist/v2/playlist") {
                opsState.incrementCreatePlaylist()
                return HTTPResponseData(statusCode: 200, body: Data(#"{"uri":"spotify:playlist:1234567890abcdefghijkl"}"#.utf8))
            }
            if req.httpMethod == "POST" && url.contains("/playlist/v2/user/usercanon123/rootlist/changes") {
                opsState.markRootlist()
                return HTTPResponseData(statusCode: 200, body: Data(#"{"revision":"root-1"}"#.utf8))
            }
            if req.httpMethod == "POST" && url.contains("image-upload.spotify.com/v4/playlist") {
                return HTTPResponseData(statusCode: 200, body: Data(#"{"uploadToken":"tok-img-1"}"#.utf8))
            }
            if req.httpMethod == "POST" && url.contains("/playlist/v2/playlist/plOwned/register-image") {
                return HTTPResponseData(statusCode: 200, body: Data(#"{"picture":"spotify:image:abcd1234"}"#.utf8))
            }
            return HTTPResponseData(statusCode: 404, body: Data())
        }

        let source = SpotifySource(transport: transport)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("spotify-ops-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try await source.initialize(
            params: PluginInitializeParams(
                host: PluginHostInfo(os: "macos", arch: "arm64", appVersion: "0.1", onIPod: false),
                paths: PluginPaths(data: tmp.path, cache: tmp.path, temp: tmp.path)
            ),
            context: TestRuntimeRecorder()
        )
        _ = try await source.login(key: "account", fields: [
            "accessToken": "tok-user",
            "clientToken": "ct-user",
            "expiresAtMs": String(Int64(Date().timeIntervalSince1970 * 1000) + 3_600_000),
        ])

        let addRes = try await source.addTracks(request: PlaylistAddTracksRequest(
            playlistID: "plOwned",
            tracks: [PlaylistAddTrackInput(title: "One More Time", artist: "Daft Punk", durationMs: 320000)]
        ))
        XCTAssertTrue(opsState.didAdd)
        XCTAssertEqual(addRes.added.first?.matchedTrack.sourceID, "1234567890123456789012")

        try await source.removeTracks(request: PlaylistRemoveTracksRequest(
            playlistID: "plOwned",
            trackIDs: ["1234567890123456789012"]
        ))
        XCTAssertTrue(opsState.didRemove)

        let created = try await source.createPlaylist(request: PlaylistCreateRequest(name: "Created Mix"))
        XCTAssertEqual(opsState.createPlaylistCalls, 1)
        XCTAssertTrue(opsState.didRootlist)
        XCTAssertEqual(created.playlist.sourceID, "1234567890abcdefghijkl")
        XCTAssertEqual(created.url.absoluteString, "https://open.spotify.com/playlist/1234567890abcdefghijkl")

        try await source.setPlaylistArtwork(request: PlaylistArtworkRequest(
            playlistID: "plOwned",
            jpegData: Data([0xFF, 0xD8, 0xFF, 0xE0])
        ))
        XCTAssertEqual(opsState.picture, "spotify:image:abcd1234")

        opsState.setSearchRateLimit(true)
        do {
            _ = try await source.addTracks(request: PlaylistAddTracksRequest(
                playlistID: "plOwned",
                tracks: [PlaylistAddTrackInput(title: "One More Time", artist: "Daft Punk")]
            ))
            XCTFail("Expected .rateLimited when search returns HTTP 429")
        } catch let err as PluginError {
            XCTAssertEqual(err.code, .rateLimited)
            XCTAssertEqual(err.retryAfterSeconds, 9)
        }

        do {
            try await source.removeTracks(request: PlaylistRemoveTracksRequest(
                playlistID: "plNotOwned",
                trackIDs: ["1234567890123456789012"]
            ))
            XCTFail("Expected .unsupported on HTTP 403")
        } catch let err as PluginError {
            XCTAssertEqual(err.code, .unsupported)
        }
    }

    func testSpotifyListUserPlaylistsPaginationNullToleranceAndUnauthorized() async throws {
        let transport = MockHTTPTransport { req in
            let url = req.url?.absoluteString ?? ""
            if url.contains("/v1/me/playlists") {
                if req.value(forHTTPHeaderField: "Authorization") == "Bearer expired-tok" {
                    return HTTPResponseData(statusCode: 401, body: Data())
                }
                if url.contains("offset=0") {
                    let page1 = """
                    {
                      "items": [
                        {
                          "id": "pl11111111111111111111",
                          "name": "Late Night Drives",
                          "owner": {"id": "u1", "display_name": "wwwonka"},
                          "tracks": {"total": 24},
                          "images": [{"url": "https://i.scdn.co/image/pl1", "width": 640, "height": 640}],
                          "external_urls": {"spotify": "https://open.spotify.com/playlist/pl11111111111111111111"}
                        },
                        null
                      ],
                      "next": "https://api.spotify.com/v1/me/playlists?limit=50&offset=50"
                    }
                    """
                    return HTTPResponseData(statusCode: 200, body: Data(page1.utf8))
                }
                if url.contains("offset=50") {
                    let page2 = """
                    {
                      "items": [
                        {
                          "id": "pl11111111111111111111",
                          "name": "Late Night Drives",
                          "owner": {"id": "u1"},
                          "tracks": {"total": 24}
                        },
                        {
                          "id": "pl22222222222222222222",
                          "name": "Studio Focus",
                          "owner": {"id": "curator"},
                          "items": {"total": 12}
                        }
                      ],
                      "next": null
                    }
                    """
                    return HTTPResponseData(statusCode: 200, body: Data(page2.utf8))
                }
            }
            if url.contains("/v1/me") {
                return HTTPResponseData(statusCode: 200, body: Data(#"{"id":"u1","display_name":"wwwonka"}"#.utf8))
            }
            return HTTPResponseData(statusCode: 404, body: Data())
        }

        let source = SpotifySource(transport: transport)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("spotify-list-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try await source.initialize(
            params: PluginInitializeParams(
                host: PluginHostInfo(os: "macos", arch: "arm64", appVersion: "0.1", onIPod: false),
                paths: PluginPaths(data: tmp.path, cache: tmp.path, temp: tmp.path)
            ),
            context: TestRuntimeRecorder()
        )
        // Requires signed-in user session
        do {
            _ = try await source.listUserPlaylists()
            XCTFail("Expected .unauthorized when signed out")
        } catch let err as PluginError {
            XCTAssertEqual(err.code, .unauthorized)
        }
        _ = try await source.login(key: "account", fields: [
            "accessToken": "tok-user",
            "clientToken": "ct-user",
            "expiresAtMs": String(Int64(Date().timeIntervalSince1970 * 1000) + 3_600_000),
        ])

        let lists = try await source.listUserPlaylists()
        XCTAssertEqual(lists.count, 2)
        XCTAssertEqual(lists[0].id, "pl11111111111111111111")
        XCTAssertEqual(lists[0].title, "Late Night Drives")
        XCTAssertEqual(lists[0].owner, "wwwonka")
        XCTAssertEqual(lists[0].trackCount, 24)
        XCTAssertEqual(lists[0].artworkURL?.absoluteString, "https://i.scdn.co/image/pl1")
        XCTAssertEqual(lists[1].id, "pl22222222222222222222")
        XCTAssertEqual(lists[1].trackCount, 12)
        XCTAssertEqual(lists[1].url.absoluteString, "https://open.spotify.com/playlist/pl22222222222222222222")

        // Verify 401 surfaces .unauthorized so host can refresh session
        _ = try await source.login(key: "account", fields: [
            "accessToken": "expired-tok",
            "clientToken": "ct-user",
            "expiresAtMs": String(Int64(Date().timeIntervalSince1970 * 1000) + 3_600_000),
        ])
        do {
            _ = try await source.listUserPlaylists()
            XCTFail("Expected .unauthorized on 401")
        } catch let err as PluginError {
            XCTAssertEqual(err.code, .unauthorized)
        }
    }

    func testSpotifySpDCRefreshPersistenceAndReorderSpClientFallback() async throws {
        let state = SendableRenameState()
        let recorder = RequestRecorder()
        let transport = MockHTTPTransport { req in
            await recorder.append(req)
            let url = req.url?.absoluteString ?? ""
            if url == "https://open.spotify.com/" {
                let html = """
                <html><body>
                <script id="appServerConfig" type="application/json">{"clientId":"cid-test"}</script>
                <script id="session" type="application/json">{"accessToken":"refreshed-user-tok","accessTokenExpirationTimestampMs":4102444800000,"isAnonymous":false}</script>
                </body></html>
                """
                return HTTPResponseData(statusCode: 200, body: Data(html.utf8))
            }
            if url == "https://clienttoken.spotify.com/v1/clienttoken" {
                return HTTPResponseData(statusCode: 200, body: Data(#"{"granted_token":{"token":"refreshed-client-tok"}}"#.utf8))
            }
            if url.contains("/v1/me") {
                return HTTPResponseData(statusCode: 200, body: Data(#"{"id":"julien","display_name":"Julien"}"#.utf8))
            }
            if url.contains("pathfinder") {
                return HTTPResponseData(statusCode: 200, body: Data(#"{"errors":[{"message":"PersistedQueryNotFound"}]}"#.utf8))
            }
            if url.contains("spclient.wg.spotify.com/playlist/v2/playlist/plMove/changes") {
                XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer refreshed-user-tok")
                XCTAssertEqual(req.value(forHTTPHeaderField: "client-token"), "refreshed-client-tok")
                if let body = req.httpBody,
                   let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                    state.setSpClientBody(json)
                }
                return HTTPResponseData(statusCode: 200, body: Data(#"{"revision":"rev-mov"}"#.utf8))
            }
            return HTTPResponseData(statusCode: 404, body: Data())
        }

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sp-persist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        do {
            let source = SpotifySource(transport: transport)
            try await source.initialize(
                params: PluginInitializeParams(
                    host: PluginHostInfo(os: "macos", arch: "arm64", appVersion: "1.0", onIPod: false),
                    paths: PluginPaths(data: tmp.path, cache: tmp.path, temp: tmp.path)
                ),
                context: TestRuntimeRecorder()
            )
            // Initial login with expired accessToken + valid sp_dc
            _ = try await source.login(key: "account", fields: [
                "sp_dc": "persistent-sp-dc",
                "accessToken": "old-expired-tok",
                "expiresAtMs": "1000",
                "displayName": "Julien",
            ])
        }

        // Simulate app relaunch with a brand new SpotifySource instance loading `.spotify-session.json` from disk
        let relaunchedSource = SpotifySource(transport: transport)
        try await relaunchedSource.initialize(
            params: PluginInitializeParams(
                host: PluginHostInfo(os: "macos", arch: "arm64", appVersion: "1.0", onIPod: false),
                paths: PluginPaths(data: tmp.path, cache: tmp.path, temp: tmp.path)
            ),
            context: TestRuntimeRecorder()
        )
        let restoredStatus = try await relaunchedSource.status()
        XCTAssertEqual(restoredStatus.status, "signedIn")
        XCTAssertEqual(restoredStatus.displayName, "Julien")

        try await relaunchedSource.reorder(request: PlaylistReorderRequest(
            playlistID: "plMove",
            movedItemUIDs: ["uid-1"],
            beforeItemUID: "uid-3",
            rangeStart: 0,
            rangeLength: 1,
            insertBefore: 3
        ))

        let deltas = state.spClientBody()?["deltas"] as? [[String: Any]]
        let ops = deltas?.first?["ops"] as? [[String: Any]]
        XCTAssertEqual(ops?.first?["kind"] as? String, "MOV")
        let mov = ops?.first?["mov"] as? [String: Any]
        XCTAssertEqual(mov?["fromIndex"] as? Int, 0)
        XCTAssertEqual(mov?["length"] as? Int, 1)
        XCTAssertEqual(mov?["toIndex"] as? Int, 3)
    }

    func testSpotifyLibraryV3SidebarPlaylistsAndLikedSongsCollectionFetch() async throws {
        XCTAssertEqual(try SpotifyURL.parse("https://open.spotify.com/collection/tracks").kind, .collection)
        XCTAssertEqual(try SpotifyURL.parse("spotify:collection:tracks").kind, .collection)
        XCTAssertEqual(try SpotifyURL.parse("spotify:user:wwwonka:collection").kind, .collection)

        let transport = MockHTTPTransport { req in
            let url = req.url?.absoluteString ?? ""
            if url.contains("/v1/me") {
                return HTTPResponseData(statusCode: 200, body: Data(#"{"id":"wwwonka","display_name":"wwwonka"}"#.utf8))
            }
            if url.contains("operationName=libraryV3") {
                let libJSON = """
                {
                  "data": {
                    "me": {
                      "libraryV3": {
                        "totalCount": 4,
                        "pagingInfo": {"offset": 0, "limit": 50},
                        "items": [
                          {
                            "item": {
                              "__typename": "LibraryPseudoPlaylistResponseWrapper",
                              "_uri": "spotify:user:wwwonka:collection",
                              "data": {
                                "__typename": "PseudoPlaylist",
                                "uri": "spotify:user:wwwonka:collection",
                                "name": "Liked Songs",
                                "count": 289
                              }
                            }
                          },
                          {
                            "item": {
                              "__typename": "LibraryPseudoPlaylistResponseWrapper",
                              "_uri": "spotify:user:wwwonka:collection:your-episodes",
                              "data": {
                                "__typename": "PseudoPlaylist",
                                "uri": "spotify:user:wwwonka:collection:your-episodes",
                                "name": "Your Episodes",
                                "count": 4
                              }
                            }
                          },
                          {
                            "item": {
                              "__typename": "PlaylistResponseWrapper",
                              "data": {
                                "__typename": "Playlist",
                                "uri": "spotify:playlist:37i9dQZF1DXcBWIGoYBM5M",
                                "name": "LAVA LAMP",
                                "ownerV2": {"data": {"name": "wwwonka", "username": "wwwonka"}},
                                "content": {"totalCount": 31}
                              }
                            }
                          },
                          {
                            "item": {
                              "__typename": "FolderResponseWrapper",
                              "data": {
                                "__typename": "Folder",
                                "uri": "spotify:folder:abc",
                                "name": "Emiel"
                              }
                            }
                          }
                        ]
                      }
                    }
                  }
                }
                """
                return HTTPResponseData(statusCode: 200, body: Data(libJSON.utf8))
            }
            if url.contains("operationName=fetchLibraryTracks") {
                let likedJSON = """
                {
                  "data": {
                    "me": {
                      "library": {
                        "tracks": {
                          "totalCount": 1,
                          "pagingInfo": {"offset": 0, "limit": 50},
                          "items": [
                            {
                              "track": {
                                "data": {
                                  "__typename": "Track",
                                  "uri": "spotify:track:4uLU6hMCjMI75M1A2tKUQC",
                                  "name": "Never Gonna Give You Up",
                                  "duration": {"totalMilliseconds": 213573},
                                  "artists": {"items": [{"profile": {"name": "Rick Astley"}}]},
                                  "albumOfTrack": {"name": "Whenever You Need Somebody", "artists": {"items": [{"profile": {"name": "Rick Astley"}}]}}
                                }
                              }
                            }
                          ]
                        }
                      }
                    }
                  }
                }
                """
                return HTTPResponseData(statusCode: 200, body: Data(likedJSON.utf8))
            }
            return HTTPResponseData(statusCode: 404, body: Data())
        }

        let source = SpotifySource(transport: transport)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sp-libv3-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try await source.initialize(
            params: PluginInitializeParams(
                host: PluginHostInfo(os: "macos", arch: "arm64", appVersion: "1.0", onIPod: false),
                paths: PluginPaths(data: tmp.path, cache: tmp.path, temp: tmp.path)
            ),
            context: TestRuntimeRecorder()
        )
        let hashesJSON = #"{"libraryV3":"1111111111111111111111111111111111111111111111111111111111111111","fetchLibraryTracks":"2222222222222222222222222222222222222222222222222222222222222222"}"#
        _ = try await source.login(key: "account", fields: [
            "accessToken": "tok-user",
            "clientToken": "ct-user",
            "expiresAtMs": String(Int64(Date().timeIntervalSince1970 * 1000) + 3_600_000),
            "pathfinderHashesJSON": hashesJSON,
        ])

        let lists = try await source.listUserPlaylists()
        XCTAssertEqual(lists.count, 2)
        XCTAssertEqual(lists[0].id, "collection-tracks")
        XCTAssertEqual(lists[0].title, "Liked Songs")
        XCTAssertEqual(lists[0].trackCount, 289)
        XCTAssertEqual(lists[0].url.absoluteString, "https://open.spotify.com/collection/tracks")
        XCTAssertEqual(lists[1].id, "37i9dQZF1DXcBWIGoYBM5M")
        XCTAssertEqual(lists[1].title, "LAVA LAMP")
        XCTAssertEqual(lists[1].trackCount, 31)

        let likedFetch = try await source.fetch(url: URL(string: "https://open.spotify.com/collection/tracks")!)
        XCTAssertEqual(likedFetch.playlist.title, "Liked Songs")
        XCTAssertEqual(likedFetch.tracks.count, 1)
        XCTAssertEqual(likedFetch.tracks[0].title, "Never Gonna Give You Up")
    }

    func testPersistedHashesReuseAndFastWebAPI429Handling() async throws {
        let playlistCountCalls = LockedCounter()
        let bundleRequests = LockedCounter()

        let transport = MockHTTPTransport { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("https://open.spotify.com/get_access_token") {
                return HTTPResponseData(
                    statusCode: 200,
                    body: Data(#"{"accessToken":"tok-u","accessTokenExpirationTimestampMs":4102444800000,"isAnonymous":false}"#.utf8)
                )
            }
            if url == "https://open.spotify.com/" || url.hasSuffix(".js") {
                bundleRequests.increment()
                return HTTPResponseData(statusCode: 404, body: Data())
            }
            if url.contains("https://api.spotify.com/v1/me/playlists") {
                return HTTPResponseData(statusCode: 429, headers: ["Retry-After": "30"], body: Data())
            }
            if url.contains("https://api.spotify.com/v1/me/tracks") {
                return HTTPResponseData(statusCode: 200, body: Data(#"{"total":42,"items":[]}"#.utf8))
            }
            if url.contains("https://api.spotify.com/v1/me") {
                return HTTPResponseData(statusCode: 200, body: Data(#"{"id":"wwwonka","display_name":"wwwonka"}"#.utf8))
            }
            if url.contains("operationName=fetchPlaylist") {
                playlistCountCalls.increment()
                return HTTPResponseData(statusCode: 404, body: Data())
            }
            if url.contains("operationName=libraryV3") {
                let libJSON = """
                {
                  "data": {
                    "me": {
                      "libraryV3": {
                        "totalCount": 1,
                        "pagingInfo": {"offset": 0, "limit": 50},
                        "items": [
                          {
                            "item": {
                              "__typename": "PlaylistResponseWrapper",
                              "data": {
                                "__typename": "Playlist",
                                "uri": "spotify:playlist:37i9dQZF1DXcBWIGoYBM5M",
                                "name": "No Count Sidebar",
                                "ownerV2": {"data": {"name": "wwwonka", "username": "wwwonka"}}
                              }
                            }
                          }
                        ]
                      }
                    }
                  }
                }
                """
                return HTTPResponseData(statusCode: 200, body: Data(libJSON.utf8))
            }
            return HTTPResponseData(statusCode: 404, body: Data())
        }

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sp-hash-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let firstSource = SpotifySource(transport: transport)
        try await firstSource.initialize(
            params: PluginInitializeParams(
                host: PluginHostInfo(os: "macos", arch: "arm64", appVersion: "1.0", onIPod: false),
                paths: PluginPaths(data: tmp.path, cache: tmp.path, temp: tmp.path)
            ),
            context: TestRuntimeRecorder()
        )
        _ = try await firstSource.login(key: "account", fields: [
            "sp_dc": "spdc-val",
            "accessToken": "tok-u",
            "expiresAtMs": String(Int64(Date().timeIntervalSince1970 * 1000) + 3_600_000),
            "pathfinderHashesJSON": #"{"libraryV3":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}"#,
        ])

        // Re-initialize a fresh instance pointing at the same data folder (simulating app relaunch).
        let secondSource = SpotifySource(transport: transport)
        try await secondSource.initialize(
            params: PluginInitializeParams(
                host: PluginHostInfo(os: "macos", arch: "arm64", appVersion: "1.0", onIPod: false),
                paths: PluginPaths(data: tmp.path, cache: tmp.path, temp: tmp.path)
            ),
            context: TestRuntimeRecorder()
        )

        let startedAt = Date()
        let lists = try await secondSource.listUserPlaylists()
        let elapsed = Date().timeIntervalSince(startedAt)

        XCTAssertLessThan(elapsed, 2.0, "429 during optional Web API count enrichment must not stall listUserPlaylists")
        XCTAssertEqual(bundleRequests.value, 0, "Persisted libraryV3 hash should skip open.spotify.com JS bundle scraping")
        XCTAssertEqual(playlistCountCalls.value, 0, "listUserPlaylists must not fire blocking per-playlist fetchPlaylist probes")
        XCTAssertEqual(lists.map(\.id), ["collection-tracks", "37i9dQZF1DXcBWIGoYBM5M"])
        XCTAssertEqual(lists[0].trackCount, 42)
    }

    func testRemoveTracksSkipsBundleDiscoveryAndUsesFastSpClientREM() async throws {
        let bundleRequests = LockedCounter()
        let spclientRemCalls = LockedCounter()

        let transport = MockHTTPTransport { request in
            let url = request.url?.absoluteString ?? ""
            if url == "https://open.spotify.com/" || url.hasSuffix(".js") {
                bundleRequests.increment()
                return HTTPResponseData(statusCode: 200, body: Data())
            }
            if url.contains("https://spclient.wg.spotify.com/playlist/v2/playlist/plFast/changes") {
                spclientRemCalls.increment()
                return HTTPResponseData(statusCode: 200, body: Data(#"{}"#.utf8))
            }
            return HTTPResponseData(statusCode: 404, body: Data())
        }

        let source = SpotifySource(transport: transport)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sp-fast-del-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try await source.initialize(
            params: PluginInitializeParams(
                host: PluginHostInfo(os: "macos", arch: "arm64", appVersion: "1.0", onIPod: false),
                paths: PluginPaths(data: tmp.path, cache: tmp.path, temp: tmp.path)
            ),
            context: TestRuntimeRecorder()
        )
        _ = try await source.login(key: "account", fields: [
            "sp_dc": "spdc-val",
            "accessToken": "tok-user",
            "expiresAtMs": String(Int64(Date().timeIntervalSince1970 * 1000) + 3_600_000),
        ])

        try await source.removeTracks(request: PlaylistRemoveTracksRequest(
            playlistID: "plFast",
            trackIDs: ["4uLU6hMCjMI75M1A2tKUQC"],
            itemUIDs: ["uid-row-1"]
        ))

        XCTAssertEqual(bundleRequests.value, 0, "removeTracks must not scan open.spotify.com JS bundles when removeItemsFromPlaylist hash is uncached")
        XCTAssertEqual(spclientRemCalls.value, 1, "removeTracks should go directly to fast spclient REM delta")
    }

    func testSpotifyRemoveTracksSkipsBundleScrapingAndUsesFastPath() async throws {
        let hitCounter = SendableOpsState()
        let transport = MockHTTPTransport { req in
            let url = req.url?.absoluteString ?? ""
            if url.contains("/v1/me") {
                return HTTPResponseData(statusCode: 200, body: Data(#"{"id":"userfast","display_name":"wwwonka"}"#.utf8))
            }
            if url.contains("open.spotify.com") || url.contains("spotifycdn.com") {
                hitCounter.markAdd() // Reuse flag to assert zero HTML/bundle fetches on remove.
                return HTTPResponseData(statusCode: 500, body: Data())
            }
            if req.httpMethod == "POST" && url.contains("spclient.wg.spotify.com/playlist/v2/playlist/plFast/changes") {
                hitCounter.markRemove()
                return HTTPResponseData(statusCode: 200, body: Data(#"{"revision":"rev-fast"}"#.utf8))
            }
            return HTTPResponseData(statusCode: 404, body: Data())
        }

        let source = SpotifySource(transport: transport)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("spotify-fast-rm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try await source.initialize(
            params: PluginInitializeParams(
                host: PluginHostInfo(os: "macos", arch: "arm64", appVersion: "0.1", onIPod: false),
                paths: PluginPaths(data: tmp.path, cache: tmp.path, temp: tmp.path)
            ),
            context: TestRuntimeRecorder()
        )
        _ = try await source.login(key: "account", fields: [
            "accessToken": "tok-user",
            "clientToken": "ct-user",
            "expiresAtMs": String(Int64(Date().timeIntervalSince1970 * 1000) + 3_600_000),
        ])

        try await source.removeTracks(request: PlaylistRemoveTracksRequest(
            playlistID: "plFast",
            trackIDs: ["1234567890123456789012"],
            itemUIDs: ["uid-1"]
        ))
        XCTAssertFalse(hitCounter.didAdd, "removeTracks should not scrape open.spotify.com bundles when hash is uncached")
        XCTAssertTrue(hitCounter.didRemove)
    }

    private static func makeEmbedHTML(token: String, expiresAtMs: Int64) -> String {
        """
        <html><body>
        <script id="__NEXT_DATA__" type="application/json">{"props":{"pageProps":{"state":{"settings":{"session":{"accessToken":"\(token)","accessTokenExpirationTimestampMs":\(expiresAtMs),"isAnonymous":true}}}}}}</script>
        </body></html>
        """
    }

    private static func makePlaylistPageJSON(
        title: String,
        uri: String,
        owner: String,
        tracks: [(id: String, name: String, artist: String, duration: Int, playable: Bool, explicit: Bool)],
        includeEpisodeAndLocal: Bool,
        nextOffset: Int?
    ) -> String {
        var itemsJSON: [String] = tracks.map { t in
            let rating = t.explicit ? "EXPLICIT" : "NONE"
            return """
            {
              "itemV2": {
                "__typename": "TrackResponseWrapper",
                "data": {
                  "__typename": "Track",
                  "uri": "spotify:track:\(t.id)",
                  "name": "\(t.name)",
                  "trackNumber": 1,
                  "discNumber": 1,
                  "contentRating": {"label": "\(rating)"},
                  "playability": {"playable": \(t.playable)},
                  "duration": {"totalMilliseconds": \(t.duration)},
                  "artists": {"items": [{"uri": "spotify:artist:1", "profile": {"name": "\(t.artist)"}}]},
                  "albumOfTrack": {
                    "uri": "spotify:album:4aawyAB9vmqN3uQ7FjRGTy",
                    "name": "Sample Album",
                    "date": {"year": 2020, "month": 3, "day": 20},
                    "artists": {"items": [{"uri": "spotify:artist:1", "profile": {"name": "\(t.artist)"}}]},
                    "coverArt": {
                      "sources": [
                        {"url": "https://i.scdn.co/image/small64", "width": 64, "height": 64},
                        {"url": "https://i.scdn.co/image/large640", "width": 640, "height": 640}
                      ]
                    }
                  }
                }
              }
            }
            """
        }

        if includeEpisodeAndLocal {
            itemsJSON.append("""
            {
              "itemV2": {
                "__typename": "EpisodeResponseWrapper",
                "data": {
                  "__typename": "Episode",
                  "uri": "spotify:episode:512ojhOuo1ktJprKbVcKyQ",
                  "name": "Ignored Episode"
                }
              }
            }
            """)
            itemsJSON.append("""
            {
              "itemV2": {
                "__typename": "TrackResponseWrapper",
                "data": {
                  "__typename": "LocalTrack",
                  "uri": "spotify:local:Artist:Album:Title:180",
                  "name": "Local File"
                }
              }
            }
            """)
        }

        let offsetStr = nextOffset.map { "\($0)" } ?? "null"
        return """
        {
          "data": {
            "playlistV2": {
              "__typename": "Playlist",
              "data": {
                "uri": "\(uri)",
                "name": "\(title)",
                "ownerV2": {"data": {"name": "\(owner)"}},
                "images": {"items": [{"sources": [{"url": "https://i.scdn.co/image/pl640", "width": 640, "height": 640}]}]},
                "contents": {
                  "totalCount": \(tracks.count),
                  "offsets": {"nextOffset": \(offsetStr)},
                  "items": [\(itemsJSON.joined(separator: ","))]
                }
              }
            }
          }
        }
        """
    }
}

private final class MockHTTPTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var callCount = 0
    private let handler: @Sendable (URLRequest) async throws -> HTTPResponseData

    init(handler: @escaping @Sendable (URLRequest) async throws -> HTTPResponseData) {
        self.handler = handler
    }

    func send(_ request: URLRequest) async throws -> HTTPResponseData {
        lock.lock()
        callCount += 1
        lock.unlock()
        return try await handler(request)
    }
}

private final class SequenceMockTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [HTTPResponseData]

    init(responses: [HTTPResponseData]) {
        self.responses = responses
    }

    func send(_ request: URLRequest) async throws -> HTTPResponseData {
        lock.lock()
        defer { lock.unlock() }
        return responses.removeFirst()
    }
}

private final class TestRuntimeRecorder: PluginRuntimeContext, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var warnings: [String] = []
    private(set) var statuses: [PluginStatusUpdate] = []

    func log(_ level: PluginLogLevel, _ message: String) async {
        lock.lock()
        if level == .warning { warnings.append(message) }
        lock.unlock()
    }

    func reportStatus(_ state: PluginRuntimeState, message: String?) async {
        lock.lock()
        statuses.append(PluginStatusUpdate(state: state, message: message))
        lock.unlock()
    }

    func reportAccountStatus(_ status: PluginAccountStatus) async {}
}

private actor RequestRecorder {
    private var requests: [URLRequest] = []
    private var mutations = 0

    func append(_ req: URLRequest) {
        requests.append(req)
        if req.httpMethod == "POST" { mutations += 1 }
    }

    func mutationCount() -> Int { mutations }

    func lastMutationRequest() -> URLRequest? {
        requests.last(where: { $0.httpMethod == "POST" })
    }
}

private final class SendableCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    @discardableResult
    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }
}

private final class SendableRenameState: @unchecked Sendable {
    private let lock = NSLock()
    private var _spClientBody: [String: Any]?
    private var _fallbackBody: [String: Any]?

    func setSpClientBody(_ value: [String: Any]) {
        lock.lock()
        _spClientBody = value
        lock.unlock()
    }

    func spClientBody() -> [String: Any]? {
        lock.lock()
        defer { lock.unlock() }
        return _spClientBody
    }

    func setFallbackBody(_ value: [String: Any]) {
        lock.lock()
        _fallbackBody = value
        lock.unlock()
    }

    func fallbackBody() -> [String: Any]? {
        lock.lock()
        defer { lock.unlock() }
        return _fallbackBody
    }
}

private final class SendableOpsState: @unchecked Sendable {
    private let lock = NSLock()
    private var _didAdd = false
    private var _didRemove = false
    private var _didRootlist = false
    private var _createPlaylistCalls = 0
    private var _picture: String?
    private var _simulateSearchRateLimit = false

    var didAdd: Bool { lock.lock(); defer { lock.unlock() }; return _didAdd }
    var didRemove: Bool { lock.lock(); defer { lock.unlock() }; return _didRemove }
    var didRootlist: Bool { lock.lock(); defer { lock.unlock() }; return _didRootlist }
    var createPlaylistCalls: Int { lock.lock(); defer { lock.unlock() }; return _createPlaylistCalls }
    var picture: String? { lock.lock(); defer { lock.unlock() }; return _picture }
    var simulateSearchRateLimit: Bool { lock.lock(); defer { lock.unlock() }; return _simulateSearchRateLimit }

    func markAdd() { lock.lock(); _didAdd = true; lock.unlock() }
    func markRemove() { lock.lock(); _didRemove = true; lock.unlock() }
    func markRootlist() { lock.lock(); _didRootlist = true; lock.unlock() }
    func incrementCreatePlaylist() { lock.lock(); _createPlaylistCalls += 1; lock.unlock() }
    func setPicture(_ value: String) { lock.lock(); _picture = value; lock.unlock() }
    func setSearchRateLimit(_ value: Bool) { lock.lock(); _simulateSearchRateLimit = value; lock.unlock() }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}
