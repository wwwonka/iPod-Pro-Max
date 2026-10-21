//
//  AudiobookMuxer.swift
//  iPod Pro Max
//
//  Merges a multi-file audiobook's chapters into one .m4b with real QuickTime chapter markers, via
//  ffmpeg (expected to already be installed, e.g. via Homebrew). Authoring chapter tracks by hand with
//  AVFoundation means hand-crafting raw tx3g sample buffers — ffmpeg already does this correctly and
//  is well-tested, so this file stays a thin wrapper instead of reinventing that.
//

import AVFoundation
import Foundation

enum AudiobookMuxer {
    /// Concatenates `chapters` (in order) into `destination` as one .m4b, with a chapter marker at
    /// each original file's start carrying its title. Falls back to re-encoding if the chapters don't
    /// share identical audio parameters (stream-copy concat requires that).
    static func merge(chapters: [(title: String, url: URL)], to destination: URL) async throws {
        guard let ffmpeg = FFmpeg.binaryPath() else {
            throw IPodDBError.unsupported("Merging audiobook chapters needs ffmpeg. Install it with “brew install ffmpeg”, then try again.")
        }
        guard !chapters.isEmpty else { throw IPodDBError.io("No chapters to merge.") }

        let workDir = destination.deletingLastPathComponent().appendingPathComponent(".merge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        var durationsMs: [Int] = []
        for (_, url) in chapters {
            let duration = try await AVURLAsset(url: url).load(.duration)
            durationsMs.append(max(Int((CMTimeGetSeconds(duration) * 1000).rounded()), 0))
        }

        let listURL = workDir.appendingPathComponent("concat.txt")
        let listText = chapters.map { "file '\($0.url.path.replacingOccurrences(of: "'", with: "'\\''"))'" }.joined(separator: "\n")
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
            try await FFmpeg.run(ffmpeg, ["-y", "-v", "error", "-f", "concat", "-safe", "0", "-i", listURL.path, "-c", "copy", concatenated.path])
        } catch {
            // Chapters don't share identical audio parameters; re-encode instead of stream-copying.
            try await FFmpeg.run(ffmpeg, ["-y", "-v", "error", "-f", "concat", "-safe", "0", "-i", listURL.path, "-c:a", "aac", "-b:a", "160k", concatenated.path])
        }

        if FileManager.default.fileExists(atPath: destination.path) { try? FileManager.default.removeItem(at: destination) }
        try await FFmpeg.run(ffmpeg, ["-y", "-v", "error", "-i", concatenated.path, "-i", metaURL.path, "-map_metadata", "1", "-codec", "copy", destination.path])
    }

    /// Escapes '=' and newlines, the two characters ffmetadata treats specially in a value.
    private static func sanitize(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "=", with: "\\=").replacingOccurrences(of: "\n", with: " ")
    }
}
