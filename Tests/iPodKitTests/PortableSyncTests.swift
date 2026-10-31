import XCTest
@testable import iPodKit

final class PortableSyncTests: XCTestCase {
    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("portable-sync-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func testHostsArePortableAndRelocationKeepsSourceIdentity() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let a = PortableLibraryStore(root: root, hostID: "mac")
        let original = try a.register(name: "Mac", musicFolder: URL(fileURLWithPath: "/music"))
        let relocated = try a.register(name: "Renamed Mac", musicFolder: URL(fileURLWithPath: "/new/music"))
        XCTAssertEqual(original.sources.first?.id, relocated.sources.first?.id)
        let b = PortableLibraryStore(root: root, hostID: "windows")
        _ = try b.register(name: "PC", musicFolder: URL(fileURLWithPath: "/pc-music"))
        let registry = try XCTUnwrap(a.data.read(KnownHosts.self, from: "known_hosts.json"))
        XCTAssertEqual(registry.hosts.count, 2)
        XCTAssertEqual(registry.hosts.first { $0.id == "mac" }?.sources.first?.path, "/new/music")
        try a.save(PortableLibraryCache(tracks: [LibraryTrack(path: "/music/a.mp3", title: "A", fileExtension: "mp3")]))
        XCTAssertEqual(a.cache().tracks.count, 1)
        XCTAssertTrue(b.cache().tracks.isEmpty)
    }
    func testDamagedRegistryDoesNotEraseKnownHosts() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let store = PortableLibraryStore(root: root, hostID: "a")
        _ = try store.register(name: "Mac")
        let file = store.data.url.appendingPathComponent("known_hosts.json")
        let damaged = Data("{".utf8)
        try damaged.write(to: file)
        XCTAssertThrowsError(try store.register(name: "Renamed"))
        XCTAssertEqual(try Data(contentsOf: file), damaged)
    }

    func testFingerprintIsPathIndependentAndDetectsEdits() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
        try Data(repeating: 42, count: 1_100_000).write(to: a)
        try FileManager.default.copyItem(at: a, to: b)
        XCTAssertEqual(try FileFingerprint.read(a), try FileFingerprint.read(b))
        try Data([1]).write(to: b)
        XCTAssertNotEqual(try FileFingerprint.read(a), try FileFingerprint.read(b))
    }
    func testAdditiveSyncPreservesTracksPlaylistsAndArtwork() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        try IPodDevice.createSimulatedIPod(at: root)
        let device = try XCTUnwrap(IPodDevice.detect(volume: root, simulated: true))
        let source = root.appendingPathComponent("source.mp3")
        try Data([1, 2, 3]).write(to: source)
        let art = root.appendingPathComponent("art")
        try FileManager.default.createDirectory(at: art, withIntermediateDirectories: true)
        try Data([0]).write(to: art.appendingPathComponent("cover.jpg"))
        var first = LibraryTrack(path: source.path, title: "First", fileSize: 3, fileExtension: "mp3")
        first.artworkKey = "cover"
        var options = SyncOptions(); options.additiveOnly = true; options.syncPhotos = false; options.syncPodcasts = false
        func request(_ tracks: [LibraryTrack], _ record: DeviceSyncRecord) -> SyncRequest {
            SyncRequest(device: device, record: record, tracks: tracks, playlists: [], shows: [], artworkDir: art,
                transcodeDir: root.appendingPathComponent("transcodes"), photoCacheDir: root.appendingPathComponent("photos"),
                photoSelection: PhotoSelection(), options: options, media: FakeMedia())
        }
        let firstResult = try await SyncEngine(request: request([first], DeviceSyncRecord(deviceID: device.id, deviceName: "Test")), progress: { _ in }).run()
        var db = try device.readDatabase()
        let firstDBID = try XCTUnwrap(firstResult.record.trackDBIDs[first.id])
        let oldThumbs = try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(at: device.artworkDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "ithmb" }.map { ($0, try Data(contentsOf: $0)) })
        let firstArt = try Data(contentsOf: device.artworkDBURL)
        let oldRecord = try XCTUnwrap(ExistingArtwork.records(firstArt).first)
        var foreign = IPodPlaylist(name: "Other host playlist"); foreign.memberDBIDs = [firstDBID]; foreign.isSmart = true
        var prefs = ByteWriter()
        prefs.header("mhod"); prefs.u32(24); prefs.u32(24); prefs.u32(MHODType.smartPlaylistPrefs); prefs.u32(0); prefs.u32(0)
        foreign.smartMetadata = [prefs.data]
        db.playlists.append(foreign)
        try FileOps.writeReplacing(ITunesDBWriter(database: db, checksum: device.checksumType, firewireID: device.firewireIDBytes).write().data, to: device.iTunesDBURL)
        var second = first; second.id = UUID(); second.title = "Second"
        let secondResult = try await SyncEngine(request: request([second], firstResult.record), progress: { _ in }).run()
        XCTAssertEqual(secondResult.added, 1); XCTAssertEqual(secondResult.removed, 0)
        db = try device.readDatabase()
        XCTAssertEqual(db.tracks.count, 2)
        XCTAssertEqual(db.playlists.first { $0.id == foreign.id }?.memberDBIDs, [firstDBID])
        XCTAssertEqual(db.playlists.first { $0.id == foreign.id }?.smartMetadata, foreign.smartMetadata)
        let records = try ExistingArtwork.records(Data(contentsOf: device.artworkDBURL))
        XCTAssertEqual(records.count, 2)
        for (url, data) in oldThumbs { XCTAssertTrue(try Data(contentsOf: url).starts(with: data)) }
        XCTAssertEqual(records.first { $0.dbid == firstDBID }?.bytes, oldRecord.bytes)
        let repeated = try await SyncEngine(request: request([second], secondResult.record), progress: { _ in }).run()
        XCTAssertEqual(repeated.added, 0)
        XCTAssertEqual(try device.readDatabase().tracks.count, 2)
        // A now-missing selection never removes an earlier track.
        second.path = root.appendingPathComponent("missing.mp3").path
        let missing = try await SyncEngine(request: request([second], secondResult.record), progress: { _ in }).run()
        XCTAssertEqual(missing.removed, 0); XCTAssertEqual(missing.failed.count, 1)
        XCTAssertEqual(try device.readDatabase().tracks.count, 2)
    }
}

private struct FakeMedia: SyncMediaServices {
    func decodeImage(at url: URL) -> PixelBuffer? { PixelBuffer(width: 1, height: 1, bytes: [255, 0, 0, 255]) }
    func cachedAAC(for track: LibraryTrack, cacheDir: URL) async throws -> URL { URL(fileURLWithPath: track.path) }
    func cachedIPodVideo(for track: LibraryTrack, cacheDir: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL { URL(fileURLWithPath: track.path) }
    func mergeAudiobook(chapters: [AudiobookChapter], to destination: URL) async throws {}
}
