import XCTest
#if canImport(ImageIO)
import ImageIO
import CoreGraphics
#endif
import iPodKit
@testable import MediaKit

final class PhotoTests: XCTestCase {
    /// A solid-color picture, as a JPEG file.
    private func writePicture(_ url: URL, width: Int = 400, height: Int = 300, shade: UInt8) throws {
        #if canImport(ImageIO)
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: Double(shade) / 255, green: Double(shade) / 510, blue: 1 - Double(shade) / 255, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        try XCTUnwrap(ImageLoading.jpegData(from: image, maxDimension: 4000, quality: 0.9)).write(to: url)
        #else
        throw XCTSkip("needs ImageIO to make pictures")
        #endif
    }

    func testFoldersBecomeAlbumsAndPicturesAreExportedOnce() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("photos-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let pics = root.appendingPathComponent("Holidays")
        let sub = pics.appendingPathComponent("Beach")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try writePicture(pics.appendingPathComponent("a.jpg"), shade: 40)
        try writePicture(sub.appendingPathComponent("b.jpg"), width: 3000, height: 2000, shade: 120)
        try writePicture(sub.appendingPathComponent("c.jpeg"), shade: 200)
        try Data("x".utf8).write(to: pics.appendingPathComponent("notes.txt"))

        let library = FolderPhotoLibrary(folders: [pics])
        XCTAssertEqual(library.estimatedCount(selection: PhotoSelection()), 3)
        XCTAssertTrue(library.exportsWithoutSelection)
        let cache = root.appendingPathComponent("cache")
        let first = try library.export(selection: PhotoSelection(), cacheDir: cache) { _, _ in }
        XCTAssertEqual(first.photos.count, 3)
        XCTAssertEqual(first.failed, 0)
        XCTAssertEqual(first.albums.map(\.name), ["Holidays", "Holidays – Beach"])
        XCTAssertEqual(first.albums.map(\.photoKeys.count), [3, 2])
        let big = try XCTUnwrap(first.photos.first { $0.originalSize > 0 && $0.jpegURL.lastPathComponent != "" && ImageLoading.pixels(from: $0.jpegURL)?.width == 1024 })
        XCTAssertEqual(ImageLoading.pixels(from: big.jpegURL)?.height, 683, "3000×2000 shrinks to 1024 px wide")

        // Second export reuses the cache: files untouched.
        let before = try FileManager.default.attributesOfItem(atPath: first.photos[0].jpegURL.path)[.modificationDate] as? Date
        let second = try library.export(selection: PhotoSelection(), cacheDir: cache) { _, _ in }
        XCTAssertEqual(second.photos.map(\.key), first.photos.map(\.key))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: first.photos[0].jpegURL.path)[.modificationDate] as? Date, before)

        // A removed picture leaves the cache at the end of a sync.
        library.pruneCache(cache, keep: Set(first.photos.dropFirst().map(\.key)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.photos[0].jpegURL.path))
    }

    func testPhotosGoToTheIPodWithoutTouchingItsSongs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("photo-sync-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let pics = root.appendingPathComponent("Pics")
        try FileManager.default.createDirectory(at: pics, withIntermediateDirectories: true)
        for (i, shade) in [30, 90, 150, 210].enumerated() { try writePicture(pics.appendingPathComponent("p\(i).jpg"), shade: UInt8(shade)) }
        let ipod = root.appendingPathComponent("ipod")
        try IPodDevice.createSimulatedIPod(at: ipod)
        let device = try XCTUnwrap(IPodDevice.detect(volume: ipod, simulated: true))
        let store = PortableLibraryStore(root: ipod, hostID: "a")

        // A song already there must survive.
        let song = root.appendingPathComponent("song.mp3")
        try AudioFixtures.twoSecondMP3.write(to: song)
        let songPrep = try await PortableMusicTransfer.prepare(tracks: [LibraryTrack(path: song.path, title: "Keep Me", fileSize: Int64(AudioFixtures.twoSecondMP3.count), fileExtension: "mp3")], device: device, store: store)
        _ = try await SyncEngine(request: songPrep.request, progress: { _ in }).run()
        XCTAssertEqual(try device.readDatabase().tracks.count, 1)

        try store.addSource(kind: .photos, path: pics.path)
        XCTAssertEqual(store.sources(of: .photos).map(\.path), [pics.path])
        let library = PortablePhotoTransfer.library(store: store)
        let prepared = try PortablePhotoTransfer.prepare(device: device, store: store, library: library, selection: PhotoSelection())
        XCTAssertTrue(prepared.alwaysRuns)
        let result = try await SyncEngine(request: prepared.request, progress: { _ in }).run()
        XCTAssertEqual(result.photosWritten, 4, "\(result.failed) \(result.log)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: ipod.appendingPathComponent("Photos/Photo Database").path))
        XCTAssertEqual(try device.readDatabase().tracks.map(\.title), ["Keep Me"])

        // Removing a folder forgets it for this computer.
        let id = try XCTUnwrap(store.sources(of: .photos).first?.id)
        try store.removeSource(id: id)
        XCTAssertTrue(store.sources(of: .photos).isEmpty)
    }

    func testSelectionIsKeptOnTheIPod() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("photo-sel-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try IPodDevice.createSimulatedIPod(at: root)
        let store = PortableLibraryStore(root: root, hostID: "a")
        XCTAssertTrue(store.loadPhotoSelection().isEmpty)
        try store.savePhotoSelection(PhotoSelection(albumIDs: ["x"], includeAllPhotos: true, albumNames: ["x": "Trip"]))
        let other = PortableLibraryStore(root: root, hostID: "a")
        XCTAssertEqual(other.loadPhotoSelection().albumNames["x"], "Trip")
        XCTAssertTrue(other.loadPhotoSelection().includeAllPhotos)
    }
}
