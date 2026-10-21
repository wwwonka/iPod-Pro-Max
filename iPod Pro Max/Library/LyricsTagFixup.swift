//
//  LyricsTagFixup.swift
//  iPod Pro Max
//
//  The classic click-wheel Lyrics screen only reads the ID3v2.3 USLT frame — it silently ignores
//  lyrics written in ID3v2.4 (which most modern taggers write by default) and never supports the
//  synchronized SYLT frame at all. For an MP3 tagged as ID3v2.4, this rewrites the tag as ID3v2.3,
//  copying every frame's raw payload byte-for-byte (audio data untouched).
//
//  This is done by hand rather than via a re-tagging tool: ffmpeg's ID3 writer funnels frames through
//  its own generic tag table, and since USLT isn't in it, re-muxing through ffmpeg silently turns USLT
//  into a plain TXXX frame — passing the text through but losing the one thing that makes it lyrics.
//  ID3v2.3 and 2.4 frames differ only in how the frame size is encoded (synchsafe in 2.4, plain
//  big-endian in 2.3), so a byte-preserving downgrade is a small, well-defined parse.
//

import Foundation

enum LyricsTagFixup {
    /// Returns the ID3v2 major version (3, 4, …) from the file's header, or nil if it has no ID3v2 tag.
    static func id3Version(of url: URL) -> Int? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 10), header.count == 10,
              header[0] == 0x49, header[1] == 0x44, header[2] == 0x33 else { return nil } // "ID3"
        return Int(header[3])
    }

    /// If `url` is an MP3 tagged as ID3v2.4 or later, writes a copy at `destination` retagged as
    /// ID3v2.3 with every frame preserved exactly. Returns `destination` when a fixup happened, nil
    /// when the file didn't need one or has a tag shape this doesn't handle (left untouched, not
    /// guessed at — callers should just keep using the original file in that case).
    static func ensureID3v23(for url: URL, destination: URL) throws -> URL? {
        guard url.pathExtension.lowercased() == "mp3",
              let data = try? Data(contentsOf: url), data.count > 10,
              data[0] == 0x49, data[1] == 0x44, data[2] == 0x33, data[3] >= 4 else { return nil }

        let headerFlags = data[5]
        guard headerFlags & 0x80 == 0 else { return nil } // unsynchronized header: not handled, leave as-is
        let tagSize = synchsafeInt(data, 6)
        var offset = 10
        if headerFlags & 0x40 != 0 { // extended header present
            guard offset + 4 <= data.count else { return nil }
            offset += synchsafeInt(data, offset)
        }
        let tagEnd = 10 + tagSize
        guard tagEnd <= data.count else { return nil }

        var frames: [(id: String, payload: Data)] = []
        while offset + 10 <= tagEnd {
            guard let id = String(data: data[offset..<offset + 4], encoding: .ascii),
                  id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { break }
            let frameSize = synchsafeInt(data, offset + 4)
            let payloadStart = offset + 10
            let payloadEnd = payloadStart + frameSize
            guard frameSize > 0, payloadEnd <= tagEnd else { break }
            // Frames with compression, encryption, grouping or a data-length-indicator need extra
            // unwrapping we don't do; skip just that frame rather than risk emitting a corrupt one.
            if data[offset + 9] & 0x0F == 0 {
                frames.append((id, Data(data[payloadStart..<payloadEnd])))
            }
            offset = payloadEnd
        }
        guard frames.contains(where: { $0.id == "USLT" }) else { return nil } // nothing to fix

        var body = Data()
        for f in frames {
            body.append(f.id.data(using: .ascii)!)
            body.append(contentsOf: bigEndian32(f.payload.count))
            body.append(contentsOf: [0, 0])
            body.append(f.payload)
        }
        var header = Data([0x49, 0x44, 0x33, 3, 0, 0])
        header.append(contentsOf: synchsafeBytes(body.count))

        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (header + body + data[tagEnd...]).write(to: destination, options: .atomic)
        return destination
    }

    private static func synchsafeInt(_ data: Data, _ offset: Int) -> Int {
        let b = data[offset..<offset + 4]
        let a = Array(b)
        return (Int(a[0] & 0x7F) << 21) | (Int(a[1] & 0x7F) << 14) | (Int(a[2] & 0x7F) << 7) | Int(a[3] & 0x7F)
    }

    private static func synchsafeBytes(_ n: Int) -> [UInt8] {
        [UInt8((n >> 21) & 0x7F), UInt8((n >> 14) & 0x7F), UInt8((n >> 7) & 0x7F), UInt8(n & 0x7F)]
    }

    private static func bigEndian32(_ n: Int) -> [UInt8] {
        [UInt8((n >> 24) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)]
    }
}
