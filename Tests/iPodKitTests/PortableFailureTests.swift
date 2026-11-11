import XCTest
@testable import iPodKit

final class PortableFailureTests: XCTestCase {
    private func fixture() throws -> (URL, IPodDevice, URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("portable-failures-" + UUID().uuidString)
        let root = base.appendingPathComponent("mount")
        try IPodDevice.createSimulatedIPod(at: root)
        let source = base.appendingPathComponent("song.mp3")
        try Data([1, 2, 3]).write(to: source)
        return (base, try XCTUnwrap(IPodDevice.detect(volume: root, simulated: true)), source)
    }
    private func request(_ device: IPodDevice, tracks: [LibraryTrack], media: any SyncMediaServices = FailureMedia()) -> SyncRequest {
        var options = SyncOptions(); options.additiveOnly = true; options.writeArtwork = false; options.syncPhotos = false; options.syncPodcasts = false
        return SyncRequest(device: device, record: DeviceSyncRecord(deviceID: device.id, deviceName: "Test"),
            tracks: tracks, playlists: [], shows: [], artworkDir: device.mountPoint.appendingPathComponent("art"),
            transcodeDir: device.mountPoint.appendingPathComponent("transcodes"), photoCacheDir: device.mountPoint.appendingPathComponent("photos"),
            photoSelection: PhotoSelection(), options: options, media: media)
    }
    func testInsufficientSpaceLeavesDatabaseAndMusicUntouched() async throws {
        let (base, device, source) = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let before = try Data(contentsOf: device.iTunesDBURL)
        let huge = LibraryTrack(path: source.path, title: "Too large", fileSize: Int64.max / 4, fileExtension: "mp3")
        do { _ = try await SyncEngine(request: request(device, tracks: [huge]), progress: { _ in }).run(); XCTFail("Accepted impossible capacity") }
        catch let error as SyncError { if case .notEnoughSpace = error {} else { XCTFail("Unexpected error: \(error)") } }
        XCTAssertEqual(try Data(contentsOf: device.iTunesDBURL), before)
        XCTAssertEqual(try device.readDatabase().tracks.count, 0)
    }
    func testCancellationAfterFirstCopyRollsBackUncommittedFiles() async throws {
        let (base, device, source) = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let before = try Data(contentsOf: device.iTunesDBURL)
        let tracks = (0..<3).map { LibraryTrack(path: source.path, title: "Song \($0)", fileSize: 3, fileExtension: "mp3") }
        let snapshot = request(device, tracks: tracks)
        let task = Task.detached {
            try await SyncEngine(request: snapshot, progress: { progress in
                if progress.phase == "Copying" && progress.detail.hasPrefix("2 of 3") {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }).run()
        }
        do { _ = try await task.value; XCTFail("Cancellation ignored") }
        catch let error as SyncError { if case .cancelled = error {} else { XCTFail("Unexpected error: \(error)") } }
        XCTAssertEqual(try Data(contentsOf: device.iTunesDBURL), before)
        let files = FileManager.default.enumerator(at: device.musicDir, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
        XCTAssertFalse(files.contains { $0.pathExtension == "mp3" })
    }
    func testDisconnectedVolumeIsNotRecreatedDuringTransfer() async throws {
        let (base, device, source) = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let before = try Data(contentsOf: device.iTunesDBURL)
        let detached = base.appendingPathComponent("detached")
        let track = LibraryTrack(path: source.path, title: "Song", fileSize: 3, fileExtension: "mp3")
        do {
            _ = try await SyncEngine(request: request(device, tracks: [track]), progress: { progress in
                if progress.phase == "Copying" { try? FileManager.default.moveItem(at: device.mountPoint, to: detached) }
            }).run()
            XCTFail("Disconnected volume accepted")
        } catch { XCTAssertTrue(error is IPodDBError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: device.mountPoint.path), "A host folder was recreated")
        let relative = device.iTunesDBURL.path.dropFirst(device.mountPoint.path.count + 1)
        XCTAssertEqual(try Data(contentsOf: detached.appendingPathComponent(String(relative))), before)
    }
    func testUnavailablePortableRegistryDoesNotRecreateMountPoint() throws {
        let (base, device, _) = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let store = PortableLibraryStore(root: device.mountPoint, hostID: "a")
        try FileManager.default.removeItem(at: device.mountPoint)
        XCTAssertThrowsError(try store.register(name: "Host"))
        XCTAssertThrowsError(try store.save(PortableLibraryCache()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: device.mountPoint.path))
    }
    func testFavoriteRoundTripAndOldTracksRemainCompatible() throws {
        let track = LibraryTrack(path: "/music/a.mp3", title: "A", fileExtension: "mp3", rating: 4)
        let legacy = try JSONEncoder().encode(track)
        XCTAssertNil(try JSONDecoder().decode(LibraryTrack.self, from: legacy).isFavorite)
        var favorite = track
        favorite.isFavorite = true
        let restored = try JSONDecoder().decode(LibraryTrack.self, from: JSONEncoder().encode(favorite))
        XCTAssertEqual(restored.isFavorite, true)
        XCTAssertEqual(restored.rating, 4, "Favorites must not alter the iPod star rating")
        let (base, device, _) = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let store = PortableLibraryStore(root: device.mountPoint, hostID: "favorite-test")
        try store.save(PortableLibraryCache(tracks: [favorite]))
        XCTAssertEqual(try store.cache().tracks.first?.isFavorite, true)
        favorite.isFavorite = false
        try store.save(PortableLibraryCache(tracks: [favorite]))
        XCTAssertEqual(try store.cache().tracks.first?.isFavorite, false)
        XCTAssertEqual(try JSONDecoder().decode(LibraryTrack.self, from: JSONEncoder().encode(favorite)).isFavorite, false)
    }
    func testOfflineFavoriteReferenceFollowsRelocatedSource() {
        let id = UUID()
        var cache = PortableLibraryCache()
        cache.favoriteReferences = [PortableFavoriteReference(id: id, path: "/old/music/album/song.mp3")]
        cache.relocateFavoriteReferences(from: "/old/music", to: "/new/music")
        XCTAssertEqual(cache.favoriteReferences?.first?.path, "/new/music/album/song.mp3")
        XCTAssertEqual(cache.cachedTracksIncludingFavorites().first?.id, id)
        XCTAssertTrue(cache.tracks.isEmpty)
        cache.forgetFavoriteReferences(under: "/new/music")
        XCTAssertTrue(cache.favoriteReferences?.isEmpty == true)
    }

    func testMovingSourceDoesNotRelocateEntriesCoveredByRemainingSource() {
        let child = PortableFavoriteReference(id: UUID(), path: "/music/child/song.mp3")
        let moved = PortableFavoriteReference(id: UUID(), path: "/music/other/song.mp3")
        var cache = PortableLibraryCache()
        cache.favoriteReferences = [child, moved]
        cache.offlineTracks = [LibraryTrack(id: child.id, path: child.path, title: "Child", fileExtension: "mp3", isFavorite: true)]
        cache.relocateFavoriteReferences(from: "/music", to: "/new", keeping: ["/music/child"])
        XCTAssertEqual(cache.favoriteReferences?.first(where: { $0.id == child.id })?.path, child.path)
        XCTAssertEqual(cache.favoriteReferences?.first(where: { $0.id == moved.id })?.path, "/new/other/song.mp3")
        XCTAssertEqual(cache.offlineTracks?.first?.path, child.path)
    }

    func testRemovingSourceKeepsOfflineFavoritesCoveredByAnotherSource() {
        let nested = PortableFavoriteReference(id: UUID(), path: "/music/live/song.mp3")
        let sibling = PortableFavoriteReference(id: UUID(), path: "/music/other/song.mp3")
        let lookalike = PortableFavoriteReference(id: UUID(), path: "/music/live-other/song.mp3")
        var cache = PortableLibraryCache()
        cache.favoriteReferences = [nested, sibling, lookalike]
        cache.forgetFavoriteReferences(under: "/music", keeping: ["/music/live/"])
        XCTAssertEqual(cache.favoriteReferences, [nested])
        cache.forgetFavoriteReferences(under: "/music/live", keeping: [])
        XCTAssertTrue(cache.favoriteReferences?.isEmpty == true)
    }

    func testDuplicateMusicReferencesPreservePlaylistAndFavorites() {
        let firstID = UUID(), playlistID = UUID()
        let first = LibraryTrack(id: firstID, path: "/music/live/song.mp3", title: "Song", fileExtension: "mp3", rating: 3, isFavorite: true)
        let second = LibraryTrack(id: playlistID, path: "/music/live/../live/song.mp3", title: "Song", fileExtension: "mp3")
        var cache = PortableLibraryCache(tracks: [first, second], playlists: [LibraryPlaylist(name: "Saved", trackIDs: [firstID, playlistID])])
        cache.coalesceMusicTracks { URL(fileURLWithPath: $0).standardizedFileURL.path }
        XCTAssertEqual(cache.tracks.count, 1)
        XCTAssertEqual(cache.tracks[0].id, firstID)
        XCTAssertEqual(cache.tracks[0].isFavorite, true)
        XCTAssertEqual(cache.tracks[0].rating, 3)
        XCTAssertEqual(cache.playlists[0].trackIDs, [firstID, firstID])
    }

    func testOfflineTracksRetainIdentityAndChoicesButStayOutOfView() {
        let added = Date(timeIntervalSince1970: 1_000)
        let favorite = LibraryTrack(path: "/music/favorite.mp3", title: "Favorite", fileExtension: "mp3", rating: 4, isFavorite: true, playCount: 12, dateAdded: added)
        let playlistTrack = LibraryTrack(path: "/music/playlist.mp3", title: "Playlist track", fileExtension: "mp3", dateAdded: added)
        var cache = PortableLibraryCache(tracks: [], playlists: [LibraryPlaylist(name: "Saved", trackIDs: [playlistTrack.id])])
        cache.reconcileOfflineTracks(previous: [favorite, playlistTrack], keeping: ["/music"])
        XCTAssertTrue(cache.tracks.isEmpty)
        let hints = cache.cachedTracksIncludingFavorites()
        XCTAssertEqual(hints.first { $0.id == favorite.id }?.rating, 4)
        XCTAssertEqual(hints.first { $0.id == favorite.id }?.playCount, 12)
        XCTAssertEqual(hints.first { $0.id == favorite.id }?.dateAdded, added)
        XCTAssertEqual(hints.first { $0.id == playlistTrack.id }?.id, playlistTrack.id)
        cache.forgetFavoriteReferences(under: "/music")
        XCTAssertTrue(cache.cachedTracksIncludingFavorites().isEmpty)
    }

    func testFailedRepairPreservesValidBackup() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("failed-repair-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = DeviceDataFolder(url: base)
        let old = PortableSettings()
        try folder.write(old, to: "settings.json")
        var next = old; next.sidebarOpen = false
        try folder.write(next, to: "settings.json")
        let primary = base.appendingPathComponent("settings.json")
        let backup = base.appendingPathComponent("settings.json.bak")
        let originalBackup = try Data(contentsOf: backup)
        try Data("{broken".utf8).write(to: primary)
        XCTAssertThrowsError(try folder.write(next, to: "settings.json", replacing: { _, _ in
            throw IPodDBError.io("Simulated write failure")
        }))
        XCTAssertEqual(try Data(contentsOf: backup), originalBackup)
        XCTAssertTrue(try XCTUnwrap(folder.readChecked(PortableSettings.self, from: "settings.json")).sidebarOpen)
        try folder.write(next, to: "settings.json")
        XCTAssertFalse(try XCTUnwrap(folder.readChecked(PortableSettings.self, from: "settings.json")).sidebarOpen)
        XCTAssertEqual(try Data(contentsOf: backup), originalBackup)
    }

    func testUnreadablePrimaryCanReachRepairWithoutTouchingBackup() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("unreadable-primary-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = DeviceDataFolder(url: base)
        let settings = PortableSettings()
        try folder.write(settings, to: "settings.json")
        try folder.write(settings, to: "settings.json")
        let primary = base.appendingPathComponent("settings.json")
        let backup = base.appendingPathComponent("settings.json.bak")
        let previous = try Data(contentsOf: backup)
        try FileManager.default.removeItem(at: primary)
        try FileManager.default.createDirectory(at: primary, withIntermediateDirectories: false)
        var attemptedRepair = false
        XCTAssertThrowsError(try folder.write(settings, to: "settings.json", replacing: { _, destination in
            attemptedRepair = destination.standardizedFileURL.path == primary.standardizedFileURL.path
            throw IPodDBError.io("Simulated write failure")
        }))
        XCTAssertTrue(attemptedRepair, "Unreadable primary should not prevent trying to repair it")
        XCTAssertEqual(try Data(contentsOf: backup), previous)
    }

    func testCorruptLibraryDoesNotBecomeAnEmptyCache() throws {
        let (base, device, _) = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let store = PortableLibraryStore(root: device.mountPoint, hostID: "corrupt-test")
        XCTAssertTrue(try store.cacheChecked().tracks.isEmpty, "A genuinely absent cache starts empty")
        try FileManager.default.createDirectory(at: store.hostFolder.url, withIntermediateDirectories: true)
        let current = store.hostFolder.url.appendingPathComponent("library.json")
        let backup = store.hostFolder.url.appendingPathComponent("library.json.bak")
        let broken = Data("{broken".utf8)
        try broken.write(to: current); try broken.write(to: backup)
        XCTAssertThrowsError(try store.cacheChecked())
        XCTAssertThrowsError(try store.cache())
        XCTAssertEqual(try Data(contentsOf: current), broken)
        XCTAssertEqual(try Data(contentsOf: backup), broken)
    }

    func testFailedLibrarySaveIsRetriedBeforeEjection() async throws {
        let (base, device, _) = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let store = PortableLibraryStore(root: device.mountPoint, hostID: "retry-test")
        let writer = PortableLibraryWriter()
        let song = LibraryTrack(path: "/song.mp3", title: "Song", fileExtension: "mp3", isFavorite: true)
        let unavailable = base.appendingPathComponent("detached-control")
        try FileManager.default.moveItem(at: device.mountPoint.appendingPathComponent("iPod_Control"), to: unavailable)
        do { try await writer.save(PortableLibraryCache(tracks: [song]), to: store); XCTFail("Save must fail without the device") } catch {}
        var ejected = false
        do { try await writer.flush(); ejected = true } catch {}
        XCTAssertFalse(ejected, "A failed flush must prevent ejection")
        try FileManager.default.moveItem(at: unavailable, to: device.mountPoint.appendingPathComponent("iPod_Control"))
        try await writer.flush()
        XCTAssertEqual(try store.cacheChecked().tracks.first?.isFavorite, true)
    }

    func testLibraryGateWaitsForEarlierWriteBeforeRefresh() async {
        let gate = PortableLibraryGate()
        await gate.acquire()
        let started = expectation(description: "refresh is waiting")
        let finished = expectation(description: "refresh runs after save")
        let flag = TestOperationFlag()
        let refresh = Task {
            started.fulfill()
            await gate.acquire()
            await flag.mark()
            finished.fulfill()
            await gate.release()
        }
        await fulfillment(of: [started], timeout: 2)
        let ranTooEarly = await flag.value
        XCTAssertFalse(ranTooEarly, "Refresh must not start before the write releases the gate")
        await gate.release()
        await fulfillment(of: [finished], timeout: 2)
        await refresh.value
    }

    func testPartialPreferencesAndCrossPlatformJSONPreserveChoices() throws {
        let decoder = JSONDecoder()
        let partial = try decoder.decode(PortableSettings.self, from: Data(#"{"musicViewMode":"By Artist","futureField":42}"#.utf8))
        XCTAssertEqual(partial.version, 1); XCTAssertTrue(partial.syncArtwork); XCTAssertEqual(partial.musicViewMode, "By Artist")
        XCTAssertTrue(partial.sidebarOpen); XCTAssertTrue(partial.sectionTabs.isEmpty); XCTAssertEqual(partial.albumArtworkSize, 172)
        var choices = partial
        choices.lastTab = "movies"; choices.sidebarWidth = 287; choices.sidebarOpen = false; choices.albumArtworkSize = 220
        choices.sectionTabs = ["music": "albums", "videos": "movies"]
        let saved = try decoder.decode(PortableSettings.self, from: JSONEncoder().encode(choices))
        XCTAssertEqual(saved.lastTab, "movies"); XCTAssertEqual(saved.sidebarWidth, 287)
        XCTAssertFalse(saved.sidebarOpen); XCTAssertEqual(saved.sectionTabs, choices.sectionTabs); XCTAssertEqual(saved.albumArtworkSize, 220)
        let roundTrip = try decoder.decode(PortableSettings.self, from: JSONEncoder().encode(partial))
        XCTAssertEqual(roundTrip.musicViewMode, partial.musicViewMode)
        let hosts = try decoder.decode(KnownHosts.self, from: Data(#"{"hosts":[{"id":"windows","name":"PC"},{"id":"linux"}]}"#.utf8))
        XCTAssertEqual(hosts.version, 1); XCTAssertTrue(hosts.hosts[0].sources.isEmpty); XCTAssertEqual(hosts.hosts[1].name, "linux")
        let cache = try decoder.decode(PortableLibraryCache.self, from: Data(#"{"tracks":[]}"#.utf8))
        XCTAssertTrue(cache.playlists.isEmpty)
        XCTAssertTrue(cache.videoPlaylists.isEmpty)
        let legacyDocument = try decoder.decode(LibraryDocument.self, from: Data(#"{"tracks":[],"playlists":[]}"#.utf8))
        XCTAssertTrue(legacyDocument.videoPlaylists.isEmpty)
    }
    func testVideoPlaylistsRoundTripSeparatelyFromMusicPlaylists() throws {
        let music = LibraryPlaylist(name: "Songs")
        let video = LibraryPlaylist(name: "Clips")
        let cache = PortableLibraryCache(playlists: [music], videoPlaylists: [video])
        let decoded = try JSONDecoder().decode(PortableLibraryCache.self, from: JSONEncoder().encode(cache))
        XCTAssertEqual(decoded.playlists, [music])
        XCTAssertEqual(decoded.videoPlaylists, [video])
    }
    func testBackupPreferencesRecoverWithoutErasingOtherFields() throws {
        let (base, device, _) = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let folder = DeviceDataFolder(mountPoint: device.mountPoint)
        var settings = PortableSettings(); settings.musicViewMode = "By Artist"; settings.syncArtwork = false
        try folder.write(settings, to: "settings.json")
        try folder.write(settings, to: "settings.json")
        try Data("{".utf8).write(to: folder.url.appendingPathComponent("settings.json"))
        let recovered = try XCTUnwrap(folder.read(PortableSettings.self, from: "settings.json"))
        XCTAssertEqual(recovered.musicViewMode, "By Artist"); XCTAssertFalse(recovered.syncArtwork)
    }
}

private actor TestOperationFlag {
    private(set) var value = false
    func mark() { value = true }
}

private struct FailureMedia: SyncMediaServices {
    func decodeImage(at url: URL) -> PixelBuffer? { nil }
    func cachedAAC(for track: LibraryTrack, cacheDir: URL) async throws -> URL { URL(fileURLWithPath: track.path) }
    func cachedIPodVideo(for track: LibraryTrack, cacheDir: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL { URL(fileURLWithPath: track.path) }
    func mergeAudiobook(chapters: [AudiobookChapter], to destination: URL) async throws {}
}
