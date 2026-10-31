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
