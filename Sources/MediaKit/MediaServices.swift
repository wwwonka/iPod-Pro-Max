//
//  MediaServices.swift
//  iPod Pro Max
//
//  The sync engine's media needs, answered the best way on each OS: AVFoundation, VideoToolbox and
//  ImageIO on the Mac (unchanged fast paths), ffmpeg and pure Swift on Linux and Windows.
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
        return try await Transcoder.cachedAAC(for: track, cacheDir: cacheDir)
        #else
        return try await FFmpegTranscoder.cachedAAC(for: track, cacheDir: cacheDir)
        #endif
    }

    public func cachedIPodVideo(for track: LibraryTrack, cacheDir: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        #if canImport(AVFoundation)
        return try await VideoTranscoder.cachedIPodVideo(for: track, cacheDir: cacheDir, progress: progress)
        #else
        return try await FFmpegTranscoder.cachedIPodVideo(for: track, cacheDir: cacheDir, progress: progress)
        #endif
    }

    public func mergeAudiobook(chapters: [AudiobookChapter], to destination: URL) async throws {
        try await AudiobookMuxer.merge(chapters: chapters, to: destination)
    }

    /// Size and duration of a video file.
    public static func videoInfo(for url: URL) async throws -> VideoInfo {
        #if canImport(AVFoundation)
        return try await VideoTranscoder.info(for: url)
        #else
        return try await FFmpegTranscoder.videoInfo(for: url)
        #endif
    }

    /// A JPEG still from a video, for its artwork.
    public static func posterFrame(for url: URL, durationMs: Int) async -> Data? {
        #if canImport(AVFoundation)
        return await VideoTranscoder.posterFrame(for: url)
        #else
        return await FFmpegTranscoder.posterFrame(for: url, durationMs: durationMs)
        #endif
    }
}
