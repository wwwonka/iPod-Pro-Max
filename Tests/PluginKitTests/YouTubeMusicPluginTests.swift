import XCTest
import PluginKit
@testable import YouTubeMusicPlugin
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class YouTubeMusicPluginTests: XCTestCase {
    private static func repoRoot(file: String = #filePath) -> URL {
        URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    // MARK: - Manifest & URL Parsing

    func testManifestURLPatternsAndBadge() throws {
        let pluginFolder = Self.repoRoot().appendingPathComponent("Plug-ins/YouTubeMusic", isDirectory: true)
        let validated = try ManifestValidator.loadAndValidate(from: pluginFolder.appendingPathComponent("plugin.json"))
        let manifest = validated.manifest

        XCTAssertEqual(manifest.id, "youtube-music")
        XCTAssertEqual(manifest.knownRoles, [.playlistSource])
        XCTAssertEqual(manifest.requiresConsent, .scraping)
        XCTAssertNotNil(manifest.config?["userAgent"]?.stringValue)
        XCTAssertNotNil(manifest.config?["clientVersion"]?.stringValue)

        let badgeData = try Data(contentsOf: pluginFolder.appendingPathComponent("badge.svg"))
        let badge = try SVGBadgeParser.parse(data: badgeData)
        XCTAssertGreaterThan(badge.steps.count, 10)

        let accepted = [
            "https://music.youtube.com/playlist?list=PL4fGSI1pDJn6O1LS0XSdF3RyO0Rq_LDeI",
            "https://music.youtube.com/playlist?list=OLAK5uy_nTestAlbumId1234&si=abc",
            "https://music.youtube.com/browse/VLPL4fGSI1pDJn6O1LS0XSdF3RyO0Rq_LDeI",
            "https://music.youtube.com/browse/MPREb_dcYZhAh5urI",
            "https://www.youtube.com/playlist?list=PLu0ocO48LFms5WsI1ipaeanxqRjn2fC_5",
            "https://youtu.be/dQw4w9WgXcQ?list=PLu0ocO48LFms5WsI1ipaeanxqRjn2fC_5",
            "music.youtube.com/playlist?list=PLu0ocO48LFms5WsI1ipaeanxqRjn2fC_5",
            "ytmusic:playlist:PLu0ocO48LFms5WsI1ipaeanxqRjn2fC_5",
            "ytmusic:album:MPREb_dcYZhAh5urI",
        ]
        for raw in accepted {
            XCTAssertTrue(manifest.matchesURL(raw), "Manifest should match: \(raw)")
        }

        let rejected = [
            "https://music.youtube.com/watch?v=dQw4w9WgXcQ",
            "https://music.youtube.com/channel/UCwZEU0wAwIyZb4x5G_KJp2w",
            "https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M",
        ]
        for raw in rejected {
            XCTAssertFalse(manifest.matchesURL(raw), "Manifest should reject: \(raw)")
        }
    }

    func testYouTubeMusicURLParser() throws {
        let pl = try YouTubeMusicURL.parse("https://music.youtube.com/playlist?list=VLPLabc123_xyz&feature=share")
        XCTAssertEqual(pl.kind, .playlist)
        XCTAssertEqual(pl.id, "PLabc123_xyz")
        XCTAssertEqual(pl.browseID, "VLPLabc123_xyz")

        let alb = try YouTubeMusicURL.parse("https://music.youtube.com/browse/MPREb_dcYZhAh5urI")
        XCTAssertEqual(alb.kind, .album)
        XCTAssertEqual(alb.id, "MPREb_dcYZhAh5urI")
        XCTAssertEqual(alb.browseID, "MPREb_dcYZhAh5urI")

        let olak = try YouTubeMusicURL.parse("https://music.youtube.com/playlist?list=OLAK5uy_abcd1234")
        XCTAssertEqual(olak.kind, .album)
        XCTAssertEqual(olak.id, "OLAK5uy_abcd1234")
        XCTAssertEqual(olak.browseID, "VLOLAK5uy_abcd1234")

        XCTAssertThrowsError(try YouTubeMusicURL.parse("https://music.youtube.com/watch?v=dQw4w9WgXcQ"))
    }

    // MARK: - Bootstrap & SAPISIDHASH

    func testYTCfgExtractionAndSAPISIDHash() throws {
        let html = """
        <html><script>ytcfg.set({"INNERTUBE_API_KEY":"AIzaTestKey123","INNERTUBE_CLIENT_VERSION":"1.20261117.06.00","VISITOR_DATA":"CgtTestVisitor","NESTED":{"a":{"b":1}}});</script></html>
        """
        let cfg = try InnerTube.extractClientConfig(fromHTML: html, fallbackClientVersion: "1.0")
        XCTAssertEqual(cfg.apiKey, "AIzaTestKey123")
        XCTAssertEqual(cfg.clientVersion, "1.20261117.06.00")
        XCTAssertEqual(cfg.visitorData, "CgtTestVisitor")

        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let header = YTMusicCookieHelper.buildSAPISIDAuthHeader(
            cookieHeader: "SAPISID=mysecret123; __Secure-3PAPISID=secret3p; SID=abc",
            origin: "https://music.youtube.com",
            now: fixedDate
        )
        XCTAssertNotNil(header)
        let expected3P = PluginSHA1.hex(Data("1700000000 secret3p https://music.youtube.com".utf8))
        XCTAssertTrue(header?.contains("SAPISIDHASH 1700000000_\(expected3P)") == true)
        XCTAssertTrue(header?.contains("SAPISID3PHASH 1700000000_\(expected3P)") == true)
    }

    func testBootstrapCoalescesConcurrentRequests() async throws {
        let transport = MockYTMusicTransport { req in
            XCTAssertEqual(req.url?.host, "music.youtube.com")
            let html = #"ytcfg.set({"INNERTUBE_API_KEY":"KeyOne","INNERTUBE_CLIENT_VERSION":"1.20261117.06.00"});"#
            return HTTPResponseData(statusCode: 200, body: Data(html.utf8))
        }
        let mgr = YTMusicTokenManager(transport: transport)
        async let c1 = mgr.getClientConfig()
        async let c2 = mgr.getClientConfig()
        let (r1, r2) = try await (c1, c2)
        XCTAssertEqual(r1.apiKey, "KeyOne")
        XCTAssertEqual(r2.apiKey, "KeyOne")
        XCTAssertEqual(transport.callCount, 1)
    }

    // MARK: - Fetch, Pagination & Album Parsing

    func testFetchPlaylistWithContinuationPaginationAndAlbumBrowse() async throws {
        let transport = MockYTMusicTransport { req in
            let urlStr = req.url?.absoluteString ?? ""
            if req.httpMethod == "GET" && urlStr == "https://music.youtube.com" {
                let html = #"ytcfg.set({"INNERTUBE_API_KEY":"FakeKey","INNERTUBE_CLIENT_VERSION":"1.20261117.06.00","VISITOR_DATA":"V1"});"#
                return HTTPResponseData(statusCode: 200, body: Data(html.utf8))
            }
            guard let body = req.httpBody,
                  let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
                return HTTPResponseData(statusCode: 400, body: Data())
            }
            if let cont = obj["continuation"] as? String, cont == "CONT_PAGE_2" {
                let page2JSON = """
                {
                  "onResponseReceivedActions": [{
                    "appendContinuationItemsAction": {
                      "continuationItems": [
                        \(Self.makeTrackRendererJSON(videoID: "vid2", setVideoID: "set2", title: "Second Song", artist: "Artist Two", duration: "4:05", explicit: true))
                      ]
                    }
                  }]
                }
                """
                return HTTPResponseData(statusCode: 200, body: Data(page2JSON.utf8))
            }
            let bid = obj["browseId"] as? String ?? ""
            if bid == "MPREb_testAlbum" {
                let albumJSON = """
                {
                  "contents": {
                    "twoColumnBrowseResultsRenderer": {
                      "tabs": [{"tabRenderer": {"content": {"sectionListRenderer": {"contents": [{
                        "musicResponsiveHeaderRenderer": {
                          "title": {"runs": [{"text": "Whenever You Need Somebody"}]},
                          "subtitle": {"runs": [{"text": "Album"}, {"text": " • "}, {"text": "1987"}]},
                          "straplineTextOne": {"runs": [{"text": "Rick Astley", "navigationEndpoint": {"browseEndpoint": {"browseId": "UC123"}}}]},
                          "thumbnail": {"musicThumbnailRenderer": {"thumbnail": {"thumbnails": [{"url": "https://yt3.googleusercontent.com/alb600", "width": 600, "height": 600}]}}}
                        }
                      }]}}}}],
                      "secondaryContents": {"sectionListRenderer": {"contents": [{
                        "musicShelfRenderer": {
                          "contents": [
                            \(Self.makeTrackRendererJSON(videoID: "dQw4w9WgXcQ", setVideoID: "setA", title: "Never Gonna Give You Up", artist: nil, duration: "3:34", explicit: false))
                          ]
                        }
                      }]}}
                    }
                  }
                }
                """
                return HTTPResponseData(statusCode: 200, body: Data(albumJSON.utf8))
            }

            let playlistJSON = """
            {
              "contents": {
                "twoColumnBrowseResultsRenderer": {
                  "tabs": [{"tabRenderer": {"content": {"sectionListRenderer": {"contents": [{
                    "musicResponsiveHeaderRenderer": {
                      "title": {"runs": [{"text": "Road Trip"}]},
                      "facepile": {"avatarStackViewModel": {"text": {"content": "wwwonka"}}},
                      "thumbnail": {"musicThumbnailRenderer": {"thumbnail": {"thumbnails": [{"url": "https://yt3.googleusercontent.com/pl544", "width": 544, "height": 544}]}}}
                    }
                  }]}}}}],
                  "secondaryContents": {"sectionListRenderer": {"contents": [{
                    "musicPlaylistShelfRenderer": {
                      "contents": [
                        \(Self.makeTrackRendererJSON(videoID: "vid1", setVideoID: "set1", title: "First Song", artist: "Artist One", duration: "3:10", explicit: false)),
                        {"continuationItemRenderer": {"continuationEndpoint": {"continuationCommand": {"token": "CONT_PAGE_2"}}}}
                      ]
                    }
                  }]}}
                }
              }
            }
            """
            return HTTPResponseData(statusCode: 200, body: Data(playlistJSON.utf8))
        }

        let source = YouTubeMusicSource(transport: transport)
        let recorder = YTTestRuntimeRecorder()
        try await source.initialize(
            params: PluginInitializeParams(
                apiVersion: 1,
                host: PluginHostInfo(os: "macos", arch: "arm64", appVersion: "0.1", onIPod: true),
                paths: PluginPaths(data: "", cache: "", temp: "")
            ),
            context: recorder
        )

        let res1 = try await source.fetch(url: URL(string: "https://music.youtube.com/playlist?list=PLroadtrip123")!)
        XCTAssertEqual(res1.playlist.source, "youtube-music")
        XCTAssertEqual(res1.playlist.title, "Road Trip")
        XCTAssertEqual(res1.playlist.owner, "wwwonka")
        XCTAssertEqual(res1.tracks.count, 2)
        XCTAssertEqual(res1.tracks[0].sourceID, "vid1")
        XCTAssertEqual(res1.tracks[0].remoteItemUID, "set1")
        XCTAssertEqual(res1.tracks[0].durationMs, 190_000)
        XCTAssertEqual(res1.tracks[1].sourceID, "vid2")
        XCTAssertEqual(res1.tracks[1].remoteItemUID, "set2")
        XCTAssertEqual(res1.tracks[1].explicit, true)

        let albumRes = try await source.fetch(url: URL(string: "https://music.youtube.com/browse/MPREb_testAlbum")!)
        XCTAssertEqual(albumRes.playlist.title, "Whenever You Need Somebody")
        XCTAssertEqual(albumRes.tracks.count, 1)
        XCTAssertEqual(albumRes.tracks[0].album, "Whenever You Need Somebody")
        XCTAssertEqual(albumRes.tracks[0].albumArtist, "Rick Astley")
        XCTAssertEqual(albumRes.tracks[0].releaseDate, "1987")
        XCTAssertEqual(albumRes.tracks[0].trackNumber, 1)
    }

    // MARK: - Authenticated Mutations (Rename, Reorder, Search+Add, Remove, Create, Cover)

    func testAuthenticatedMutations() async throws {
        let ops = SendableYTMusicOpsState()
        let transport = MockYTMusicTransport { req in
            let urlStr = req.url?.absoluteString ?? ""
            if req.httpMethod == "GET" && urlStr == "https://music.youtube.com" {
                let html = #"ytcfg.set({"INNERTUBE_API_KEY":"KeyAuth","INNERTUBE_CLIENT_VERSION":"1.20261117.06.00"});"#
                return HTTPResponseData(statusCode: 200, body: Data(html.utf8))
            }

            if urlStr.contains("/playlist_image_upload/playlist_custom_thumbnail") {
                let cmd = req.value(forHTTPHeaderField: "X-Goog-Upload-Command") ?? ""
                if cmd == "start" {
                    return HTTPResponseData(
                        statusCode: 200,
                        headers: ["X-Goog-Upload-URL": "https://music.youtube.com/playlist_image_upload/playlist_custom_thumbnail?upload_id=up1"],
                        body: Data()
                    )
                }
                if cmd == "upload, finalize" {
                    ops.markCoverUploaded()
                    return HTTPResponseData(
                        statusCode: 200,
                        body: Data(#"{"encryptedBlobId":"BLOB_XYZ_99"}"#.utf8)
                    )
                }
            }

            // Require SAPISIDHASH Authorization for authenticated endpoints
            if urlStr.contains("/youtubei/v1/account/account_menu") {
                XCTAssertTrue(req.value(forHTTPHeaderField: "Authorization")?.hasPrefix("SAPISIDHASH ") == true)
                return HTTPResponseData(statusCode: 200, body: Data(#"{"accountName":{"runs":[{"text":"Julien"}]}}"#.utf8))
            }

            guard let body = req.httpBody,
                  let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
                return HTTPResponseData(statusCode: 400, body: Data())
            }

            if urlStr.contains("/youtubei/v1/search") {
                if ops.simulateRateLimit {
                    return HTTPResponseData(statusCode: 429, headers: ["Retry-After": "1"], body: Data())
                }
                let q = json["query"] as? String ?? ""
                if q.localizedCaseInsensitiveContains("Unsearchable") {
                    return HTTPResponseData(statusCode: 200, body: Data(#"{"contents":{"tabbedSearchResultsRenderer":{"tabs":[]}}}"#.utf8))
                }
                let searchResp = """
                {
                  "contents": {
                    "tabbedSearchResultsRenderer": {
                      "tabs": [{"tabRenderer": {"content": {"sectionListRenderer": {"contents": [{
                        "musicShelfRenderer": {
                          "contents": [
                            \(Self.makeTrackRendererJSON(videoID: "ytVidAdded", setVideoID: nil, title: "Hello World", artist: "Tester", duration: "3:20", explicit: false))
                          ]
                        }
                      }]}}}}]
                    }
                  }
                }
                """
                return HTTPResponseData(statusCode: 200, body: Data(searchResp.utf8))
            }

            if urlStr.contains("/youtubei/v1/playlist/create") {
                XCTAssertTrue(req.value(forHTTPHeaderField: "Authorization")?.hasPrefix("SAPISIDHASH ") == true)
                ops.recordCreate(title: json["title"] as? String)
                return HTTPResponseData(statusCode: 200, body: Data(#"{"playlistId":"PLnewCreated777"}"#.utf8))
            }

            if urlStr.contains("/youtubei/v1/browse/edit_playlist") {
                XCTAssertTrue(req.value(forHTTPHeaderField: "Authorization")?.hasPrefix("SAPISIDHASH ") == true)
                let actions = json["actions"] as? [[String: Any]] ?? []
                for act in actions {
                    let kind = act["action"] as? String ?? ""
                    switch kind {
                    case "ACTION_SET_PLAYLIST_NAME":
                        ops.recordRename(act["playlistName"] as? String)
                    case "ACTION_MOVE_VIDEO_BEFORE":
                        ops.recordReorder(setID: act["setVideoId"] as? String, successor: act["movedSetVideoIdSuccessor"] as? String)
                    case "ACTION_ADD_VIDEO":
                        ops.recordAdd(act["addedVideoId"] as? String)
                        return HTTPResponseData(
                            statusCode: 200,
                            body: Data(#"{"status":"STATUS_SUCCEEDED","playlistEditResults":[{"playlistEditVideoAddedResultData":{"videoId":"ytVidAdded","setVideoId":"newSetUID1"}}]}"#.utf8)
                        )
                    case "ACTION_REMOVE_VIDEO":
                        ops.recordRemove(videoID: act["removedVideoId"] as? String, setID: act["setVideoId"] as? String)
                    case "ACTION_SET_CUSTOM_THUMBNAIL":
                        let thumb = act["addedCustomThumbnail"] as? [String: Any]
                        ops.recordCoverBlob(thumb?["playlistScottyEncryptedBlobId"] as? String)
                    default:
                        break
                    }
                }
                return HTTPResponseData(statusCode: 200, body: Data(#"{"status":"STATUS_SUCCEEDED"}"#.utf8))
            }

            return HTTPResponseData(statusCode: 404, body: Data())
        }

        let source = YouTubeMusicSource(transport: transport)
        let recorder = YTTestRuntimeRecorder()
        try await source.initialize(
            params: PluginInitializeParams(
                apiVersion: 1,
                host: PluginHostInfo(os: "macos", arch: "arm64", appVersion: "0.1", onIPod: true),
                paths: PluginPaths(data: "", cache: "", temp: "")
            ),
            context: recorder
        )

        let loginStatus = try await source.login(key: "account", fields: [
            "cookie": "SAPISID=sapi123; __Secure-3PAPISID=sapi3p; SID=sidval"
        ])
        XCTAssertEqual(loginStatus.status, "signedIn")
        XCTAssertEqual(loginStatus.displayName, "Julien")

        try await source.renamePlaylist(request: PlaylistRenameRequest(playlistID: "PLmine", name: "Renamed YTM"))
        XCTAssertEqual(ops.renamedTitle, "Renamed YTM")

        try await source.reorder(request: PlaylistReorderRequest(
            playlistID: "PLmine",
            movedItemUIDs: ["setA"],
            beforeItemUID: "setC",
            afterItemUID: nil,
            atStart: false,
            atEnd: false,
            rangeStart: 0,
            rangeLength: 1,
            insertBefore: 2
        ))
        XCTAssertEqual(ops.reorderedSetID, "setA")
        XCTAssertEqual(ops.reorderedSuccessor, "setC")

        let added = try await source.addTracks(request: PlaylistAddTracksRequest(
            playlistID: "PLmine",
            tracks: [
                PlaylistAddTrackInput(title: "Hello World", artist: "Tester", durationMs: 200_000),
                PlaylistAddTrackInput(title: "Unsearchable Song", artist: "Nobody", durationMs: 180_000),
            ]
        ))
        XCTAssertEqual(added.added.count, 1)
        XCTAssertEqual(added.added[0].matchedTrack.sourceID, "ytVidAdded")
        XCTAssertEqual(added.added[0].matchedTrack.remoteItemUID, "newSetUID1")
        XCTAssertEqual(added.notFoundTitles, ["Unsearchable Song"])
        XCTAssertEqual(ops.addedVideoID, "ytVidAdded")

        try await source.removeTracks(request: PlaylistRemoveTracksRequest(
            playlistID: "PLmine",
            trackIDs: ["ytVidAdded"],
            itemUIDs: ["newSetUID1"]
        ))
        XCTAssertEqual(ops.removedVideoID, "ytVidAdded")
        XCTAssertEqual(ops.removedSetID, "newSetUID1")

        let created = try await source.createPlaylist(request: PlaylistCreateRequest(name: "Fresh YTM List"))
        XCTAssertEqual(created.playlist.source, "youtube-music")
        XCTAssertEqual(created.playlist.sourceID, "PLnewCreated777")
        XCTAssertEqual(created.url.absoluteString, "https://music.youtube.com/playlist?list=PLnewCreated777")
        XCTAssertEqual(ops.createdTitle, "Fresh YTM List")

        try await source.setPlaylistArtwork(request: PlaylistArtworkRequest(
            playlistID: "PLmine",
            jpegData: Data([0xFF, 0xD8, 0xFF, 0xD9])
        ))
        XCTAssertTrue(ops.didUploadCover)
        XCTAssertEqual(ops.coverBlobID, "BLOB_XYZ_99")
    }

    func testListUserPlaylistsPaginationAndUnauthorized() async throws {
        let transport = MockYTMusicTransport { req in
            let urlStr = req.url?.absoluteString ?? ""
            if req.httpMethod == "GET" && urlStr == "https://music.youtube.com" {
                let html = #"ytcfg.set({"INNERTUBE_API_KEY":"KeyList","INNERTUBE_CLIENT_VERSION":"1.20261117.06.00"});"#
                return HTTPResponseData(statusCode: 200, body: Data(html.utf8))
            }
            if urlStr.contains("/youtubei/v1/account/account_menu") {
                return HTTPResponseData(statusCode: 200, body: Data(#"{"accountName":{"runs":[{"text":"Julien"}]}}"#.utf8))
            }
            if urlStr.contains("/youtubei/v1/browse"),
               let body = req.httpBody,
               let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] {
                if (json["browseId"] as? String) == "FEmusic_liked_playlists" {
                    let page1 = """
                    {
                      "contents": {
                        "singleColumnBrowseResultsRenderer": {
                          "tabs": [{
                            "tabRenderer": {
                              "content": {
                                "sectionListRenderer": {
                                  "contents": [{
                                    "gridRenderer": {
                                      "items": [
                                        {
                                          "musicTwoRowItemRenderer": {
                                            "title": {"runs": [{"text": "Your Likes"}]},
                                            "subtitle": {"runs": [{"text": "Auto playlist"}, {"text": " • "}, {"text": "42 songs"}]},
                                            "navigationEndpoint": {"browseEndpoint": {"browseId": "VLLM"}},
                                            "thumbnailRenderer": {"musicThumbnailRenderer": {"thumbnail": {"thumbnails": [{"url": "https://yt3.googleusercontent.com/likes.jpg", "width": 544, "height": 544}]}}}
                                          }
                                        },
                                        {
                                          "musicTwoRowItemRenderer": {
                                            "title": {"runs": [{"text": "Episodes for Later"}]},
                                            "subtitle": {"runs": [{"text": "Auto playlist"}]},
                                            "navigationEndpoint": {"browseEndpoint": {"browseId": "VLSE"}}
                                          }
                                        },
                                        {
                                          "musicTwoRowItemRenderer": {
                                            "title": {"runs": [{"text": "Morning Coffee"}]},
                                            "subtitle": {"runs": [{"text": "Playlist"}, {"text": " • "}, {"text": "Julien"}, {"text": " • "}, {"text": "18 tracks"}]},
                                            "navigationEndpoint": {"browseEndpoint": {"browseId": "VLPLcoffee123"}}
                                          }
                                        }
                                      ],
                                      "continuations": [{"nextContinuationData": {"continuation": "CONT_YTM_PL_2"}}]
                                    }
                                  }]
                                }
                              }
                            }
                          }]
                        }
                      }
                    }
                    """
                    return HTTPResponseData(statusCode: 200, body: Data(page1.utf8))
                }
                if (json["continuation"] as? String) == "CONT_YTM_PL_2" {
                    let page2 = """
                    {
                      "onResponseReceivedActions": [{
                        "appendContinuationItemsAction": {
                          "continuationItems": [
                            {
                              "musicResponsiveListItemRenderer": {
                                "navigationEndpoint": {"browseEndpoint": {"browseId": "VLPLnight999"}},
                                "flexColumns": [
                                  {"musicResponsiveListItemFlexColumnRenderer": {"text": {"runs": [{"text": "Night Run"}]}}},
                                  {"musicResponsiveListItemFlexColumnRenderer": {"text": {"runs": [{"text": "Alex"}, {"text": " • "}, {"text": "9 songs"}]}}}
                                ]
                              }
                            }
                          ]
                        }
                      }]
                    }
                    """
                    return HTTPResponseData(statusCode: 200, body: Data(page2.utf8))
                }
            }
            return HTTPResponseData(statusCode: 404, body: Data())
        }

        let source = YouTubeMusicSource(transport: transport)
        try await source.initialize(
            params: PluginInitializeParams(
                host: PluginHostInfo(os: "macos", arch: "arm64", appVersion: "0.1", onIPod: false),
                paths: PluginPaths(data: "", cache: "", temp: "")
            ),
            context: YTTestRuntimeRecorder()
        )

        do {
            _ = try await source.listUserPlaylists()
            XCTFail("Expected .unauthorized when signed out")
        } catch let err as PluginError {
            XCTAssertEqual(err.code, .unauthorized)
        }

        _ = try await source.login(key: "account", fields: [
            "cookie": "SAPISID=abc123; __Secure-3PAPISID=abc123; SID=sidval",
        ])

        let lists = try await source.listUserPlaylists()
        XCTAssertEqual(lists.count, 3)
        XCTAssertEqual(lists[0].id, "LM")
        XCTAssertEqual(lists[0].trackCount, 42)
        XCTAssertEqual(lists[1].id, "PLcoffee123")
        XCTAssertEqual(lists[1].owner, "Julien")
        XCTAssertEqual(lists[1].trackCount, 18)
        XCTAssertEqual(lists[1].url.absoluteString, "https://music.youtube.com/playlist?list=PLcoffee123")
        XCTAssertEqual(lists[2].id, "PLnight999")
        XCTAssertEqual(lists[2].title, "Night Run")
        XCTAssertEqual(lists[2].owner, "Alex")
        XCTAssertEqual(lists[2].trackCount, 9)
    }

    func testListUserPlaylistsFallbackLikedSongsAndLoggedOut() async throws {
        final class ModeState: @unchecked Sendable {
            private let lock = NSLock()
            private var _loggedOut = false
            var loggedOut: Bool {
                get { lock.withLock { _loggedOut } }
                set { lock.withLock { _loggedOut = newValue } }
            }
        }
        let mode = ModeState()

        let transport = MockYTMusicTransport { req in
            let urlStr = req.url?.absoluteString ?? ""
            if req.httpMethod == "GET" && urlStr == "https://music.youtube.com" {
                return HTTPResponseData(
                    statusCode: 200,
                    body: Data(#"ytcfg.set({"INNERTUBE_API_KEY":"KeyFallback","INNERTUBE_CLIENT_VERSION":"1.20261117.06.00"});"#.utf8)
                )
            }
            if urlStr.contains("/youtubei/v1/account/account_menu") {
                return HTTPResponseData(statusCode: 200, body: Data(#"{"accountName":{"runs":[{"text":"Julien"}]}}"#.utf8))
            }
            if urlStr.contains("/youtubei/v1/browse"),
               let body = req.httpBody,
               let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
               let browseID = json["browseId"] as? String {
                if mode.loggedOut {
                    return HTTPResponseData(
                        statusCode: 200,
                        body: Data(#"{"responseContext":{"mainAppWebResponseContext":{"loggedOut":true}},"contents":{}}"#.utf8)
                    )
                }
                if browseID == "FEmusic_liked_playlists" {
                    // Empty liked_playlists -> triggers FEmusic_library_landing + VLLM probe
                    return HTTPResponseData(
                        statusCode: 200,
                        body: Data(#"{"contents":{"singleColumnBrowseResultsRenderer":{"tabs":[{"tabRenderer":{"content":{"sectionListRenderer":{"contents":[]}}}}]}}}"#.utf8)
                    )
                }
                if browseID == "FEmusic_library_landing" {
                    let landing = """
                    {
                      "contents": {
                        "singleColumnBrowseResultsRenderer": {
                          "tabs": [{
                            "tabRenderer": {
                              "content": {
                                "sectionListRenderer": {
                                  "contents": [{
                                    "richGridRenderer": {
                                      "contents": [{
                                        "richItemRenderer": {
                                          "content": {
                                            "musicTwoRowItemRenderer": {
                                              "title": {"runs": [{"text": "Mix Perso", "navigationEndpoint": {"browseEndpoint": {"browseId": "VLPLperso55"}}}]},
                                              "subtitle": {"runs": [{"text": "Julien"}]}
                                            }
                                          }
                                        }
                                      }]
                                    }
                                  }]
                                }
                              }
                            }
                          }]
                        }
                      }
                    }
                    """
                    return HTTPResponseData(statusCode: 200, body: Data(landing.utf8))
                }
                if browseID == "VLLM" {
                    let vllm = """
                    {
                      "header": {
                        "musicEditablePlaylistDetailHeaderRenderer": {
                          "header": {
                            "musicResponsiveHeaderRenderer": {
                              "title": {"runs": [{"text": "Chansons aimées"}]},
                              "subtitle": {"runs": [{"text": "Playlist"}]}
                            }
                          }
                        }
                      },
                      "contents": {
                        "singleColumnBrowseResultsRenderer": {
                          "tabs": [{
                            "tabRenderer": {
                              "content": {
                                "sectionListRenderer": {
                                  "contents": [{
                                    "musicPlaylistShelfRenderer": {
                                      "contents": [
                                        \(Self.makeTrackRendererJSON(videoID: "liked1", setVideoID: nil, title: "Liked Song", artist: "Artist", duration: "2:50", explicit: false))
                                      ]
                                    }
                                  }]
                                }
                              }
                            }
                          }]
                        }
                      }
                    }
                    """
                    return HTTPResponseData(statusCode: 200, body: Data(vllm.utf8))
                }
            }
            return HTTPResponseData(statusCode: 404, body: Data())
        }

        let source = YouTubeMusicSource(transport: transport)
        try await source.initialize(
            params: PluginInitializeParams(
                host: PluginHostInfo(os: "macos", arch: "arm64", appVersion: "0.1", onIPod: false),
                paths: PluginPaths(data: "", cache: "", temp: "")
            ),
            context: YTTestRuntimeRecorder()
        )
        _ = try await source.login(key: "account", fields: [
            "cookie": "SAPISID=abc123; __Secure-3PAPISID=abc123; SID=sidval",
        ])

        let lists = try await source.listUserPlaylists()
        XCTAssertEqual(lists.count, 2)
        XCTAssertEqual(lists[0].id, "LM")
        XCTAssertEqual(lists[0].title, "Chansons aimées")
        XCTAssertEqual(lists[0].url.absoluteString, "https://music.youtube.com/playlist?list=LM")
        XCTAssertEqual(lists[0].trackCount, 1)
        XCTAssertEqual(lists[1].id, "PLperso55")
        XCTAssertEqual(lists[1].title, "Mix Perso")

        mode.loggedOut = true
        do {
            _ = try await source.listUserPlaylists()
            XCTFail("Expected .unauthorized when InnerTube reports loggedOut: true")
        } catch let err as PluginError {
            XCTAssertEqual(err.code, .unauthorized)
        }
    }

    func testUserCreatedPlaylistsSortAfterLikedAndHTMLFallback() throws {
        let items = [
            RemotePlaylistSummary(id: "PLcurated", title: "Curated", owner: "DJ", trackCount: 15, url: URL(string: "https://music.youtube.com/playlist?list=PLcurated")!, isLikedSongs: false, isOwned: false),
            RemotePlaylistSummary(id: "PLmine", title: "My Mix", owner: "Julien", trackCount: 8, url: URL(string: "https://music.youtube.com/playlist?list=PLmine")!, isLikedSongs: false, isOwned: true),
            RemotePlaylistSummary(id: "LM", title: "Chansons aimées", owner: "Julien", trackCount: 120, url: URL(string: "https://music.youtube.com/playlist?list=LM")!, isLikedSongs: true, isOwned: true),
        ]
        let sorted = RemotePlaylistSummary.sortedForDisplay(items)
        XCTAssertEqual(sorted.map(\.id), ["LM", "PLmine", "PLcurated"])

        let libraryHTML = #"""
        <script>initialData.push({path: '/library/playlists', data: '{"contents":{"singleColumnBrowseResultsRenderer":{"tabs":[{"tabRenderer":{"content":{"sectionListRenderer":{"contents":[{"gridRenderer":{"items":[{"musicTwoRowItemRenderer":{"title":{"runs":[{"text":"Vidéos aimées"}]},"subtitle":{"runs":[{"text":"Playlist • 19 vidéos"}]},"navigationEndpoint":{"browseEndpoint":{"browseId":"VLLM"}}}},{"musicTwoRowItemRenderer":{"title":{"runs":[{"text":"Road Trip"}]},"subtitle":{"runs":[{"text":"Privée • 14 titres"}]},"navigationEndpoint":{"browseEndpoint":{"browseId":"VLPLroad"}}}}]}}]}}}}]}}}'});</script>
        """#
        let parsedHTML = try XCTUnwrap(YTMusicParsers.parseLibraryHTMLPlaylists(html: libraryHTML, currentDisplayName: "Julien"))
        XCTAssertEqual(parsedHTML.playlists.count, 2)
        XCTAssertEqual(parsedHTML.playlists[0].id, "LM")
        XCTAssertEqual(parsedHTML.playlists[0].trackCount, 19)
        XCTAssertTrue(parsedHTML.playlists[0].isLikedSongs)
        XCTAssertEqual(parsedHTML.playlists[1].id, "PLroad")
        XCTAssertEqual(parsedHTML.playlists[1].trackCount, 14)
        XCTAssertEqual(parsedHTML.playlists[1].isOwned, true)
    }

    func testExtractClientConfigDelegatedSessionAndModernLibraryHTML() throws {
        let htmlWithDelegated = """
        <script>ytcfg.set({"INNERTUBE_API_KEY":"key123","INNERTUBE_CLIENT_VERSION":"1.20261120.01.00","VISITOR_DATA":"vis123","SESSION_INDEX":2,"DELEGATED_SESSION_ID":"109876543210","LOGGED_IN":true});</script>
        """
        let cfg = try InnerTube.extractClientConfig(fromHTML: htmlWithDelegated, fallbackClientVersion: "1.0")
        XCTAssertEqual(cfg.apiKey, "key123")
        XCTAssertEqual(cfg.sessionIndex, "2")
        XCTAssertEqual(cfg.delegatedSessionID, "109876543210")
        XCTAssertEqual(cfg.loggedIn, true)

        let session = YTMusicUserSession(cookieHeader: "SAPISID=abc; __Secure-3PAPISID=xyz", displayName: "Julien", authUser: nil)
        let req = try XCTUnwrap(InnerTube.makeAPIRequest(
            endpoint: "browse",
            payload: ["browseId": "FEmusic_liked_playlists"],
            clientConfig: cfg,
            userAgent: "UA",
            session: session
        ))
        XCTAssertEqual(req.value(forHTTPHeaderField: "X-Goog-PageId"), "109876543210")
        XCTAssertEqual(req.value(forHTTPHeaderField: "X-Goog-AuthUser"), "2")
        let bodyJSON = try XCTUnwrap(try JSONSerialization.jsonObject(with: try XCTUnwrap(req.httpBody)) as? [String: Any])
        let ctxUser = ((bodyJSON["context"] as? [String: Any])?["user"] as? [String: Any])
        XCTAssertEqual(ctxUser?["onBehalfOfUser"] as? String, "109876543210")

        // Ensure `params: JSON.parse('{"browseId":...}')` + `\x7b`/`\x22` hex escapes + `lockupViewModel` parse cleanly.
        let lockupJSON = #"{"contents":{"singleColumnBrowseResultsRenderer":{"tabs":[{"tabRenderer":{"content":{"sectionListRenderer":{"contents":[{"gridRenderer":{"items":[{"lockupViewModel":{"contentId":"PLlockup99","contentType":"LOCKUP_CONTENT_TYPE_PLAYLIST","rendererContext":{"commandContext":{"onTap":{"innertubeCommand":{"browseEndpoint":{"browseId":"VLPLlockup99"}}}}},"metadata":{"lockupMetadataViewModel":{"title":{"content":"Late Night Mix"},"metadata":{"contentMetadataViewModel":{"metadataRows":[{"metadataParts":[{"text":{"content":"Playlist • Julien"}}]},{"metadataParts":[{"text":{"content":"27 tracks"}}]}]}}}}}}]}}]}}}}]}}}"#
        let escapedData = lockupJSON
            .replacingOccurrences(of: "{", with: #"\x7b"#)
            .replacingOccurrences(of: "}", with: #"\x7d"#)
            .replacingOccurrences(of: "\"", with: #"\x22"#)
            .replacingOccurrences(of: "[", with: #"\x5b"#)
            .replacingOccurrences(of: "]", with: #"\x5d"#)
        let realPushHTML = """
        <script>initialData.push({path: '\\/browse', params: JSON.parse('{"browseId":"FEmusic_liked_playlists"}'), data: '\(escapedData)'});</script>
        """
        let parsed = try XCTUnwrap(YTMusicParsers.parseLibraryHTMLPlaylists(html: realPushHTML, currentDisplayName: "Julien"))
        XCTAssertEqual(parsed.playlists.count, 1)
        XCTAssertEqual(parsed.playlists[0].id, "PLlockup99")
        XCTAssertEqual(parsed.playlists[0].title, "Late Night Mix")
        XCTAssertEqual(parsed.playlists[0].trackCount, 27)
        XCTAssertEqual(parsed.playlists[0].isOwned, true)

        XCTAssertTrue(YTMusicParsers.isHTMLPageLoggedOut(#"<script>ytcfg.set({"LOGGED_IN":false});</script>"#))
        XCTAssertFalse(YTMusicParsers.isHTMLPageLoggedOut(htmlWithDelegated))
    }

    func testParsesVideoVsAlbumTrackTypeAndSkipsRedundantReorderFetch() async throws {
        let playlistJSON = #"""
        {
          "contents": {
            "twoColumnBrowseResultsRenderer": {
              "tabs": [{"tabRenderer":{"content":{"sectionListRenderer":{"contents":[{"musicResponsiveHeaderRenderer":{"title":{"runs":[{"text":"Mixed List"}]}}}]}}}}],
              "secondaryContents": {
                "sectionListRenderer": {
                  "contents": [{
                    "musicPlaylistShelfRenderer": {
                      "contents": [
                        {
                          "musicResponsiveListItemRenderer": {
                            "playlistItemData": {"videoId": "omvVid1", "playlistSetVideoId": "SET_OMV"},
                            "overlay": {"musicItemThumbnailOverlayRenderer":{"content":{"musicPlayButtonRenderer":{"playNavigationEndpoint":{"watchEndpoint":{"videoId":"omvVid1","watchEndpointMusicSupportedConfigs":{"watchEndpointMusicConfig":{"musicVideoType":"MUSIC_VIDEO_TYPE_OMV"}}}}}}}},
                            "thumbnail": {"musicThumbnailRenderer":{"thumbnail":{"thumbnails":[{"url":"https://i.ytimg.com/vi/omvVid1/hqdefault.jpg","width":480,"height":360}]}}},
                            "flexColumns": [
                              {"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"My Song (Live Video)"}]}}},
                              {"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Artist Name"}]}}}
                            ]
                          }
                        },
                        {
                          "musicResponsiveListItemRenderer": {
                            "playlistItemData": {"videoId": "atvSong2", "playlistSetVideoId": "SET_ATV"},
                            "overlay": {"musicItemThumbnailOverlayRenderer":{"content":{"musicPlayButtonRenderer":{"playNavigationEndpoint":{"watchEndpoint":{"videoId":"atvSong2","watchEndpointMusicSupportedConfigs":{"watchEndpointMusicConfig":{"musicVideoType":"MUSIC_VIDEO_TYPE_ATV"}}}}}}}},
                            "thumbnail": {"musicThumbnailRenderer":{"thumbnail":{"thumbnails":[{"url":"https://lh3.googleusercontent.com/art=w544-h544","width":544,"height":544}]}}},
                            "flexColumns": [
                              {"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"My Song"}]}}},
                              {"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Artist Name","navigationEndpoint":{"browseEndpoint":{"browseId":"UC1"}}}]}}},
                              {"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Album Title","navigationEndpoint":{"browseEndpoint":{"browseId":"MPREb_alb1"}}}]}}}
                            ]
                          }
                        }
                      ]
                    }
                  }]
                }
              }
            }
          }
        }
        """#
        let target = try YouTubeMusicURL.parse("https://music.youtube.com/playlist?list=PLmixed")
        let page = try YTMusicParsers.parseBrowseInitial(data: Data(playlistJSON.utf8), target: target)
        XCTAssertEqual(page.tracks.count, 2)
        XCTAssertEqual(page.tracks[0].isVideo, true)
        XCTAssertEqual(page.tracks[1].isVideo, false)

        let mode = SendableYTMusicOpsState()
        let browseCalls = LockedYTCounter()
        let transport = MockYTMusicTransport { req in
            let url = req.url?.absoluteString ?? ""
            if url == "https://music.youtube.com" {
                return HTTPResponseData(statusCode: 200, body: Data(#"ytcfg.set({"INNERTUBE_API_KEY":"KeyReorder","INNERTUBE_CLIENT_VERSION":"1.0"});"#.utf8))
            }
            if url.contains("/youtubei/v1/browse/edit_playlist") {
                if let body = req.httpBody,
                   let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                   let actions = json["actions"] as? [[String: Any]],
                   let act = actions.first {
                    mode.recordReorder(
                        setID: act["setVideoId"] as? String,
                        successor: act["movedSetVideoIdSuccessor"] as? String
                    )
                }
                return HTTPResponseData(statusCode: 200, body: Data(#"{"status":"STATUS_SUCCEEDED"}"#.utf8))
            }
            if url.contains("/youtubei/v1/browse") {
                browseCalls.increment()
            }
            return HTTPResponseData(statusCode: 404, body: Data())
        }
        let source = YouTubeMusicSource(transport: transport)
        try await source.initialize(
            params: PluginInitializeParams(host: PluginHostInfo(os: "macos", arch: "arm64", appVersion: "1.0", onIPod: false), paths: PluginPaths(data: "", cache: "", temp: "")),
            context: YTTestRuntimeRecorder()
        )
        _ = try await source.login(key: "account", fields: ["cookie": "SAPISID=abc; __Secure-3PAPISID=xyz"])
        try await source.reorder(request: PlaylistReorderRequest(
            playlistID: "PLmixed",
            movedItemUIDs: ["SET_OMV"],
            beforeItemUID: "SET_ATV",
            afterItemUID: nil,
            atStart: false,
            atEnd: false,
            rangeStart: 0,
            rangeLength: 1,
            insertBefore: 1
        ))
        XCTAssertEqual(browseCalls.value, 0, "Reorder with known UIDs should not perform a redundant browse fetch")
        XCTAssertEqual(mode.reorderedSetID, "SET_OMV")
        XCTAssertEqual(mode.reorderedSuccessor, "SET_ATV")
    }

    func testFetchLoggedOutPrivatePlaylistThrowsUnauthorizedAndLoginPreservesSession() async throws {
        let htmlPlaylistJSON = #"{"contents":{"twoColumnBrowseResultsRenderer":{"tabs":[{"tabRenderer":{"content":{"sectionListRenderer":{"contents":[{"musicResponsiveHeaderRenderer":{"title":{"runs":[{"text":"radioheadz"}]}}}]}}}}],"secondaryContents":{"sectionListRenderer":{"contents":[{"musicPlaylistShelfRenderer":{"contents":[{"musicResponsiveListItemRenderer":{"playlistItemData":{"videoId":"rh01","playlistSetVideoId":"SETRH1"},"flexColumns":[{"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Everything In Its Right Place"}]}}},{"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Radiohead"}]}}}]}}]}}]}}}}}"#
        let escapedPlaylistData = htmlPlaylistJSON
            .replacingOccurrences(of: "{", with: #"\x7b"#)
            .replacingOccurrences(of: "}", with: #"\x7d"#)
            .replacingOccurrences(of: "\"", with: #"\x22"#)
            .replacingOccurrences(of: "[", with: #"\x5b"#)
            .replacingOccurrences(of: "]", with: #"\x5d"#)
        let htmlFallbackBody = """
        <script>initialData.push({path: '/browse', params: JSON.parse('{"browseId":"VLPLhtmlpriv"}'), data: '\(escapedPlaylistData)'});</script>
        """
        let recordedAuthUsers = LockedYTStrings()
        let recordedPageIDs = LockedYTStrings()

        let transport = MockYTMusicTransport { req in
            let url = req.url?.absoluteString ?? ""
            if url == "https://music.youtube.com" {
                return HTTPResponseData(statusCode: 200, body: Data(#"ytcfg.set({"INNERTUBE_API_KEY":"KeyPriv","INNERTUBE_CLIENT_VERSION":"1.0"});"#.utf8))
            }
            if url.contains("/youtubei/v1/browse"),
               let body = req.httpBody,
               let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
               let browseID = json["browseId"] as? String {
                if let au = req.value(forHTTPHeaderField: "X-Goog-AuthUser") { recordedAuthUsers.append(au) }
                if let pid = req.value(forHTTPHeaderField: "X-Goog-PageId") { recordedPageIDs.append(pid) }
                if browseID == "VLPLloggedout" {
                    let body = #"{"responseContext":{"mainAppWebResponseContext":{"loggedOut":true}},"alerts":[{"alertRenderer":{"text":{"runs":[{"text":"This playlist does not exist."}]}}}]}"#
                    return HTTPResponseData(statusCode: 200, body: Data(body.utf8))
                }
                if browseID == "VLPLhtmlpriv" {
                    return HTTPResponseData(statusCode: 200, body: Data(#"{"responseContext":{"mainAppWebResponseContext":{"loggedOut":false}}}"#.utf8))
                }
            }
            if url.contains("https://music.youtube.com/playlist?list=PLhtmlpriv") {
                return HTTPResponseData(statusCode: 200, body: Data(htmlFallbackBody.utf8))
            }
            return HTTPResponseData(statusCode: 404, body: Data())
        }

        let source = YouTubeMusicSource(transport: transport)
        try await source.initialize(
            params: PluginInitializeParams(host: PluginHostInfo(os: "macos", arch: "arm64", appVersion: "1.0", onIPod: false), paths: PluginPaths(data: "", cache: "", temp: "")),
            context: YTTestRuntimeRecorder()
        )
        // Login with explicit authUser + delegatedSessionID + displayName
        _ = try await source.login(key: "account", fields: [
            "cookie": "SAPISID=abc; __Secure-3PAPISID=xyz",
            "authUser": "2",
            "delegatedSessionID": "DEL_99",
            "displayName": "JulienYT",
        ])
        // Partial refresh omitting authUser / delegatedSessionID must preserve existing authUser "2" and delegatedSessionID "DEL_99".
        _ = try await source.login(key: "account", fields: [
            "cookie": "SAPISID=abc2; __Secure-3PAPISID=xyz2",
        ])

        do {
            _ = try await source.fetch(url: URL(string: "https://music.youtube.com/playlist?list=PLloggedout")!)
            XCTFail("Expected .unauthorized when InnerTube reports loggedOut: true for unavailable private playlist")
        } catch let err as PluginError {
            XCTAssertEqual(err.code, .unauthorized)
        }
        XCTAssertTrue(recordedAuthUsers.values.contains("2"))
        XCTAssertTrue(recordedPageIDs.values.contains("DEL_99"))

        // When browse lacks contents for private list but signed-in HTML includes playlist data, HTML fallback succeeds.
        let htmlFetched = try await source.fetch(url: URL(string: "https://music.youtube.com/playlist?list=PLhtmlpriv")!)
        XCTAssertEqual(htmlFetched.playlist.title, "radioheadz")
        XCTAssertEqual(htmlFetched.tracks.map(\.title), ["Everything In Its Right Place"])

        // account_menu display name resolver supports simpleText + channelHandle without brittle regexes.
        let simpleMenu: [String: Any] = [
            "actions": [[
                "openPopupAction": [
                    "popup": [
                        "multiPageMenuRenderer": [
                            "header": [
                                "activeAccountHeaderRenderer": [
                                    "accountName": ["simpleText": "Julien"],
                                    "channelHandle": ["simpleText": "@julienmusic"],
                                ]
                            ]
                        ]
                    ]
                ]
            ]]
        ]
        XCTAssertEqual(YTMusicParsers.extractAccountDisplayName(from: simpleMenu), "Julien (@julienmusic)")
    }

    // MARK: - Helpers

    private static func makeTrackRendererJSON(
        videoID: String,
        setVideoID: String?,
        title: String,
        artist: String?,
        duration: String,
        explicit: Bool
    ) -> String {
        let itemData = setVideoID.map { #""playlistItemData": {"videoId": "\#(videoID)", "playlistSetVideoId": "\#($0)"}"# }
            ?? #""playlistItemData": {"videoId": "\#(videoID)"}"#
        let artistCol = artist.map {
            #"{"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"\#($0)","navigationEndpoint":{"browseEndpoint":{"browseId":"UCartist1"}}}]}}}"#
        } ?? #"{"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[]}}}"#
        let badges = explicit
            ? #""badges":[{"musicInlineBadgeRenderer":{"icon":{"iconType":"MUSIC_EXPLICIT_BADGE"}}}],"#
            : ""
        return """
        {
          "musicResponsiveListItemRenderer": {
            \(itemData),
            \(badges)
            "thumbnail": {"musicThumbnailRenderer": {"thumbnail": {"thumbnails": [{"url": "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg", "width": 480, "height": 360}]}}},
            "flexColumns": [
              {"musicResponsiveListItemFlexColumnRenderer": {"text": {"runs": [{"text": "\(title)"}]}}},
              \(artistCol),
              {"musicResponsiveListItemFlexColumnRenderer": {"text": {"runs": []}}}
            ],
            "fixedColumns": [
              {"musicResponsiveListItemFixedColumnRenderer": {"text": {"runs": [{"text": "\(duration)"}]}}}
            ]
          }
        }
        """
    }
}

private final class MockYTMusicTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _callCount = 0
    private let handler: @Sendable (URLRequest) async throws -> HTTPResponseData

    var callCount: Int {
        lock.withLock { _callCount }
    }

    init(handler: @escaping @Sendable (URLRequest) async throws -> HTTPResponseData) {
        self.handler = handler
    }

    func send(_ request: URLRequest) async throws -> HTTPResponseData {
        lock.withLock { _callCount += 1 }
        return try await handler(request)
    }
}

private final class YTTestRuntimeRecorder: PluginRuntimeContext, @unchecked Sendable {
    func log(_ level: PluginLogLevel, _ message: String) async {}
    func reportStatus(_ state: PluginRuntimeState, message: String?) async {}
    func reportAccountStatus(_ status: PluginAccountStatus) async {}
}

private final class SendableYTMusicOpsState: @unchecked Sendable {
    private let lock = NSLock()
    private var _renamedTitle: String?
    private var _reorderedSetID: String?
    private var _reorderedSuccessor: String?
    private var _addedVideoID: String?
    private var _removedVideoID: String?
    private var _removedSetID: String?
    private var _createdTitle: String?
    private var _didUploadCover = false
    private var _coverBlobID: String?
    private var _simulateRateLimit = false

    var renamedTitle: String? { lock.withLock { _renamedTitle } }
    var reorderedSetID: String? { lock.withLock { _reorderedSetID } }
    var reorderedSuccessor: String? { lock.withLock { _reorderedSuccessor } }
    var addedVideoID: String? { lock.withLock { _addedVideoID } }
    var removedVideoID: String? { lock.withLock { _removedVideoID } }
    var removedSetID: String? { lock.withLock { _removedSetID } }
    var createdTitle: String? { lock.withLock { _createdTitle } }
    var didUploadCover: Bool { lock.withLock { _didUploadCover } }
    var coverBlobID: String? { lock.withLock { _coverBlobID } }
    var simulateRateLimit: Bool { lock.withLock { _simulateRateLimit } }

    func recordRename(_ val: String?) { lock.withLock { _renamedTitle = val } }
    func recordReorder(setID: String?, successor: String?) {
        lock.withLock {
            _reorderedSetID = setID
            _reorderedSuccessor = successor
        }
    }
    func recordAdd(_ id: String?) { lock.withLock { _addedVideoID = id } }
    func recordRemove(videoID: String?, setID: String?) {
        lock.withLock {
            _removedVideoID = videoID
            _removedSetID = setID
        }
    }
    func recordCreate(title: String?) { lock.withLock { _createdTitle = title } }
    func markCoverUploaded() { lock.withLock { _didUploadCover = true } }
    func recordCoverBlob(_ id: String?) { lock.withLock { _coverBlobID = id } }
}

private final class LockedYTCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int { lock.withLock { _value } }
    func increment() { lock.withLock { _value += 1 } }
}

private final class LockedYTStrings: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [String] = []
    var values: [String] { lock.withLock { _values } }
    func append(_ val: String) { lock.withLock { _values.append(val) } }
}
