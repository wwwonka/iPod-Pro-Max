//
//  MetadataExtractor.swift
//  iPod Pro Max
//
//  Reads tags, duration, bitrate and artwork from media files. On the Mac this is AVFoundation (the
//  fast path the app always had); on Linux and Windows it is the pure-Swift reader, which only reads
//  the few kilobytes of tags at the start (and sometimes the end) of each file.
//

import Foundation
import iPodKit

public enum MetadataExtractor {
    public static let audioExtensions: Set<String> = IPodFileType.nativeExtensions.union(IPodFileType.transcodableExtensions)

    public static func isAudioFile(_ url: URL) -> Bool {
        audioExtensions.contains(url.pathExtension.lowercased())
    }

    public static func extract(from url: URL) async throws -> ExtractedMetadata {
        #if canImport(AVFoundation)
        if #available(macOS 12, *) { return try await AVTagReader.extract(from: url) }
        #endif
        return try PortableTagReader.read(url)
    }

    /// Looks for a cover image next to the audio file (folder.jpg, cover.png, …).
    public static func sidecarArtwork(for url: URL) -> Data? {
        let dir = url.deletingLastPathComponent()
        let names = ["cover", "folder", "front", "album", "artwork", "Cover", "Folder", "Front", "Album", "Artwork"]
        let exts = ["jpg", "jpeg", "png"]
        for n in names {
            for e in exts {
                let candidate = dir.appendingPathComponent("\(n).\(e)")
                if let d = try? Data(contentsOf: candidate), !d.isEmpty { return d }
            }
        }
        return nil
    }
}
