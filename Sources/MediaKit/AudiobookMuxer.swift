//
//  AudiobookMuxer.swift
//  iPod Pro Max
//
//  Merges a multi-file audiobook's chapters into one .m4b with real QuickTime chapter markers, via
//  ffmpeg (see FFmpeg.binaryPath for where it is looked for). Authoring chapter tracks by hand with
//  AVFoundation means hand-crafting raw tx3g sample buffers — ffmpeg already does this correctly and
//  is well-tested, so this file stays a thin wrapper instead of reinventing that.
//
//  The bundled ffmpeg has the concat *demuxer* but not the concat filter, and the demuxer neither
//  resamples nor converts: chapters in different codecs or at different sample rates (MP3 files,
//  a stray 48 kHz one) must first be brought to the same AAC parameters, else the demuxer silently
//  drops or garbles them. So: chapters that already share one AAC format are joined by stream copy
//  (fast, lossless); otherwise each chapter is re-encoded to a common format first, in parallel.
//

import Foundation
import iPodKit

public enum AudiobookMuxer {
    struct AudioFormat: Equatable {
        var codec: String
        var sampleRate: Int
        var channels: Int
        var durationMs: Int
    }

    /// Concatenates `chapters` (in order) into `destination` as one .m4b, with a chapter marker at
    /// each original file's start carrying its title.
    public static func merge(chapters: [AudiobookChapter], to destination: URL) async throws {
        let ffmpeg = try FFmpeg.requireBinary(for: "Merging audiobook chapters")
        guard !chapters.isEmpty else { throw IPodDBError.io("No chapters to merge.") }

        let workDir = destination.deletingLastPathComponent().appendingPathComponent(".merge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        var formats: [AudioFormat] = []
        for chapter in chapters {
            guard let format = await probe(chapter.url, ffmpeg: ffmpeg) else {
                throw IPodDBError.io("“\(chapter.title)” isn't an audio file ffmpeg can read.")
            }
            formats.append(format)
        }

        // Stream copy needs one AAC format throughout; anything else is normalized first.
        var inputs = chapters.map(\.url)
        let uniform = formats.allSatisfy { $0.codec == "aac" && $0.sampleRate == formats[0].sampleRate && $0.channels == formats[0].channels }
        if !uniform {
            let rate = commonSampleRate(formats)
            let channels = formats.map(\.channels).max().map { $0 >= 2 ? 2 : 1 } ?? 1
            inputs = try await normalize(chapters.map(\.url), rate: rate, channels: channels, in: workDir, ffmpeg: ffmpeg)
            for i in inputs.indices { if let f = await probe(inputs[i], ffmpeg: ffmpeg) { formats[i] = f } }
        }

        // Chapter marks follow the audio actually joined, not tag durations, which drift by frames.
        var meta = ";FFMETADATA1\n"
        var cursor = 0
        for (i, chapter) in chapters.enumerated() {
            let length = formats[i].durationMs > 0 ? formats[i].durationMs : max(chapter.durationMs, 0)
            meta += "[CHAPTER]\nTIMEBASE=1/1000\nSTART=\(cursor)\nEND=\(cursor + length)\ntitle=\(sanitize(chapter.title))\n\n"
            cursor += length
        }
        let metaURL = workDir.appendingPathComponent("chapters.ffmetadata")
        try meta.write(to: metaURL, atomically: true, encoding: .utf8)

        let listURL = workDir.appendingPathComponent("concat.txt")
        let listText = inputs.map { "file '\(FFmpeg.concatPath($0).replacingOccurrences(of: "'", with: "'\\''"))'" }.joined(separator: "\n")
        try listText.write(to: listURL, atomically: true, encoding: .utf8)

        let concatenated = workDir.appendingPathComponent("concatenated.m4a")
        try await FFmpeg.run(ffmpeg, ["-y", "-v", "error", "-f", "concat", "-safe", "0", "-i", FileOps.nativePath(listURL), "-vn", "-c", "copy", FileOps.nativePath(concatenated)])

        // Written in the work folder beside the destination, then renamed: a cancelled or failed merge never leaves half a book.
        let partial = workDir.appendingPathComponent("book.m4b")
        try await FFmpeg.run(ffmpeg, ["-y", "-v", "error", "-i", FileOps.nativePath(concatenated), "-i", FileOps.nativePath(metaURL), "-map", "0:a", "-map_metadata", "1", "-map_chapters", "1", "-codec", "copy", "-f", "ipod", FileOps.nativePath(partial)])
        // `workDir` sits next to the destination, so this is a rename on the same volume, not a copy.
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(at: partial, to: destination)
    }

    // MARK: Pieces

    /// Re-encodes every chapter to AAC at one rate and channel count, `cores / 2` at a time (the encoder is
    /// light, the disks are the limit), and returns the files in chapter order.
    private static func normalize(_ sources: [URL], rate: Int, channels: Int, in workDir: URL, ffmpeg: String) async throws -> [URL] {
        let outputs = sources.indices.map { workDir.appendingPathComponent("chapter-\($0).m4a") }
        try await withThrowingTaskGroup(of: Void.self) { group in
            var next = 0
            func add() {
                guard next < sources.count else { return }
                let i = next; next += 1
                group.addTask {
                    try await FFmpeg.run(ffmpeg, ["-y", "-v", "error", "-i", FileOps.nativePath(sources[i]), "-vn", "-map", "0:a:0",
                                                  "-c:a", "aac", "-b:a", channels == 1 ? "96k" : "128k", "-ar", "\(rate)", "-ac", "\(channels)",
                                                  FileOps.nativePath(outputs[i])])
                }
            }
            for _ in 0..<max(1, ProcessInfo.processInfo.activeProcessorCount / 2) { add() }
            while try await group.next() != nil { add() }
        }
        return outputs
    }

    /// The most common rate among the chapters, taken as is when it is one the iPods play.
    static func commonSampleRate(_ formats: [AudioFormat]) -> Int {
        let counts = Dictionary(grouping: formats.map(\.sampleRate), by: { $0 }).mapValues(\.count)
        let best = counts.max { ($0.value, $0.key) < ($1.value, $1.key) }?.key ?? 44100
        return [8000, 11025, 16000, 22050, 24000, 32000, 44100, 48000].contains(best) ? best : 44100
    }

    /// Codec, rate, channels and length of the first audio stream, from what `ffmpeg -i` prints.
    static func probe(_ url: URL, ffmpeg: String) async -> AudioFormat? {
        parse(await FFmpeg.probe(ffmpeg, ["-i", FileOps.nativePath(url)]))
    }

    static func parse(_ text: String) -> AudioFormat? {
        guard let audio = text.range(of: #"Audio: (\w+)[^,\n]*, (\d+) Hz, ([^,\n]+)"#, options: .regularExpression) else { return nil }
        let line = String(text[audio])
        let parts = line.dropFirst("Audio: ".count).split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 3 else { return nil }
        let codec = String(parts[0].split(separator: " ").first ?? "")
        let rate = Int(parts[1].split(separator: " ").first ?? "") ?? 0
        let layout = parts[2]
        let channels: Int
        switch layout {
        case "mono": channels = 1
        case "stereo": channels = 2
        default: channels = Int(layout.split(whereSeparator: { !$0.isNumber }).first ?? "") ?? 2
        }
        var durationMs = 0
        if let d = text.range(of: #"Duration: (\d+):(\d+):(\d+\.\d+)"#, options: .regularExpression) {
            let t = text[d].dropFirst("Duration: ".count).split(separator: ":")
            if t.count == 3, let h = Double(t[0]), let m = Double(t[1]), let s = Double(t[2]) { durationMs = Int(((h * 60 + m) * 60 + s) * 1000) }
        }
        return AudioFormat(codec: codec, sampleRate: rate, channels: channels, durationMs: durationMs)
    }

    /// Escapes '=' and newlines, the two characters ffmetadata treats specially in a value.
    private static func sanitize(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "=", with: "\\=").replacingOccurrences(of: "\n", with: " ")
    }
}
