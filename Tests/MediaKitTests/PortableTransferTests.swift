import XCTest
import iPodKit
@testable import MediaKit

final class PortableTransferTests: XCTestCase {
    func testSameFileAcrossHostsAndInterruptedCommitDoesNotDuplicate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("portable-transfer-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try IPodDevice.createSimulatedIPod(at: root)
        let device = try XCTUnwrap(IPodDevice.detect(volume: root, simulated: true))
        let source = root.appendingPathComponent("song.mp3")
        try Data([1, 2, 3]).write(to: source)
        let first = LibraryTrack(path: source.path, title: "Song", fileSize: 3, fileExtension: "mp3")
        let a = PortableLibraryStore(root: root, hostID: "a")
        var duplicate = first; duplicate.id = UUID()
        let prepared = try await PortableMusicTransfer.prepare(tracks: [first, duplicate], device: device, store: a)
        XCTAssertEqual(prepared.request.tracks.count, 1)
        XCTAssertEqual(prepared.reused, 1)
        let result = try await SyncEngine(request: prepared.request, progress: { _ in }).run()
        XCTAssertEqual(result.added, 1)
        let dbid = try XCTUnwrap(result.record.trackDBIDs[first.id])
        // Deliberately do not publish a result manifest: simulate quitting after the DB commit.
        let b = PortableLibraryStore(root: root, hostID: "b")
        var secondHost = first; secondHost.id = UUID()
        let again = try await PortableMusicTransfer.prepare(tracks: [secondHost], device: device, store: b)
        XCTAssertTrue(again.request.tracks.isEmpty)
        XCTAssertEqual(again.reused, 1)
        XCTAssertEqual(again.manifest.tracks.first?.dbid, dbid)
        XCTAssertEqual(again.manifest.tracks.first?.owner, "a")
        XCTAssertEqual(again.manifest.tracks.first?.references.count, 3)
        // Deleting the physical iPod file requires a replacement on the next drop.
        let db = try device.readDatabase()
        let onDevice = try XCTUnwrap(db.tracks.first?.fileURL(mountPoint: root))
        try FileManager.default.removeItem(at: onDevice)
        let repair = try await PortableMusicTransfer.prepare(tracks: [secondHost], device: device, store: b)
        XCTAssertEqual(repair.request.tracks.count, 1)
        let repaired = try await SyncEngine(request: repair.request, progress: { _ in }).run()
        XCTAssertEqual(repaired.added, 1)
        XCTAssertEqual(try device.readDatabase().tracks.count, 1)
    }

    func testIdenticalRelativePathsAcrossHostsDoNotCollide() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("portable-paths-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("ipod")
        try IPodDevice.createSimulatedIPod(at: root)
        let device = try XCTUnwrap(IPodDevice.detect(volume: root, simulated: true))
        for (host, bytes) in [("a", [UInt8(1), 2, 3]), ("b", [UInt8(4), 5, 6])] {
            let source = base.appendingPathComponent(host)
            let file = source.appendingPathComponent("album/song.mp3")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(bytes).write(to: file)
            let store = PortableLibraryStore(root: root, hostID: host)
            _ = try store.register(name: host, musicFolder: source)
            let track = LibraryTrack(path: file.path, title: host, fileSize: 3, fileExtension: "mp3")
            let prepared = try await PortableMusicTransfer.prepare(tracks: [track], device: device, store: store)
            XCTAssertEqual(prepared.request.tracks.count, 1)
            XCTAssertEqual(prepared.manifest.tracks.last?.relativePath, "album/song.mp3")
            XCTAssertNotNil(prepared.manifest.tracks.last?.sourceRootID)
            _ = try await SyncEngine(request: prepared.request, progress: { _ in }).run()
        }
        XCTAssertEqual(try device.readDatabase().tracks.count, 2)
        let entries = try XCTUnwrap(DeviceDataFolder(mountPoint: root).read(TransferManifest.self, from: "manifest.json")?.tracks)
        XCTAssertEqual(Set(entries.map(\.fingerprint)).count, 2)
        XCTAssertEqual(Set(entries.map(\.owner)), ["a", "b"])
    }

    func testRescanKeepsFavoriteAfterMediaChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("favorite-scan-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("song.wav")
        let samples = 8000, bytes = samples * 2
        var wav = Data("RIFF".utf8)
        func le32(_ value: Int) { withUnsafeBytes(of: UInt32(value).littleEndian) { wav.append(contentsOf: $0) } }
        func le16(_ value: Int) { withUnsafeBytes(of: UInt16(value).littleEndian) { wav.append(contentsOf: $0) } }
        le32(36 + bytes); wav.append(Data("WAVEfmt ".utf8)); le32(16); le16(1); le16(1); le32(8000); le32(16000); le16(2); le16(16)
        wav.append(Data("data".utf8)); le32(bytes); wav.append(Data(repeating: 0, count: bytes))
        try wav.write(to: source)
        let artwork = root.appendingPathComponent("Artwork")
        let first = await FolderImporter.scan(folder: root, artworkDir: artwork, namespace: "source", musicOnly: true)
        var cached = try XCTUnwrap(first.tracks.first)
        cached.isFavorite = true
        cached.rating = 4
        cached.playCount = 12
        cached.lastPlayed = Date(timeIntervalSince1970: 2_000)
        cached.syncEnabled = false
        cached.musicPersistentID = "ABC123"
        cached.dateAdded = Date(timeIntervalSince1970: 1_000)
        // Force metadata extraction again while retaining the cached identity.
        cached.fileSize = -1
        let second = await FolderImporter.scan(folder: root, artworkDir: artwork, cached: [cached], namespace: "source", musicOnly: true)
        XCTAssertEqual(second.tracks.first?.id, cached.id)
        XCTAssertEqual(second.tracks.first?.isFavorite, true)
        XCTAssertEqual(second.tracks.first?.rating, 4)
        XCTAssertEqual(second.tracks.first?.playCount, 12)
        XCTAssertEqual(second.tracks.first?.lastPlayed, cached.lastPlayed)
        XCTAssertEqual(second.tracks.first?.syncEnabled, false)
        XCTAssertEqual(second.tracks.first?.musicPersistentID, "ABC123")
        XCTAssertEqual(second.tracks.first?.dateAdded, cached.dateAdded, "Editing metadata must not make an old song recently added")
    }
    func testUnavailableFavoriteReturnsWithSameIdentityAndExplicitRemovalForgetsIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("favorite-offline-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("song.wav")
        let samples = 8000, bytes = samples * 2
        var wav = Data("RIFF".utf8)
        func le32(_ value: Int) { withUnsafeBytes(of: UInt32(value).littleEndian) { wav.append(contentsOf: $0) } }
        func le16(_ value: Int) { withUnsafeBytes(of: UInt16(value).littleEndian) { wav.append(contentsOf: $0) } }
        le32(36 + bytes); wav.append(Data("WAVEfmt ".utf8)); le32(16); le16(1); le16(1); le32(8000); le32(16000); le16(2); le16(16)
        wav.append(Data("data".utf8)); le32(bytes); wav.append(Data(repeating: 0, count: bytes))
        try wav.write(to: source)
        let artwork = root.appendingPathComponent("Artwork")
        let first = await FolderImporter.scan(folder: root, artworkDir: artwork, namespace: "source", musicOnly: true)
        var favorite = try XCTUnwrap(first.tracks.first); favorite.isFavorite = true
        var cache = PortableLibraryCache(tracks: [favorite])
        cache.reconcileFavoriteReferences()
        try FileManager.default.removeItem(at: source)
        let offline = await FolderImporter.scan(folder: root, artworkDir: artwork, cached: cache.cachedTracksIncludingFavorites(), namespace: "source", musicOnly: true)
        cache.tracks = offline.tracks
        cache.reconcileFavoriteReferences()
        XCTAssertTrue(cache.tracks.isEmpty, "Unavailable media must not be displayed or synced")
        cache = try JSONDecoder().decode(PortableLibraryCache.self, from: JSONEncoder().encode(cache))
        try wav.write(to: source)
        let restored = await FolderImporter.scan(folder: root, artworkDir: artwork, cached: cache.cachedTracksIncludingFavorites(), namespace: "source", musicOnly: true)
        XCTAssertEqual(restored.tracks.first?.id, favorite.id)
        XCTAssertEqual(restored.tracks.first?.isFavorite, true)
        cache.forgetFavoriteReferences(under: root.path)
        XCTAssertTrue(cache.favoriteReferences?.isEmpty == true)
        XCTAssertTrue(cache.cachedTracksIncludingFavorites().isEmpty, "An explicitly removed source leaves no favorite scan hints")
    }
    func testIncrementalScanReusesTagsAndRemovesInaccessibleFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("portable-scan-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("song.mp3")
        // Invalid bytes deliberately prove the cached path does not attempt tag decoding again.
        try Data([1, 2, 3]).write(to: source)
        let attrs = try source.resourceValues(forKeys: [.contentModificationDateKey])
        var track = LibraryTrack(path: source.path, title: "Cached tags", fileSize: 3, fileExtension: "mp3")
        track.dateModified = attrs.contentModificationDate
        let cached = await FolderImporter.scan(folder: root, artworkDir: root.appendingPathComponent("Artwork"), cached: [track], namespace: "source", musicOnly: true)
        XCTAssertEqual(cached.tracks.first?.id, track.id)
        XCTAssertEqual(cached.tracks.first?.title, "Cached tags")
        try FileManager.default.removeItem(at: source)
        let removed = await FolderImporter.scan(folder: root, artworkDir: root.appendingPathComponent("Artwork"), cached: [track], musicOnly: true)
        XCTAssertTrue(removed.tracks.isEmpty)
        let missingFolder = await FolderImporter.scan(folder: root.appendingPathComponent("missing"), artworkDir: root.appendingPathComponent("Artwork"), cached: [track], musicOnly: true)
        XCTAssertTrue(missingFolder.tracks.isEmpty)
    }
}
