//
//  MediaServices.swift
//  iPod Pro Max
//
//  The sync engine's media needs, answered the best way on each OS: AVFoundation, VideoToolbox and
//  ImageIO on the Mac (unchanged fast paths), ffmpeg and pure Swift on Linux, Windows and on Macs
//  too old for the AVFoundation APIs used (before macOS 12, or 15 for audio conversion).
//

import Foundation
import iPodKit

public struct MediaServices: SyncMediaServices {
    public init() {}

    public func decodeImage(at url: URL) -> PixelBuffer? {
        ImageLoading.pixels(from: url)
    }

    public func cachedAAC(for track: LibraryTrack, cacheDir: URL) async throws -> URL {
        #if canImport(AVFoundation)
        if #available(macOS 15, *) { return try await Transcoder.cachedAAC(for: track, cacheDir: cacheDir) }
        #endif
        return try await FFmpegTranscoder.cachedAAC(for: track, cacheDir: cacheDir)
    }

    public func cachedIPodVideo(for track: LibraryTrack, cacheDir: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        #if canImport(AVFoundation)
        if #available(macOS 12, *) { return try await VideoTranscoder.cachedIPodVideo(for: track, cacheDir: cacheDir, progress: progress) }
        #endif
        return try await FFmpegTranscoder.cachedIPodVideo(for: track, cacheDir: cacheDir, progress: progress)
    }

    public func mergeAudiobook(chapters: [AudiobookChapter], to destination: URL) async throws {
        try await AudiobookMuxer.merge(chapters: chapters, to: destination)
    }

    /// Size and duration of a video file.
    public static func videoInfo(for url: URL) async throws -> VideoInfo {
        #if canImport(AVFoundation)
        if #available(macOS 12, *) { return try await VideoTranscoder.info(for: url) }
        #endif
        return try await FFmpegTranscoder.videoInfo(for: url)
    }

    /// A JPEG still from a video, for its artwork.
    public static func posterFrame(for url: URL, durationMs: Int) async -> Data? {
        #if canImport(AVFoundation)
        if #available(macOS 13, *) { return await VideoTranscoder.posterFrame(for: url) }
        #endif
        return await FFmpegTranscoder.posterFrame(for: url, durationMs: durationMs)
    }
}
