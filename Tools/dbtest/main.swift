// dbtest: end-to-end check of the sync engine against a simulated iPod folder.
// Build: see Tools/dbtest/run.sh
import Foundation

@main
struct DBTest {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count >= 3 else {
            print("usage: dbtest <samples dir> <ipod folder> [--read-only]")
            exit(1)
        }
        let samples = URL(fileURLWithPath: args[1])
        let ipod = URL(fileURLWithPath: args[2])
        let readOnly = args.contains("--read-only")
        let fm = FileManager.default

        if args.contains("--lyrics") {
            let mp3 = samples.appendingPathComponent("song.mp3")
            print("source ID3 version:", LyricsTagFixup.id3Version(of: mp3) ?? -1)
            let md = try await MetadataExtractor.extract(from: mp3)
            print("hasLyrics detected:", md.hasLyrics, "title:", md.title ?? "-", "artist:", md.artist ?? "-")

            guard let dev = IPodDevice.detect(volume: ipod, simulated: true) ?? { try? IPodDevice.createSimulatedIPod(at: ipod, name: "Test iPod"); return IPodDevice.detect(volume: ipod, simulated: true) }() else { fatalError("no device") }
            let work = ipod.deletingLastPathComponent().appendingPathComponent("dbtest-work")
            let artworkDir = work.appendingPathComponent("Artwork")
            let transcodeDir = work.appendingPathComponent("Transcodes")
            try fm.createDirectory(at: artworkDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: transcodeDir, withIntermediateDirectories: true)

            var t = LibraryTrack(path: mp3.path, title: md.title ?? "song", fileExtension: "mp3")
            t.artist = md.artist
            t.durationMs = md.durationMs
            t.bitrate = md.bitrate
            t.sampleRate = md.sampleRate
            t.fileSize = Int64((try? mp3.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            t.hasLyrics = md.hasLyrics

            let record = DeviceSyncRecord(deviceID: dev.id, deviceName: dev.volumeName)
            let req = SyncRequest(device: dev, record: record, tracks: [t], playlists: [], shows: [], artworkDir: artworkDir, transcodeDir: transcodeDir, photoCacheDir: work.appendingPathComponent("PhotoCache"), photoSelection: PhotoSelection(), options: SyncOptions(syncPhotos: false))
            let engine = SyncEngine(request: req) { p in print("  [\(p.phase)] \(p.detail)") }
            let result = try await engine.run()
            print("Sync: added=\(result.added) failed=\(result.failed) log=\(result.log)")

            let db = try dev.readDatabase()
            for dt in db.tracks {
                guard let url = dt.fileURL(mountPoint: dev.mountPoint) else { continue }
                print("on-device file:", url.lastPathComponent, "ID3 version:", LyricsTagFixup.id3Version(of: url) ?? -1, "lyricsFlag:", dt.lyricsFlag)
            }
            return
        }
        // `dbtest <music folder> <scratch dir> --import-bench`: times a full import of a folder into a
        // fresh, throwaway library (the music files are only read).
        if args.contains("--import-bench") {
            try? fm.removeItem(at: ipod)
            let start = ContinuousClock.now
            let store = await MainActor.run { LibraryStore(baseDir: ipod) }
            let added = await store.importFiles([samples])
            let elapsed = ContinuousClock.now - start
            await MainActor.run { store.saveNow() }
            print("imported \(added) files in \(elapsed.formatted(.units(allowed: [.seconds, .milliseconds]))) using up to \(ProcessInfo.processInfo.activeProcessorCount) cores")
            return
        }
        if args.contains("--migration") {
            let libDir = samples.appendingPathComponent("lib")
            try? FileManager.default.removeItem(at: libDir)
            await MainActor.run {
                // 1. Write a real, fully-populated library.json using the current code.
                let store = LibraryStore(baseDir: libDir)
                var t = LibraryTrack(path: "/tmp/song.mp3", title: "Old Song", fileExtension: "mp3")
                t.hasLyrics = true
                store.tracks = [t]
                var show = PodcastShow(feedURL: URL(string: "https://example.com/feed.xml")!, title: "Old Show")
                show.sourceKind = .rss
                store.shows = [show]
                var record = DeviceSyncRecord(deviceID: "dev1", deviceName: "Old iPod")
                record.lyricsFixedDates = [t.id: Date()]
                store.deviceRecords = ["dev1": record]
                store.saveNow()
            }
            // 2. Strip the fields that didn't exist before this session, simulating an old file.
            let docURL = libDir.appendingPathComponent("library.json")
            var root = try! JSONSerialization.jsonObject(with: Data(contentsOf: docURL)) as! [String: Any]
            var tracks = root["tracks"] as! [[String: Any]]
            tracks[0].removeValue(forKey: "hasLyrics")
            root["tracks"] = tracks
            var shows = root["shows"] as! [[String: Any]]
            shows[0].removeValue(forKey: "sourceKind")
            root["shows"] = shows
            var records = root["deviceRecords"] as! [String: [String: Any]]
            records["dev1"]!.removeValue(forKey: "lyricsFixedDates")
            root["deviceRecords"] = records
            let stripped = try! JSONSerialization.data(withJSONObject: root)
            try! stripped.write(to: docURL)
            print("Wrote old-format file (3 keys stripped).")

            // 3. Load fresh — this is what a real relaunch against an old library.json does.
            await MainActor.run {
                let reloaded = LibraryStore(baseDir: libDir)
                print("tracks:", reloaded.tracks.count, reloaded.tracks.map { "\($0.title) hasLyrics=\($0.hasLyrics)" })
                print("shows:", reloaded.shows.count, reloaded.shows.map { "\($0.title) sourceKind=\($0.sourceKind)" })
                print("deviceRecords:", reloaded.deviceRecords.count, reloaded.deviceRecords.values.map { "\($0.deviceName) fixedDates=\($0.lyricsFixedDates.count)" })
                print("lastError:", reloaded.lastError ?? "none")
            }
            return
        }
        if args.contains("--ohdio") {
            let showURL = URL(string: "https://ici.radio-canada.ca/ohdio/balados/11099/decrypteurs")!
            print("isOHdioURL: \(OHdioFeed.isOHdioURL(showURL))")
            let feed = try await OHdioFeed.fetch(url: showURL)
            print("Show: \(feed.title) by \(feed.author ?? "-") — \(feed.episodes.count) episodes, image=\(feed.imageURL?.absoluteString ?? "none")")
            guard let first = feed.episodes.first, let enclosure = first.enclosureURL else { fatalError("no episodes") }
            print("First episode: \(first.title) dur=\(first.durationMs ?? 0)ms published=\(first.publishedAt?.description ?? "-") marker=\(enclosure)")
            let resolved = try await OHdioFeed.resolveMediaURL(from: enclosure)
            print("Resolved media URL: \(resolved)")
            return
        }
        if args.contains("--youtube") {
            let playlistURL = URL(string: "https://www.youtube.com/watch?v=jNQXAC9IVRw")!
            print("isYouTubeURL: \(YouTubeFeed.isYouTubeURL(playlistURL))")
            let feed = try await YouTubeFeed.fetch(url: playlistURL)
            print("Channel: \(feed.title) — \(feed.episodes.count) episode(s)")
            guard let first = feed.episodes.first, let enclosure = first.enclosureURL else { fatalError("no episodes") }
            print("First: \(first.title) dur=\(first.durationMs ?? 0)ms marker=\(enclosure)")
            let dest = samples.deletingLastPathComponent().appendingPathComponent("ytdlp-test.m4a")
            try await YouTubeFeed.downloadAudio(videoID: enclosure.lastPathComponent, to: dest) { f in print("  progress \(Int(f * 100))%") }
            let size = (try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            print("Downloaded to \(dest.path) (\(size) bytes)")
            try? FileManager.default.removeItem(at: dest)
            return
        }
        if args.contains("--audiobooks") {
            let folder = samples.appendingPathComponent("Audiobooks")
            let books = LibraryStore.collectAudiobookFiles(folder)
            print("Found \(books.count) book(s):")
            for b in books { print("  '\(b.title)': \(b.files.map(\.lastPathComponent))") }

            guard let dev = IPodDevice.detect(volume: ipod, simulated: true) ?? { try? IPodDevice.createSimulatedIPod(at: ipod, name: "Test iPod"); return IPodDevice.detect(volume: ipod, simulated: true) }() else { fatalError("no device") }
            let work = ipod.deletingLastPathComponent().appendingPathComponent("dbtest-work")
            let artworkDir = work.appendingPathComponent("Artwork")
            let transcodeDir = work.appendingPathComponent("Transcodes")
            try fm.createDirectory(at: artworkDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: transcodeDir, withIntermediateDirectories: true)

            var tracks: [LibraryTrack] = []
            for book in books {
                for (idx, url) in book.files.enumerated() {
                    let md = try await MetadataExtractor.extract(from: url)
                    var t = LibraryTrack(path: url.path, title: md.title ?? url.deletingPathExtension().lastPathComponent, fileExtension: url.pathExtension.lowercased())
                    t.kind = .audiobook
                    t.album = book.title
                    t.artist = md.artist ?? "Test Author"
                    t.trackNumber = book.files.count > 1 ? idx + 1 : 0
                    t.trackCount = book.files.count > 1 ? book.files.count : 0
                    t.durationMs = md.durationMs
                    t.bitrate = md.bitrate
                    t.sampleRate = md.sampleRate
                    t.fileSize = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                    print("Audiobook track: book=\(book.title) title=\(t.title) ch=\(t.trackNumber)/\(t.trackCount) dur=\(t.durationMs)ms ext=\(t.fileExtension) needsTranscode=\(t.needsTranscode)")
                    tracks.append(t)
                }
            }

            var record = DeviceSyncRecord(deviceID: dev.id, deviceName: dev.volumeName)
            record.syncAllMusic = true
            let req = SyncRequest(device: dev, record: record, tracks: tracks, playlists: [], shows: [], artworkDir: artworkDir, transcodeDir: transcodeDir, photoCacheDir: work.appendingPathComponent("PhotoCache"), photoSelection: PhotoSelection(), options: SyncOptions(syncPhotos: false))
            let engine = SyncEngine(request: req) { p in print("  [\(p.phase)] \(p.detail)") }
            let result = try await engine.run()
            print("Sync: added=\(result.added) removed=\(result.removed) failed=\(result.failed)")

            let db = try dev.readDatabase()
            for t in db.tracks {
                let isAudiobook = t.mediaType & IPodMediaType.audiobook != 0
                print("  TRACK title=\(t.title ?? "") album=\(t.album ?? "") nr=\(t.trackNumber) media=\(t.mediaType) isAudiobook=\(isAudiobook) rememberPos=\(t.rememberPlaybackPosition) path=\(t.ipodPath)")
            }
            return
        }
        if args.contains("--photos") {
            guard let dev = IPodDevice.detect(volume: ipod, simulated: true) else { fatalError("no device") }
            let images = ["cover1.png", "cover2.png"].map { samples.appendingPathComponent($0) }
            let items = images.map { url -> PhotoItem in
                PhotoItem(key: url.lastPathComponent, jpegURL: url, creationDate: Date(), originalSize: UInt32((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))
            }
            let albums = [PhotoAlbumItem(name: "Holiday", photoKeys: [items[0].key]), PhotoAlbumItem(name: "Both", photoKeys: items.map(\.key))]
            let writer = PhotoDBWriter(mountPoint: ipod, formats: dev.generation.photoFormats)
            let n = try writer.write(photos: items, albums: albums, tzOffset: 0) { _, _ in }
            print("Wrote \(n) photos, formats \(dev.generation.photoFormats.map(\.id))")
            return
        }
        if readOnly {
            let dev = IPodDevice.detect(volume: ipod, simulated: true)!
            let db = try dev.readDatabase()
            dump(db)
            return
        }

        if !fm.fileExists(atPath: ipod.appendingPathComponent("iPod_Control").path) {
            try IPodDevice.createSimulatedIPod(at: ipod, name: "Test iPod")
        }
        guard let device = IPodDevice.detect(volume: ipod, simulated: true) else { fatalError("no device") }
        print("Device: \(device.displayModelName) gen=\(device.generation) checksum=\(device.checksumType) formats=\(device.coverArtFormats.map(\.id))")

        let work = ipod.deletingLastPathComponent().appendingPathComponent("dbtest-work")
        let artworkDir = work.appendingPathComponent("Artwork")
        let transcodeDir = work.appendingPathComponent("Transcodes")
        try fm.createDirectory(at: artworkDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: transcodeDir, withIntermediateDirectories: true)

        var tracks: [LibraryTrack] = []
        for name in ["song1.mp3", "song2.mp3", "song3.m4a", "song4.flac", "song5.wav"] {
            let url = samples.appendingPathComponent(name)
            let md = try await MetadataExtractor.extract(from: url)
            var t = LibraryTrack(path: url.path, title: md.title ?? name, fileExtension: url.pathExtension.lowercased())
            t.artist = md.artist; t.album = md.album; t.albumArtist = md.albumArtist; t.genre = md.genre; t.composer = md.composer
            t.year = md.year; t.trackNumber = md.trackNumber; t.trackCount = md.trackCount; t.discNumber = md.discNumber
            t.durationMs = md.durationMs; t.bitrate = md.bitrate; t.sampleRate = md.sampleRate; t.isLossless = md.isLossless
            t.fileSize = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            t.rating = 4
            if let art = md.artworkData { t.artworkKey = LibraryStore.storeArtwork(art, in: artworkDir) }
            print("Extracted \(name): title=\(t.title) artist=\(t.artist ?? "-") album=\(t.album ?? "-") genre=\(t.genre ?? "-") year=\(t.year) track=\(t.trackNumber)/\(t.trackCount) dur=\(t.durationMs) br=\(t.bitrate) sr=\(t.sampleRate) lossless=\(t.isLossless) art=\(t.artworkKey ?? "none")")
            tracks.append(t)
        }
        for name in ["clip1.mp4", "clip2.mov"] {
            let url = samples.appendingPathComponent(name)
            guard fm.fileExists(atPath: url.path) else { continue }
            let info = try await VideoTranscoder.info(for: url)
            var t = LibraryTrack(path: url.path, title: name, fileExtension: url.pathExtension.lowercased())
            t.kind = .video
            t.videoWidth = info.width; t.videoHeight = info.height; t.durationMs = info.durationMs
            t.fileSize = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            if let poster = await VideoTranscoder.posterFrame(for: url) { t.artworkKey = LibraryStore.storeArtwork(poster, in: artworkDir) }
            print("Video \(name): \(info.width)x\(info.height) \(info.durationMs)ms audio=\(info.hasAudio) poster=\(t.artworkKey ?? "none")")
            tracks.append(t)
        }
        let playlist = LibraryPlaylist(name: "Road Trip", trackIDs: [tracks[0].id, tracks[2].id, tracks[3].id])

        var show = PodcastShow(feedURL: URL(string: "https://example.com/feed.xml")!, title: "Great Show", author: "Podcaster", summary: "A show.")
        show.artworkKey = LibraryStore.storeArtwork(try Data(contentsOf: samples.appendingPathComponent("cover2.png")), in: artworkDir)
        var ep = PodcastEpisode(guid: "ep1", title: "Episode One", enclosureURL: URL(string: "https://example.com/ep1.mp3")!)
        ep.publishedAt = Date(timeIntervalSince1970: 1_700_000_000)
        ep.durationMs = 5000
        ep.localPath = samples.appendingPathComponent("episode1.mp3").path
        ep.summary = "The first episode."
        show.episodes = [ep]

        var record = DeviceSyncRecord(deviceID: device.id, deviceName: device.volumeName)
        record.removeUnknownTracks = args.contains("--remove-unknown")

        func runSync(label: String, tracks: [LibraryTrack], record: DeviceSyncRecord) async throws -> SyncResult {
            let req = SyncRequest(device: device, record: record, tracks: tracks, playlists: [playlist], shows: [show], artworkDir: artworkDir, transcodeDir: transcodeDir, photoCacheDir: work.appendingPathComponent("PhotoCache"), photoSelection: PhotoSelection(), options: SyncOptions(removeUnknownTracks: record.removeUnknownTracks, syncPhotos: false))
            let engine = SyncEngine(request: req) { p in print("  [\(p.phase)] \(p.detail) \(p.fraction.map { String(format: "%.0f%%", $0 * 100) } ?? "")") }
            let r = try await engine.run()
            print("\(label): added=\(r.added) removed=\(r.removed) failed=\(r.failed) log=\(r.log)")
            return r
        }

        let r1 = try await runSync(label: "Sync 1", tracks: tracks, record: record)
        record = r1.record

        // Simulate the iPod writing a Play Counts file for the first two tracks.
        let db1 = try device.readDatabase()
        var w = ByteWriter()
        w.header("mhdp"); w.u32(0x60); w.u32(0x1C); w.u32(UInt32(db1.tracks.count)); w.zeros(0x60 - 16)
        for (i, _) in db1.tracks.enumerated() {
            w.u32(i == 0 ? 3 : 0)  // playcount
            w.u32(i == 0 ? MacTime.fromDate(Date(), tzOffset: db1.tzOffset) : 0)
            w.u32(i == db1.tracks.count - 1 ? 2500 : 0) // bookmark
            w.u32(i == 1 ? 100 : 0) // rating
            w.u32(0); w.u32(0); w.u32(0)
        }
        try w.data.write(to: device.playCountsURL)

        // Second sync: drop one song, everything else should be kept.
        let r2 = try await runSync(label: "Sync 2", tracks: tracks.filter { $0.title != "song5.wav" }, record: record)
        print("Track stats from iPod: \(r2.trackStats)")
        print("Episode stats from iPod: \(r2.episodeStats)")
        record = r2.record

        let db = try device.readDatabase()
        dump(db)
    }

    static func dump(_ db: ITunesDatabase) {
        print("DB name=\(db.name) version=0x\(String(db.version, radix: 16)) tracks=\(db.tracks.count) playlists=\(db.playlists.count)")
        for t in db.tracks {
            print("  TRACK id=\(t.trackID) title=\(t.title ?? "") artist=\(t.artist ?? "") album=\(t.album ?? "") path=\(t.ipodPath) len=\(t.durationMs) size=\(t.fileSize) nr=\(t.trackNumber) year=\(t.year) br=\(t.bitrate) sr=\(t.sampleRate) rating=\(t.rating) pc=\(t.playCount) media=\(t.mediaType) art=\(t.hasArtwork) mhii=\(t.mhiiLink) ft=\(t.filetypeDescription ?? "") bookmark=\(t.bookmarkTimeMs) unplayed=\(t.markUnplayed)")
        }
        for p in db.playlists {
            print("  PLAYLIST \(p.name) master=\(p.isMaster) podcast=\(p.isPodcasts) members=\(p.memberDBIDs.count)")
        }
    }
}
