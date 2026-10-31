//
//  ArtworkDB.swift
//  iPod Pro Max
//
//  Writes album art for the iPod: raw RGB565 thumbnails into iPod_Control/Artwork/F<format>_<n>.ithmb
//  files plus the ArtworkDB index that links them to tracks (by dbid). Layout follows libgpod / iTunes.
//

import Foundation

/// One rendered thumbnail stored inside an .ithmb file.
public struct ThumbnailRef: Hashable, Sendable {
    public let format: ArtworkFormat
    /// iPod-style path, e.g. ":F1028_1.ithmb"
    public let filename: String
    public let offset: UInt32
    public let size: UInt32
    public let verticalPadding: Int16
    public let horizontalPadding: Int16
    /// Width/height including the leading padding (as iTunes records them).
    public let width: UInt16
    public let height: UInt16

    public init(format: ArtworkFormat, filename: String, offset: UInt32, size: UInt32, verticalPadding: Int16, horizontalPadding: Int16, width: UInt16, height: UInt16) {
        self.format = format
        self.filename = filename
        self.offset = offset
        self.size = size
        self.verticalPadding = verticalPadding
        self.horizontalPadding = horizontalPadding
        self.width = width
        self.height = height
    }
}

/// An ArtworkDB image entry (mhii) for one track.
public struct ArtworkEntry: Sendable {
    public let imageID: UInt32
    public let trackDBID: UInt64
    public let originalImageSize: UInt32
    public let thumbnails: [ThumbnailRef]

    public init(imageID: UInt32, trackDBID: UInt64, originalImageSize: UInt32, thumbnails: [ThumbnailRef]) {
        self.imageID = imageID
        self.trackDBID = trackDBID
        self.originalImageSize = originalImageSize
        self.thumbnails = thumbnails
    }
}

/// Renders artwork into .ithmb files. Identical images (same key) are stored once and shared.
public final class IThumbWriter {
    public static let maxFileSize = 256 * 1024 * 1024

    private struct FormatState {
        var fileIndex = 1
        var handle: FileHandle?
        var offset: UInt32 = 0
    }

    public let artworkDir: URL
    public let formats: [ArtworkFormat]
    private var states: [Int: FormatState] = [:]
    private var cache: [String: [ThumbnailRef]] = [:]
    private(set) var uniqueImageCount = 0

    public init(artworkDir: URL, formats: [ArtworkFormat]) {
        self.artworkDir = artworkDir
        self.formats = formats
        for f in formats { states[f.id] = FormatState() }
    }

    /// Removes any existing thumbnail files so the ArtworkDB and ithmb files stay consistent.
    public func removeExistingFiles() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: artworkDir, withIntermediateDirectories: true)
        if let items = try? fm.contentsOfDirectory(at: artworkDir, includingPropertiesForKeys: nil) {
            for url in items where url.pathExtension.lowercased() == "ithmb" && url.lastPathComponent.hasPrefix("F") {
                try? fm.removeItem(at: url)
            }
        }
        let dbURL = artworkDir.appendingPathComponent("ArtworkDB")
        if fm.fileExists(atPath: dbURL.path) { try? fm.removeItem(at: dbURL) }
    }

    /// One cover scaled and packed for one format, ready to append.
    public struct Rendered: Sendable {
        public let pixels: [UInt8]
        public let width: Int
        public let height: Int

        public init(pixels: [UInt8], width: Int, height: Int) {
            self.pixels = pixels
            self.width = width
            self.height = height
        }
    }

    /// Returns thumbnail references for the given image, rendering and appending it when not seen before.
    public func thumbnails(forKey key: String, image: PixelBuffer) throws -> [ThumbnailRef] {
        if let cached = cache[key] { return cached }
        return try append(rendered: formats.map { Self.render(image: image, format: $0) }, forKey: key)
    }

    /// Appends covers rendered beforehand (one per format, in `formats` order), possibly on other threads.
    public func append(rendered: [Rendered], forKey key: String) throws -> [ThumbnailRef] {
        if let cached = cache[key] { return cached }
        var refs: [ThumbnailRef] = []
        for (f, r) in zip(formats, rendered) {
            refs.append(try append(pixels: r.pixels, format: f, scaledWidth: r.width, scaledHeight: r.height))
        }
        cache[key] = refs
        uniqueImageCount += 1
        return refs
    }

    public func finish() {
        for (id, var s) in states {
            try? s.handle?.close()
            s.handle = nil
            states[id] = s
        }
    }

    private func append(pixels: [UInt8], format: ArtworkFormat, scaledWidth: Int, scaledHeight: Int) throws -> ThumbnailRef {
        guard var s = states[format.id] else { throw IPodDBError.io("unknown artwork format \(format.id)") }
        while s.handle == nil || Int(s.offset) + pixels.count > Self.maxFileSize {
            if s.handle != nil {
                try? s.handle?.close()
                s.fileIndex += 1
            }
            let url = artworkDir.appendingPathComponent("F\(format.id)_\(s.fileIndex).ithmb")
            if !FileManager.default.fileExists(atPath: url.path) {
                _ = FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            s.handle = try FileHandle(forWritingTo: url)
            let end = try s.handle?.seekToEnd() ?? 0
            guard end <= UInt32.max else { throw IPodDBError.io("Artwork thumbnail file is too large") }
            s.offset = UInt32(end)
        }
        try s.handle?.write(contentsOf: pixels)
        let hpad = Int16((format.width - scaledWidth) / 2)
        let vpad = Int16((format.height - scaledHeight) / 2)
        let ref = ThumbnailRef(format: format, filename: ":F\(format.id)_\(s.fileIndex).ithmb", offset: s.offset, size: UInt32(pixels.count),
                               verticalPadding: vpad, horizontalPadding: hpad,
                               width: UInt16(Int(hpad) + scaledWidth), height: UInt16(Int(vpad) + scaledHeight))
        s.offset += UInt32(pixels.count)
        states[format.id] = s
        return ref
    }

    /// Scales the image to fit the format (preserving aspect ratio, centered on black) and packs it as RGB565 little-endian.
    public static func render(image: PixelBuffer, format: ArtworkFormat) -> Rendered {
        let fitted = image.fitted(width: format.width, height: format.height)
        return Rendered(pixels: RGB565.pack(fitted.bytes), width: fitted.width, height: fitted.height)
    }
}

public enum ArtworkDBWriter: Sendable {
    public static let firstImageID: UInt32 = 0x64

    public static func write(entries: [ArtworkEntry], formats: [ArtworkFormat], tzOffset: Int32) -> Data {
        var w = ByteWriter(capacity: 4096 + entries.count * 512)
        let maxID = entries.map(\.imageID).max() ?? 0

        // mhfd
        w.header("mhfd")
        w.u32(0x84)
        w.u32(0)
        w.u32(0) // unknown1
        w.u32(2) // unknown2 (must be 2, iTunes 7 drops the db otherwise)
        w.u32(3) // children
        w.u32(0) // unknown3
        w.u32(maxID) // next id
        w.u64(0)
        w.u64(0)
        w.u8(2) // unknown_flag1
        w.u8(0); w.u8(0); w.u8(0)
        w.u32(0); w.u32(0); w.u32(0); w.u32(0)
        w.padTo(length: 0x84, from: 0)

        // mhsd 1: image list
        var mhsd = writeMHSD(&w, type: 1)
        let mhli = w.count
        w.header("mhli")
        w.u32(0x5C)
        w.u32(UInt32(entries.count))
        w.padTo(length: 0x5C, from: mhli)
        for e in entries {
            writeMHII(&w, entry: e, tzOffset: tzOffset)
        }
        w.fixTotalLength(headerStart: mhsd)

        // mhsd 2: album list (empty for the music ArtworkDB)
        mhsd = writeMHSD(&w, type: 2)
        let mhla = w.count
        w.header("mhla")
        w.u32(0x5C)
        w.u32(0)
        w.padTo(length: 0x5C, from: mhla)
        w.fixTotalLength(headerStart: mhsd)

        // mhsd 3: file list
        mhsd = writeMHSD(&w, type: 3)
        let mhlf = w.count
        w.header("mhlf")
        w.u32(0x5C)
        w.u32(UInt32(formats.count))
        w.padTo(length: 0x5C, from: mhlf)
        for f in formats {
            let s = w.count
            w.header("mhif")
            w.u32(0x7C)
            w.u32(0x7C)
            w.u32(0)
            w.u32(UInt32(f.id))
            w.u32(UInt32(f.bytesPerImage))
            w.padTo(length: 0x7C, from: s)
        }
        w.fixTotalLength(headerStart: mhsd)

        w.fixTotalLength(headerStart: 0)
        return w.data
    }

    private static func writeMHSD(_ w: inout ByteWriter, type: UInt16) -> Int {
        let s = w.count
        w.header("mhsd")
        w.u32(0x60)
        w.u32(0)
        w.u16(type)
        w.u16(0)
        w.padTo(length: 0x60, from: s)
        return s
    }

    private static func writeMHII(_ w: inout ByteWriter, entry e: ArtworkEntry, tzOffset: Int32) {
        let s = w.count
        w.header("mhii")
        w.u32(0x98)
        w.u32(0)
        w.u32(UInt32(e.thumbnails.count))
        w.u32(e.imageID)
        w.u64(e.trackDBID)
        w.u32(0) // unknown4
        w.u32(0) // rating
        w.u32(0) // unknown6
        w.u32(0) // orig date
        w.u32(0) // digitized date
        w.u32(e.originalImageSize)
        w.padTo(length: 0x98, from: s)
        for t in e.thumbnails {
            // mhod type 2 container
            let m = w.count
            w.header("mhod")
            w.u32(24)
            w.u32(0)
            w.u16(2)
            w.u16(0)
            w.u32(0)
            w.u32(0)
            // mhni
            let n = w.count
            w.header("mhni")
            w.u32(0x4C)
            w.u32(0)
            w.u32(1)
            w.u32(UInt32(t.format.id))
            w.u32(t.offset)
            w.u32(t.size)
            w.u16(UInt16(bitPattern: t.verticalPadding))
            w.u16(UInt16(bitPattern: t.horizontalPadding))
            w.u16(t.height)
            w.u16(t.width)
            w.padTo(length: 0x4C, from: n)
            // mhod type 3: filename (UTF-16LE)
            let f = w.count
            let units = Array(t.filename.utf16)
            let strBytes = units.count * 2
            var padding = 4 - ((36 + strBytes) % 4)
            if padding == 4 { padding = 0 }
            w.header("mhod")
            w.u32(24)
            w.u32(UInt32(36 + strBytes + padding))
            w.u16(3)
            w.u8(0)
            w.u8(UInt8(padding))
            w.u32(0)
            w.u32(0)
            w.u32(UInt32(strBytes))
            w.u8(2) // UTF-16LE
            w.u8(0)
            w.u16(0)
            w.u32(0)
            for u in units { w.u16(u) }
            w.zeros(padding)
            assert(w.count - f == 36 + strBytes + padding)
            w.fixTotalLength(headerStart: n)
            w.fixTotalLength(headerStart: m)
        }
        w.fixTotalLength(headerStart: s)
    }
}

/// Keeps foreign artwork records byte-for-byte when adding music. No thumbnail decoding needed.
enum ExistingArtwork {
    static func records(_ data: Data) throws -> [(id: UInt32, dbid: UInt64, bytes: Data)] {
        let r = ByteReader(data)
        guard r.hasHeader("mhfd", at: 0), r.u32(8) == data.count else { throw IPodDBError.corrupt("ArtworkDB header") }
        var section = Int(r.u32(4))
        while section + 16 <= data.count {
            let length = Int(r.u32(section + 8))
            guard r.hasHeader("mhsd", at: section), length >= 16, section + length <= data.count else { throw IPodDBError.corrupt("ArtworkDB section") }
            if r.u16(section + 12) == 1 {
                let list = section + Int(r.u32(section + 4))
                guard r.hasHeader("mhli", at: list) else { throw IPodDBError.corrupt("ArtworkDB image list") }
                var offset = list + Int(r.u32(list + 4))
                var result: [(UInt32, UInt64, Data)] = []
                for _ in 0..<Int(r.u32(list + 8)) {
                    let size = Int(r.u32(offset + 8))
                    guard r.hasHeader("mhii", at: offset), size >= 52, offset + size <= section + length else { throw IPodDBError.corrupt("ArtworkDB image") }
                    result.append((r.u32(offset + 16), r.u64(offset + 20), data.subdata(in: offset..<(offset + size))))
                    offset += size
                }
                return result
            }
            section += length
        }
        throw IPodDBError.corrupt("ArtworkDB image section missing")
    }

    static func merge(_ old: Data, into fresh: Data) throws -> Data {
        let records = try records(old)
        guard !records.isEmpty else { return fresh }
        let r = ByteReader(fresh)
        let section = Int(r.u32(4))
        let list = section + Int(r.u32(section + 4))
        let insert = list + Int(r.u32(list + 4))
        let raw = records.reduce(into: Data()) { $0.append($1.bytes) }
        var merged = fresh
        merged.insert(contentsOf: raw, at: insert)
        var writer = ByteWriter(); writer.append(merged)
        writer.patchU32(UInt32(merged.count), at: 8)
        writer.patchU32(max(r.u32(28), records.map(\.id).max() ?? 0), at: 28)
        writer.patchU32(r.u32(section + 8) + UInt32(raw.count), at: section + 8)
        writer.patchU32(r.u32(list + 8) + UInt32(records.count), at: list + 8)
        return writer.data
    }
}
