import XCTest
import iPodKit
import PluginKit
@testable import MediaKit

final class SubscriptionTests: XCTestCase {
    // MARK: - SUB-10: Library Track Matching & Normalization

    func testLibraryTrackMatcherNormalizationAndTieBreakers() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sub-match-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let dlDir = root.appendingPathComponent("Downloads", isDirectory: true)
        let otherDir = root.appendingPathComponent("Other", isDirectory: true)
        try FileManager.default.createDirectory(at: dlDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: otherDir, withIntermediateDirectories: true)

        let f1 = otherDir.appendingPathComponent("blinding.mp3")
        let f2 = dlDir.appendingPathComponent("blinding.flac")
        let f3 = otherDir.appendingPathComponent("remix.mp3")
        let f4 = otherDir.appendingPathComponent("isrc.m4a")
        for url in [f1, f2, f3, f4] {
            try AudioFixtures.threeSecondMP3.write(to: url)
        }

        let tOtherLow = LibraryTrack(
            path: f1.path,
            title: "Blinding Lights (Remastered 2020) [Explicit]",
            artist: "The Weeknd",
            album: "After Hours",
            durationMs: 200_000,
            bitrate: 192,
            fileExtension: "mp3",
            isLossless: false
        )
        let tDownloadLossless = LibraryTrack(
            path: f2.path,
            title: "Blinding Lights",
            artist: "Weeknd",
            album: "After Hours (Deluxe)",
            durationMs: 201_500,
            bitrate: 1000,
            fileExtension: "flac",
            isLossless: true
        )
        let tRemix = LibraryTrack(
            path: f3.path,
            title: "Midnight City (Eric Prydz Remix)",
            artist: "M83",
            album: "Hurry Up",
            durationMs: 240_000,
            bitrate: 320,
            fileExtension: "mp3"
        )
        let tISRC = LibraryTrack(
            path: f4.path,
            title: "Completely Different Name",
            artist: "Various",
            durationMs: 180_000,
            bitrate: 256,
            fileExtension: "m4a",
            isrc: "USUG11904206"
        )

        let matcher = LibraryTrackMatcher(
            tracks: [tOtherLow, tDownloadLossless, tRemix, tISRC],
            downloadFolderPath: dlDir.path
        )

        // 1. Normalized artist + title + duration tolerance -> prefers download-folder lossless tie-breaker
        let ref1 = TrackRef(
            source: "spotify",
            sourceID: "sp-1",
            title: "Blinding Lights (Official Audio)",
            artists: ["The Weeknd feat. Rosalía"],
            album: "After Hours",
            durationMs: 200_500
        )
        XCTAssertEqual(matcher.match(for: ref1)?.id, tDownloadLossless.id)

        // 2. ISRC exact match wins regardless of title spelling
        let ref2 = TrackRef(
            source: "spotify",
            sourceID: "sp-2",
            title: "Real Title",
            artists: ["Real Artist"],
            isrc: "usug11904206"
        )
        XCTAssertEqual(matcher.match(for: ref2)?.id, tISRC.id)

        // 3. Remix qualifier is preserved (non-remix does NOT match a remix local track)
        let refOriginal = TrackRef(
            source: "spotify",
            sourceID: "sp-3",
            title: "Midnight City",
            artists: ["M83"],
            album: "Hurry Up",
            durationMs: 240_000
        )
        XCTAssertNil(matcher.match(for: refOriginal))

        let refRemix = TrackRef(
            source: "spotify",
            sourceID: "sp-4",
            title: "Midnight City (Eric Prydz Remix)",
            artists: ["M83"],
            durationMs: 240_000
        )
        XCTAssertEqual(matcher.match(for: refRemix)?.id, tRemix.id)
    }

    // MARK: - SUB-11: Candidate Filtering & Ranking

    func testCandidateScorerRejectionsAndOrdering() {
        let ref = TrackRef(
            source: "spotify",
            sourceID: "tr-1",
            title: "Alive Tonight",
            artists: ["Daft Punk"],
            album: "Discovery",
            durationMs: 200_000
        )

        let policy = QualityPolicy(
            preferredFormats: ["flac", "mp3-320", "aac-256"],
            minimumBitrateKbps: 192,
            acceptYouTubeFallback: true
        )

        let rejectedDuration = Candidate(
            resolver: "soulseek",
            token: "dur",
            displayName: "Daft Punk - Alive Tonight.flac",
            title: "Alive Tonight",
            artist: "Daft Punk",
            durationMs: 204_500, // > 3s for non-youtube
            container: "flac",
            codec: "flac"
        )
        let rejectedRemix = Candidate(
            resolver: "soulseek",
            token: "rmx",
            displayName: "Daft Punk - Alive Tonight (Club Remix).mp3",
            title: "Alive Tonight (Club Remix)",
            artist: "Daft Punk",
            durationMs: 200_000,
            container: "mp3",
            bitrateKbps: 320
        )
        let rejectedLowBitrate = Candidate(
            resolver: "soulseek",
            token: "low",
            displayName: "Daft Punk - Alive Tonight.mp3",
            title: "Alive Tonight",
            artist: "Daft Punk",
            durationMs: 200_000,
            container: "mp3",
            bitrateKbps: 128
        )
        let rejectedMissingWord = Candidate(
            resolver: "soulseek",
            token: "miss",
            displayName: "Daft Punk - Alive.flac",
            title: "Alive",
            artist: "Daft Punk",
            durationMs: 200_000,
            container: "flac",
            codec: "flac"
        )
        let acceptedFLAC = Candidate(
            resolver: "soulseek",
            token: "flac-ok",
            displayName: "Daft Punk - Alive Tonight.flac",
            title: "Alive Tonight",
            artist: "Daft Punk",
            durationMs: 201_000,
            container: "flac",
            codec: "flac",
            availability: Availability(freeSlot: true, queueLength: 0, speedBytesPerSec: 1_000_000)
        )
        let acceptedMP3 = Candidate(
            resolver: "soulseek",
            token: "mp3-ok",
            displayName: "Daft Punk - Alive Tonight.mp3",
            title: "Alive Tonight",
            artist: "Daft Punk",
            durationMs: 200_200,
            container: "mp3",
            codec: "mp3",
            bitrateKbps: 320,
            availability: Availability(freeSlot: true, queueLength: 0, speedBytesPerSec: 500_000)
        )
        let acceptedYT = Candidate(
            resolver: "yt-dlp",
            token: "yt-ok",
            displayName: "Daft Punk - Alive Tonight",
            title: "Alive Tonight",
            artist: "Daft Punk",
            durationMs: 204_500, // within ±5s for yt-dlp!
            container: "m4a",
            codec: "aac",
            bitrateKbps: 256
        )

        let ranked = CandidateScorer.rank(
            candidates: [
                rejectedDuration,
                rejectedRemix,
                rejectedLowBitrate,
                rejectedMissingWord,
                acceptedYT,
                acceptedMP3,
                acceptedFLAC,
            ],
            for: ref,
            policy: policy,
            resolverOrder: ["soulseek", "yt-dlp"]
        )

        XCTAssertEqual(ranked.map(\.token), ["flac-ok", "mp3-ok", "yt-ok"])

        // Disabling YouTube fallback excludes yt-dlp candidates immediately
        var noYT = policy
        noYT.acceptYouTubeFallback = false
        let rankedNoYT = CandidateScorer.rank(
            candidates: [acceptedYT, acceptedMP3],
            for: ref,
            policy: noYT,
            resolverOrder: ["soulseek", "yt-dlp"]
        )
        XCTAssertEqual(rankedNoYT.map(\.token), ["mp3-ok"])
    }

    // MARK: - SUB-14: Path Sanitization & Collision Suffix

    func testDownloadPlacementPathsAndCollisions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sub-place-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let longTitle = String(repeating: "Long/Title:Name?", count: 10)
        let ref = TrackRef(
            source: "spotify",
            sourceID: "1",
            title: longTitle,
            artists: ["Artist:One/Two"],
            album: nil,
            albumArtist: nil,
            trackNumber: 3,
            discNumber: 2
        )
        let first = DownloadPlacement.uniqueDestinationURL(for: ref, fileExtension: "mp3", in: root)
        XCTAssertEqual(first.deletingLastPathComponent().lastPathComponent, "Singles")
        XCTAssertEqual(first.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent, "Artist_One_Two")
        XCTAssertTrue(first.lastPathComponent.hasPrefix("2-03 "))
        XCTAssertLessThanOrEqual(first.lastPathComponent.count, 120)

        try FileManager.default.createDirectory(at: first.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0x01]).write(to: first)

        let second = DownloadPlacement.uniqueDestinationURL(for: ref, fileExtension: "mp3", in: root)
        XCTAssertNotEqual(first.path, second.path)
        XCTAssertTrue(second.deletingPathExtension().lastPathComponent.hasSuffix(" (2)"))
    }

    // MARK: - SUB-15: Tag Stripping + ReplayGain + ISRC

    func testTagWriterPreservesReplayGainAndWritesISRC() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sub-tag-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let mp3URL = root.appendingPathComponent("sample.mp3")
        // Build an MP3 with an existing ReplayGain TXXX frame + a junk COMM frame + audio body
        var oldFrames = Data()
        oldFrames.append(makeID3Frame(id: "COMM", payload: Data([0x03]) + Data("eng".utf8) + Data([0x00]) + Data("Downloaded from sketchy site".utf8)))
        oldFrames.append(makeID3Frame(id: "TXXX", payload: Data([0x03]) + Data("REPLAYGAIN_TRACK_GAIN".utf8) + Data([0x00]) + Data("-6.2 dB".utf8)))

        let audioStart = AudioFixtures.threeSecondMP3.range(of: Data([0xFF, 0xFB]))?.lowerBound ?? 0
        let audioBody = AudioFixtures.threeSecondMP3.subdata(in: audioStart..<AudioFixtures.threeSecondMP3.count)
        var initial = Data([0x49, 0x44, 0x33, 0x04, 0x00, 0x00])
        initial.append(synchsafe32(UInt32(oldFrames.count)))
        initial.append(oldFrames)
        initial.append(audioBody)
        try initial.write(to: mp3URL)

        let track = LibraryTrack(
            path: mp3URL.path,
            title: "Clean Title",
            artist: "Clean Artist",
            album: "Clean Album",
            albumArtist: "Clean Artist",
            comment: "Source: Spotify",
            year: 2024,
            trackNumber: 1,
            fileExtension: "mp3"
        )
        try await TagWriter.writeTags(for: track, customArtworkData: nil, isrc: "USABC2400001", stripExistingNonTechnical: true)

        let md = try await MetadataExtractor.extract(from: mp3URL)
        XCTAssertEqual(md.title, "Clean Title")
        XCTAssertEqual(md.artist, "Clean Artist")
        XCTAssertEqual(md.comment, "Source: Spotify")

        let writtenBytes = try Data(contentsOf: mp3URL)
        let writtenASCII = String(decoding: writtenBytes.prefix(512), as: UTF8.self)
        XCTAssertTrue(writtenASCII.contains("REPLAYGAIN_TRACK_GAIN"))
        XCTAssertTrue(writtenASCII.contains("TSRC"))
        XCTAssertTrue(writtenASCII.contains("USABC2400001"))
        XCTAssertFalse(writtenASCII.contains("sketchy site"))
    }

    // MARK: - SUB-9 / SUB-12 / SUB-17 / SUB-18: Full End-to-End Sync + Simulated iPod Sync + Unchanged Revision

    func testEndToEndSubscriptionSyncSimulatedIPodAndShareIndex() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sub-e2e-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }

        let ipodRoot = root.appendingPathComponent("iPod", isDirectory: true)
        let musicDir = root.appendingPathComponent("HostMusic", isDirectory: true)
        let downloadDir = root.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: musicDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: downloadDir, withIntermediateDirectories: true)

        try IPodDevice.createSimulatedIPod(at: ipodRoot)
        let device = try XCTUnwrap(IPodDevice.detect(volume: ipodRoot, simulated: true))
        let store = PortableLibraryStore(root: ipodRoot, hostID: "test-host")
        _ = try store.register(name: "Test Mac", musicFolder: musicDir)

        // Track 1 already present in host library
        let localURL = musicDir.appendingPathComponent("Already/Local/01 Local Song.mp3")
        try FileManager.default.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AudioFixtures.threeSecondMP3.write(to: localURL)
        let existingTrack = LibraryTrack(
            path: localURL.path,
            title: "Local Song",
            artist: "Local Artist",
            album: "Local Album",
            durationMs: 3_000,
            bitrate: 192,
            fileSize: Int64(AudioFixtures.threeSecondMP3.count),
            fileExtension: "mp3",
            isrc: "LOCISRC00001"
        )

        let tracks: [TrackRef] = [
            TrackRef(source: "spotify", sourceID: "s1", title: "Local Song", artists: ["Local Artist"], album: "Local Album", trackNumber: 1, durationMs: 3_000, isrc: "LOCISRC00001"),
            TrackRef(source: "spotify", sourceID: "s2", title: "Primary Found", artists: ["Artist Two"], album: "Album Two", trackNumber: 2, durationMs: 3_000),
            TrackRef(source: "spotify", sourceID: "s3", title: "Fallback Track", artists: ["Artist Three"], album: "Album Two", trackNumber: 3, durationMs: 3_000),
            TrackRef(source: "spotify", sourceID: "s4", title: "Missing Track", artists: ["Ghost"], album: "Nowhere", trackNumber: 4, durationMs: 180_000),
        ]

        let mockHost = MockPluginHost(
            playlist: PluginKit.Playlist(source: "spotify", sourceID: "pl-1", title: "Roadtrip", owner: "tester", revision: "rev-1"),
            tracks: tracks,
            tempFixtureDir: root.appendingPathComponent("Fixtures", isDirectory: true)
        )
        let engine = SubscriptionEngine(host: mockHost)

        let entry = SubscriptionEntry(
            sourcePluginID: "spotify",
            sourceName: "Spotify",
            sourceURL: "https://open.spotify.com/playlist/pl-1",
            sourcePlaylistID: "pl-1",
            title: "Roadtrip"
        )

        let policy = QualityPolicy(preferredFormats: ["flac", "mp3-320", "aac-256"], minimumBitrateKbps: 192, acceptYouTubeFallback: true)

        let result1 = await engine.sync(
            subscription: entry,
            existingTracks: [existingTrack],
            downloadFolder: downloadDir,
            artworkDir: store.artwork,
            qualityPolicy: policy
        )

        XCTAssertFalse(result1.skippedDueToUnchangedRevision)
        XCTAssertEqual(result1.newlyImportedTracks.count, 2) // s2 from soulseek + s3 from yt-dlp
        XCTAssertEqual(result1.updatedEntry.tracks.count, 4)

        XCTAssertEqual(result1.updatedEntry.tracks[0].libraryTrackID, existingTrack.id)
        XCTAssertEqual(result1.updatedEntry.tracks[0].status, .available)
        XCTAssertEqual(result1.updatedEntry.tracks[1].status, .available)
        XCTAssertFalse(result1.updatedEntry.tracks[1].isYouTubeFallback)
        XCTAssertEqual(result1.updatedEntry.tracks[2].status, .available)
        XCTAssertTrue(result1.updatedEntry.tracks[2].isYouTubeFallback)
        XCTAssertEqual(result1.updatedEntry.tracks[3].status, .notFound)

        // Verify downloaded files exist at sanitized <Artist>/<Album>/<NN> <Title>.mp3
        for t in result1.newlyImportedTracks {
            XCTAssertTrue(FileManager.default.fileExists(atPath: t.path))
            XCTAssertTrue(t.path.hasPrefix(downloadDir.path))
        }

        // Persist subscriptions.json and verify round-trip recovery
        let doc = SubscriptionsDocument(version: 1, subscriptions: [result1.updatedEntry])
        try SubscriptionsStore.save(doc, to: store.data)
        let loaded = SubscriptionsStore.load(from: store.data)
        XCTAssertFalse(loaded.bothCorrupted)
        XCTAssertEqual(loaded.document.subscriptions.first?.tracks.count, 4)

        // Verify Soulseek share index builder on host music folders
        let hostShare = ShareIndexBuilder.build(store: store, tracks: [existingTrack] + result1.newlyImportedTracks, connectedDevice: device)
        XCTAssertEqual(hostShare.uploadSlots, 2)
        XCTAssertEqual(hostShare.entries.count, 1) // existingTrack sits in musicDir
        XCTAssertTrue(hostShare.entries.first?.virtualPath.hasPrefix("HostMusic\\") == true)

        // Sync downloaded tracks onto the simulated iPod!
        let syncTracks = [existingTrack] + result1.newlyImportedTracks
        let prepared = try await PortableMusicTransfer.prepare(tracks: syncTracks, device: device, store: store)
        XCTAssertEqual(prepared.request.tracks.count, 3)
        let ipodSyncResult = try await SyncEngine(request: prepared.request, progress: { _ in }).run()
        XCTAssertEqual(ipodSyncResult.added, 3)
        XCTAssertEqual(try device.readDatabase().tracks.count, 3)

        // Check second sync when revision matches rev-1 and 24h cooldown skips s4 -> completes < 2.0s!
        let start = Date()
        let result2 = await engine.sync(
            subscription: result1.updatedEntry,
            existingTracks: syncTracks,
            downloadFolder: downloadDir,
            artworkDir: store.artwork,
            qualityPolicy: policy
        )
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertTrue(result2.skippedDueToUnchangedRevision)
        XCTAssertLessThan(elapsed, 2.0)
        XCTAssertTrue(result2.newlyImportedTracks.isEmpty)
    }

    func testImmediatePerTrackReadyCallbackAndPlaylistCoverCaching() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sub-ready-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let dlDir = root.appendingPathComponent("Downloads", isDirectory: true)
        let artDir = root.appendingPathComponent("Artwork", isDirectory: true)
        try FileManager.default.createDirectory(at: dlDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: artDir, withIntermediateDirectories: true)

        // Write a tiny valid 1x1 PNG file for local artworkURL caching check
        let pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        let pngURL = root.appendingPathComponent("cover.png")
        try Data(base64Encoded: pngBase64)!.write(to: pngURL)

        let t1 = TrackRef(source: "spotify", sourceID: "s2", title: "Primary Found", artists: ["Artist Two"], durationMs: 3_000)
        let playlist = PluginKit.Playlist(
            source: "spotify",
            sourceID: "pl-ready",
            title: "Ready Fast",
            owner: "tester",
            artworkURL: pngURL,
            revision: "rev-ready"
        )
        let host = MockPluginHost(playlist: playlist, tracks: [t1], tempFixtureDir: root.appendingPathComponent("tmp"))
        let engine = SubscriptionEngine(host: host)

        final class ReadyCapture: @unchecked Sendable {
            private let lock = NSLock()
            var trackIDs: [UUID] = []
            var checkpointCounts: [Int] = []
            func addTrack(_ id: UUID) { lock.withLock { trackIDs.append(id) } }
            func addCheckpoint(_ count: Int) { lock.withLock { checkpointCounts.append(count) } }
        }
        let capture = ReadyCapture()
        let result = await engine.sync(
            subscription: SubscriptionEntry(
                sourcePluginID: "spotify",
                sourceName: "Spotify",
                sourceURL: "https://open.spotify.com/playlist/pl-ready",
                title: "Ready Fast",
                tracks: [SubscribedTrackEntry(key: "spotify:s2", trackRef: t1, position: 0)]
            ),
            existingTracks: [],
            downloadFolder: dlDir,
            artworkDir: artDir,
            qualityPolicy: QualityPolicy(),
            onTrackReady: { _, track, _ in
                capture.addTrack(track.id)
            },
            onCheckpointSave: { _, added in
                capture.addCheckpoint(added.count)
            }
        )

        XCTAssertEqual(result.newlyImportedTracks.count, 1)
        XCTAssertEqual(capture.trackIDs, [result.newlyImportedTracks[0].id], "Track must be surfaced immediately without waiting 20 tracks")
        XCTAssertEqual(capture.checkpointCounts, [1])
        let artKey = try XCTUnwrap(result.updatedEntry.artworkKey)
        XCTAssertTrue(FileManager.default.fileExists(atPath: artDir.appendingPathComponent("\(artKey).jpg").path))
    }

    func testRefreshSearchesMissingFirstThenUpgradesLowerQuality() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sub-refresh-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let dlDir = root.appendingPathComponent("Downloads", isDirectory: true)
        let artDir = root.appendingPathComponent("Artwork", isDirectory: true)
        try FileManager.default.createDirectory(at: dlDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: artDir, withIntermediateDirectories: true)

        let losslessFile = dlDir.appendingPathComponent("optimal.mp3")
        let fallbackFile = dlDir.appendingPathComponent("fallback.mp3")
        try AudioFixtures.threeSecondMP3.write(to: losslessFile)
        try AudioFixtures.threeSecondMP3.write(to: fallbackFile)

        let trackA = LibraryTrack(
            path: losslessFile.path,
            title: "Optimal Song",
            artist: "Alpha",
            durationMs: 3_000,
            bitrate: 1000,
            fileExtension: "flac",
            isLossless: true,
            sourcePluginID: "spotify",
            sourceTrackID: "opt-a"
        )
        let trackB = LibraryTrack(
            path: fallbackFile.path,
            title: "Fallback Song",
            artist: "Beta",
            durationMs: 3_000,
            bitrate: 128,
            fileExtension: "mp3",
            isLossless: false,
            sourcePluginID: "spotify",
            sourceTrackID: "fb-b"
        )

        let refA = TrackRef(source: "spotify", sourceID: "opt-a", title: "Optimal Song", artists: ["Alpha"], durationMs: 3_000)
        let refB = TrackRef(source: "spotify", sourceID: "fb-b", title: "Fallback Song", artists: ["Beta"], durationMs: 3_000)
        let refC = TrackRef(source: "spotify", sourceID: "miss-c", title: "Missing Song", artists: ["Gamma"], durationMs: 3_000)

        let initialSub = SubscriptionEntry(
            sourcePluginID: "spotify",
            sourceName: "Spotify",
            sourceURL: "https://open.spotify.com/playlist/pl-refresh",
            title: "Refresh Order",
            revision: "rev-same",
            tracks: [
                SubscribedTrackEntry(key: "spotify:opt-a", trackRef: refA, position: 0, libraryTrackID: trackA.id, status: .available, isYouTubeFallback: false),
                SubscribedTrackEntry(key: "spotify:fb-b", trackRef: refB, position: 1, libraryTrackID: trackB.id, status: .available, isYouTubeFallback: true),
                SubscribedTrackEntry(key: "spotify:miss-c", trackRef: refC, position: 2, libraryTrackID: nil, status: .notFound, lastFailureAt: Date()),
            ]
        )

        let host = UpgradeOrderMockHost(
            playlist: PluginKit.Playlist(source: "spotify", sourceID: "pl-refresh", title: "Refresh Order", revision: "rev-same"),
            tracks: [refA, refB, refC]
        )
        let engine = SubscriptionEngine(host: host)

        let result = await engine.sync(
            subscription: initialSub,
            existingTracks: [trackA, trackB],
            downloadFolder: dlDir,
            artworkDir: artDir,
            qualityPolicy: QualityPolicy(),
            retryFailedCooldownOverride: true,
            attemptQualityUpgrades: true
        )

        XCTAssertFalse(result.skippedDueToUnchangedRevision)
        // Must NEVER search A; must search C (missing, Pass 1) BEFORE B (quality upgrade, Pass 2)
        XCTAssertEqual(host.recordedSearchIDs(), ["miss-c", "fb-b"])
        XCTAssertEqual(result.replacedTrackIDs, [trackB.id])
        XCTAssertEqual(result.updatedEntry.tracks[0].libraryTrackID, trackA.id)
        XCTAssertNotEqual(result.updatedEntry.tracks[1].libraryTrackID, trackB.id)
        XCTAssertFalse(result.updatedEntry.tracks[1].isYouTubeFallback)
        XCTAssertEqual(result.updatedEntry.tracks[2].status, .available)
        XCTAssertEqual(result.playlistTrackIDs.count, 3)
    }

    func testYouTubeVideoTracksBypassSoulseekAndAvoidAlbumMatch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sub-yt-video-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let dlDir = root.appendingPathComponent("Downloads", isDirectory: true)
        let artDir = root.appendingPathComponent("Artwork", isDirectory: true)
        try FileManager.default.createDirectory(at: dlDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: artDir, withIntermediateDirectories: true)

        let existingAlbumURL = dlDir.appendingPathComponent("studio-album.flac")
        try AudioFixtures.threeSecondMP3.write(to: existingAlbumURL)
        let studioAlbumTrack = LibraryTrack(
            path: existingAlbumURL.path,
            title: "My Track",
            artist: "The Artist",
            album: "Studio LP",
            durationMs: 3_000,
            bitrate: 1000,
            fileExtension: "flac",
            isLossless: true
        )

        let videoRef = TrackRef(
            source: "youtube-music",
            sourceID: "ytVid999",
            title: "My Track",
            artists: ["The Artist"],
            album: nil,
            durationMs: 3_000,
            isVideo: true
        )

        // 1. LibraryTrackMatcher must NOT link the local studio album FLAC to a video TrackRef.
        let matcher = LibraryTrackMatcher(tracks: [studioAlbumTrack], downloadFolderPath: dlDir.path)
        XCTAssertNil(matcher.match(for: videoRef, linkedTrackID: nil))

        // 2. CandidateScorer accepts exact video ID even when acceptYouTubeFallback is false & title says "(Live)".
        let policyNoYT = QualityPolicy(acceptYouTubeFallback: false)
        let ytCand = Candidate(
            resolver: "yt-dlp",
            token: "https://www.youtube.com/watch?v=ytVid999",
            displayName: "The Artist - My Track (Live Video)",
            title: "My Track (Live Video)",
            artist: "The Artist",
            durationMs: 3_000,
            container: "mp3",
            codec: "mp3",
            bitrateKbps: 128
        )
        XCTAssertTrue(CandidateScorer.evaluate(ytCand, against: videoRef, policy: policyNoYT).accepted)

        // 3. SubscriptionEngine routes isVideo track strictly to yt-dlp (never soulseek), even with acceptYouTubeFallback: false,
        //    and does not overwrite it on subsequent refresh upgrades.
        let videoHost = VideoOnlyMockHost(videoRef: videoRef, candidate: ytCand)
        let engine = SubscriptionEngine(host: videoHost)
        let sub = SubscriptionEntry(
            playlistID: UUID(),
            sourcePluginID: "youtube-music",
            sourceName: "YouTube Music",
            sourceURL: "https://music.youtube.com/playlist?list=PLvid",
            sourcePlaylistID: "PLvid",
            title: "Video Playlist",
            revision: "",
            tracks: []
        )

        let firstSync = await engine.sync(
            subscription: sub,
            existingTracks: [studioAlbumTrack],
            downloadFolder: dlDir,
            artworkDir: artDir,
            qualityPolicy: policyNoYT
        )
        XCTAssertEqual(videoHost.requestedResolvers(), ["yt-dlp"])
        XCTAssertEqual(firstSync.updatedEntry.tracks.first?.status, .available)
        XCTAssertEqual(firstSync.updatedEntry.tracks.first?.isYouTubeFallback, true)

        // Subsequent upgrade pass must leave the video track alone (no Soulseek album replacement).
        let secondSync = await engine.sync(
            subscription: firstSync.updatedEntry,
            existingTracks: [studioAlbumTrack] + firstSync.newlyImportedTracks,
            downloadFolder: dlDir,
            artworkDir: artDir,
            qualityPolicy: policyNoYT,
            attemptQualityUpgrades: true
        )
        XCTAssertTrue(secondSync.replacedTrackIDs.isEmpty)
        XCTAssertEqual(videoHost.requestedResolvers(), ["yt-dlp"], "Quality upgrade pass must not re-search Soulseek for video tracks")
    }

    // MARK: - Helpers

    private func makeID3Frame(id: String, payload: Data) -> Data {
        var out = Data()
        out.append(contentsOf: id.utf8.prefix(4))
        out.append(synchsafe32(UInt32(payload.count)))
        out.append(contentsOf: [0x00, 0x00])
        out.append(payload)
        return out
    }

    private func synchsafe32(_ v: UInt32) -> Data {
        Data([
            UInt8((v >> 21) & 0x7F),
            UInt8((v >> 14) & 0x7F),
            UInt8((v >> 7) & 0x7F),
            UInt8(v & 0x7F),
        ])
    }
}

private final class MockPluginHost: SubscriptionPluginHost, @unchecked Sendable {
    let playlist: PluginKit.Playlist
    let tracks: [TrackRef]
    let tempFixtureDir: URL

    init(playlist: PluginKit.Playlist, tracks: [TrackRef], tempFixtureDir: URL) {
        self.playlist = playlist
        self.tracks = tracks
        self.tempFixtureDir = tempFixtureDir
        try? FileManager.default.createDirectory(at: tempFixtureDir, withIntermediateDirectories: true)
    }

    func fetchPlaylist(pluginID: String, url: String) async throws -> PlaylistFetchResult {
        PlaylistFetchResult(playlist: playlist, tracks: tracks)
    }

    func orderedResolvers(includeYouTubeFallback: Bool) async -> [String] {
        includeYouTubeFallback ? ["soulseek", "yt-dlp"] : ["soulseek"]
    }

    func searchCandidates(
        resolverID: String,
        track: TrackRef,
        policy: QualityPolicy,
        onPartial: @escaping @Sendable ([Candidate]) -> Void
    ) async throws -> [Candidate] {
        switch track.sourceID {
        case "s2":
            guard resolverID == "soulseek" else { return [] }
            return [Candidate(
                resolver: "soulseek",
                token: "s2-slsk-1",
                displayName: "Artist Two - Primary Found.mp3",
                title: "Primary Found",
                artist: "Artist Two",
                durationMs: 3_000,
                container: "mp3",
                codec: "mp3",
                bitrateKbps: 320,
                availability: Availability(freeSlot: true, queueLength: 0, speedBytesPerSec: 1_000_000)
            )]
        case "s3":
            if resolverID == "soulseek" {
                // Return 3 candidates that all fail during download -> verifies fallback to yt-dlp!
                return (1...3).map { idx in
                    Candidate(
                        resolver: "soulseek",
                        token: "s3-fail-\(idx)",
                        displayName: "Artist Three - Fallback Track.mp3",
                        title: "Fallback Track",
                        artist: "Artist Three",
                        durationMs: 3_000,
                        container: "mp3",
                        codec: "mp3",
                        bitrateKbps: 320
                    )
                }
            }
            return [Candidate(
                resolver: "yt-dlp",
                token: "s3-yt-1",
                displayName: "Artist Three - Fallback Track",
                title: "Fallback Track",
                artist: "Artist Three",
                durationMs: 3_000,
                container: "mp3",
                codec: "mp3",
                bitrateKbps: 320
            )]
        case "s4":
            // Only return a forbidden remix so CandidateScorer rejects it cleanly -> .notFound
            return [Candidate(
                resolver: resolverID,
                token: "s4-remix",
                displayName: "Ghost - Missing Track (Nightcore Remix).mp3",
                title: "Missing Track (Nightcore Remix)",
                artist: "Ghost",
                durationMs: 180_000,
                container: "mp3",
                bitrateKbps: 320
            )]
        default:
            return []
        }
    }

    func downloadCandidate(
        resolverID: String,
        candidate: Candidate,
        destinationDir: URL,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        if candidate.token.hasPrefix("s3-fail-") {
            throw PluginError(code: .network, message: "peer disconnected")
        }
        onProgress(0.5)
        let partURL = destinationDir.appendingPathComponent("\(candidate.token).mp3.part")
        try AudioFixtures.threeSecondMP3.write(to: partURL)
        onProgress(1.0)
        return partURL
    }
}

private final class VideoOnlyMockHost: SubscriptionPluginHost, @unchecked Sendable {
    private let videoRef: TrackRef
    private let candidate: Candidate
    private let lock = NSLock()
    private var resolversSeen: [String] = []

    init(videoRef: TrackRef, candidate: Candidate) {
        self.videoRef = videoRef
        self.candidate = candidate
    }

    func requestedResolvers() -> [String] {
        lock.withLock { resolversSeen }
    }

    func fetchPlaylist(pluginID: String, url: String) async throws -> PlaylistFetchResult {
        PlaylistFetchResult(
            playlist: PluginKit.Playlist(source: "youtube-music", sourceID: "PLvid", title: "Video Playlist", revision: "rev-vid"),
            tracks: [videoRef]
        )
    }

    func orderedResolvers(includeYouTubeFallback: Bool) async -> [String] {
        includeYouTubeFallback ? ["soulseek", "yt-dlp"] : ["soulseek"]
    }

    func searchCandidates(
        resolverID: String,
        track: TrackRef,
        policy: QualityPolicy,
        onPartial: @escaping @Sendable ([Candidate]) -> Void
    ) async throws -> [Candidate] {
        lock.withLock { resolversSeen.append(resolverID) }
        return resolverID == "yt-dlp" ? [candidate] : []
    }

    func downloadCandidate(
        resolverID: String,
        candidate: Candidate,
        destinationDir: URL,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)
        let partURL = destinationDir.appendingPathComponent("video.mp3.part")
        try AudioFixtures.threeSecondMP3.write(to: partURL)
        onProgress(1.0)
        return partURL
    }
}

private final class UpgradeOrderMockHost: SubscriptionPluginHost, @unchecked Sendable {
    let playlist: PluginKit.Playlist
    let tracks: [TrackRef]
    private let lock = NSLock()
    private var searchOrder: [String] = []

    init(playlist: PluginKit.Playlist, tracks: [TrackRef]) {
        self.playlist = playlist
        self.tracks = tracks
    }

    func recordedSearchIDs() -> [String] {
        lock.withLock { searchOrder }
    }

    func fetchPlaylist(pluginID: String, url: String) async throws -> PlaylistFetchResult {
        PlaylistFetchResult(playlist: playlist, tracks: tracks)
    }

    func orderedResolvers(includeYouTubeFallback: Bool) async -> [String] {
        includeYouTubeFallback ? ["soulseek", "yt-dlp"] : ["soulseek"]
    }

    func searchCandidates(
        resolverID: String,
        track: TrackRef,
        policy: QualityPolicy,
        onPartial: @escaping @Sendable ([Candidate]) -> Void
    ) async throws -> [Candidate] {
        lock.withLock {
            if searchOrder.last != track.sourceID {
                searchOrder.append(track.sourceID)
            }
        }
        guard resolverID == "soulseek" else { return [] }
        return [
            Candidate(
                resolver: "soulseek",
                token: "\(track.sourceID)-320",
                displayName: "\(track.artists.first ?? "") - \(track.title).mp3",
                title: track.title,
                artist: track.artists.first,
                durationMs: 3_000,
                container: "mp3",
                codec: "mp3",
                bitrateKbps: 320,
                availability: Availability(freeSlot: true, queueLength: 0, speedBytesPerSec: 1_000_000)
            )
        ]
    }

    func downloadCandidate(
        resolverID: String,
        candidate: Candidate,
        destinationDir: URL,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let partURL = destinationDir.appendingPathComponent("\(candidate.token).mp3.part")
        try AudioFixtures.threeSecondMP3.write(to: partURL)
        onProgress(1.0)
        return partURL
    }
}
