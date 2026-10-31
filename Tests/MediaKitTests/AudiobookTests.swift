import XCTest
import iPodKit
@testable import MediaKit

final class AudiobookTests: XCTestCase {
    /// One second of silence, 8 kHz mono 16-bit.
    private func wav(_ seed: UInt8 = 0) -> Data {
        let samples = 8000, bytes = samples * 2
        var d = Data("RIFF".utf8)
        func le32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { d.append(contentsOf: $0) } }
        func le16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { d.append(contentsOf: $0) } }
        le32(36 + bytes); d.append(Data("WAVEfmt ".utf8)); le32(16); le16(1); le16(1); le32(8000); le32(16000); le16(2); le16(16)
        d.append(Data("data".utf8)); le32(bytes); d.append(Data(repeating: seed, count: bytes))
        return d
    }

    func testBooksAreSubfoldersAndLooseFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("books-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let book = root.appendingPathComponent("Big Novel")
        try FileManager.default.createDirectory(at: book, withIntermediateDirectories: true)
        try wav(2).write(to: book.appendingPathComponent("02 Two.wav"))
        try wav(1).write(to: book.appendingPathComponent("01 One.wav"))
        try wav(3).write(to: root.appendingPathComponent("Short Story.wav"))
        try Data("x".utf8).write(to: root.appendingPathComponent("notes.txt"))

        let found = AudiobookScanner.books(in: root)
        XCTAssertEqual(found.map(\.title), ["Big Novel", "Short Story"])
        XCTAssertEqual(found[0].files.map(\.lastPathComponent), ["01 One.wav", "02 Two.wav"])

        let scanned = await AudiobookScanner.scan(folder: root, artworkDir: root.appendingPathComponent("art"), namespace: "s")
        XCTAssertEqual(scanned.tracks.count, 3, "failed: \(scanned.failed)")
        XCTAssertTrue(scanned.tracks.allSatisfy(\.isAudiobook))
        let chapters = scanned.tracks.filter { $0.album == "Big Novel" }
        XCTAssertEqual(chapters.map(\.trackNumber), [1, 2])
        XCTAssertEqual(Set(chapters.compactMap(\.artist)).count, 1, "one author for the whole book")
        // Same folder, same ids.
        let again = await AudiobookScanner.scan(folder: root, artworkDir: root.appendingPathComponent("art"), cached: scanned.tracks, namespace: "s")
        XCTAssertEqual(again.tracks.map(\.id), scanned.tracks.map(\.id))

        // On the iPod the book is one entry: only its first chapter is fingerprinted and scheduled with the rest.
        let ipod = FileManager.default.temporaryDirectory.appendingPathComponent("books-ipod-\(UUID())")
        defer { try? FileManager.default.removeItem(at: ipod) }
        try IPodDevice.createSimulatedIPod(at: ipod)
        let device = try XCTUnwrap(IPodDevice.detect(volume: ipod, simulated: true))
        let store = PortableLibraryStore(root: ipod, hostID: "a")
        let prepared = try await PortableMusicTransfer.prepare(tracks: scanned.tracks, device: device, store: store)
        XCTAssertEqual(prepared.request.tracks.count, 3)
        XCTAssertEqual(prepared.manifest.tracks.count, 2, "one manifest entry per book, not per chapter")
    }
}
