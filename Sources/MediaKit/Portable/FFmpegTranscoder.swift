//
//  FFmpegTranscoder.swift
//  iPod Pro Max
//
//  Audio and video conversion with ffmpeg, for Linux and Windows (the Mac uses AVFoundation and
//  VideoToolbox). Audio: AAC-LC 256 kbit/s in .m4a. Video: what click-wheel iPods play, H.264
//  Baseline level 1.3 up to 320×240 and AAC-LC stereo, with the first H.264 encoder this ffmpeg has.
//

import Foundation
import iPodKit

public enum FFmpegTranscoder {
    public static func transcodeToAAC(source: URL, destination: URL) async throws -> URL {
        let ffmpeg = try FFmpeg.requireBinary(for: "Converting \(source.lastPathComponent) to AAC")
        try prepare(destination)
        try await FFmpeg.run(ffmpeg, ["-y", "-v", "error", "-i", FileOps.nativePath(source),
                                      "-map", "0:a:0", "-map_metadata", "0", "-c:a", "aac", "-b:a", "256k",
                                      "-movflags", "+faststart", FileOps.nativePath(destination)])
        return destination
    }

    public static func cachedAAC(for track: LibraryTrack, cacheDir: URL) async throws -> URL {
        let dest = cacheDir.appendingPathComponent("\(track.id.uuidString).m4a")
        if TranscodeCache.isFresh(dest, comparedTo: track.url) { return dest }
        return try await transcodeToAAC(source: track.url, destination: dest)
    }

    public static func cachedIPodVideo(for track: LibraryTrack, cacheDir: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let dest = cacheDir.appendingPathComponent("\(track.id.uuidString).m4v")
        if TranscodeCache.isFresh(dest, comparedTo: track.url) { return dest }
        try await transcodeVideo(source: track.url, destination: dest, durationMs: track.durationMs, progress: progress)
        return dest
    }

    /// H.264 encoders in order of preference. libx264 gives the best Baseline output; hardware
    /// encoders are faster; libopenh264 is the one Fedora's ffmpeg-free and our own Linux build have.
    static let videoEncoders = ["libx264", "h264_videotoolbox", "h264_nvenc", "h264_qsv", "h264_amf", "h264_mf", "h264_vaapi", "libopenh264"]

    /// The encoder that last worked, so later videos don't retry the ones that failed.
    private static let encoderCache = EncoderCache()

    /// The H.264 encoders this ffmpeg was built with, best first. Being built in doesn't mean the
    /// machine has the hardware (h264_nvenc without an NVIDIA GPU): transcodeVideo tries them in turn.
    static func availableVideoEncoders(_ ffmpeg: String) async -> [String] {
        if let cached = encoderCache.value { return [cached] }
        let list = await stdout(ffmpeg, ["-hide_banner", "-encoders"])
        let names = Set(list.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            return parts.count >= 2 && parts[0].hasPrefix("V") ? String(parts[1]) : nil
        })
        return videoEncoders.filter { names.contains($0) }
    }

    public static func transcodeVideo(source: URL, destination: URL, durationMs: Int, progress: @escaping @Sendable (Double) -> Void) async throws {
        let ffmpeg = try FFmpeg.requireBinary(for: "Converting video for the iPod")
        let encoders = await availableVideoEncoders(ffmpeg)
        guard !encoders.isEmpty else {
            throw IPodDBError.unsupported("This ffmpeg has no H.264 encoder (libx264, libopenh264 or a hardware one).")
        }
        var lastError: Error?
        for encoder in encoders {
            try Task.checkCancellation()
            do {
                try await transcodeVideo(ffmpeg: ffmpeg, encoder: encoder, source: source, destination: destination,
                                         durationMs: durationMs, progress: progress)
                encoderCache.value = encoder
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError ?? IPodDBError.unsupported("No H.264 encoder worked on this machine.")
    }

    private static func transcodeVideo(ffmpeg: String, encoder: String, source: URL, destination: URL, durationMs: Int,
                                       progress: @escaping @Sendable (Double) -> Void) async throws {
        try prepare(destination)
        // Fit 320×240, keep the aspect ratio, even dimensions; never upscale.
        var scale = "scale='min(\(IPodVideo.maxWidth),iw)':'min(\(IPodVideo.maxHeight),ih)':force_original_aspect_ratio=decrease,scale=trunc(iw/2)*2:trunc(ih/2)*2,setsar=1"
        // VA-API encodes GPU surfaces: the scaled frames are uploaded as NV12 instead of -pix_fmt yuv420p.
        let pixelFormat: [String]
        if encoder == "h264_vaapi" {
            scale += ",format=nv12,hwupload"
            pixelFormat = []
        } else {
            pixelFormat = ["-pix_fmt", "yuv420p"]
        }
        var args = ["-y", "-v", "error", "-nostats", "-progress", "pipe:1", "-i", FileOps.nativePath(source),
                    "-map", "0:v:0", "-map", "0:a:0?", "-sn", "-dn",
                    "-vf", scale, "-r", "\(Int(IPodVideo.maxFrameRate))"] + pixelFormat + [
                    "-c:v", encoder, "-b:v", "\(IPodVideo.videoBitrate / 1000)k", "-maxrate", "768k", "-bufsize", "1536k"]
        switch encoder {
        case "libx264": args += ["-profile:v", "baseline", "-level", "1.3", "-preset", "medium"]
        case "libopenh264": args += ["-profile:v", "constrained_baseline", "-allow_skip_frames", "0"]
        case "h264_vaapi": args.insert(contentsOf: ["-vaapi_device", "/dev/dri/renderD128"], at: 0); args += ["-profile:v", "constrained_baseline", "-level", "13"]
        // Media Foundation reads the generic numeric fields: 66 is Baseline, 13 is level 1.3.
        case "h264_mf": args += ["-profile:v", "66", "-level", "13"]
        default: args += ["-profile:v", "baseline", "-level", "1.3"]
        }
        args += ["-c:a", "aac", "-b:a", "\(IPodVideo.audioBitrate / 1000)k", "-ac", "2", "-ar", "44100",
                 "-movflags", "+faststart", "-f", "mp4", FileOps.nativePath(destination)]
        let total = Double(max(durationMs, 1)) * 1000 // microseconds
        try await FFmpeg.run(ffmpeg, args) { line in
            if line.hasPrefix("out_time_us="), let us = Double(line.dropFirst("out_time_us=".count)) {
                progress(min(max(us / total, 0), 1))
            }
        }
        progress(1)
    }

    /// Size and duration of a video, from `ffmpeg -i` (no ffprobe needed).
    public static func videoInfo(for url: URL) async throws -> VideoInfo {
        let ffmpeg = try FFmpeg.requireBinary(for: "Reading video files")
        let text = await FFmpeg.probe(ffmpeg, ["-hide_banner", "-i", FileOps.nativePath(url)])
        var info = VideoInfo(width: 0, height: 0, durationMs: 0, hasAudio: false)
        for line in text.split(whereSeparator: \.isNewline) {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("Duration:"), let range = l.range(of: #"\d+:\d+:\d+(\.\d+)?"#, options: .regularExpression) {
                let parts = l[range].split(separator: ":").compactMap { Double($0) }
                if parts.count == 3 { info.durationMs = Int(((parts[0] * 3600 + parts[1] * 60 + parts[2]) * 1000).rounded()) }
            } else if l.contains("Video:"), info.width == 0, let range = l.range(of: #"\b\d{2,5}x\d{2,5}\b"#, options: .regularExpression) {
                let dims = l[range].split(separator: "x").compactMap { Int($0) }
                if dims.count == 2 { info.width = dims[0]; info.height = dims[1] }
                if l.contains("rotate") || text.contains("rotation of -90") || text.contains("rotation of 90") { swap(&info.width, &info.height) }
            } else if l.contains("Audio:") {
                info.hasAudio = true
            }
        }
        guard info.width > 0 else { throw IPodDBError.unsupported("No video track found in \(url.lastPathComponent)") }
        return info
    }

    /// A JPEG poster frame about a second and a half in.
    public static func posterFrame(for url: URL, durationMs: Int) async -> Data? {
        guard let ffmpeg = FFmpeg.binaryPath() else { return nil }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("poster-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: out) }
        let at = durationMs > 3000 ? "1.5" : "0"
        do {
            try await FFmpeg.run(ffmpeg, ["-y", "-v", "error", "-ss", at, "-i", FileOps.nativePath(url), "-frames:v", "1",
                                          "-vf", "scale='min(640,iw)':-2", "-q:v", "3", FileOps.nativePath(out)])
            return try Data(contentsOf: out)
        } catch {
            return nil
        }
    }

    private static func prepare(_ destination: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    private static func stdout(_ binary: String, _ arguments: [String]) async -> String {
        let collected = OutputCollector()
        try? await FFmpeg.run(binary, arguments) { line in collected.append(Data((line + "\n").utf8)) }
        return collected.text
    }
}

private final class EncoderCache: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?

    var value: String? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
