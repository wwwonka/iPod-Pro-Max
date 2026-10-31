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
    func testPartialPreferencesAndCrossPlatformJSONPreserveChoices() throws {
        let decoder = JSONDecoder()
        let partial = try decoder.decode(PortableSettings.self, from: Data(#"{"musicViewMode":"By Artist","futureField":42}"#.utf8))
        XCTAssertEqual(partial.version, 1); XCTAssertTrue(partial.syncArtwork); XCTAssertEqual(partial.musicViewMode, "By Artist")
        let roundTrip = try decoder.decode(PortableSettings.self, from: JSONEncoder().encode(partial))
        XCTAssertEqual(roundTrip.musicViewMode, partial.musicViewMode)
        let hosts = try decoder.decode(KnownHosts.self, from: Data(#"{"hosts":[{"id":"windows","name":"PC"},{"id":"linux"}]}"#.utf8))
        XCTAssertEqual(hosts.version, 1); XCTAssertTrue(hosts.hosts[0].sources.isEmpty); XCTAssertEqual(hosts.hosts[1].name, "linux")
        let cache = try decoder.decode(PortableLibraryCache.self, from: Data(#"{"tracks":[]}"#.utf8))
        XCTAssertTrue(cache.playlists.isEmpty)
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

private struct FailureMedia: SyncMediaServices {
    func decodeImage(at url: URL) -> PixelBuffer? { nil }
    func cachedAAC(for track: LibraryTrack, cacheDir: URL) async throws -> URL { URL(fileURLWithPath: track.path) }
    func cachedIPodVideo(for track: LibraryTrack, cacheDir: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL { URL(fileURLWithPath: track.path) }
    func mergeAudiobook(chapters: [AudiobookChapter], to destination: URL) async throws {}
}
