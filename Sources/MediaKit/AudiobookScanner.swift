//
//  AudiobookScanner.swift
//  iPod Pro Max
//
//  Turns an audiobooks folder into library tracks, on every OS. A subfolder is a book with chapters
//  (its audio files sorted by name); a loose audio file is a one-part book named after itself.
//

import Foundation
import iPodKit

public struct AudiobookFolder: Sendable {
    public var tracks: [LibraryTrack]
    public var failed: [String]
}

public enum AudiobookScanner {
    /// The books of `folder`, each with its chapter files in reading order.
    public static func books(in folder: URL) -> [(title: String, files: [URL])] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return [] }
        var books: [(title: String, files: [URL])] = []
        for name in names.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) where !name.hasPrefix(".") {
            let entry = folder.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                let files = FolderImporter.mediaFiles(in: entry).filter { MetadataExtractor.isAudioFile($0) }
                    .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                if !files.isEmpty { books.append((name, files)) }
            } else if MetadataExtractor.isAudioFile(entry) {
                books.append((entry.deletingPathExtension().lastPathComponent, [entry]))
            }
        }
        return books
    }

    /// Reads every book of `folder`, one file per core in flight. Ids derive from the path relative to
    /// the folder (as for music), unchanged files are taken from `cached`.
    public static func scan(folder: URL, artworkDir: URL, cached: [LibraryTrack] = [], namespace: String,
                            progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async -> AudiobookFolder {
        let books = books(in: folder)
        try? FileManager.default.createDirectory(at: artworkDir, withIntermediateDirectories: true)
        let artwork = ArtworkStore(directory: artworkDir)
        let base = folder.standardizedFileURL.path
        let cachedByPath = Dictionary(cached.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })

        struct Job { var book: Int; var index: Int; var url: URL }
        var jobs: [Job] = []
        for (b, book) in books.enumerated() { for (i, url) in book.files.enumerated() { jobs.append(Job(book: b, index: i, url: url)) } }

        var read: [Int: LibraryTrack] = [:]
        var failed: [String] = []
        await withTaskGroup(of: (Int, LibraryTrack?).self) { group in
            var next = 0, done = 0
            func addNext() {
                guard next < jobs.count else { return }
                let n = next, job = jobs[n]
                let count = books[job.book].files.count
                let title = books[job.book].title
                next += 1
                group.addTask {
                    let attrs = try? job.url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                    if let old = cachedByPath[job.url.path], old.isAudiobook, old.fileSize == Int64(attrs?.fileSize ?? -1),
                       old.dateModified == attrs?.contentModificationDate, old.album == title {
                        return (n, old)
                    }
                    guard let md = try? await MetadataExtractor.extract(from: job.url) else { return (n, nil) }
                    let id = FolderImporter.stableID(for: namespace + ":" + FolderImporter.relativePath(of: job.url, base: base))
                    var t = LibraryTrack(id: id, path: job.url.path, title: md.title ?? job.url.deletingPathExtension().lastPathComponent,
                                         fileExtension: job.url.pathExtension.lowercased())
                    t.kind = .audiobook
                    t.album = title
                    t.genre = "Audiobooks"
                    t.artist = md.albumArtist ?? md.artist
                    t.trackNumber = count > 1 ? job.index + 1 : max(md.trackNumber, 0)
                    t.trackCount = count > 1 ? count : max(md.trackCount, 0)
                    t.durationMs = md.durationMs
                    t.bitrate = md.bitrate
                    t.sampleRate = md.sampleRate
                    t.fileSize = Int64(attrs?.fileSize ?? 0)
                    t.isLossless = md.isLossless
                    t.hasLyrics = md.hasLyrics
                    t.dateModified = attrs?.contentModificationDate
                    let art = md.artworkData ?? MetadataExtractor.sidecarArtwork(for: job.url)
                    t.artworkKey = art.flatMap { artwork.key(for: $0) }
                    return (n, t)
                }
            }
            for _ in 0..<min(max(ProcessInfo.processInfo.activeProcessorCount, 1), jobs.count) { addNext() }
            for await (n, track) in group {
                if let track { read[n] = track } else { failed.append(jobs[n].url.lastPathComponent) }
                done += 1
                progress(done, jobs.count)
                addNext()
            }
        }

        // Chapter files are often tagged inconsistently (narrator, author, nothing), which would split one
        // book into several on the iPod: every chapter gets the same author and cover.
        var tracks: [LibraryTrack] = []
        var byBook: [Int: [LibraryTrack]] = [:]
        for (n, job) in jobs.enumerated() { if let t = read[n] { byBook[job.book, default: []].append(t) } }
        for b in books.indices {
            guard var chapters = byBook[b] else { continue }
            let author = chapters.compactMap(\.artist).first { !$0.isEmpty } ?? "Unknown Author"
            let cover = chapters.compactMap(\.artworkKey).first
            for i in chapters.indices {
                // Cached chapters keep what they were read with: numbers follow the files that are there now.
                if chapters.count > 1 { chapters[i].trackNumber = i + 1; chapters[i].trackCount = chapters.count }
                chapters[i].artist = author
                chapters[i].albumArtist = author
                if chapters[i].artworkKey == nil { chapters[i].artworkKey = cover }
            }
            tracks.append(contentsOf: chapters)
        }
        return AudiobookFolder(tracks: tracks, failed: failed)
    }

    /// The tracks of each book in the order the sync engine merges them (it groups by album and artist).
    public static func bookGroups(_ tracks: [LibraryTrack]) -> [[LibraryTrack]] {
        let grouped = Dictionary(grouping: tracks.filter(\.isAudiobook)) { "\($0.album ?? "")\u{1}\($0.artist ?? "")" }
        return grouped.values.map { $0.sorted { ($0.trackNumber, $0.title) < ($1.trackNumber, $1.title) } }
    }
}
