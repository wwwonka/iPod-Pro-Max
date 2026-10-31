//
//  Transcoder.swift
//  iPod Pro Max
//
//  Converts audio the iPod can't play (FLAC, etc.) to AAC in an .m4a container with AVFoundation.
//

#if canImport(AVFoundation)
import Foundation
import AVFoundation
import iPodKit

/// macOS 15 for `AVAssetExportSession.export(to:as:)`; older Macs convert with ffmpeg (MediaServices).
@available(macOS 15, *)
public enum Transcoder {
    public static func transcodeToAAC(source: URL, destination: URL) async throws -> URL {
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw IPodDBError.unsupported("This file can't be converted to AAC: \(source.lastPathComponent)")
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        session.metadata = try? await asset.load(.metadata)
        try await session.export(to: destination, as: .m4a)
        return destination
    }

    /// Returns a cached transcode when it is newer than the source, otherwise transcodes.
    public static func cachedAAC(for track: LibraryTrack, cacheDir: URL) async throws -> URL {
        let dest = cacheDir.appendingPathComponent("\(track.id.uuidString).m4a")
        if TranscodeCache.isFresh(dest, comparedTo: track.url) { return dest }
        return try await transcodeToAAC(source: track.url, destination: dest)
    }
}
#endif
