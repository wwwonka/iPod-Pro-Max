//
//  ReferenceTests.swift
//  iPodKitTests
//
//  The same inputs must give the same bytes on macOS, Linux and Windows: databases, signatures and
//  thumbnails are checked against SHA-1 fingerprints recorded once (on the Mac, where the app has
//  been writing databases real iPods accept). A mismatch on one OS means that OS writes differently.
//

import Foundation
import XCTest
@testable import iPodKit
#if canImport(CryptoKit)
import CryptoKit
#endif

final class ReferenceTests: XCTestCase {
    static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
    static func fingerprint(data: Data) -> String { hex(SHA1.hash([UInt8](data))) }
    static func fingerprint(_ bytes: [UInt8]) -> String { hex(SHA1.hash(bytes)) }

    // MARK: SHA-1 and hash58

    func testSHA1Vectors() {
        XCTAssertEqual(Self.hex(SHA1.hash([])), "da39a3ee5e6b4b0d3255bfef95601890afd80709")
        XCTAssertEqual(Self.hex(SHA1.hash(Array("abc".utf8))), "a9993e364706816aba3e25717850c26c9cd0d89d")
        XCTAssertEqual(Self.hex(SHA1.hash(Array("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8))),
                       "84983e441c3bd26ebaae4aa1f95129e5e54670f1")
        // Fed in uneven pieces, like the hash58 HMAC does.
        var s = SHA1()
        let million = [UInt8](repeating: 0x61, count: 1_000_000)
        s.update(data: Array(million[0..<7]))
        s.update(data: Array(million[7..<70_001]))
        s.update(data: Array(million[70_001...]))
        XCTAssertEqual(Self.hex(s.finalize()), "34aa973cd4c4daa4f61eeb2bdbad27316534016f")
    }

    func testHash58Signature() throws {
        let guid = try XCTUnwrap(Hash58.firewireBytes(from: "000A27001A5D2ABC"))
        let digest = Hash58.compute(firewireID: guid, database: Array(0..<255).map(UInt8.init))
        XCTAssertEqual(Self.hex(digest), Self.expected["hash58"])
    }

    #if canImport(CryptoKit)
    /// The portable SHA-1 must match CryptoKit's (what hash58 used before) for any input length.
    func testSHA1MatchesCryptoKit() {
        var generator = SystemRandomNumberGenerator()
        for length in [0, 1, 55, 56, 63, 64, 65, 119, 120, 1000, 4096, 70_001] {
            let data = (0..<length).map { _ in UInt8.random(in: 0...255, using: &generator) }
            XCTAssertEqual(SHA1.hash(data), Array(Insecure.SHA1.hash(data: data)), "length \(length)")
        }
    }
    #endif

    // MARK: iTunesDB

    /// A database with no clock, random or locale input: fixed ids, dates and time zone.
    static func referenceDatabase() -> ITunesDatabase {
        var db = ITunesDatabase()
        db.databaseID = 0x1122_3344_5566_7788
        db.libraryPersistentID = 0x0102_0304_0506_0708
        db.tzOffset = -4 * 3600
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        var mpl = IPodPlaylist(id: 0xA1A1_A1A1_A1A1_A1A1, name: "Julien’s iPod")
        mpl.isMaster = true
        mpl.timestamp = date
        let rows: [(String, String?, String?, String, UInt32)] = [
            ("Rococo", "Arcade Fire", "The Suburbs", "mp3", 4),
            ("Étienne d'août", "Malajube", "Trompe l'oeil", "m4a", 10),
            ("The Woodlands National Anthem", "Arcade Fire", "Arcade Fire [EP]", "mp3", 4),
            ("夜に駆ける", "YOASOBI", nil, "m4a", 1),
            ("Ça va", nil, "Les Rita Mitsouko", "mp3", 2),
        ]
        for (i, row) in rows.enumerated() {
            var t = IPodTrack(dbid: 0x1000 + UInt64(i))
            let info = IPodFileType.info(forExtension: row.3)
            t.title = row.0
            t.artist = row.1
            t.album = row.2
            t.albumArtist = row.1
            t.genre = "Alternative"
            t.ipodPath = ":iPod_Control:Music:F0\(i):ABC\(i).\(row.3)"
            t.filetypeDescription = info.description
            t.filetypeMarker = info.marker
            t.type2 = info.type2
            t.unk144 = info.unk144
            t.unk126 = info.unk126
            t.trackNumber = row.4
            t.trackCount = 12
            t.year = 2010
            t.durationMs = 200_000 + UInt32(i) * 1000
            t.fileSize = 5_000_000 + UInt32(i)
            t.bitrate = 256
            t.sampleRate = 44100
            t.timeAdded = date
            t.timeModified = date
            t.mediaType = IPodMediaType.audio
            t.sortArtist = SortKey.articleAware(t.artist).flatMap { $0 == t.artist ? nil : $0 }
            db.tracks.append(t)
            mpl.memberDBIDs.append(t.dbid)
        }
        var playlist = IPodPlaylist(id: 0xB2B2_B2B2_B2B2_B2B2, name: "Road trip")
        playlist.timestamp = date
        playlist.memberDBIDs = [0x1002, 0x1000]
        db.playlists = [mpl, playlist]
        return db
    }

    func testDatabaseBytesAreIdenticalEverywhere() throws {
        let out = try ITunesDBWriter(database: Self.referenceDatabase()).write()
        XCTAssertEqual(Self.fingerprint(data: out.data), Self.expected["iTunesDB"], "iTunesDB bytes differ from the reference")
    }

    func testSignedDatabaseBytesAreIdenticalEverywhere() throws {
        let guid = try XCTUnwrap(Hash58.firewireBytes(from: "000A27001A5D2ABC"))
        let out = try ITunesDBWriter(database: Self.referenceDatabase(), checksum: .hash58, firewireID: guid).write()
        XCTAssertEqual(Self.fingerprint(data: out.data), Self.expected["iTunesDB-hash58"], "hash58-signed iTunesDB differs from the reference")
    }

    func testDatabaseRoundTrip() throws {
        let original = Self.referenceDatabase()
        let out = try ITunesDBWriter(database: original).write()
        let read = try ITunesDBReader(data: out.data).parse()
        XCTAssertEqual(read.tracks.count, original.tracks.count)
        XCTAssertEqual(read.tracks.map(\.title), original.tracks.map(\.title))
        XCTAssertEqual(read.tracks.map(\.artist), original.tracks.map(\.artist))
        XCTAssertEqual(read.tracks.map(\.ipodPath), original.tracks.map(\.ipodPath))
        XCTAssertEqual(read.tracks.map(\.durationMs), original.tracks.map(\.durationMs))
        XCTAssertEqual(read.masterPlaylist?.name, "Julien’s iPod")
        XCTAssertEqual(read.playlists.first { $0.name == "Road trip" }?.memberDBIDs, [0x1002, 0x1000])
    }

    // MARK: Thumbnails

    /// A 300×200 gradient with a sharp diagonal edge: exercises the filter in both directions.
    static func referenceImage(width: Int = 300, height: Int = 200) -> PixelBuffer {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                bytes[i] = UInt8(x * 255 / (width - 1))
                bytes[i + 1] = UInt8(y * 255 / (height - 1))
                bytes[i + 2] = x > y ? 230 : 20
            }
        }
        return PixelBuffer(width: width, height: height, bytes: bytes)
    }

    func testFitKeepsPreviousGeometry() {
        // Same dimensions and padding as the CoreGraphics version produced.
        let fit = PixelBuffer.fittedSize(sourceWidth: 300, sourceHeight: 200, width: 100, height: 100)
        XCTAssertEqual(fit.width, 100)
        XCTAssertEqual(fit.height, 67)
        let tall = PixelBuffer.fittedSize(sourceWidth: 500, sourceHeight: 1000, width: 320, height: 240)
        XCTAssertEqual(tall.width, 120)
        XCTAssertEqual(tall.height, 240)
    }

    func testResizeAveragesFlatColors() {
        let flat = PixelBuffer(width: 64, height: 64, bytes: [UInt8]((0..<(64 * 64)).flatMap { _ in [200, 100, 50, 255] as [UInt8] }))
        for size in [(1, 1), (17, 9), (64, 64), (200, 130)] {
            let r = flat.resized(width: size.0, height: size.1)
            XCTAssertEqual(r.bytes[0], 200); XCTAssertEqual(r.bytes[1], 100); XCTAssertEqual(r.bytes[2], 50)
            XCTAssertEqual(r.bytes[r.bytes.count - 4], 200)
        }
    }

    func testArtworkThumbnailsAreIdenticalEverywhere() {
        let image = Self.referenceImage()
        let classic = IThumbWriter.render(image: image, format: ArtworkFormat(id: 1061, width: 56, height: 56))
        let large = IThumbWriter.render(image: image, format: ArtworkFormat(id: 1060, width: 320, height: 320))
        XCTAssertEqual(classic.width, 56); XCTAssertEqual(classic.height, 38)
        XCTAssertEqual(Self.fingerprint(classic.pixels), Self.expected["artwork-56"])
        XCTAssertEqual(Self.fingerprint(large.pixels), Self.expected["artwork-320"])
    }

    func testPhotoThumbnailsAreIdenticalEverywhere() {
        let image = Self.referenceImage(width: 1024, height: 683)
        for format in IPodGeneration.classic3.photoFormats + IPodGeneration.video1.photoFormats {
            let r = PhotoDBWriter.render(image: image, format: format)
            XCTAssertEqual(r.pixels.count, format.bytesPerImage)
            XCTAssertEqual(Self.fingerprint(r.pixels), Self.expected["photo-\(format.id)"], "photo format \(format.id)")
        }
    }

    func testStraightAlphaIsCompositedOverBlack() {
        let p = PixelBuffer(width: 1, height: 1, straightRGBA: [255, 128, 0, 128])
        XCTAssertEqual(Array(p.bytes), [128, 64, 0, 255])
    }

    // MARK: Device helpers

    func testUSBSerialGivesFireWireGUID() {
        let usb = USBDeviceIdentity(vendorID: 0x05AC, productID: 0x1261, serialNumber: "000A27001A5D2ABC", productName: "iPod")
        XCTAssertEqual(usb.firewireGUIDFromSerial, "000A27001A5D2ABC")
        XCTAssertEqual(usb.generation, .classic1)
        XCTAssertNil(USBDeviceIdentity(vendorID: 0x05AC, productID: 0x1209, serialNumber: "8K5100XYZ", productName: nil).firewireGUIDFromSerial)
    }

    func testSafeReplaceAndDataFolder() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ipodkit-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = DeviceDataFolder(mountPoint: dir)
        var record = DeviceSyncRecord(deviceID: "x", deviceName: "Test")
        record.lyricsFixedDates[UUID()] = Date(timeIntervalSince1970: 1_700_000_000.123456)
        try folder.write(record, to: "r.json")
        record.deviceName = "Second"
        try folder.write(record, to: "r.json")
        let back = try XCTUnwrap(folder.read(DeviceSyncRecord.self, from: "r.json"))
        XCTAssertEqual(back, record, "dates must survive with their fractions of a second")
        // A damaged file falls back to the previous generation.
        try Data("{".utf8).write(to: folder.url.appendingPathComponent("r.json"))
        XCTAssertEqual(folder.read(DeviceSyncRecord.self, from: "r.json")?.deviceName, "Test")
    }

    /// Recorded on macOS. `IPODKIT_PRINT_REFERENCES=1 swift test --filter testPrintReferences` prints the
    /// current values (only update them for an intended change of output).
    static let expected: [String: String] = [
        "hash58": "0cd1d58eb674777bf9cf0bb3be0b0b9c26da7b4a",
        "iTunesDB": "3d4e10a0d86a95723062c4f6b479369681216193",
        "iTunesDB-hash58": "11b0b1aa3ef0bd12754ab20f04d7308489c3a9e1",
        "artwork-56": "026307166117a1f5c547f519f1b9b0c859072c33",
        "artwork-320": "bac8b15574890bcf7a4e62029e1b5678a638aa7e",
        "photo-1067": "b5ae39952d38fcd1441bf7d38af29296f42e4bf0",
        "photo-1024": "280eebe0cbdb09b3de9713c2a9d38df0799f145b",
        "photo-1066": "81d11d85d77ba53c15b9e943e23e4145d2c5bff0",
        "photo-1036": "3ab13a5c19291008f607ddfe33351921c6d97b02",
        "photo-1015": "e4f745d24c5d8a61bafa9fd2c961b5d46fb5efb2",
        "photo-1019": "e2863dd30aafec5652b0441c12ff7e84959a04e1",
    ]

    func testPrintReferences() throws {
        guard ProcessInfo.processInfo.environment["IPODKIT_PRINT_REFERENCES"] != nil else { return }
        let guid = try XCTUnwrap(Hash58.firewireBytes(from: "000A27001A5D2ABC"))
        var lines: [String] = []
        lines.append("\"hash58\": \"\(Self.hex(Hash58.compute(firewireID: guid, database: Array(0..<255).map(UInt8.init))))\",")
        lines.append("\"iTunesDB\": \"\(Self.fingerprint(data: try ITunesDBWriter(database: Self.referenceDatabase()).write().data))\",")
        lines.append("\"iTunesDB-hash58\": \"\(Self.fingerprint(data: try ITunesDBWriter(database: Self.referenceDatabase(), checksum: .hash58, firewireID: guid).write().data))\",")
        let image = Self.referenceImage()
        lines.append("\"artwork-56\": \"\(Self.fingerprint(IThumbWriter.render(image: image, format: ArtworkFormat(id: 1061, width: 56, height: 56)).pixels))\",")
        lines.append("\"artwork-320\": \"\(Self.fingerprint(IThumbWriter.render(image: image, format: ArtworkFormat(id: 1060, width: 320, height: 320)).pixels))\",")
        let photo = Self.referenceImage(width: 1024, height: 683)
        for format in IPodGeneration.classic3.photoFormats + IPodGeneration.video1.photoFormats {
            lines.append("\"photo-\(format.id)\": \"\(Self.fingerprint(PhotoDBWriter.render(image: photo, format: format).pixels))\",")
        }
        print(lines.joined(separator: "\n"))
    }
}
