//
//  LibraryStore.swift
//  iPod Pro Max
//
//  Owns the app library (songs, playlists, podcasts, per-iPod sync records) and persists it as JSON
//  under ~/Library/Application Support/iPod Pro Max.
//

import Foundation
import Observation
import CryptoKit
import AppKit
import os
import iPodKit
import MediaKit
import DeviceKit

/// Every track of an album usually embeds the same cover. Decoding and re-encoding it as JPEG is the
/// most expensive part of reading a file, so during one import pass each distinct embedded image
/// (by a hash of its raw bytes, which is cheap) is stored once and its key reused. Safe to share
/// across concurrent import tasks.
final class ArtworkKeyCache: Sendable {
    private let keys = OSAllocatedUnfairLock(initialState: [SHA256Digest: String]())

    func key(for data: Data, in artworkDir: URL) -> String? {
        let digest = SHA256.hash(data: data)
        if let key = keys.withLock({ $0[digest] }) { return key }
        guard let key = LibraryStore.storeArtwork(data, in: artworkDir) else { return nil }
        keys.withLock { $0[digest] = key }
        return key
    }
}

@MainActor
@Observable
final class LibraryStore {
    var tracks: [LibraryTrack] = [] { didSet { tracksRevision &+= 1 } }
    /// Bumped on every change to `tracks`. Views key their cached derived data on this instead of
    /// comparing thousands of tracks on every render.
    private(set) var tracksRevision = 0
    var playlists: [LibraryPlaylist] = []
    var shows: [PodcastShow] = []
    var deviceRecords: [String: DeviceSyncRecord] = [:]
    var photoSelection = PhotoSelection()
    var audiobooksFolderPath: String?
    var musicFolderPath: String?

    // Transient UI state
    var isImporting = false
    var isScanningLibrary = false
    var importStatus: String?
    var importProgress: Double?
    var downloadProgress: [UUID: Double] = [:]
    var refreshingShows: Set<UUID> = []
    var lastError: String?
    /// Paths that didn't exist on disk the last time `refreshMissingFiles()` ran. `LibraryTrack.fileExists`
    /// hits the disk synchronously, so views check this cache instead of calling it per row per render.
    var missingPaths: Set<String> = []

    let baseDir: URL
    let artworkDir: URL
    let podcastsDir: URL
    let transcodeDir: URL
    let photoCacheDir: URL
    private let documentURL: URL
    private var saveTask: Task<Void, Never>?
    private var activeDownloads: [UUID: Task<Void, Never>] = [:]

    init(baseDir: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        // Development aid: `-libraryDir /path` uses a different library for this launch only.
        let override = UserDefaults.standard.string(forKey: "libraryDir").map { URL(fileURLWithPath: $0, isDirectory: true) }
        let base = baseDir ?? override ?? support.appendingPathComponent("iPod Pro Max", isDirectory: true)
        self.baseDir = base
        artworkDir = base.appendingPathComponent("Artwork", isDirectory: true)
        podcastsDir = base.appendingPathComponent("Podcasts", isDirectory: true)
        transcodeDir = base.appendingPathComponent("Transcodes", isDirectory: true)
        photoCacheDir = base.appendingPathComponent("PhotoCache", isDirectory: true)
        documentURL = base.appendingPathComponent("library.json")
        for d in [base, artworkDir, podcastsDir, transcodeDir, photoCacheDir] {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        load()
        Task { await backfillLyricsIfNeeded() }
        if UserDefaults.standard.object(forKey: "scanLibraryOnLaunch") as? Bool ?? true {
            Task {
                inferMusicFolderIfNeeded()
                await scanLibraryFolders()
            }
        } else {
            Task { await refreshMissingFiles() }
        }
    }

    /// Re-checks which library files are missing from disk (e.g. deleted in Finder), off the main
    /// thread, and caches the result in `missingPaths` for views to read without hitting the disk.
    func refreshMissingFiles() async {
        let paths = tracks.map(\.path)
        let missing = await Task.detached(priority: .utility) {
            Set(paths.filter { !FileManager.default.fileExists(atPath: $0) })
        }.value
        missingPaths = missing
    }

    /// Removes every track whose file no longer exists (per the last `refreshMissingFiles()`).
    @discardableResult
    func removeMissingTracks() -> Int {
        let ids = Set(tracks.filter { missingPaths.contains($0.path) }.map(\.id))
        guard !ids.isEmpty else { return 0 }
        removeTracks(ids: ids)
        return ids.count
    }

    // MARK: - Persistence

    /// Tracks imported before lyrics detection existed were never checked for a lyrics tag, so their
    /// `hasLyrics` is stuck at its default `false` regardless of what the file actually carries. Runs
    /// once (gated by a UserDefaults flag) and just re-reads each file's tags, no re-import needed.
    private func backfillLyricsIfNeeded() async {
        let key = "lyricsBackfillDone_v1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        let candidates = tracks.filter { !$0.isVideo && !$0.hasLyrics && $0.fileExists }
        var changed = false
        for t in candidates {
            guard let md = try? await MetadataExtractor.extract(from: t.url), md.hasLyrics else { continue }
            guard let i = tracks.firstIndex(where: { $0.id == t.id }) else { continue }
            tracks[i].hasLyrics = true
            changed = true
        }
        UserDefaults.standard.set(true, forKey: key)
        if changed { scheduleSave() } // never save just because this housekeeping pass ran and found nothing
    }

    /// Re-reads tags for any track whose file was modified since we last scanned it (e.g. edited in
    /// another app since the last sync), so the next sync pushes the new metadata to an iPod that
    /// already has the file — no re-copy, no duplicate, just the on-device database record updated.
    ///
    /// The cheap "did this change" check (one disk stat) runs for the whole library, which is fine;
    /// the expensive part (AVFoundation re-extraction) only runs for files that actually need it, and
    /// runs several at once instead of one at a time — doing that serially for a large library is what
    /// made this take forever. A 2-second tolerance also avoids false positives from sub-second mtime
    /// rounding flagging the entire library as "changed" on every sync.
    func refreshChangedTrackMetadata() async {
        guard !Task.isCancelled else { return }
        let candidates: [(id: UUID, url: URL, modified: Date)] = tracks.compactMap { t in
            guard !t.isVideo, !t.isAudiobook,
                  let modified = try? t.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  modified.timeIntervalSince(t.dateModified ?? .distantPast) > 2 else { return nil }
            return (t.id, t.url, modified)
        }
        guard !candidates.isEmpty else { return }

        let artworkDir = self.artworkDir
        let artCache = ArtworkKeyCache()
        let width = max(2, ProcessInfo.processInfo.activeProcessorCount)
        typealias Refreshed = (id: UUID, modified: Date, md: ExtractedMetadata, artworkKey: String?)
        let results = await withTaskGroup(of: Refreshed?.self) { group -> [Refreshed] in
            var iterator = candidates.makeIterator()
            var running = 0
            var collected: [Refreshed] = []
            func addNext() {
                guard let next = iterator.next() else { return }
                running += 1
                group.addTask {
                    guard var md = try? await MetadataExtractor.extract(from: next.url) else { return nil }
                    // Artwork re-encoding happens here on the worker, never on the main actor below.
                    let art = md.artworkData ?? MetadataExtractor.sidecarArtwork(for: next.url)
                    md.artworkData = nil
                    return (next.id, next.modified, md, art.flatMap { artCache.key(for: $0, in: artworkDir) })
                }
            }
            for _ in 0..<width { addNext() }
            while let result = await group.next() {
                running -= 1
                if let result { collected.append(result) }
                if !Task.isCancelled { addNext() }
            }
            return collected
        }
        guard !Task.isCancelled, !results.isEmpty else { return }

        var byID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        for (id, modified, md, artworkKey) in results {
            guard var t = byID[id] else { continue }
            t.title = md.title ?? t.title
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
            t.isLossless = md.isLossless
            t.compilation = md.compilation
            t.bpm = md.bpm
            t.hasLyrics = md.hasLyrics
            t.dateModified = modified
            if let artworkKey { t.artworkKey = artworkKey }
            byID[id] = t
        }
        for i in tracks.indices {
            if let updated = byID[tracks[i].id] { tracks[i] = updated }
        }
        scheduleSave()
    }

    func load() {
        guard let data = try? Data(contentsOf: documentURL) else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let doc = try decoder.decode(LibraryDocument.self, from: Self.backfillMissingKeys(in: data) ?? data)
            tracks = doc.tracks
            playlists = doc.playlists
            shows = doc.shows
            deviceRecords = doc.deviceRecords
            photoSelection = doc.photoSelection ?? PhotoSelection()
            audiobooksFolderPath = doc.audiobooksFolderPath
            musicFolderPath = doc.musicFolderPath
        } catch {
            lastError = "Couldn't read the library file: \(error.localizedDescription)"
        }
    }

    /// A Swift default value on a stored property (e.g. `var hasLyrics: Bool = false`) only applies
    /// when constructing the struct in code — it does nothing for Decodable synthesis, which still
    /// requires the key to be present and throws for the whole document otherwise. Fields added to
    /// LibraryTrack/PodcastShow/DeviceSyncRecord after 1.0 shipped would otherwise make any library
    /// saved before that change fail to load at all. This patches the raw JSON to backfill just those
    /// keys (when absent) before decoding, so older library files keep loading as new fields are added.
    private static func backfillMissingKeys(in data: Data) -> Data? {
        guard var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if var tracks = root["tracks"] as? [[String: Any]] {
            for i in tracks.indices where tracks[i]["hasLyrics"] == nil { tracks[i]["hasLyrics"] = false }
            root["tracks"] = tracks
        }
        if var shows = root["shows"] as? [[String: Any]] {
            for i in shows.indices where shows[i]["sourceKind"] == nil { shows[i]["sourceKind"] = "rss" }
            root["shows"] = shows
        }
        if var records = root["deviceRecords"] as? [String: [String: Any]] {
            // [UUID: Date] encodes as a flat array (alternating key, value), not a JSON object — same
            // shape as the other UUID-keyed dictionaries (trackDBIDs, etc.) already in this record.
            for key in records.keys where records[key]?["lyricsFixedDates"] == nil { records[key]?["lyricsFixedDates"] = [Any]() }
            root["deviceRecords"] = records
        }
        return try? JSONSerialization.data(withJSONObject: root)
    }

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        // Safety net: a save that would wipe everything, while the file on disk is clearly not empty,
        // is almost certainly a bug (e.g. a load failed and left this object's in-memory state at its
        // defaults) rather than something a person did — no normal action empties tracks, playlists,
        // shows and device records all at once. Refuse it instead of silently destroying the library.
        if tracks.isEmpty, playlists.isEmpty, shows.isEmpty, deviceRecords.isEmpty {
            let existingSize = (try? documentURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if existingSize > 500 {
                lastError = "Refused to save: the library in memory is empty but the saved file isn't. Restart iPod Pro Max rather than continuing — this usually means the file failed to load."
                return
            }
        }
        let doc = LibraryDocument(tracks: tracks, playlists: playlists, shows: shows, deviceRecords: deviceRecords, photoSelection: photoSelection, audiobooksFolderPath: audiobooksFolderPath, musicFolderPath: musicFolderPath)
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(doc)
            let tmp = documentURL.appendingPathExtension("tmp")
            try data.write(to: tmp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(documentURL, withItemAt: tmp)
        } catch {
            lastError = "Couldn't save the library: \(error.localizedDescription)"
        }
    }

    // MARK: - Artwork

    func artworkURL(for key: String) -> URL {
        artworkDir.appendingPathComponent("\(key).jpg")
    }

    /// Optional variant for views that may have no artwork.
    func artworkURL(_ key: String?) -> URL? {
        key.map { artworkURL(for: $0) }
    }

    /// Stores artwork (re-encoded as JPEG, max 600px) and returns its key. Thread-safe file work is done inline.
    nonisolated static func storeArtwork(_ data: Data, in artworkDir: URL) -> String? {
        guard let image = ImageLoading.cgImage(from: data) else { return nil }
        guard let jpeg = ImageLoading.jpegData(from: image) else { return nil }
        let digest = SHA256.hash(data: jpeg)
        let key = digest.prefix(12).map { String(format: "%02x", $0) }.joined()
        let url = artworkDir.appendingPathComponent("\(key).jpg")
        if !FileManager.default.fileExists(atPath: url.path) {
            try? jpeg.write(to: url, options: .atomic)
        }
        return key
    }

    func storeArtwork(_ data: Data) -> String? {
        Self.storeArtwork(data, in: artworkDir)
    }

    func artworkImage(for key: String?) -> NSImage? {
        guard let key else { return nil }
        return NSImage(contentsOf: artworkURL(for: key))
    }

    // MARK: - Tracks

    var songs: [LibraryTrack] { tracks.filter { !$0.isVideo && !$0.isAudiobook } }
    var videos: [LibraryTrack] { tracks.filter { $0.isVideo } }
    var audiobooks: [LibraryTrack] { tracks.filter { $0.isAudiobook } }

    func track(id: UUID) -> LibraryTrack? { tracks.first { $0.id == id } }

    func updatePhotoSelection(_ sel: PhotoSelection) {
        photoSelection = sel
        scheduleSave()
    }

    func removeTracks(ids: Set<UUID>) {
        tracks.removeAll { ids.contains($0.id) }
        for i in playlists.indices { playlists[i].trackIDs.removeAll { ids.contains($0) } }
        scheduleSave()
    }

    func setSync(_ enabled: Bool, forTracks ids: Set<UUID>) {
        for i in tracks.indices where ids.contains(tracks[i].id) { tracks[i].syncEnabled = enabled }
        scheduleSave()
    }

    func setVideoCategory(_ category: VideoCategory, forTracks ids: Set<UUID>) {
        for i in tracks.indices where ids.contains(tracks[i].id) { tracks[i].videoCategory = category }
        scheduleSave()
    }

    /// Imports audio and video files (folders are searched recursively). Returns the number of items added.
    /// Files under `excludingFolder` are skipped (used to keep the Audiobooks folder out of a music scan).
    @discardableResult
    func importFiles(_ urls: [URL], excludingFolder: String? = nil) async -> Int {
        isImporting = true
        importStatus = "Looking for media files…"
        importProgress = nil
        defer {
            isImporting = false
            importStatus = nil
            importProgress = nil
        }
        let files = await Task.detached(priority: .userInitiated) { Self.collectAudioFiles(urls) }.value
        let existing = Set(tracks.map(\.path))
        let excludedPrefix = excludingFolder.map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        let toImport = files.filter { f in
            !existing.contains(f.path) && !(excludedPrefix.map { f.path.hasPrefix($0) } ?? false)
        }
        guard !toImport.isEmpty else { return 0 }

        var added = 0
        let artworkDir = self.artworkDir
        let artCache = ArtworkKeyCache()
        // Development aid: `-importDelay 2` sleeps before each file to mimic slow cloud storage.
        let importDelay = UserDefaults.standard.double(forKey: "importDelay")
        // Reading tags is mostly AVFoundation parsing plus artwork re-encoding: CPU-bound, so one file
        // per core keeps the machine busy without oversubscribing it. Results are appended to `tracks`
        // in batches — every append re-renders (and regroups) the Music view, which, done per file,
        // cost more than the import itself.
        let width = max(2, ProcessInfo.processInfo.activeProcessorCount)
        var pending: [LibraryTrack] = []
        var done = 0
        var lastFlush = ContinuousClock.now
        importStatus = "Importing \(toImport.count) file\(toImport.count == 1 ? "" : "s")…"
        importProgress = 0
        await withTaskGroup(of: LibraryTrack?.self) { group in
            var iterator = toImport.makeIterator()
            func addNext() {
                guard let url = iterator.next() else { return }
                group.addTask(priority: .userInitiated) {
                    if importDelay > 0 { try? await Task.sleep(for: .seconds(importDelay)) }
                    return await Self.makeTrack(from: url, artworkDir: artworkDir, artCache: artCache)
                }
            }
            for _ in 0..<width { addNext() }
            while let result = await group.next() {
                done += 1
                if let result { pending.append(result) }
                if !Task.isCancelled { addNext() }
                let now = ContinuousClock.now
                if now - lastFlush > .milliseconds(500) {
                    lastFlush = now
                    added += pending.count
                    tracks.append(contentsOf: pending)
                    pending.removeAll(keepingCapacity: true)
                    importStatus = "Importing \(done) of \(toImport.count)…"
                    importProgress = Double(done) / Double(toImport.count)
                    scheduleSave()
                }
            }
        }
        added += pending.count
        tracks.append(contentsOf: pending)
        scheduleSave()
        return added
    }

    /// Reads one media file into a library track, off the main actor. Nil when it can't be read.
    nonisolated private static func makeTrack(from url: URL, artworkDir: URL, artCache: ArtworkKeyCache) async -> LibraryTrack? {
        let attrs = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        if VideoTranscoder.isVideoFile(url) {
            guard let info = try? await VideoTranscoder.info(for: url) else { return nil }
            let md = try? await MetadataExtractor.extract(from: url)
            var t = LibraryTrack(path: url.path, title: md?.title ?? url.deletingPathExtension().lastPathComponent, fileExtension: url.pathExtension.lowercased())
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
            if art == nil { art = await VideoTranscoder.posterFrame(for: url) }
            t.artworkKey = art.flatMap { artCache.key(for: $0, in: artworkDir) }
            return t
        }
        guard let md = try? await MetadataExtractor.extract(from: url) else { return nil }
        var t = LibraryTrack(path: url.path, title: md.title ?? url.deletingPathExtension().lastPathComponent, fileExtension: url.pathExtension.lowercased())
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
        t.artworkKey = art.flatMap { artCache.key(for: $0, in: artworkDir) }
        return t
    }

    nonisolated static func collectAudioFiles(_ urls: [URL]) -> [URL] {
        var out: [URL] = []
        let fm = FileManager.default
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                if let e = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                    for case let f as URL in e where MetadataExtractor.isAudioFile(f) || VideoTranscoder.isVideoFile(f) {
                        out.append(f)
                    }
                }
            } else if MetadataExtractor.isAudioFile(url) || VideoTranscoder.isVideoFile(url) {
                out.append(url)
            }
        }
        return out.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    // MARK: - Library folder

    /// Points the music library at a folder and scans it for files not in the library yet.
    func setMusicFolder(_ url: URL?) async {
        musicFolderPath = url?.path
        scheduleSave()
        if url != nil { await scanLibraryFolders() }
    }

    /// Brings the library up to date with what's on disk: imports files added to the music folder (and
    /// the Audiobooks folder) since the last scan, re-reads tags of files edited elsewhere, and refreshes
    /// which files have gone missing. Never removes anything by itself — a folder on an unplugged drive
    /// looks empty, and treating that as "everything was deleted" would wipe the library.
    /// Returns the number of new songs/videos imported from the music folder, or nil if it couldn't run.
    @discardableResult
    func scanLibraryFolders() async -> Int? {
        guard !isScanningLibrary else { return nil }
        isScanningLibrary = true
        defer { isScanningLibrary = false }

        let fm = FileManager.default
        var isDir: ObjCBool = false
        if let path = audiobooksFolderPath, fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
            await rescanAudiobooks()
        }
        var added: Int?
        if let path = musicFolderPath, fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
            added = await importFiles([URL(fileURLWithPath: path, isDirectory: true)], excludingFolder: audiobooksFolderPath)
        }
        await refreshChangedTrackMetadata()
        await refreshMissingFiles()
        return added
    }

    /// Libraries created before the music folder setting existed have no folder recorded. If every song
    /// lives under one reasonably specific folder (e.g. ~/Music/Music Library — not ~ or ~/Music, which
    /// would sweep in unrelated media), adopt it so launch scans work without any setup.
    func inferMusicFolderIfNeeded() {
        guard musicFolderPath == nil else { return }
        let paths = songs.map(\.path)
        guard paths.count >= 10 else { return }
        var common = (paths[0] as NSString).deletingLastPathComponent.split(separator: "/").map(String.init)
        for p in paths.dropFirst() {
            let parts = (p as NSString).deletingLastPathComponent.split(separator: "/")
            var n = 0
            while n < min(common.count, parts.count), common[n] == parts[n] { n += 1 }
            common.removeLast(common.count - n)
            if common.isEmpty { return }
        }
        let folder = "/" + common.joined(separator: "/")
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let tooBroad = [home, home + "/Music", home + "/Desktop", home + "/Downloads", home + "/Documents"]
        guard common.count >= 3, !tooBroad.contains(folder), !folder.contains("/Music/Music/Media") else { return }
        musicFolderPath = folder
        scheduleSave()
    }

    // MARK: - Audiobooks

    /// Points Audiobooks at a folder and rescans it. Pass nil to clear the folder and remove all audiobooks.
    func setAudiobooksFolder(_ url: URL?) async {
        audiobooksFolderPath = url?.path
        scheduleSave()
        if let url {
            await rescanAudiobooks(folder: url)
        } else {
            tracks.removeAll { $0.isAudiobook }
            scheduleSave()
        }
    }

    func rescanAudiobooks() async {
        guard let path = audiobooksFolderPath else { return }
        await rescanAudiobooks(folder: URL(fileURLWithPath: path, isDirectory: true))
    }

    private func rescanAudiobooks(folder: URL) async {
        isImporting = true
        importStatus = "Scanning audiobooks…"
        importProgress = nil
        defer {
            isImporting = false
            importStatus = nil
            importProgress = nil
        }
        let books = await Task.detached(priority: .userInitiated) { Self.collectAudiobookFiles(folder) }.value
        let existingByPath = Dictionary(tracks.filter(\.isAudiobook).map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        let artworkDir = self.artworkDir
        var kept: [LibraryTrack] = []
        let totalFiles = books.reduce(0) { $0 + $1.files.count }
        var done = 0

        for book in books {
            var bookTracks: [LibraryTrack] = []
            var bookAuthor: String?
            var bookArtworkKey: String?

            for (idx, url) in book.files.enumerated() {
                done += 1
                if let existing = existingByPath[url.path] {
                    if bookAuthor == nil, let a = existing.artist, !a.isEmpty { bookAuthor = a }
                    if bookArtworkKey == nil { bookArtworkKey = existing.artworkKey }
                    bookTracks.append(existing)
                    continue
                }
                importStatus = "Importing \(url.lastPathComponent)"
                importProgress = totalFiles > 0 ? Double(done) / Double(totalFiles) : nil
                let attrs = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                guard let md = try? await MetadataExtractor.extract(from: url) else { continue }
                var t = LibraryTrack(path: url.path, title: md.title ?? url.deletingPathExtension().lastPathComponent, fileExtension: url.pathExtension.lowercased())
                t.kind = .audiobook
                t.album = book.title
                t.genre = "Audiobooks"
                t.trackNumber = book.files.count > 1 ? idx + 1 : max(md.trackNumber, 0)
                t.trackCount = book.files.count > 1 ? book.files.count : max(md.trackCount, 0)
                t.durationMs = md.durationMs
                t.bitrate = md.bitrate
                t.sampleRate = md.sampleRate
                t.fileSize = Int64(attrs?.fileSize ?? 0)
                t.isLossless = md.isLossless
                t.hasLyrics = md.hasLyrics
                t.dateModified = attrs?.contentModificationDate
                let art = md.artworkData ?? MetadataExtractor.sidecarArtwork(for: url)
                t.artworkKey = art.flatMap { Self.storeArtwork($0, in: artworkDir) }
                if bookAuthor == nil, let a = md.albumArtist ?? md.artist, !a.isEmpty { bookAuthor = a }
                if bookArtworkKey == nil { bookArtworkKey = t.artworkKey }
                bookTracks.append(t)
            }

            // Chapter files are often tagged inconsistently (narrator vs. author vs. nothing), which
            // otherwise fragments one book into several "albums" on the iPod. Force every chapter to
            // the same artist/album-artist and the same artwork, so the book groups as a single unit.
            let author = bookAuthor ?? "Unknown Author"
            for i in bookTracks.indices {
                bookTracks[i].artist = author
                bookTracks[i].albumArtist = author
                if bookTracks[i].artworkKey == nil { bookTracks[i].artworkKey = bookArtworkKey }
            }
            kept.append(contentsOf: bookTracks)
        }
        tracks.removeAll { $0.isAudiobook }
        tracks.append(contentsOf: kept)
        scheduleSave()
    }

    /// A subfolder becomes a multi-chapter book (files sorted by name); a loose audio file becomes a
    /// single-chapter book named after itself.
    nonisolated static func collectAudiobookFiles(_ folder: URL) -> [(title: String, files: [URL])] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        var books: [(title: String, files: [URL])] = []
        for entry in entries.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                guard let e = fm.enumerator(at: entry, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
                var files: [URL] = []
                for case let f as URL in e where MetadataExtractor.isAudioFile(f) { files.append(f) }
                guard !files.isEmpty else { continue }
                files.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                books.append((title: entry.lastPathComponent, files: files))
            } else if MetadataExtractor.isAudioFile(entry) {
                books.append((title: entry.deletingPathExtension().lastPathComponent, files: [entry]))
            }
        }
        return books
    }

    /// Loads the Music app catalog off the main thread.
    func loadMusicCatalog() async throws -> MusicAppCatalog {
        try await Task.detached(priority: .userInitiated) { try MusicAppImporter.loadCatalog() }.value
    }

    /// Imports the chosen Music items (and optionally playlists). Returns a summary string.
    func importMusicItems(_ items: [MusicAppItem], playlists: [MusicAppPlaylist]) async -> String {
        isImporting = true
        importStatus = "Importing from Music…"
        importProgress = nil
        defer {
            isImporting = false
            importStatus = nil
        }
        let existingByPID = Dictionary(tracks.compactMap { t -> (String, UUID)? in
            guard let pid = t.musicPersistentID else { return nil }
            return (MusicPID.normalize(pid), t.id)
        }, uniquingKeysWith: { a, _ in a })
        let byPath = Dictionary(tracks.map { ($0.path, $0.id) }, uniquingKeysWith: { a, _ in a })
        var byID = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        // Artwork for the new items.
        let importable = items.filter { $0.status.canImport }
        let wantArt = Set(importable.map(\.id).filter { pid in
            guard let id = existingByPID[pid], let t = byID[id] else { return true }
            return t.artworkKey == nil
        })
        let artworkDir = self.artworkDir
        importStatus = "Copying artwork…"
        let keys: [String: String] = await Task.detached(priority: .userInitiated) {
            let data = MusicAppImporter.artwork(forPersistentIDs: wantArt)
            var d: [String: String] = [:]
            for (pid, bytes) in data {
                if let k = Self.storeArtwork(bytes, in: artworkDir) { d[pid] = k }
            }
            return d
        }.value

        var added = 0, updated = 0
        var order: [UUID] = tracks.map(\.id)
        for m in importable {
            let id = existingByPID[m.id] ?? (m.location.flatMap { byPath[$0.path] }) ?? UUID()
            guard var t = MusicAppImporter.makeTrack(from: m, id: id) else { continue }
            if let old = byID[id] {
                t.syncEnabled = old.syncEnabled
                t.artworkKey = keys[m.id] ?? old.artworkKey
                t.kind = t.kind ?? old.kind
                byID[id] = t
                updated += 1
            } else {
                t.artworkKey = keys[m.id]
                byID[id] = t
                order.append(id)
                added += 1
            }
        }
        tracks = order.compactMap { byID[$0] }

        let pidToID = Dictionary(tracks.compactMap { t -> (String, UUID)? in
            guard let pid = t.musicPersistentID else { return nil }
            return (MusicPID.normalize(pid), t.id)
        }, uniquingKeysWith: { a, _ in a })
        var playlistsAdded = 0
        for pl in playlists {
            let ids = pl.itemIDs.compactMap { pidToID[$0] }
            guard !ids.isEmpty else { continue }
            if let idx = self.playlists.firstIndex(where: { $0.musicPersistentID.map(MusicPID.normalize) == pl.id }) {
                self.playlists[idx].name = pl.name
                self.playlists[idx].trackIDs = ids
            } else {
                var p = LibraryPlaylist(name: pl.name, trackIDs: ids)
                p.musicPersistentID = pl.id
                self.playlists.append(p)
                playlistsAdded += 1
            }
        }
        scheduleSave()
        var parts = ["Added \(added) item\(added == 1 ? "" : "s")"]
        if updated > 0 { parts.append("updated \(updated)") }
        if playlistsAdded > 0 { parts.append("added \(playlistsAdded) playlist\(playlistsAdded == 1 ? "" : "s")") }
        return parts.joined(separator: ", ") + "."
    }

    // MARK: - Playlists

    @discardableResult
    func addPlaylist(name: String, trackIDs: [UUID] = []) -> LibraryPlaylist {
        let pl = LibraryPlaylist(name: name, trackIDs: trackIDs)
        playlists.append(pl)
        scheduleSave()
        return pl
    }

    func renamePlaylist(id: UUID, to name: String) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[i].name = name
        scheduleSave()
    }

    func deletePlaylist(id: UUID) {
        playlists.removeAll { $0.id == id }
        for k in deviceRecords.keys {
            deviceRecords[k]?.selectedPlaylistIDs.remove(id)
        }
        scheduleSave()
    }

    func addTracks(_ ids: [UUID], toPlaylist playlistID: UUID) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        let existing = Set(playlists[i].trackIDs)
        for id in ids where !existing.contains(id) { playlists[i].trackIDs.append(id) }
        scheduleSave()
    }

    func removeTracks(_ ids: Set<UUID>, fromPlaylist playlistID: UUID) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[i].trackIDs.removeAll { ids.contains($0) }
        scheduleSave()
    }

    func moveTracks(in playlistID: UUID, from source: IndexSet, to destination: Int) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        var ids = playlists[i].trackIDs
        let moving = source.sorted().map { ids[$0] }
        let before = ids.enumerated().filter { !source.contains($0.offset) && $0.offset < destination }.map(\.element)
        let after = ids.enumerated().filter { !source.contains($0.offset) && $0.offset >= destination }.map(\.element)
        ids = before + moving + after
        playlists[i].trackIDs = ids
        scheduleSave()
    }

    func tracks(in playlist: LibraryPlaylist) -> [LibraryTrack] {
        let byID = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return playlist.trackIDs.compactMap { byID[$0] }
    }

    // MARK: - Podcasts

    func show(id: UUID) -> PodcastShow? { shows.first { $0.id == id } }

    @discardableResult
    func subscribe(feedURL: URL) async throws -> PodcastShow {
        if let existing = shows.first(where: { $0.feedURL == feedURL }) { return existing }
        let kind = PodcastSourceKind.detect(from: feedURL)
        let feed = try await Self.fetchFeed(feedURL, kind: kind)
        var show = PodcastShow(feedURL: feedURL, title: feed.title, author: feed.author, summary: feed.summary, imageURL: feed.imageURL)
        show.sourceKind = kind
        show.keepLatest = UserDefaults.standard.object(forKey: "defaultKeepLatest") as? Int ?? 5
        show.episodes = feed.episodes.map { Self.makeEpisode($0) }
        show.lastRefreshed = Date()
        if let img = feed.imageURL {
            show.artworkKey = await Self.downloadArtwork(img, into: artworkDir)
        }
        shows.append(show)
        scheduleSave()
        return show
    }

    func unsubscribe(showID: UUID) {
        guard let show = show(id: showID) else { return }
        for id in show.episodes.map(\.id) { activeDownloads[id]?.cancel() }
        try? FileManager.default.removeItem(at: podcastsDir.appendingPathComponent(show.id.uuidString))
        shows.removeAll { $0.id == showID }
        scheduleSave()
    }

    func updateShow(_ show: PodcastShow) {
        guard let i = shows.firstIndex(where: { $0.id == show.id }) else { return }
        shows[i] = show
        scheduleSave()
    }

    func refreshShow(id: UUID) async {
        guard let i = shows.firstIndex(where: { $0.id == id }) else { return }
        refreshingShows.insert(id)
        defer { refreshingShows.remove(id) }
        let url = shows[i].feedURL
        let kind = shows[i].sourceKind
        do {
            let feed = try await Self.fetchFeed(url, kind: kind)
            guard let idx = shows.firstIndex(where: { $0.id == id }) else { return }
            var show = shows[idx]
            show.title = feed.title.isEmpty ? show.title : feed.title
            show.author = feed.author ?? show.author
            show.summary = feed.summary ?? show.summary
            if show.artworkKey == nil, let img = feed.imageURL {
                show.imageURL = img
                show.artworkKey = await Self.downloadArtwork(img, into: artworkDir)
            }
            let existingByGUID = Dictionary(show.episodes.map { ($0.guid, $0) }, uniquingKeysWith: { a, _ in a })
            var merged: [PodcastEpisode] = []
            var seen = Set<String>()
            for parsed in feed.episodes {
                let guid = parsed.guid.isEmpty ? (parsed.enclosureURL?.absoluteString ?? parsed.title) : parsed.guid
                if seen.contains(guid) { continue }
                seen.insert(guid)
                if var old = existingByGUID[guid] {
                    old.title = parsed.title
                    old.summary = parsed.summary ?? old.summary
                    old.publishedAt = parsed.publishedAt ?? old.publishedAt
                    old.durationMs = parsed.durationMs ?? old.durationMs
                    if !old.isDownloaded, let u = parsed.enclosureURL { old.enclosureURL = u }
                    merged.append(old)
                } else {
                    merged.append(Self.makeEpisode(parsed))
                }
            }
            // Keep downloaded episodes that dropped out of the feed.
            for old in show.episodes where !seen.contains(old.guid) && old.isDownloaded {
                merged.append(old)
            }
            show.episodes = merged
            show.lastRefreshed = Date()
            if let idx2 = shows.firstIndex(where: { $0.id == id }) { shows[idx2] = show }
            scheduleSave()
        } catch {
            lastError = "Couldn't refresh \(shows[i].title): \(error.localizedDescription)"
        }
    }

    func refreshAllShows() async {
        for id in shows.map(\.id) {
            await refreshShow(id: id)
        }
    }

    private static func makeEpisode(_ p: ParsedEpisode) -> PodcastEpisode {
        var e = PodcastEpisode(guid: p.guid.isEmpty ? (p.enclosureURL?.absoluteString ?? p.title) : p.guid,
                               title: p.title, enclosureURL: p.enclosureURL ?? URL(string: "about:blank")!)
        e.summary = p.summary
        e.publishedAt = p.publishedAt
        e.durationMs = p.durationMs
        e.enclosureLength = p.enclosureLength
        e.mimeType = p.mimeType
        e.episodeNumber = p.episodeNumber
        e.seasonNumber = p.seasonNumber
        return e
    }

    nonisolated static func fetchFeed(_ url: URL, kind: PodcastSourceKind) async throws -> ParsedFeed {
        switch kind {
        case .rss: return try await fetchRSSFeed(url)
        case .ohdio: return try await OHdioFeed.fetch(url: url)
        case .youtube: return try await YouTubeFeed.fetch(url: url)
        }
    }

    nonisolated static func fetchRSSFeed(_ url: URL) async throws -> ParsedFeed {
        var request = URLRequest(url: url)
        request.setValue("iPod Pro Max/1.0 (Macintosh)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw IPodDBError.io("The feed server returned status \(http.statusCode).")
        }
        return try await Task.detached { try PodcastFeedParser.parse(data: data) }.value
    }

    nonisolated static func downloadArtwork(_ url: URL, into artworkDir: URL) async -> String? {
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return storeArtwork(data, in: artworkDir)
    }

    /// Episodes that the sync rules want but which aren't downloaded yet.
    var pendingEpisodeDownloads: [(show: PodcastShow, episode: PodcastEpisode)] {
        var out: [(PodcastShow, PodcastEpisode)] = []
        for s in shows {
            for e in s.episodesToSync() where !e.isDownloaded && activeDownloads[e.id] == nil {
                out.append((s, e))
            }
        }
        return out
    }

    func downloadPendingEpisodes() async {
        let pending = pendingEpisodeDownloads
        await withTaskGroup(of: Void.self) { group in
            var running = 0
            for (show, ep) in pending {
                if running >= 3 { await group.next(); running -= 1 }
                group.addTask { await self.downloadEpisode(showID: show.id, episodeID: ep.id) }
                running += 1
            }
        }
    }

    func isDownloading(_ episodeID: UUID) -> Bool { activeDownloads[episodeID] != nil }

    func cancelDownload(episodeID: UUID) {
        activeDownloads[episodeID]?.cancel()
        activeDownloads[episodeID] = nil
        downloadProgress[episodeID] = nil
    }

    func downloadEpisode(showID: UUID, episodeID: UUID) async {
        guard let show = show(id: showID), let ep = show.episodes.first(where: { $0.id == episodeID }) else { return }
        if ep.isDownloaded || activeDownloads[episodeID] != nil { return }
        let dir = podcastsDir.appendingPathComponent(show.id.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        downloadProgress[episodeID] = 0

        let task: Task<Void, Never>
        switch show.sourceKind {
        case .youtube:
            let dest = dir.appendingPathComponent("\(ep.id.uuidString).m4a")
            task = Task { [weak self] in
                do {
                    try await YouTubeFeed.downloadAudio(videoID: ep.enclosureURL.lastPathComponent, to: dest) { fraction in
                        Task { @MainActor in self?.downloadProgress[episodeID] = fraction }
                    }
                    await self?.finishEpisodeDownload(showID: showID, episodeID: episodeID, dest: dest)
                } catch {
                    if !(error is CancellationError) {
                        await MainActor.run { self?.lastError = "Download failed for “\(ep.title)”: \(error.localizedDescription)" }
                    }
                }
                await MainActor.run { self?.downloadProgress[episodeID] = nil; self?.activeDownloads[episodeID] = nil }
            }
        case .rss, .ohdio:
            task = Task { [weak self] in
                do {
                    let sourceURL = show.sourceKind == .ohdio ? try await OHdioFeed.resolveMediaURL(from: ep.enclosureURL) : ep.enclosureURL
                    var ext = sourceURL.pathExtension.lowercased()
                    if ext.isEmpty || ext.count > 4 {
                        if let mime = ep.mimeType?.lowercased() {
                            ext = mime.contains("mp4") || mime.contains("m4a") || mime.contains("aac") ? "m4a" : "mp3"
                        } else { ext = "mp3" }
                    }
                    let dest = dir.appendingPathComponent("\(ep.id.uuidString).\(ext)")
                    let delegate = DownloadProgressDelegate { fraction in
                        Task { @MainActor in self?.downloadProgress[episodeID] = fraction }
                    }
                    let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
                    defer { session.finishTasksAndInvalidate() }
                    var request = URLRequest(url: sourceURL)
                    request.setValue("iPod Pro Max/1.0 (Macintosh)", forHTTPHeaderField: "User-Agent")
                    let (tmp, response) = try await session.download(for: request)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        throw IPodDBError.io("Server returned status \(http.statusCode)")
                    }
                    if FileManager.default.fileExists(atPath: dest.path) { try? FileManager.default.removeItem(at: dest) }
                    try FileManager.default.moveItem(at: tmp, to: dest)
                    await self?.finishEpisodeDownload(showID: showID, episodeID: episodeID, dest: dest)
                } catch {
                    if !(error is CancellationError) {
                        await MainActor.run { self?.lastError = "Download failed for “\(ep.title)”: \(error.localizedDescription)" }
                    }
                }
                await MainActor.run { self?.downloadProgress[episodeID] = nil; self?.activeDownloads[episodeID] = nil }
            }
        }
        activeDownloads[episodeID] = task
        await task.value
    }

    private func finishEpisodeDownload(showID: UUID, episodeID: UUID, dest: URL) async {
        let size = (try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) }
        var durationMs: Int? = nil
        if let md = try? await MetadataExtractor.extract(from: dest), md.durationMs > 0 { durationMs = md.durationMs }
        guard let si = shows.firstIndex(where: { $0.id == showID }),
              let ei = shows[si].episodes.firstIndex(where: { $0.id == episodeID }) else { return }
        shows[si].episodes[ei].localPath = dest.path
        shows[si].episodes[ei].fileSize = size
        if let d = durationMs { shows[si].episodes[ei].durationMs = d }
        scheduleSave()
    }

    func deleteDownload(showID: UUID, episodeID: UUID) {
        guard let si = shows.firstIndex(where: { $0.id == showID }), let ei = shows[si].episodes.firstIndex(where: { $0.id == episodeID }) else { return }
        if let p = shows[si].episodes[ei].localPath { try? FileManager.default.removeItem(atPath: p) }
        shows[si].episodes[ei].localPath = nil
        shows[si].episodes[ei].fileSize = nil
        scheduleSave()
    }

    func setEpisodeSync(showID: UUID, episodeID: UUID, override: Bool?) {
        guard let si = shows.firstIndex(where: { $0.id == showID }), let ei = shows[si].episodes.firstIndex(where: { $0.id == episodeID }) else { return }
        shows[si].episodes[ei].syncOverride = override
        scheduleSave()
    }

    func setEpisodePlayed(showID: UUID, episodeID: UUID, played: Bool) {
        guard let si = shows.firstIndex(where: { $0.id == showID }), let ei = shows[si].episodes.firstIndex(where: { $0.id == episodeID }) else { return }
        shows[si].episodes[ei].played = played
        if !played { shows[si].episodes[ei].playbackPositionMs = 0 }
        scheduleSave()
    }

    /// Removes downloads that fall outside the keep rule (called after a sync).
    func pruneOldDownloads() {
        for si in shows.indices {
            let keep = Set(shows[si].episodesToSync().map(\.id))
            for ei in shows[si].episodes.indices where shows[si].episodes[ei].isDownloaded && !keep.contains(shows[si].episodes[ei].id) {
                if let p = shows[si].episodes[ei].localPath { try? FileManager.default.removeItem(atPath: p) }
                shows[si].episodes[ei].localPath = nil
                shows[si].episodes[ei].fileSize = nil
            }
        }
        scheduleSave()
    }

    // MARK: - Device records

    func record(for device: IPodDevice) -> DeviceSyncRecord {
        if let r = deviceRecords[device.id] { return r }
        return DeviceSyncRecord(deviceID: device.id, deviceName: device.volumeName)
    }

    func updateRecord(_ record: DeviceSyncRecord) {
        deviceRecords[record.deviceID] = record
        scheduleSave()
    }

    func forgetDevice(id: String) {
        deviceRecords[id] = nil
        scheduleSave()
    }

    /// Music tracks that a device wants, honoring its "all music" / "selected playlists" choice, plus videos when enabled.
    func tracksToSync(for record: DeviceSyncRecord) -> [LibraryTrack] {
        var out: [LibraryTrack]
        if record.syncAllMusic {
            out = tracks.filter { $0.syncEnabled && !$0.isVideo && !$0.isAudiobook }
        } else {
            var ids = Set<UUID>()
            for pl in playlists where record.selectedPlaylistIDs.contains(pl.id) {
                ids.formUnion(pl.trackIDs)
            }
            out = tracks.filter { ids.contains($0.id) && $0.syncEnabled && !$0.isVideo && !$0.isAudiobook }
        }
        if record.videosEnabled {
            out += tracks.filter { $0.isVideo && $0.syncEnabled }
        }
        if record.audiobooksEnabled {
            out += tracks.filter { $0.isAudiobook && $0.syncEnabled }
        }
        return out
    }

    func playlistsToSync(for record: DeviceSyncRecord) -> [LibraryPlaylist] {
        if record.syncAllMusic { return playlists.filter { $0.syncEnabled } }
        return playlists.filter { record.selectedPlaylistIDs.contains($0.id) }
    }

    /// Applies play statistics read back from an iPod.
    func applyPlayback(trackStats: [UUID: (playCount: Int, lastPlayed: Date?, rating: Int?)],
                       episodeStats: [UUID: (played: Bool, positionMs: Int)]) {
        for (id, s) in trackStats {
            guard let i = tracks.firstIndex(where: { $0.id == id }) else { continue }
            tracks[i].playCount += s.playCount
            if let d = s.lastPlayed, d > (tracks[i].lastPlayed ?? .distantPast) { tracks[i].lastPlayed = d }
            if let r = s.rating, r > 0 { tracks[i].rating = r }
        }
        for (id, s) in episodeStats {
            for si in shows.indices {
                if let ei = shows[si].episodes.firstIndex(where: { $0.id == id }) {
                    if s.played { shows[si].episodes[ei].played = true }
                    shows[si].episodes[ei].playbackPositionMs = s.positionMs
                }
            }
        }
        scheduleSave()
    }
}

/// Reports download progress from URLSession.
final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let onProgress: @Sendable (Double) -> Void
    init(onProgress: @escaping @Sendable (Double) -> Void) { self.onProgress = onProgress }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }
}
