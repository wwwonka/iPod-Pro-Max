//
//  SyncServices.swift
//  iPod Pro Max
//
//  What the sync engine needs from the host but can't do in pure Swift: decoding images, converting
//  audio and video, merging audiobooks, reading the photo library. MediaKit provides the
//  implementations (AVFoundation/ImageIO on the Mac, ffmpeg and pure Swift elsewhere); the Mac app
//  adds its Photos library.
//

import Foundation

public protocol SyncMediaServices: Sendable {
    /// Decodes an image file (JPEG, PNG…) into pixels, or nil when it can't be read.
    func decodeImage(at url: URL) -> PixelBuffer?
    /// An AAC (.m4a) copy of a track the iPod can't play as is, reused from `cacheDir` when still fresh.
    func cachedAAC(for track: LibraryTrack, cacheDir: URL) async throws -> URL
    /// An iPod-compatible H.264 (.m4v) copy of a video, reused from `cacheDir` when still fresh.
    func cachedIPodVideo(for track: LibraryTrack, cacheDir: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL
    /// Concatenates audiobook chapters into one .m4b with a chapter marker per file.
    func mergeAudiobook(chapters: [AudiobookChapter], to destination: URL) async throws
}

public struct AudiobookChapter: Sendable {
    public var title: String
    public var url: URL
    /// From the library; 0 makes the muxer read it from the file.
    public var durationMs: Int

    public init(title: String, url: URL, durationMs: Int = 0) {
        self.title = title
        self.url = url
        self.durationMs = durationMs
    }
}

/// The photos chosen for the iPod, exported as JPEG files.
public struct PhotoExport: Sendable {
    public struct Album: Sendable {
        public var name: String
        public var photoKeys: [String]

        public init(name: String, photoKeys: [String]) {
            self.name = name
            self.photoKeys = photoKeys
        }
    }

    public var photos: [PhotoItem]
    public var albums: [Album]
    public var failed: Int

    public init(photos: [PhotoItem], albums: [Album], failed: Int) {
        self.photos = photos
        self.albums = albums
        self.failed = failed
    }
}

/// A photo library the sync can copy from (the Photos app on the Mac).
public protocol PhotoLibrarySource: Sendable {
    var isAuthorized: Bool { get }
    /// Rough count, only used for the free-space check.
    func estimatedCount(selection: PhotoSelection) -> Int
    func export(selection: PhotoSelection, cacheDir: URL, progress: @escaping (Int, Int) -> Void) throws -> PhotoExport
    func pruneCache(_ cacheDir: URL, keep: Set<String>)
}

/// Limits of the video the click-wheel iPods play: H.264 Baseline up to 320×240, AAC-LC stereo.
public enum IPodVideo {
    public static let maxWidth = 320
    public static let maxHeight = 240
    public static let videoBitrate = 700_000
    public static let audioBitrate = 128_000
    public static let maxFrameRate = 30.0

    public static let videoExtensions: Set<String> = ["mp4", "m4v", "mov", "mpg", "mpeg", "mkv", "avi", "3gp", "ts", "m2ts", "mts", "webm", "flv", "wmv", "mxf"]

    public static func isVideoFile(_ url: URL) -> Bool {
        videoExtensions.contains(url.pathExtension.lowercased())
    }

    /// Target dimensions that fit the iPod screen, even-sized, preserving aspect ratio.
    public static func targetSize(width: Int, height: Int) -> (Int, Int) {
        guard width > 0, height > 0 else { return (maxWidth, maxHeight) }
        let scale = min(Double(maxWidth) / Double(width), Double(maxHeight) / Double(height), 1.0)
        var w = Int((Double(width) * scale).rounded())
        var h = Int((Double(height) * scale).rounded())
        w -= w % 2
        h -= h % 2
        return (max(w, 16), max(h, 16))
    }
}

/// Converted files kept between syncs, redone only when the source is newer.
public enum TranscodeCache {
    public static func isFresh(_ cached: URL, comparedTo source: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: cached.path) else { return false }
        let srcDate = (try? source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        let dstDate = (try? cached.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        return dstDate >= srcDate
    }
}
