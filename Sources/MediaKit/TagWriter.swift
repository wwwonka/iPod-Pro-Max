//
//  TagWriter.swift
//  iPod Pro Max
//
//  Writes audio metadata tags, lyrics, and cover artwork back to local audio files:
//  - Pure Swift ID3v2.4 writer for `.mp3` (instant, zero-copy audio, preserves existing APIC if no new artwork)
//  - FFmpeg remuxer (`-c copy`) for `.m4a`, `.m4b`, `.mp4`, and other formats supported by the bundled FFmpeg.
//

import Foundation
import iPodKit

public enum TagWriter {
    public static func writeTags(for track: LibraryTrack, customArtworkData: Data? = nil) async throws {
        let url = URL(fileURLWithPath: track.path)
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            throw IPodDBError.io("File not found: \(url.lastPathComponent)")
        }
        guard fm.isWritableFile(atPath: url.path) else {
            throw IPodDBError.io("File is read-only: \(url.lastPathComponent)")
        }

        let ext = url.pathExtension.lowercased()
        if ext == "mp3" {
            try writeID3v2MP3(url: url, track: track, customArtworkData: customArtworkData)
            return
        }

        try await writeWithFFmpeg(url: url, ext: ext, track: track, customArtworkData: customArtworkData)
    }

    // MARK: - FFmpeg Backend (.m4a, .m4b, .mp4, etc.)

    private static func writeWithFFmpeg(url: URL, ext: String, track: LibraryTrack, customArtworkData: Data?) async throws {
        let fm = FileManager.default
        let ffmpeg = try FFmpeg.requireBinary(for: "Writing audio tags")
        let workDir = url.deletingLastPathComponent()
        let token = UUID().uuidString
        let tempOutput = workDir.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent).ippm-\(token).\(ext)")
        var tempArtwork: URL?

        defer {
            if fm.fileExists(atPath: tempOutput.path) { try? fm.removeItem(at: tempOutput) }
            if let tempArtwork, fm.fileExists(atPath: tempArtwork.path) { try? fm.removeItem(at: tempArtwork) }
        }

        var args: [String] = ["-y", "-v", "error", "-i", FileOps.nativePath(url)]

        let supportsAttachedPicture = ["m4a", "m4b", "mp4", "flac"].contains(ext)
        if let artworkData = customArtworkData, !artworkData.isEmpty, supportsAttachedPicture {
            let isPNG = artworkData.starts(with: [0x89, 0x50, 0x4E, 0x47])
            let isJPEG = artworkData.starts(with: [0xFF, 0xD8, 0xFF])
            let artExt = isPNG ? "png" : "jpg"
            let artURL = TemporaryMediaCache.shared.scratchURL(extension: artExt)
            try artworkData.write(to: artURL, options: .atomic)
            tempArtwork = artURL

            args += ["-i", FileOps.nativePath(artURL)]
            args += ["-map", "0:a", "-map", "1:v:0", "-c:a", "copy"]
            args += (isPNG || isJPEG) ? ["-c:v", "copy"] : ["-c:v", "mjpeg"]
            args += ["-disposition:v:0", "attached_pic"]
        } else {
            args += ["-map", "0", "-c", "copy"]
        }

        args += ["-map_metadata", "0"]
        if ext == "m4a" || ext == "m4b" {
            args += ["-f", ext == "m4b" ? "ipod" : "mp4"]
        }

        for (key, value) in metadataPairs(for: track, fileExtension: ext) {
            args += ["-metadata", "\(key)=\(value)"]
        }

        args.append(FileOps.nativePath(tempOutput))
        try await FFmpeg.run(ffmpeg, args)

        let attrs = try? fm.attributesOfItem(atPath: tempOutput.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else {
            throw IPodDBError.io("FFmpeg produced an empty file for \(url.lastPathComponent)")
        }

        try replaceFile(at: url, with: tempOutput)
    }

    // MARK: - Pure Swift ID3v2.4 Writer (.mp3)

    private static func writeID3v2MP3(url: URL, track: LibraryTrack, customArtworkData: Data?) throws {
        let originalData = try Data(contentsOf: url)
        let (audioOffset, existingAPICs) = parseExistingID3v2Header(in: originalData)
        let audioBody = originalData.subdata(in: audioOffset..<originalData.count)

        var frames = Data()
        func appendText(_ id: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            var payload = Data([0x03]) // UTF-8
            payload.append(Data(value.utf8))
            frames.append(makeID3v24Frame(id: id, payload: payload))
        }

        appendText("TIT2", track.title)
        appendText("TPE1", track.artist)
        appendText("TALB", track.album)
        appendText("TPE2", track.albumArtist)
        appendText("TCOM", track.composer)
        appendText("TIT1", track.grouping)
        appendText("TCON", track.genre)
        if track.year > 0 { appendText("TDRC", "\(track.year)") }
        let trackStr = formatFraction(track.trackNumber, total: track.trackCount)
        if !trackStr.isEmpty { appendText("TRCK", trackStr) }
        let discStr = formatFraction(track.discNumber, total: track.discCount)
        if !discStr.isEmpty { appendText("TPOS", discStr) }
        if track.bpm > 0 { appendText("TBPM", "\(track.bpm)") }
        if track.compilation { appendText("TCMP", "1") }
        appendText("TSOT", track.sortTitle)
        appendText("TSOA", track.sortAlbum)
        appendText("TSOP", track.sortArtist)
        appendText("TSO2", track.sortAlbumArtist)
        appendText("TSOC", track.sortComposer)

        if let comment = track.comment, !comment.isEmpty {
            var payload = Data([0x03])
            payload.append(Data("eng".utf8))
            payload.append(0x00) // empty description
            payload.append(Data(comment.utf8))
            frames.append(makeID3v24Frame(id: "COMM", payload: payload))
        }

        if track.customLyrics == true, let lyrics = track.lyrics, !lyrics.isEmpty {
            var payload = Data([0x03])
            payload.append(Data("eng".utf8))
            payload.append(0x00) // empty descriptor
            payload.append(Data(lyrics.utf8))
            frames.append(makeID3v24Frame(id: "USLT", payload: payload))
        }

        if let artworkData = customArtworkData, !artworkData.isEmpty {
            let mime = artworkData.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "image/png" : "image/jpeg"
            var payload = Data([0x00]) // Latin-1 mime
            payload.append(Data(mime.utf8))
            payload.append(0x00)
            payload.append(0x03) // Front cover
            payload.append(0x00) // empty description
            payload.append(artworkData)
            frames.append(makeID3v24Frame(id: "APIC", payload: payload))
        } else {
            for apicPayload in existingAPICs {
                frames.append(makeID3v24Frame(id: "APIC", payload: apicPayload))
            }
        }

        var header = Data([0x49, 0x44, 0x33, 0x04, 0x00, 0x00]) // "ID3" v2.4.0 flags=0
        header.append(encodeSynchsafe32(UInt32(frames.count)))

        var combined = Data(capacity: header.count + frames.count + audioBody.count)
        combined.append(header)
        combined.append(frames)
        combined.append(audioBody)

        let token = UUID().uuidString
        let tempOutput = url.deletingLastPathComponent().appendingPathComponent("\(url.deletingPathExtension().lastPathComponent).ippm-\(token).mp3")
        try combined.write(to: tempOutput, options: .atomic)
        try replaceFile(at: url, with: tempOutput)
    }

    private static func parseExistingID3v2Header(in data: Data) -> (audioOffset: Int, apicPayloads: [Data]) {
        guard data.count >= 10, data[0] == 0x49, data[1] == 0x44, data[2] == 0x33 else {
            return (0, [])
        }
        let majorVersion = data[3]
        let flags = data[5]
        let tagSize = decodeSynchsafe32(data, offset: 6)
        let hasFooter = (flags & 0x10) != 0
        let totalEnd = min(data.count, 10 + tagSize + (hasFooter ? 10 : 0))

        var apics: [Data] = []
        var cursor = 10
        // Skip extended header if present (bit 6)
        if (flags & 0x40) != 0, cursor + 4 <= totalEnd {
            let extSize = majorVersion >= 4 ? decodeSynchsafe32(data, offset: cursor) : readUInt32BE(data, offset: cursor)
            cursor += max(4, extSize)
        }

        while cursor + 10 <= totalEnd {
            if data[cursor] == 0 { break } // padding
            guard let frameID = String(bytes: data[cursor..<(cursor + 4)], encoding: .ascii) else { break }
            let frameSize = majorVersion >= 4 ? decodeSynchsafe32(data, offset: cursor + 4) : readUInt32BE(data, offset: cursor + 4)
            let bodyStart = cursor + 10
            let bodyEnd = bodyStart + frameSize
            guard frameSize > 0, bodyEnd <= totalEnd else { break }
            if frameID == "APIC" {
                apics.append(data.subdata(in: bodyStart..<bodyEnd))
            }
            cursor = bodyEnd
        }
        return (totalEnd, apics)
    }

    private static func makeID3v24Frame(id: String, payload: Data) -> Data {
        var frame = Data(capacity: 10 + payload.count)
        frame.append(contentsOf: id.utf8.prefix(4))
        frame.append(encodeSynchsafe32(UInt32(payload.count)))
        frame.append(contentsOf: [0x00, 0x00]) // flags
        frame.append(payload)
        return frame
    }

    private static func encodeSynchsafe32(_ value: UInt32) -> Data {
        Data([
            UInt8((value >> 21) & 0x7F),
            UInt8((value >> 14) & 0x7F),
            UInt8((value >> 7) & 0x7F),
            UInt8(value & 0x7F),
        ])
    }

    private static func decodeSynchsafe32(_ data: Data, offset: Int) -> Int {
        guard offset + 4 <= data.count else { return 0 }
        return (Int(data[offset] & 0x7F) << 21)
            | (Int(data[offset + 1] & 0x7F) << 14)
            | (Int(data[offset + 2] & 0x7F) << 7)
            | Int(data[offset + 3] & 0x7F)
    }

    private static func readUInt32BE(_ data: Data, offset: Int) -> Int {
        guard offset + 4 <= data.count else { return 0 }
        return (Int(data[offset]) << 24)
            | (Int(data[offset + 1]) << 16)
            | (Int(data[offset + 2]) << 8)
            | Int(data[offset + 3])
    }

    // MARK: - Helpers

    private static func replaceFile(at destination: URL, with tempOutput: URL) throws {
        let fm = FileManager.default
        #if os(Windows)
        let backupURL = destination.deletingLastPathComponent().appendingPathComponent(".ippm-backup-\(UUID().uuidString).\(destination.pathExtension)")
        try fm.moveItem(at: destination, to: backupURL)
        do {
            try fm.moveItem(at: tempOutput, to: destination)
            try? fm.removeItem(at: backupURL)
        } catch {
            try? fm.moveItem(at: backupURL, to: destination)
            throw error
        }
        #else
        if Foundation.rename(tempOutput.path, destination.path) != 0 {
            throw IPodDBError.io("Couldn't replace \(destination.lastPathComponent): \(String(cString: strerror(errno)))")
        }
        #endif
    }

    static func metadataPairs(for track: LibraryTrack, fileExtension ext: String) -> [(String, String)] {
        var pairs: [(String, String)] = [
            ("title", track.title),
            ("artist", track.artist ?? ""),
            ("album", track.album ?? ""),
            ("album_artist", track.albumArtist ?? ""),
            ("composer", track.composer ?? ""),
            ("grouping", track.grouping ?? ""),
            ("genre", track.genre ?? ""),
            ("date", track.year > 0 ? "\(track.year)" : ""),
            ("track", formatFraction(track.trackNumber, total: track.trackCount)),
            ("disc", formatFraction(track.discNumber, total: track.discCount)),
            ("comment", track.comment ?? ""),
            ("compilation", track.compilation ? "1" : "0"),
        ]

        let bpmValue = track.bpm > 0 ? "\(track.bpm)" : ""
        pairs.append((ext == "mp3" ? "TBPM" : "bpm", bpmValue))

        if track.customLyrics == true {
            let lyrics = track.lyrics ?? ""
            pairs.append((ext == "mp3" ? "lyrics-eng" : "lyrics", lyrics))
        }

        if let sortTitle = track.sortTitle { pairs.append(("title-sort", sortTitle)) }
        if let sortAlbum = track.sortAlbum { pairs.append(("album-sort", sortAlbum)) }
        if let sortArtist = track.sortArtist { pairs.append(("artist-sort", sortArtist)) }
        if let sortAlbumArtist = track.sortAlbumArtist { pairs.append(("album_artist-sort", sortAlbumArtist)) }
        if let sortComposer = track.sortComposer { pairs.append(("composer-sort", sortComposer)) }

        return pairs
    }

    private static func formatFraction(_ number: Int, total: Int) -> String {
        guard number > 0 else { return "" }
        return total > 0 ? "\(number)/\(total)" : "\(number)"
    }
}
