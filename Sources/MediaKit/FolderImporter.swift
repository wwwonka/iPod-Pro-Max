//
//  FolderImporter.swift
//  iPod Pro Max
//
//  Turns a folder of media files into library tracks, on every core: one file per core in flight,
//  each album's cover stored once. Used by the command-line tool and the cross-platform prototype;
//  the Mac app has its own LibraryStore import with the same mapping.
//

import Foundation
import iPodKit

public struct FolderImport: Sendable {
    public var tracks: [LibraryTrack]
    /// Files that couldn't be read, with the reason.
    public var failed: [String]
}

public enum FolderImporter {
    /// Media files under `folder` (hidden files skipped), in a stable order.
    /// A plain recursive walk: on Windows, FileManager's enumerator returns nothing for network
    /// (UNC) folders such as \\server\share\Music.
    public static func mediaFiles(in folder: URL) -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        var pending = [folder]
        while let dir = pending.popLast() {
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for name in names where !name.hasPrefix(".") {
                let url = dir.appendingPathComponent(name)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
                if isDir.boolValue {
                    #if os(macOS)
                    if (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true { continue }
                    #endif
                    pending.append(url)
                } else if MetadataExtractor.isAudioFile(url) || IPodVideo.isVideoFile(url) {
                    out.append(url)
                }
            }
        }
        return out.sorted { $0.path < $1.path }
    }

    /// Reads every media file of `folder`. Track ids are derived from the path relative to `folder`,
    /// so the same folder keeps the same ids from one run (and one computer) to the next.
    /// `progress(done, total)` is called from worker threads.
    public static func scan(folder: URL, artworkDir: URL, progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }, cached: [LibraryTrack] = [], namespace: String? = nil, musicOnly: Bool = false) async -> FolderImport {
        let files = mediaFiles(in: folder).filter { !musicOnly || (MetadataExtractor.isAudioFile($0) && !["m4b", "aa"].contains($0.pathExtension.lowercased())) }
        try? FileManager.default.createDirectory(at: artworkDir, withIntermediateDirectories: true)
        let artwork = ArtworkStore(directory: artworkDir)
        let base = folder.standardizedFileURL.path
        let cachedByPath = Dictionary(cached.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        var tracks: [Int: LibraryTrack] = [:]
        var failed: [String] = []
        let workers = max(ProcessInfo.processInfo.activeProcessorCount, 1)
        await withTaskGroup(of: (Int, LibraryTrack?).self) { group in
            var next = 0
            var done = 0
            func addNext() {
                guard next < files.count else { return }
                let index = next
                let url = files[index]
                next += 1
                group.addTask {
                    let relative = relativePath(of: url, base: base)
                    let old = cachedByPath[url.path]
                    let attrs = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                    if let old, old.fileSize == Int64(attrs?.fileSize ?? -1), old.dateModified == attrs?.contentModificationDate {
                        return (index, old)
                    }
                    return (index, await makeTrack(from: url, id: old?.id ?? stableID(for: (namespace.map { $0 + ":" } ?? "") + relative), artwork: artwork))
                }
            }
            for _ in 0..<min(workers, files.count) { addNext() }
            for await (index, track) in group {
                if let track { tracks[index] = track } else { failed.append(files[index].lastPathComponent) }
                done += 1
                progress(done, files.count)
                addNext()
            }
        }
        return FolderImport(tracks: files.indices.compactMap { tracks[$0] }, failed: failed)
    }

    static func relativePath(of url: URL, base: String) -> String {
        let path = url.standardizedFileURL.path
        let rel = path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
        return rel.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// A name-based UUID (version 5 layout, SHA-1) for a relative path.
    public static func stableID(for relativePath: String) -> UUID {
        var h = SHA1.hash(Array(("ipodpromax.track:" + relativePath).utf8))
        h[6] = (h[6] & 0x0F) | 0x50
        h[8] = (h[8] & 0x3F) | 0x80
        return UUID(uuid: (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8], h[9], h[10], h[11], h[12], h[13], h[14], h[15]))
    }

    /// Same mapping as the Mac app's LibraryStore.makeTrack.
    static func makeTrack(from url: URL, id: UUID, artwork: ArtworkStore) async -> LibraryTrack? {
        let attrs = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let ext = url.pathExtension.lowercased()
        if IPodVideo.isVideoFile(url) {
            guard let info = try? await MediaServices.videoInfo(for: url) else { return nil }
            let md = try? await MetadataExtractor.extract(from: url)
            var t = LibraryTrack(id: id, path: url.path, title: md?.title ?? url.deletingPathExtension().lastPathComponent, fileExtension: ext)
            t.kind = .video
            t.videoWidth = info.width
            t.videoHeight = info.height
            t.durationMs = info.durationMs
            t.artist = md?.artist
            t.album = md?.album
            t.genre = md?.genre
            t.year = md?.year ?? 0
            t.fileSize = Int64(attrs?.fileSize ?? 0)
            t.bitrate = info.durationMs > 0 ? Int(Double(t.fileSize) * 8 / Double(info.durationMs)) : 0
            t.dateModified = attrs?.contentModificationDate
            var art = md?.artworkData
            if art == nil { art = await MediaServices.posterFrame(for: url, durationMs: info.durationMs) }
            t.artworkKey = art.flatMap { artwork.key(for: $0) }
            return t
        }
        guard let md = try? await MetadataExtractor.extract(from: url) else { return nil }
        var t = LibraryTrack(id: id, path: url.path, title: md.title ?? url.deletingPathExtension().lastPathComponent, fileExtension: ext)
        if ext == "m4b" || ext == "aa" { t.kind = .audiobook }
        t.artist = md.artist
        t.album = md.album
        t.albumArtist = md.albumArtist
        t.genre = md.genre
        t.composer = md.composer
        t.comment = md.comment
        t.grouping = md.grouping
        t.year = md.year
        t.trackNumber = md.trackNumber
        t.trackCount = md.trackCount
        t.discNumber = md.discNumber
        t.discCount = md.discCount
        t.durationMs = md.durationMs
        t.bitrate = md.bitrate
        t.sampleRate = md.sampleRate
        t.fileSize = Int64(attrs?.fileSize ?? 0)
        t.isLossless = md.isLossless
        t.compilation = md.compilation
        t.bpm = md.bpm
        t.hasLyrics = md.hasLyrics
        t.dateModified = attrs?.contentModificationDate
        let art = md.artworkData ?? MetadataExtractor.sidecarArtwork(for: url)
        t.artworkKey = art.flatMap { artwork.key(for: $0) }
        return t
    }
}

/// Covers stored once per distinct image, as `<key>.jpg` (JPEG, at most 600 px). Every track of an
/// album usually embeds the same bytes, so the re-encode is skipped for all but the first.
final class ArtworkStore: @unchecked Sendable {
    /// One per distinct image. The first worker to see it holds `lock` while it encodes, so the other
    /// tracks of the album (read at the same time, one per core) wait for that result instead of
    /// re-encoding the same cover.
    private final class Entry: @unchecked Sendable {
        let lock = NSLock()
        var key: String?
    }

    private let directory: URL
    private let lock = NSLock()
    private var entries: [[UInt8]: Entry] = [:]

    init(directory: URL) { self.directory = directory }

    func key(for data: Data) -> String? {
        let digest = SHA1.hash([UInt8](data))
        lock.lock()
        if let entry = entries[digest] {
            lock.unlock()
            entry.lock.lock(); defer { entry.lock.unlock() }
            return entry.key
        }
        let entry = Entry()
        entry.lock.lock()
        entries[digest] = entry
        lock.unlock()
        defer { entry.lock.unlock() }

        let key = digest.prefix(12).map { String(format: "%02x", $0) }.joined()
        let url = directory.appendingPathComponent("\(key).jpg")
        if !FileManager.default.fileExists(atPath: url.path) {
            // Re-encoded like the Mac app's covers; an image this OS can't decode gets no key.
            guard let jpeg = ImageLoading.jpegData(from: data) else { return nil }
            try? jpeg.write(to: url, options: .atomic)
        }
        entry.key = key
        return key
    }
}
