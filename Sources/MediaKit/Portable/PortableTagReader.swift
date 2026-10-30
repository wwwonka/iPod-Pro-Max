//
//  PortableTagReader.swift
//  iPod Pro Max
//
//  Tags, duration, bitrate and artwork in pure Swift: ID3v1/ID3v2.2–2.4 (+ MP3 frame headers),
//  MP4 atoms (m4a, m4b, mp4), FLAC, Ogg Vorbis/Opus, WAV and AIFF. Used on Linux and Windows, where
//  AVFoundation doesn't exist. It seeks to the few places that matter instead of reading whole files,
//  so a library scan stays as fast as with AVFoundation.
//

import Foundation
import iPodKit

public enum PortableTagReader {
    public static func read(_ url: URL) throws -> ExtractedMetadata {
        let file = try RandomAccessFile(url: url)
        defer { file.close() }
        var md = ExtractedMetadata()
        let head = file.read(at: 0, count: 12)
        let ext = url.pathExtension.lowercased()

        if head.starts(with: Array("fLaC".utf8)) || (head.starts(with: Array("ID3".utf8)) && ext == "flac") {
            FLACReader.read(file, into: &md)
        } else if head.count >= 8, Array(head[4..<8]) == Array("ftyp".utf8) || ["m4a", "m4b", "m4p", "mp4", "m4v", "mov"].contains(ext) {
            MP4Reader.read(file, into: &md)
        } else if head.starts(with: Array("OggS".utf8)) {
            OggReader.read(file, into: &md)
        } else if head.starts(with: Array("RIFF".utf8)), head.count >= 12, Array(head[8..<12]) == Array("WAVE".utf8) {
            WAVReader.read(file, into: &md)
        } else if head.starts(with: Array("FORM".utf8)), head.count >= 12, ["AIFF", "AIFC"].contains(String(decoding: head[8..<12], as: UTF8.self)) {
            AIFFReader.read(file, into: &md)
        } else {
            MP3Reader.read(file, into: &md)
        }
        md.normalize()
        if md.bitrate == 0, md.durationMs > 0 {
            md.bitrate = Int((Double(file.size) * 8 / Double(md.durationMs)).rounded())
        }
        return md
    }
}

extension ExtractedMetadata {
    /// Same cleanup as the AVFoundation path: trimmed strings, empty values dropped, "(17)" genres named.
    mutating func normalize() {
        func clean(_ s: String?) -> String? {
            guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\0", with: ""), !t.isEmpty else { return nil }
            return t
        }
        title = clean(title); artist = clean(artist); album = clean(album); albumArtist = clean(albumArtist)
        composer = clean(composer); comment = clean(comment); grouping = clean(grouping)
        if let g = clean(genre) { genre = ID3Genres.normalize(g) } else { genre = nil }
    }

    /// Text fields shared by Vorbis comments (FLAC, Ogg) and the APE-like freeform keys.
    mutating func applyVorbis(key rawKey: String, value: String) {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        switch rawKey.uppercased() {
        case "TITLE": if title == nil { title = v }
        case "ARTIST": if artist == nil { artist = v }
        case "ALBUM": if album == nil { album = v }
        case "ALBUMARTIST", "ALBUM ARTIST", "ALBUM_ARTIST": if albumArtist == nil { albumArtist = v }
        case "GENRE": if genre == nil { genre = v }
        case "COMPOSER": if composer == nil { composer = v }
        case "COMMENT", "DESCRIPTION": if comment == nil { comment = v }
        case "GROUPING", "CONTENTGROUP": if grouping == nil { grouping = v }
        case "DATE", "YEAR", "ORIGINALDATE":
            if year == 0, let y = Int(v.prefix(4)) { year = y }
            if releaseDate == nil { releaseDate = DateParsing.parseISO(v) }
        case "TRACKNUMBER":
            if trackNumber == 0 { let p = TagText.pair(v); trackNumber = p.0; if p.1 > 0 { trackCount = p.1 } }
        case "TRACKTOTAL", "TOTALTRACKS": if trackCount == 0 { trackCount = Int(v) ?? 0 }
        case "DISCNUMBER":
            if discNumber == 0 { let p = TagText.pair(v); discNumber = p.0; if p.1 > 0 { discCount = p.1 } }
        case "DISCTOTAL", "TOTALDISCS": if discCount == 0 { discCount = Int(v) ?? 0 }
        case "BPM": if bpm == 0 { bpm = Int(Double(v) ?? 0) }
        case "COMPILATION": compilation = (Int(v) ?? 0) != 0
        case "LYRICS", "UNSYNCEDLYRICS", "UNSYNCEDLYRIC": if !v.isEmpty { hasLyrics = true }
        case "METADATA_BLOCK_PICTURE":
            if artworkData == nil, let raw = Data(base64Encoded: v, options: .ignoreUnknownCharacters) {
                artworkData = FLACReader.pictureData(fromBlock: [UInt8](raw))
            }
        case "COVERART":
            if artworkData == nil, let raw = Data(base64Encoded: v, options: .ignoreUnknownCharacters), !raw.isEmpty { artworkData = raw }
        default: break
        }
    }
}

// MARK: - File access

/// Reads byte ranges without loading the file. Out-of-range reads return what exists.
final class RandomAccessFile {
    let handle: FileHandle
    let size: Int

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        size = Int((try? handle.seekToEnd()) ?? 0)
    }

    func read(at offset: Int, count: Int) -> [UInt8] {
        guard offset >= 0, offset < size, count > 0 else { return [] }
        do {
            try handle.seek(toOffset: UInt64(offset))
            return [UInt8](try handle.read(upToCount: min(count, size - offset)) ?? Data())
        } catch {
            return []
        }
    }

    func close() { try? handle.close() }
}

enum Bytes {
    static func be32(_ b: [UInt8], _ o: Int) -> Int {
        guard o + 4 <= b.count else { return 0 }
        return Int(b[o]) << 24 | Int(b[o + 1]) << 16 | Int(b[o + 2]) << 8 | Int(b[o + 3])
    }
    static func be16(_ b: [UInt8], _ o: Int) -> Int {
        guard o + 2 <= b.count else { return 0 }
        return Int(b[o]) << 8 | Int(b[o + 1])
    }
    static func be24(_ b: [UInt8], _ o: Int) -> Int {
        guard o + 3 <= b.count else { return 0 }
        return Int(b[o]) << 16 | Int(b[o + 1]) << 8 | Int(b[o + 2])
    }
    static func be64(_ b: [UInt8], _ o: Int) -> Int {
        guard o + 8 <= b.count else { return 0 }
        var v: UInt64 = 0
        for i in 0..<8 { v = v << 8 | UInt64(b[o + i]) }
        return Int(truncatingIfNeeded: v)
    }
    static func le32(_ b: [UInt8], _ o: Int) -> Int {
        guard o + 4 <= b.count else { return 0 }
        return Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24
    }
    static func le16(_ b: [UInt8], _ o: Int) -> Int {
        guard o + 2 <= b.count else { return 0 }
        return Int(b[o]) | Int(b[o + 1]) << 8
    }
    static func le64(_ b: [UInt8], _ o: Int) -> Int {
        guard o + 8 <= b.count else { return 0 }
        var v: UInt64 = 0
        for i in (0..<8).reversed() { v = v << 8 | UInt64(b[o + i]) }
        return Int(truncatingIfNeeded: v)
    }
    static func synchsafe(_ b: [UInt8], _ o: Int) -> Int {
        guard o + 4 <= b.count else { return 0 }
        return Int(b[o] & 0x7F) << 21 | Int(b[o + 1] & 0x7F) << 14 | Int(b[o + 2] & 0x7F) << 7 | Int(b[o + 3] & 0x7F)
    }
    /// Four bytes as Latin-1, so MP4's "\u{A9}nam" (0xA9 = ©) compares as written.
    static func fourCC(_ b: [UInt8], _ o: Int) -> String {
        guard o + 4 <= b.count else { return "" }
        return TagText.latin1(b[o..<(o + 4)])
    }
}

enum TagText {
    /// "3/12" → (3, 12).
    static func pair(_ s: String) -> (Int, Int) {
        let parts = s.split(separator: "/", maxSplits: 1)
        let n = Int(parts.first?.trimmingCharacters(in: .whitespaces) ?? "") ?? 0
        let total = parts.count > 1 ? Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0 : 0
        return (n, total)
    }

    static func latin1(_ b: ArraySlice<UInt8>) -> String {
        String(String.UnicodeScalarView(b.map { Unicode.Scalar($0) }))
    }

    /// Decodes an ID3 text payload in `encoding` (0 Latin-1, 1 UTF-16 with BOM, 2 UTF-16BE, 3 UTF-8).
    static func decode(_ b: ArraySlice<UInt8>, encoding: UInt8) -> String {
        switch encoding {
        case 1, 2:
            var bytes = Array(b)
            var bigEndian = encoding == 2
            if bytes.count >= 2 {
                if bytes[0] == 0xFF && bytes[1] == 0xFE { bigEndian = false; bytes.removeFirst(2) }
                else if bytes[0] == 0xFE && bytes[1] == 0xFF { bigEndian = true; bytes.removeFirst(2) }
            }
            var units: [UInt16] = []
            units.reserveCapacity(bytes.count / 2)
            var i = 0
            while i + 1 < bytes.count {
                let u = bigEndian ? UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1]) : UInt16(bytes[i + 1]) << 8 | UInt16(bytes[i])
                units.append(u)
                i += 2
            }
            return String(decoding: units, as: UTF16.self)
        case 3:
            return String(decoding: b, as: UTF8.self)
        default:
            return latin1(b)
        }
    }

    /// Index just past the string terminator starting at `start` (1 zero byte, or 2 for UTF-16).
    static func terminatorEnd(_ b: [UInt8], from start: Int, encoding: UInt8) -> (stringEnd: Int, next: Int) {
        if encoding == 1 || encoding == 2 {
            var i = start
            while i + 1 < b.count {
                if b[i] == 0 && b[i + 1] == 0 { return (i, i + 2) }
                i += 2
            }
            return (b.count, b.count)
        }
        var i = start
        while i < b.count {
            if b[i] == 0 { return (i, i + 1) }
            i += 1
        }
        return (b.count, b.count)
    }

    /// First value of a (possibly NUL-separated, ID3v2.4) text frame.
    static func firstValue(_ s: String) -> String {
        s.split(separator: "\0", omittingEmptySubsequences: true).first.map(String.init) ?? ""
    }
}

// MARK: - ID3 and MP3

enum ID3Reader {
    /// Size of the ID3v2 tag at `offset` (header and footer included), or 0 when there is none.
    static func tagSize(_ file: RandomAccessFile, at offset: Int = 0) -> Int {
        let h = file.read(at: offset, count: 10)
        guard h.count == 10, h.starts(with: Array("ID3".utf8)) else { return 0 }
        let footer = h[5] & 0x10 != 0 ? 10 : 0
        return 10 + Bytes.synchsafe(h, 6) + footer
    }

    /// Parses the ID3v2 tag at `offset` into `md`. Returns false when there is no tag there.
    @discardableResult
    static func readV2(_ file: RandomAccessFile, at offset: Int = 0, into md: inout ExtractedMetadata) -> Bool {
        let h = file.read(at: offset, count: 10)
        guard h.count == 10, h.starts(with: Array("ID3".utf8)) else { return false }
        let version = h[3]
        let flags = h[5]
        let size = Bytes.synchsafe(h, 6)
        guard version >= 2, version <= 4, size > 0 else { return false }
        var body = file.read(at: offset + 10, count: size)
        if version < 4, flags & 0x80 != 0 { body = deunsynchronize(body) }
        var pos = 0
        if flags & 0x40 != 0, version >= 3 {
            let extSize = version == 4 ? Bytes.synchsafe(body, 0) : Bytes.be32(body, 0) + 4
            pos = min(extSize, body.count)
        }
        var comments: [(desc: String, text: String)] = []
        var pictures: [(type: UInt8, data: [UInt8])] = []
        var originalYear = 0
        let idLength = version == 2 ? 3 : 4
        let headerLength = version == 2 ? 6 : 10
        while pos + headerLength <= body.count {
            let idBytes = body[pos..<(pos + idLength)]
            if idBytes.first == 0 { break }
            let id = String(decoding: idBytes, as: Unicode.ASCII.self)
            let frameSize: Int
            var formatFlags: UInt8 = 0
            switch version {
            case 2: frameSize = Bytes.be24(body, pos + 3)
            case 3: frameSize = Bytes.be32(body, pos + 4); formatFlags = body[pos + 9]
            default: frameSize = Bytes.synchsafe(body, pos + 4); formatFlags = body[pos + 9]
            }
            let start = pos + headerLength
            guard frameSize > 0, start + frameSize <= body.count else { break }
            var data = Array(body[start..<(start + frameSize)])
            pos = start + frameSize
            if version == 3, formatFlags & 0xC0 != 0 { continue } // compressed or encrypted
            if version == 4 {
                if formatFlags & 0x0C != 0 { continue }
                if formatFlags & 0x01 != 0, data.count >= 4 { data.removeFirst(4) } // data length indicator
                if formatFlags & 0x02 != 0 { data = deunsynchronize(data) }
            }
            guard !data.isEmpty else { continue }
            if id == "TDOR" || id == "TORY" {
                originalYear = Int(text(data).prefix(4)) ?? 0
                continue
            }
            apply(id: id, data: data, version: version, md: &md, comments: &comments, pictures: &pictures)
        }
        // The original release year only stands in when the recording year is missing (as AVFoundation does).
        if md.year == 0 { md.year = originalYear }
        if md.comment == nil {
            md.comment = (comments.first { $0.desc.isEmpty } ?? comments.first { !$0.desc.hasPrefix("iTun") })?.text
        }
        if md.artworkData == nil, let pic = pictures.first(where: { $0.type == 3 }) ?? pictures.first {
            md.artworkData = Data(pic.data)
        }
        return true
    }

    private static func text(_ data: [UInt8]) -> String {
        TagText.firstValue(TagText.decode(data[1...], encoding: data[0]))
    }

    private static func apply(id: String, data: [UInt8], version: UInt8, md: inout ExtractedMetadata,
                              comments: inout [(desc: String, text: String)], pictures: inout [(type: UInt8, data: [UInt8])]) {
        switch id {
        case "TIT2", "TT2": if md.title == nil { md.title = text(data) }
        case "TPE1", "TP1": if md.artist == nil { md.artist = text(data) }
        case "TALB", "TAL": if md.album == nil { md.album = text(data) }
        case "TPE2", "TP2": if md.albumArtist == nil { md.albumArtist = text(data) }
        case "TCON", "TCO": if md.genre == nil { md.genre = text(data) }
        case "TCOM", "TCM": if md.composer == nil { md.composer = text(data) }
        case "TIT1", "TT1", "GRP1": if md.grouping == nil { md.grouping = text(data) }
        case "TYER", "TYE", "TDRC":
            let s = text(data)
            if md.year == 0, let y = Int(s.prefix(4)) { md.year = y }
            if md.releaseDate == nil { md.releaseDate = DateParsing.parseISO(s) }
        case "TRCK", "TRK":
            if md.trackNumber == 0 { let p = TagText.pair(text(data)); md.trackNumber = p.0; md.trackCount = p.1 }
        case "TPOS", "TPA":
            if md.discNumber == 0 { let p = TagText.pair(text(data)); md.discNumber = p.0; md.discCount = p.1 }
        case "TBPM", "TBP": if md.bpm == 0 { md.bpm = Int(Double(text(data)) ?? 0) }
        case "TCMP", "TCP": md.compilation = (Int(text(data)) ?? 0) != 0
        case "TLEN", "TLE":
            if md.durationMs == 0, let ms = Int(text(data).trimmingCharacters(in: .whitespaces)) { md.durationMs = ms }
        case "PCST": md.isPodcast = true
        case "COMM", "COM":
            guard data.count > 4 else { return }
            let enc = data[0]
            let (descEnd, textStart) = TagText.terminatorEnd(data, from: 4, encoding: enc)
            let desc = TagText.decode(data[4..<descEnd], encoding: enc)
            let body = TagText.decode(data[min(textStart, data.count)...], encoding: enc)
            comments.append((desc, TagText.firstValue(body)))
        case "USLT", "ULT":
            guard data.count > 4 else { return }
            let enc = data[0]
            let (_, textStart) = TagText.terminatorEnd(data, from: 4, encoding: enc)
            let lyrics = TagText.decode(data[min(textStart, data.count)...], encoding: enc)
            if !lyrics.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\0", with: "").isEmpty { md.hasLyrics = true }
        case "APIC":
            guard data.count > 3 else { return }
            let enc = data[0]
            var i = 1
            while i < data.count && data[i] != 0 { i += 1 } // MIME type, always Latin-1
            i += 1
            guard i < data.count else { return }
            let type = data[i]
            let (_, imageStart) = TagText.terminatorEnd(data, from: i + 1, encoding: enc)
            if imageStart < data.count { pictures.append((type, Array(data[imageStart...]))) }
        case "PIC":
            guard data.count > 6 else { return }
            let enc = data[0]
            let type = data[4]
            let (_, imageStart) = TagText.terminatorEnd(data, from: 5, encoding: enc)
            if imageStart < data.count { pictures.append((type, Array(data[imageStart...]))) }
        default: break
        }
    }

    /// Removes the 0x00 inserted after every 0xFF by ID3 unsynchronisation.
    static func deunsynchronize(_ b: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(b.count)
        var i = 0
        while i < b.count {
            out.append(b[i])
            if b[i] == 0xFF, i + 1 < b.count, b[i + 1] == 0 { i += 2 } else { i += 1 }
        }
        return out
    }

    /// ID3v1 (last 128 bytes): only fills what the ID3v2 tag left empty.
    static func readV1(_ file: RandomAccessFile, into md: inout ExtractedMetadata) -> Bool {
        guard file.size >= 128 else { return false }
        let t = file.read(at: file.size - 128, count: 128)
        guard t.count == 128, t.starts(with: Array("TAG".utf8)) else { return false }
        func field(_ r: Range<Int>) -> String? {
            let slice = t[r]
            let end = slice.firstIndex(of: 0) ?? slice.endIndex
            let s = TagText.latin1(t[slice.startIndex..<end]).trimmingCharacters(in: .whitespaces)
            return s.isEmpty ? nil : s
        }
        if md.title == nil { md.title = field(3..<33) }
        if md.artist == nil { md.artist = field(33..<63) }
        if md.album == nil { md.album = field(63..<93) }
        if md.year == 0, let y = field(93..<97).flatMap({ Int($0) }) { md.year = y }
        if md.comment == nil { md.comment = field(97..<(t[125] == 0 ? 125 : 127)) }
        if md.trackNumber == 0, t[125] == 0, t[126] != 0 { md.trackNumber = Int(t[126]) }
        if md.genre == nil, t[127] != 255 { md.genre = ID3Genres.name(forIndex: Int(t[127])) }
        return true
    }
}

enum MP3Reader {
    private static let bitratesV1L3 = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0]
    private static let bitratesV2L3 = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0]
    private static let bitratesV1L2 = [0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 0]
    private static let bitratesV1L1 = [0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448, 0]
    private static let bitratesV2L1 = [0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256, 0]

    static func read(_ file: RandomAccessFile, into md: inout ExtractedMetadata) {
        let tag = ID3Reader.tagSize(file)
        ID3Reader.readV2(file, into: &md)
        let hasV1 = ID3Reader.readV1(file, into: &md)
        let audioEnd = file.size - (hasV1 ? 128 : 0)
        readAudio(file, from: tag, audioEnd: audioEnd, into: &md)
    }

    struct FrameHeader {
        var versionBits: Int   // 3 = MPEG1, 2 = MPEG2, 0 = MPEG2.5
        var layer: Int         // 1, 2, 3
        var bitrate: Int       // kbit/s
        var sampleRate: Int
        var channelMode: Int
        var frameLength: Int

        var samplesPerFrame: Int {
            switch layer {
            case 1: return 384
            case 2: return 1152
            default: return versionBits == 3 ? 1152 : 576
            }
        }
    }

    static func parseHeader(_ b: [UInt8], _ o: Int) -> FrameHeader? {
        guard o + 4 <= b.count, b[o] == 0xFF, b[o + 1] & 0xE0 == 0xE0 else { return nil }
        let versionBits = Int(b[o + 1] >> 3) & 3
        let layerBits = Int(b[o + 1] >> 1) & 3
        let bitrateIndex = Int(b[o + 2] >> 4)
        let rateIndex = Int(b[o + 2] >> 2) & 3
        let padding = Int(b[o + 2] >> 1) & 1
        guard versionBits != 1, layerBits != 0, bitrateIndex != 0, bitrateIndex != 15, rateIndex != 3 else { return nil }
        let layer = 4 - layerBits
        let rates = [[11025, 12000, 8000], [], [22050, 24000, 16000], [44100, 48000, 32000]]
        let sampleRate = rates[versionBits][rateIndex]
        let table: [Int]
        switch (versionBits == 3, layer) {
        case (true, 1): table = bitratesV1L1
        case (true, 2): table = bitratesV1L2
        case (true, _): table = bitratesV1L3
        case (false, 1): table = bitratesV2L1
        default: table = bitratesV2L3
        }
        let bitrate = table[bitrateIndex]
        let frameLength: Int
        if layer == 1 {
            frameLength = (12 * bitrate * 1000 / sampleRate + padding) * 4
        } else {
            let coefficient = (layer == 3 && versionBits != 3) ? 72 : 144
            frameLength = coefficient * bitrate * 1000 / sampleRate + padding
        }
        guard frameLength > 4 else { return nil }
        return FrameHeader(versionBits: versionBits, layer: layer, bitrate: bitrate, sampleRate: sampleRate,
                           channelMode: Int(b[o + 3] >> 6), frameLength: frameLength)
    }

    /// Duration and bitrate from the first frame: Xing/Info or VBRI header for VBR files, else CBR maths.
    static func readAudio(_ file: RandomAccessFile, from start: Int, audioEnd: Int, into md: inout ExtractedMetadata) {
        let window = file.read(at: start, count: 64 * 1024)
        var o = 0
        var header: FrameHeader?
        // A real frame is followed by another one: checking both skips false syncs in junk data.
        while o + 4 <= window.count {
            if let h = parseHeader(window, o) {
                if o + h.frameLength + 4 > window.count || parseHeader(window, o + h.frameLength) != nil {
                    header = h
                    break
                }
            }
            o += 1
        }
        guard let h = header else { return }
        md.sampleRate = h.sampleRate
        let audioBytes = max(audioEnd - (start + o), 0)
        let frame = Array(window[o..<min(o + h.frameLength + 200, window.count)])
        let mono = h.channelMode == 3
        let sideInfo = h.versionBits == 3 ? (mono ? 17 : 32) : (mono ? 9 : 17)
        var frames = 0
        let xing = 4 + sideInfo
        if frame.count >= xing + 12, ["Xing", "Info"].contains(Bytes.fourCC(frame, xing)) {
            let flags = Bytes.be32(frame, xing + 4)
            if flags & 1 != 0 { frames = Bytes.be32(frame, xing + 8) }
        } else if frame.count >= 36 + 18, Bytes.fourCC(frame, 36) == "VBRI" {
            frames = Bytes.be32(frame, 36 + 14)
        }
        if frames > 0 {
            let seconds = Double(frames * h.samplesPerFrame) / Double(h.sampleRate)
            md.durationMs = Int((seconds * 1000).rounded())
            if seconds > 0 { md.bitrate = Int((Double(audioBytes) * 8 / seconds / 1000).rounded()) }
            return
        }
        // No VBR header: walk the frames in the window. All at one bitrate means CBR, where the byte
        // count gives the exact duration. Otherwise (VBR without a Xing header, rare) count every frame.
        var bitrates: [Int] = []
        var f = o
        while bitrates.count < 64, let fh = parseHeader(window, f) {
            bitrates.append(fh.bitrate)
            f += fh.frameLength
        }
        if Set(bitrates).count <= 1 {
            md.bitrate = h.bitrate
            if h.bitrate > 0 { md.durationMs = Int((Double(audioBytes) * 8 / Double(h.bitrate)).rounded()) }
            return
        }
        let frameCount = countFrames(file, from: start + o, end: audioEnd)
        if frameCount > 0 {
            let seconds = Double(frameCount * h.samplesPerFrame) / Double(h.sampleRate)
            md.durationMs = Int((seconds * 1000).rounded())
            md.bitrate = Int((Double(audioBytes) * 8 / seconds / 1000).rounded())
        }
    }

    /// Counts frames by hopping from header to header, reading the file in 1 MB chunks.
    static func countFrames(_ file: RandomAccessFile, from start: Int, end: Int) -> Int {
        var count = 0
        var position = start
        var chunkStart = -1
        var chunk: [UInt8] = []
        while position + 4 <= end {
            if position < chunkStart || position + 4 > chunkStart + chunk.count {
                chunkStart = position
                chunk = file.read(at: position, count: min(1 << 20, end - position))
                if chunk.count < 4 { break }
            }
            guard let fh = parseHeader(chunk, position - chunkStart) else {
                // Lost sync (junk between frames): look for the next header byte.
                position += 1
                continue
            }
            count += 1
            position += fh.frameLength
        }
        return count
    }
}

// MARK: - MP4

enum MP4Reader {
    private struct Atom {
        var type: String
        var start: Int      // first byte of the atom
        var dataStart: Int  // first byte after the header
        var end: Int
    }

    /// Children of [from, to) read straight from the file (moov can be anywhere, and big).
    private static func atoms(_ file: RandomAccessFile, from: Int, to: Int) -> [Atom] {
        var result: [Atom] = []
        var o = from
        while o + 8 <= to {
            let h = file.read(at: o, count: 16)
            guard h.count >= 8 else { break }
            var size = Bytes.be32(h, 0)
            let type = Bytes.fourCC(h, 4)
            var header = 8
            if size == 1 { size = Bytes.be64(h, 8); header = 16 }
            else if size == 0 { size = to - o }
            // `size <= to - o`, not `o + size <= to`: a damaged 64-bit size would overflow and trap.
            guard size >= header, size <= to - o else { break }
            result.append(Atom(type: type, start: o, dataStart: o + header, end: o + size))
            o += size
        }
        return result
    }

    private static func atoms(in b: [UInt8], from: Int, to: Int) -> [(type: String, data: Range<Int>)] {
        var result: [(String, Range<Int>)] = []
        var o = from
        while o + 8 <= to {
            var size = Bytes.be32(b, o)
            let type = Bytes.fourCC(b, o + 4)
            var header = 8
            if size == 1 { size = Bytes.be64(b, o + 8); header = 16 } else if size == 0 { size = to - o }
            // `size <= to - o`, not `o + size <= to`: a damaged 64-bit size would overflow and trap.
            guard size >= header, size <= to - o else { break }
            result.append((type, (o + header)..<(o + size)))
            o += size
        }
        return result
    }

    static func read(_ file: RandomAccessFile, into md: inout ExtractedMetadata) {
        let top = atoms(file, from: 0, to: file.size)
        guard let moov = top.first(where: { $0.type == "moov" }) else { return }
        // moov holds sample tables and the cover: a few MB at most, read in one go.
        let b = file.read(at: moov.dataStart, count: moov.end - moov.dataStart)
        let children = atoms(in: b, from: 0, to: b.count)
        let mdatBytes = top.filter { $0.type == "mdat" }.reduce(0) { $0 + ($1.end - $1.dataStart) }

        if let mvhd = children.first(where: { $0.type == "mvhd" }) {
            let o = mvhd.data.lowerBound
            let version = o < b.count ? b[o] : 0
            let timescale = version == 1 ? Bytes.be32(b, o + 20) : Bytes.be32(b, o + 12)
            let duration = version == 1 ? Bytes.be64(b, o + 24) : Bytes.be32(b, o + 16)
            if timescale > 0 { md.durationMs = Int((Double(duration) / Double(timescale) * 1000).rounded()) }
        }
        for trak in children where trak.type == "trak" {
            guard let mdia = atoms(in: b, from: trak.data.lowerBound, to: trak.data.upperBound).first(where: { $0.type == "mdia" }) else { continue }
            let mdiaChildren = atoms(in: b, from: mdia.data.lowerBound, to: mdia.data.upperBound)
            guard let hdlr = mdiaChildren.first(where: { $0.type == "hdlr" }), Bytes.fourCC(b, hdlr.data.lowerBound + 8) == "soun",
                  let minf = mdiaChildren.first(where: { $0.type == "minf" }),
                  let stbl = atoms(in: b, from: minf.data.lowerBound, to: minf.data.upperBound).first(where: { $0.type == "stbl" }),
                  let stsd = atoms(in: b, from: stbl.data.lowerBound, to: stbl.data.upperBound).first(where: { $0.type == "stsd" }) else { continue }
            let entry = stsd.data.lowerBound + 8
            let format = Bytes.fourCC(b, entry + 4)
            let rate = Bytes.be32(b, entry + 32) >> 16
            if rate > 0 { md.sampleRate = rate }
            if format == "alac" || format == "fLaC" || format == "lpcm" { md.isLossless = true }
            break
        }
        if md.durationMs > 0, mdatBytes > 0 {
            md.bitrate = Int((Double(mdatBytes) * 8 / Double(md.durationMs)).rounded())
        }
        guard let udta = children.first(where: { $0.type == "udta" }),
              let meta = atoms(in: b, from: udta.data.lowerBound, to: udta.data.upperBound).first(where: { $0.type == "meta" }) else { return }
        // meta is a full box: 4 bytes of version and flags before its children.
        guard let ilst = atoms(in: b, from: meta.data.lowerBound + 4, to: meta.data.upperBound).first(where: { $0.type == "ilst" }) else { return }
        for item in atoms(in: b, from: ilst.data.lowerBound, to: ilst.data.upperBound) {
            let parts = atoms(in: b, from: item.data.lowerBound, to: item.data.upperBound)
            guard let data = parts.first(where: { $0.type == "data" }), data.data.count >= 8 else { continue }
            let kind = Bytes.be32(b, data.data.lowerBound) & 0xFFFFFF
            let payload = Array(b[(data.data.lowerBound + 8)..<data.data.upperBound])
            let string = String(decoding: payload, as: UTF8.self)
            func int() -> Int {
                var v = 0
                for byte in payload.prefix(8) { v = v << 8 | Int(byte) }
                return v
            }
            switch item.type {
            case "\u{A9}nam": if md.title == nil { md.title = string }
            case "\u{A9}ART": if md.artist == nil { md.artist = string }
            case "\u{A9}alb": if md.album == nil { md.album = string }
            case "aART": if md.albumArtist == nil { md.albumArtist = string }
            case "\u{A9}gen": if md.genre == nil { md.genre = string }
            case "gnre": if md.genre == nil, payload.count >= 2 { md.genre = ID3Genres.name(forIndex: Bytes.be16(payload, 0) - 1) }
            case "\u{A9}wrt": if md.composer == nil { md.composer = string }
            case "\u{A9}cmt": if md.comment == nil { md.comment = string }
            case "\u{A9}grp", "grup": if md.grouping == nil { md.grouping = string }
            case "\u{A9}day":
                if md.year == 0, let y = Int(string.prefix(4)) { md.year = y }
                if md.releaseDate == nil { md.releaseDate = DateParsing.parseISO(string) }
            case "trkn": if payload.count >= 6 { md.trackNumber = Bytes.be16(payload, 2); md.trackCount = Bytes.be16(payload, 4) }
            case "disk": if payload.count >= 6 { md.discNumber = Bytes.be16(payload, 2); md.discCount = Bytes.be16(payload, 4) }
            case "tmpo": md.bpm = int()
            case "cpil": md.compilation = int() != 0
            case "pcst": md.isPodcast = int() != 0
            case "\u{A9}lyr": if !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { md.hasLyrics = true }
            case "covr": if md.artworkData == nil, !payload.isEmpty, kind == 13 || kind == 14 || kind == 0 || kind == 27 { md.artworkData = Data(payload) }
            default: break
            }
        }
    }
}

// MARK: - FLAC

enum FLACReader {
    static func read(_ file: RandomAccessFile, into md: inout ExtractedMetadata) {
        md.isLossless = true
        var o = ID3Reader.tagSize(file)
        if o > 0 { ID3Reader.readV2(file, into: &md) }
        guard file.read(at: o, count: 4) == Array("fLaC".utf8) else { return }
        o += 4
        var last = false
        while !last {
            let h = file.read(at: o, count: 4)
            guard h.count == 4 else { break }
            last = h[0] & 0x80 != 0
            let type = h[0] & 0x7F
            let length = Bytes.be24(h, 1)
            let start = o + 4
            o = start + length
            switch type {
            case 0:
                let b = file.read(at: start, count: length)
                guard b.count >= 18 else { continue }
                let rate = Int(b[10]) << 12 | Int(b[11]) << 4 | Int(b[12]) >> 4
                let samples = Int(b[13] & 0x0F) << 32 | Bytes.be32(b, 14)
                if rate > 0 {
                    md.sampleRate = rate
                    md.durationMs = Int((Double(samples) / Double(rate) * 1000).rounded())
                }
            case 4:
                VorbisComments.parse(file.read(at: start, count: length), into: &md)
            case 6:
                if md.artworkData == nil, let d = pictureData(fromBlock: file.read(at: start, count: length)) { md.artworkData = d }
            default: break
            }
        }
    }

    /// The image inside a FLAC PICTURE block (also how Ogg files carry covers, base64-encoded).
    static func pictureData(fromBlock b: [UInt8]) -> Data? {
        var o = 4
        let mimeLength = Bytes.be32(b, o); o += 4 + mimeLength
        let descLength = Bytes.be32(b, o); o += 4 + descLength
        o += 16
        let length = Bytes.be32(b, o); o += 4
        guard length > 0, o + length <= b.count else { return nil }
        return Data(b[o..<(o + length)])
    }
}

enum VorbisComments {
    /// A Vorbis comment block: vendor string, then "KEY=value" strings, all little-endian lengths.
    static func parse(_ b: [UInt8], into md: inout ExtractedMetadata) {
        var o = 0
        let vendor = Bytes.le32(b, o); o += 4 + vendor
        let count = Bytes.le32(b, o); o += 4
        for _ in 0..<min(count, 10_000) {
            let length = Bytes.le32(b, o); o += 4
            guard length > 0, o + length <= b.count else { break }
            let entry = String(decoding: b[o..<(o + length)], as: UTF8.self)
            o += length
            guard let eq = entry.firstIndex(of: "=") else { continue }
            md.applyVorbis(key: String(entry[..<eq]), value: String(entry[entry.index(after: eq)...]))
        }
    }
}

// MARK: - Ogg

enum OggReader {
    static func read(_ file: RandomAccessFile, into md: inout ExtractedMetadata) {
        // Assemble the first packets (identification, comments); covers can span many pages.
        var packets: [[UInt8]] = []
        var current: [UInt8] = []
        var o = 0
        let limit = min(file.size, 16 * 1024 * 1024)
        pages: while o + 27 <= limit && packets.count < 2 {
            let h = file.read(at: o, count: 27 + 255)
            guard h.count >= 27, h.starts(with: Array("OggS".utf8)) else { break }
            let segments = Int(h[26])
            let table = Array(h[27..<min(27 + segments, h.count)])
            let dataStart = o + 27 + segments
            let pageLength = table.reduce(0) { $0 + Int($1) }
            let page = file.read(at: dataStart, count: pageLength)
            var p = 0
            for length in table {
                let end = min(p + Int(length), page.count)
                current += page[p..<end]
                p = end
                if length < 255 {
                    packets.append(current)
                    current = []
                    if packets.count == 2 { break pages }
                }
            }
            o = dataStart + pageLength
        }
        guard let ident = packets.first else { return }
        var rate = 0
        var preSkip = 0
        let isOpus = ident.starts(with: Array("OpusHead".utf8))
        if isOpus {
            preSkip = Bytes.le16(ident, 10)
            rate = 48000
            md.sampleRate = Bytes.le32(ident, 12) > 0 ? Bytes.le32(ident, 12) : 48000
        } else if ident.count >= 16, ident[0] == 1, Array(ident[1..<7]) == Array("vorbis".utf8) {
            rate = Bytes.le32(ident, 12)
            md.sampleRate = rate
            // Signed in the Vorbis header: 0 or -1 means "not set".
            let nominal = Int(Int32(truncatingIfNeeded: Bytes.le32(ident, 20)))
            if nominal > 0 { md.bitrate = nominal / 1000 }
        }
        if packets.count > 1 {
            let c = packets[1]
            if isOpus, c.starts(with: Array("OpusTags".utf8)) {
                VorbisComments.parse(Array(c[8...]), into: &md)
            } else if c.count > 7, c[0] == 3, Array(c[1..<7]) == Array("vorbis".utf8) {
                VorbisComments.parse(Array(c[7...]), into: &md)
            }
        }
        // Duration: granule position of the last page.
        guard rate > 0 else { return }
        let tailStart = max(file.size - 64 * 1024, 0)
        let tail = file.read(at: tailStart, count: file.size - tailStart)
        var i = tail.count - 27
        while i >= 0 {
            if tail[i] == 0x4F, tail[i + 1] == 0x67, tail[i + 2] == 0x67, tail[i + 3] == 0x53 {
                let granule = Bytes.le64(tail, i + 6)
                if granule > 0 {
                    md.durationMs = Int((Double(max(granule - preSkip, 0)) / Double(rate) * 1000).rounded())
                    break
                }
            }
            i -= 1
        }
    }
}

// MARK: - WAV and AIFF

enum WAVReader {
    static func read(_ file: RandomAccessFile, into md: inout ExtractedMetadata) {
        md.isLossless = true
        var o = 12
        var byteRate = 0
        while o + 8 <= file.size {
            let h = file.read(at: o, count: 8)
            let id = Bytes.fourCC(h, 0)
            let size = Bytes.le32(h, 4)
            let start = o + 8
            switch id {
            case "fmt ":
                let b = file.read(at: start, count: min(size, 40))
                md.sampleRate = Bytes.le32(b, 4)
                byteRate = Bytes.le32(b, 8)
                if Bytes.le16(b, 0) != 1 && Bytes.le16(b, 0) != 0xFFFE && Bytes.le16(b, 0) != 3 { md.isLossless = false }
            case "data":
                if byteRate > 0 { md.durationMs = Int((Double(size) / Double(byteRate) * 1000).rounded()) }
            case "LIST":
                let b = file.read(at: start, count: min(size, 64 * 1024))
                if Bytes.fourCC(b, 0) == "INFO" { readInfo(b, into: &md) }
            case "id3 ", "ID3 ":
                ID3Reader.readV2(file, at: start, into: &md)
            default: break
            }
            o = start + size + (size & 1)
        }
        if byteRate > 0 { md.bitrate = byteRate * 8 / 1000 }
    }

    private static func readInfo(_ b: [UInt8], into md: inout ExtractedMetadata) {
        var o = 4
        while o + 8 <= b.count {
            let id = Bytes.fourCC(b, o)
            let size = Bytes.le32(b, o + 4)
            let start = o + 8
            guard start + size <= b.count else { break }
            let raw = b[start..<(start + size)]
            let value = String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            switch id {
            case "INAM": if md.title == nil { md.title = value }
            case "IART": if md.artist == nil { md.artist = value }
            case "IPRD": if md.album == nil { md.album = value }
            case "IGNR": if md.genre == nil { md.genre = value }
            case "ICMT": if md.comment == nil { md.comment = value }
            case "ICRD": if md.year == 0, let y = Int(value.prefix(4)) { md.year = y }
            case "ITRK", "IPRT": if md.trackNumber == 0 { md.trackNumber = TagText.pair(value).0 }
            default: break
            }
            o = start + size + (size & 1)
        }
    }
}

enum AIFFReader {
    static func read(_ file: RandomAccessFile, into md: inout ExtractedMetadata) {
        md.isLossless = true
        var o = 12
        while o + 8 <= file.size {
            let h = file.read(at: o, count: 8)
            let id = Bytes.fourCC(h, 0)
            let size = Bytes.be32(h, 4)
            let start = o + 8
            switch id {
            case "COMM":
                let b = file.read(at: start, count: min(size, 32))
                guard b.count >= 18 else { break }
                let channels = Bytes.be16(b, 0)
                let frames = Bytes.be32(b, 2)
                let bits = Bytes.be16(b, 6)
                let rate = extended80(Array(b[8..<18]))
                if rate > 0 {
                    md.sampleRate = Int(rate)
                    md.durationMs = Int((Double(frames) / rate * 1000).rounded())
                    md.bitrate = Int(rate) * channels * bits / 1000
                }
            case "ID3 ", "id3 ":
                ID3Reader.readV2(file, at: start, into: &md)
            default: break
            }
            o = start + size + (size & 1)
        }
    }

    /// The 80-bit IEEE extended float AIFF uses for its sample rate.
    static func extended80(_ b: [UInt8]) -> Double {
        guard b.count >= 10 else { return 0 }
        let exponent = Int(b[0] & 0x7F) << 8 | Int(b[1])
        var mantissa: UInt64 = 0
        for i in 2..<10 { mantissa = mantissa << 8 | UInt64(b[i]) }
        if exponent == 0 && mantissa == 0 { return 0 }
        let value = Double(mantissa) * pow(2.0, Double(exponent - 16383 - 63))
        return b[0] & 0x80 != 0 ? -value : value
    }
}
