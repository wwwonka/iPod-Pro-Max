//
//  AudiobookMuxer.swift
//  iPod Pro Max
//
//  Merges a multi-file audiobook's chapters into one .m4b with real QuickTime chapter markers, via
//  ffmpeg (see FFmpeg.binaryPath for where it is looked for). Authoring chapter tracks by hand with
//  AVFoundation means hand-crafting raw tx3g sample buffers — ffmpeg already does this correctly and
//  is well-tested, so this file stays a thin wrapper instead of reinventing that.
//

import Foundation
import iPodKit

public enum AudiobookMuxer {
    /// Concatenates `chapters` (in order) into `destination` as one .m4b, with a chapter marker at
    /// each original file's start carrying its title. Falls back to re-encoding if the chapters don't
    /// share identical audio parameters (stream-copy concat requires that).
    public static func merge(chapters: [AudiobookChapter], to destination: URL) async throws {
        let ffmpeg = try FFmpeg.requireBinary(for: "Merging audiobook chapters")
        guard !chapters.isEmpty else { throw IPodDBError.io("No chapters to merge.") }

        let workDir = destination.deletingLastPathComponent().appendingPathComponent(".merge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        var durationsMs: [Int] = []
        for chapter in chapters {
            var ms = chapter.durationMs
            if ms <= 0 { ms = (try? await MetadataExtractor.extract(from: chapter.url))?.durationMs ?? 0 }
            durationsMs.append(max(ms, 0))
        }

        let listURL = workDir.appendingPathComponent("concat.txt")
        let listText = chapters.map { "file '\(FFmpeg.concatPath($0.url).replacingOccurrences(of: "'", with: "'\\''"))'" }.joined(separator: "\n")
        try listText.write(to: listURL, atomically: true, encoding: .utf8)

        var meta = ";FFMETADATA1\n"
        var cursor = 0
        for (i, chapter) in chapters.enumerated() {
            let end = cursor + durationsMs[i]
            meta += "[CHAPTER]\nTIMEBASE=1/1000\nSTART=\(cursor)\nEND=\(end)\ntitle=\(sanitize(chapter.title))\n\n"
            cursor = end
        }
        let metaURL = workDir.appendingPathComponent("chapters.ffmetadata")
        try meta.write(to: metaURL, atomically: true, encoding: .utf8)

        let concatenated = workDir.appendingPathComponent("concatenated.m4a")
        do {
            try await FFmpeg.run(ffmpeg, ["-y", "-v", "error", "-f", "concat", "-safe", "0", "-i", FileOps.nativePath(listURL), "-c", "copy", FileOps.nativePath(concatenated)])
        } catch {
            // Chapters don't share identical audio parameters; re-encode instead of stream-copying.
            try await FFmpeg.run(ffmpeg, ["-y", "-v", "error", "-f", "concat", "-safe", "0", "-i", FileOps.nativePath(listURL), "-c:a", "aac", "-b:a", "160k", FileOps.nativePath(concatenated)])
        }

        if FileManager.default.fileExists(atPath: destination.path) { try? FileManager.default.removeItem(at: destination) }
        try await FFmpeg.run(ffmpeg, ["-y", "-v", "error", "-i", FileOps.nativePath(concatenated), "-i", FileOps.nativePath(metaURL), "-map_metadata", "1", "-codec", "copy", FileOps.nativePath(destination)])
    }

    /// Escapes '=' and newlines, the two characters ffmetadata treats specially in a value.
    private static func sanitize(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "=", with: "\\=").replacingOccurrences(of: "\n", with: " ")
    }
}
