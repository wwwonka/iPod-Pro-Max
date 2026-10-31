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

final class AudiobookMergeTests: XCTestCase {
    override func setUp() { TestFFmpeg.prepare() }

    /// An AAC chapter at another sample rate, made from a WAV with the ffmpeg under test.
    private func aacChapter(_ ffmpeg: String, in dir: URL) async throws -> URL {
        let samples = 48_000 * 2
        var wav = Data("RIFF".utf8)
        func le32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { wav.append(contentsOf: $0) } }
        func le16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { wav.append(contentsOf: $0) } }
        le32(36 + samples * 2); wav.append(Data("WAVEfmt ".utf8)); le32(16); le16(1); le16(1); le32(48_000); le32(96_000); le16(2); le16(16)
        wav.append(Data("data".utf8)); le32(samples * 2)
        for i in 0..<samples { le16(Int(Double(Int16.max) / 4 * sin(Double(i) * 2 * .pi * 880 / 48_000)) & 0xFFFF) }
        let source = dir.appendingPathComponent("3.wav"), out = dir.appendingPathComponent("3.m4a")
        try wav.write(to: source)
        try await FFmpeg.run(ffmpeg, ["-y", "-v", "error", "-i", source.path, "-c:a", "aac", out.path])
        return out
    }

    func testChaptersBecomeOneM4BWithChapterMarks() async throws {
        guard let ffmpeg = FFmpeg.binaryPath() else { throw XCTSkip("no ffmpeg found (set IPODPROMAX_FFMPEG)") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("merge-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // Typical: MP3 chapters (which can't go into an m4a by copying), one with other audio parameters.
        let one = dir.appendingPathComponent("1.mp3"), two = dir.appendingPathComponent("2.mp3")
        try AudioFixtures.threeSecondMP3.write(to: one)
        try AudioFixtures.twoSecondMP3.write(to: two)
        let three = try await aacChapter(ffmpeg, in: dir)
        let out = dir.appendingPathComponent("book.m4b")
        let chapters = [AudiobookChapter(title: "Chapter One", url: one, durationMs: 3000),
                        AudiobookChapter(title: "Chapter Two", url: two, durationMs: 2000),
                        AudiobookChapter(title: "Chapter Three", url: three, durationMs: 2000)]
        try await AudiobookMuxer.merge(chapters: chapters, to: out)

        let info = await FFmpeg.probe(ffmpeg, ["-i", out.path])
        XCTAssertTrue(info.contains("Chapter One") && info.contains("Chapter Two") && info.contains("Chapter Three"), info)
        XCTAssertTrue(info.contains("Audio: aac"), info)
        XCTAssertTrue(info.contains("Duration: 00:00:07"), "all three chapters are in the audio: \(info)")
        XCTAssertTrue(info.contains("start 3.0"), "second chapter starts after the first: \(info)")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix(".merge-") }, [])
    }

    func testAlreadyUniformAACIsJoinedByCopyAndProbeParsing() async throws {
        let parsed = AudiobookMuxer.parse("""
        Input #0, mp3, from 'x.mp3':
          Duration: 01:02:03.50, start: 0.025057, bitrate: 64 kb/s
          Stream #0:0: Audio: mp3 (mp3float), 44100 Hz, stereo, fltp, 64 kb/s
        """)
        XCTAssertEqual(parsed, AudiobookMuxer.AudioFormat(codec: "mp3", sampleRate: 44100, channels: 2, durationMs: 3_723_500))
        XCTAssertEqual(AudiobookMuxer.parse("Stream #0:0: Audio: aac (LC), 22050 Hz, mono, fltp")?.channels, 1)
        XCTAssertNil(AudiobookMuxer.parse("Stream #0:0: Video: h264"))
        XCTAssertEqual(AudiobookMuxer.commonSampleRate([.init(codec: "mp3", sampleRate: 22050, channels: 1, durationMs: 0),
                                                        .init(codec: "mp3", sampleRate: 22050, channels: 1, durationMs: 0),
                                                        .init(codec: "aac", sampleRate: 48000, channels: 1, durationMs: 0)]), 22050)

        guard let ffmpeg = FFmpeg.binaryPath() else { throw XCTSkip("no ffmpeg found (set IPODPROMAX_FFMPEG)") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("merge-copy-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.mp3"), b = dir.appendingPathComponent("b.mp3")
        try AudioFixtures.threeSecondMP3.write(to: a)
        try AudioFixtures.twoSecondMP3.write(to: b)
        let m4a = dir.appendingPathComponent("a.m4a"), m4a2 = dir.appendingPathComponent("b.m4a")
        try await FFmpeg.run(ffmpeg, ["-y", "-v", "error", "-i", a.path, "-c:a", "aac", m4a.path])
        try await FFmpeg.run(ffmpeg, ["-y", "-v", "error", "-i", b.path, "-c:a", "aac", m4a2.path])
        let out = dir.appendingPathComponent("two.m4b")
        try await AudiobookMuxer.merge(chapters: [AudiobookChapter(title: "A", url: m4a), AudiobookChapter(title: "B", url: m4a2)], to: out)
        let info = await FFmpeg.probe(ffmpeg, ["-i", out.path])
        XCTAssertTrue(info.contains("Duration: 00:00:05"), info)
        XCTAssertTrue(info.contains("title           : B"), info)
    }

    func testBookGoesToTheIPodAsOneMergedM4BAndIsNotCopiedTwice() async throws {
        guard FFmpeg.binaryPath() != nil else { throw XCTSkip("no ffmpeg found (set IPODPROMAX_FFMPEG)") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("book-sync-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("Audiobooks/Short Novel")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try AudioFixtures.threeSecondMP3.write(to: library.appendingPathComponent("01 Start.mp3"))
        try AudioFixtures.twoSecondMP3.write(to: library.appendingPathComponent("02 End.mp3"))
        let ipod = root.appendingPathComponent("ipod")
        try IPodDevice.createSimulatedIPod(at: ipod)
        let device = try XCTUnwrap(IPodDevice.detect(volume: ipod, simulated: true))
        let store = PortableLibraryStore(root: ipod, hostID: "a")

        let scanned = await AudiobookScanner.scan(folder: root.appendingPathComponent("Audiobooks"), artworkDir: store.artwork, namespace: "s")
        XCTAssertEqual(scanned.tracks.count, 2, "\(scanned.failed)")
        // Dragging only the second chapter must still send the whole book (the app expands it; the transfer groups it).
        let prepared = try await PortableMusicTransfer.prepare(tracks: scanned.tracks, device: device, store: store)
        let result = try await SyncEngine(request: prepared.request, progress: { _ in }).run()
        XCTAssertEqual(result.added, 1, "one merged file for the whole book: \(result.failed)")

        let db = try device.readDatabase()
        let book = try XCTUnwrap(db.tracks.first)
        XCTAssertEqual(db.tracks.count, 1)
        XCTAssertEqual(book.title, "Short Novel")
        XCTAssertEqual(book.mediaType, IPodMediaType.audiobook)
        XCTAssertTrue(book.ipodPath.hasSuffix(".m4b"), book.ipodPath)
        XCTAssertGreaterThan(book.durationMs, 4500)
        let file = try XCTUnwrap(book.fileURL(mountPoint: ipod))
        let info = await FFmpeg.probe(try XCTUnwrap(FFmpeg.binaryPath()), ["-i", file.path])
        XCTAssertTrue(info.contains("01 Start") && info.contains("02 End"), "chapter marks on the iPod: \(info)")

        // Same book again: nothing to copy, whatever the chapters picked.
        try DeviceDataFolder(mountPoint: ipod).write(prepared.manifest, to: "manifest.json")
        let again = try await PortableMusicTransfer.prepare(tracks: scanned.tracks, device: device, store: store)
        XCTAssertTrue(again.request.tracks.isEmpty, "book is already there")
        XCTAssertEqual(again.reused, 1)
    }
}

final class MusicScanExclusionTests: XCTestCase {
    func testAudiobooksFolderInsideMusicFolderIsNotScannedAsMusic() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("music-excl-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let books = root.appendingPathComponent("Audiobooks")
        try FileManager.default.createDirectory(at: books, withIntermediateDirectories: true)
        try AudioFixtures.threeSecondMP3.write(to: root.appendingPathComponent("Song.mp3"))
        try AudioFixtures.twoSecondMP3.write(to: books.appendingPathComponent("Chapter.mp3"))
        let both = await FolderImporter.scan(folder: root, artworkDir: root.appendingPathComponent("art"), musicOnly: true)
        XCTAssertEqual(both.tracks.count, 2)
        let music = await FolderImporter.scan(folder: root, artworkDir: root.appendingPathComponent("art"), musicOnly: true, excluding: [books])
        XCTAssertEqual(music.tracks.map(\.title), ["Song"])
    }
}
