//
//  main.swift
//  ipodpromax
//
//  Command-line iPod Pro Max for macOS, Linux and Windows: find iPods, sync a music folder, eject.
//  Same engine as the app (iPodKit), same media code (MediaKit), same device code (DeviceKit).
//

import Foundation
import iPodKit
import MediaKit
import DeviceKit

let usage = """
ipodpromax — sync a click-wheel iPod from any computer

USAGE
  ipodpromax list                         iPods currently mounted
  ipodpromax info   [--ipod <path>]       model, capacity, database contents
  ipodpromax sync   <folder> [--ipod <path>] [--remove-unknown] [--no-artwork] [--eject] [--verbose]
                                          puts the music, videos and audiobooks of <folder> on the iPod;
                                          later runs only copy what changed
  ipodpromax eject  [--ipod <path>]       unmounts the iPod so it can be unplugged
  ipodpromax watch                        prints iPods as they are plugged in and removed (Ctrl-C to stop)
  ipodpromax tags   <file>…               tags as iPod Pro Max reads them
  ipodpromax init-sim <folder> [--model <number>] [--name <iPod name>]
                                          makes <folder> look like an iPod, for trying things out

  --ipod <path>   the iPod's mount point (/Volumes/IPOD, /run/media/me/IPOD, E:\\) or a folder made by
                  init-sim. Optional when exactly one iPod is mounted.
"""

struct Arguments {
    var positional: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []

    init(_ raw: [String]) {
        var i = 0
        let valued: Set<String> = ["--ipod", "--model", "--name"]
        while i < raw.count {
            let a = raw[i]
            if valued.contains(a), i + 1 < raw.count {
                options[a] = raw[i + 1]
                i += 2
            } else if a.hasPrefix("--") {
                flags.insert(a)
                i += 1
            } else {
                positional.append(a)
                i += 1
            }
        }
    }
}

enum CLIError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let s) = self { return s }
        return nil
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

/// One updating status line on stderr, redrawn at most every 200 ms; silent when stderr isn't a terminal.
final class StatusLine: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast
    private var width = 0
    private let interactive = isatty(2) != 0

    func update(_ text: String, force: Bool = false) {
        guard interactive else { return }
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        guard force || now.timeIntervalSince(last) >= 0.2 else { return }
        last = now
        let line = String(text.prefix(110))
        let pad = max(width - line.count, 0)
        width = line.count
        FileHandle.standardError.write(Data(("\r" + line + String(repeating: " ", count: pad)).utf8))
    }

    func finish() {
        lock.lock(); defer { lock.unlock() }
        if width > 0 { FileHandle.standardError.write(Data(("\r" + String(repeating: " ", count: width) + "\r").utf8)) }
        width = 0
    }
}

func formatBytes(_ n: Int64) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"]
    var v = Double(n), u = 0
    while v >= 1000, u < units.count - 1 { v /= 1000; u += 1 }
    return u == 0 ? "\(n) B" : String(format: "%.1f %@", v, units[u])
}

func supportText(_ level: IPodSupportLevel) -> String {
    switch level {
    case .full: return "supported"
    case .experimental: return "experimental"
    default: return "not supported"
    }
}

/// The mounted iPods, plus the one this tool was started from by LAUNCHER.bat (`IPPM_PORTABLE_ROOT`)
/// when it isn't mounted: `Build/` on the development machine.
func knownIPods() -> [IPodDevice] {
    var devices = DeviceScanner.scan()
    if let root = ProcessInfo.processInfo.environment["IPPM_PORTABLE_ROOT"], !root.isEmpty {
        let url = URL(fileURLWithPath: root, isDirectory: true)
        let path = FileOps.canonicalPath(url)
        if !devices.contains(where: { FileOps.canonicalPath($0.mountPoint) == path }),
           let device = IPodDevice.detect(volume: url, simulated: true) {
            devices.append(device)
        }
    }
    return devices
}

func resolveDevice(_ args: Arguments) -> IPodDevice {
    if let path = args.options["--ipod"] {
        guard let device = DeviceScanner.device(at: URL(fileURLWithPath: path, isDirectory: true)) else {
            fail("no iPod at \(path) (no iPod_Control folder there).")
        }
        return device
    }
    let devices = knownIPods()
    switch devices.count {
    case 0: fail("no iPod found. Plug one in (and wait for it to mount), or pass --ipod <path>.")
    case 1: return devices[0]
    default: fail("several iPods are mounted: pick one with --ipod (\(devices.map { FileOps.nativePath($0.mountPoint) }.joined(separator: ", "))).")
    }
}

func describe(_ d: IPodDevice) -> String {
    let stats = d.volumeStats()
    var parts = [d.displayModelName]
    if let c = d.capacityLabel { parts.append(c) }
    parts.append(supportText(d.supportLevel))
    if stats.total > 0 { parts.append("\(formatBytes(stats.free)) free of \(formatBytes(stats.total))") }
    return "\(d.displayName)  —  \(parts.joined(separator: ", "))\n    \(FileOps.nativePath(d.mountPoint))"
}

// MARK: - Commands

func list() {
    let devices = knownIPods()
    if devices.isEmpty {
        print("No iPod mounted.")
        return
    }
    for d in devices { print(describe(d)) }
}

func info(_ args: Arguments) {
    let d = resolveDevice(args)
    print(describe(d))
    print("    generation: \(d.generation.displayName)")
    if let m = d.modelInfo { print("    model number: \(m.modelNumber)") }
    if let s = d.serialNumber { print("    serial number: \(s)") }
    if let g = d.firewireGUID { print("    FireWire GUID: \(g)") }
    print("    database signature: \(d.checksumType)")
    print("    conversions: \(FFmpeg.binaryPath().map { "ffmpeg at \($0)" } ?? "ffmpeg missing from this copy")")
    print("    artwork: \(d.supportsArtwork ? d.coverArtFormats.map { "\($0.width)×\($0.height)" }.joined(separator: ", ") : "none")")
    do {
        let db = try d.readDatabase()
        let videos = db.tracks.filter { $0.movieFlag != 0 }.count
        let podcasts = db.tracks.filter(\.isPodcast).count
        print("    on the iPod: \(db.tracks.count) tracks (\(videos) videos, \(podcasts) podcast episodes), \(db.playlists.count) playlists")
    } catch {
        print("    database: unreadable (\(error.localizedDescription))")
    }
}

func cacheRoot(for device: IPodDevice) -> URL {
    guard let hostID = HostIdentity.current() else { fail("This computer could not be identified; no local cache was created.") }
    return DeviceDataFolder(mountPoint: device.mountPoint).url.appendingPathComponent("Hosts/\(hostID)/CLI Cache", isDirectory: true)
}

func sync(_ args: Arguments) async {
    guard let folderPath = args.positional.dropFirst().first else { fail("sync needs a folder: ipodpromax sync <folder>") }
    let folder = URL(fileURLWithPath: folderPath, isDirectory: true)
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else { fail("\(folderPath) is not a folder.") }
    let device = resolveDevice(args)
    if device.supportLevel == .unsupported {
        fail("\(device.displayModelName) isn't supported\(device.checksumType == .hash58 && device.firewireGUID == nil ? " (its FireWire GUID couldn't be read, and the database must be signed with it)" : "").")
    }
    let verbose = args.flags.contains("--verbose")
    let status = StatusLine()
    print("iPod: \(describe(device))")

    // 1. Read the folder.
    let cache = cacheRoot(for: device)
    let artworkDir = cache.appendingPathComponent("Artwork", isDirectory: true)
    let started = Date()
    let imported = await FolderImporter.scan(folder: folder, artworkDir: artworkDir) { done, total in
        status.update("Reading \(done) of \(total) files…", force: done == total)
    }
    status.finish()
    print("Read \(imported.tracks.count) files in \(String(format: "%.1f", Date().timeIntervalSince(started))) s" +
          (imported.failed.isEmpty ? "." : " (\(imported.failed.count) unreadable: \(imported.failed.prefix(5).joined(separator: ", "))\(imported.failed.count > 5 ? "…" : "")).")
    )

    // 2. What this tool put on this iPod last time.
    let data = DeviceDataFolder(mountPoint: device.mountPoint)
    let recordName = "cli-sync.json"
    var record = data.read(DeviceSyncRecord.self, from: recordName) ?? DeviceSyncRecord(deviceID: device.id, deviceName: device.displayName)
    record.removeUnknownTracks = args.flags.contains("--remove-unknown")

    var options = SyncOptions()
    options.removeUnknownTracks = record.removeUnknownTracks
    options.writeArtwork = !args.flags.contains("--no-artwork")
    options.syncPodcasts = false
    options.syncPhotos = false
    let request = SyncRequest(device: device, record: record, tracks: imported.tracks, playlists: [], shows: [],
                              artworkDir: artworkDir, transcodeDir: cache.appendingPathComponent("Transcoded", isDirectory: true),
                              photoCacheDir: cache.appendingPathComponent("Photos", isDirectory: true), photoSelection: PhotoSelection(),
                              options: options, media: MediaServices())
    let engine = SyncEngine(request: request) { p in
        var text = p.phase
        if !p.detail.isEmpty { text += ": " + p.detail }
        if let f = p.fraction { text = "[\(String(format: "%3d", Int(f * 100)))%] " + text }
        status.update(text, force: p.phase == "Done")
    }
    do {
        let result = try await engine.run()
        status.finish()
        try data.write(result.record, to: recordName)
        print("Done: \(result.added) added, \(result.removed) removed\(result.kept > 0 ? ", \(result.kept) kept (not from this folder; --remove-unknown removes them)" : ""), \(formatBytes(result.bytesCopied)) copied.")
        for f in result.failed { print("  failed: \(f)") }
        if verbose { for line in result.log { print("  \(line)") } }
    } catch {
        status.finish()
        fail(error.localizedDescription)
    }
    if args.flags.contains("--eject") { await eject(device) }
}

func eject(_ device: IPodDevice) async {
    if device.isSimulated {
        print("\(FileOps.nativePath(device.mountPoint)) is a folder, not a mounted iPod: nothing to eject.")
        return
    }
    do {
        try await Ejector.eject(device)
        print("Ejected \(device.displayName): you can unplug it.")
    } catch {
        fail(error.localizedDescription)
    }
}

func watch() async {
    var known: [String: IPodDevice] = [:]
    func refresh() {
        let now = Dictionary(DeviceScanner.scan().map { ($0.id + "|" + $0.mountPoint.path, $0) }, uniquingKeysWith: { a, _ in a })
        for (k, d) in now where known[k] == nil { print("+ \(describe(d))") }
        for (k, d) in known where now[k] == nil { print("- \(d.displayName) (\(FileOps.nativePath(d.mountPoint)))") }
        known = now
    }
    print("Watching for iPods (Ctrl-C to stop)…")
    refresh()
    if known.isEmpty { print("  none mounted yet") }
    for await _ in VolumeWatcher.changes() { refresh() }
}

func tags(_ args: Arguments) async {
    let files = args.positional.dropFirst()
    guard !files.isEmpty else { fail("tags needs at least one file.") }
    if args.flags.contains("--bench") {
        await bench(folder: URL(fileURLWithPath: files.first!, isDirectory: true))
        return
    }
    for path in files {
        let url = URL(fileURLWithPath: path)
        do {
            let md = args.flags.contains("--portable") ? try PortableTagReader.read(url) : try await MetadataExtractor.extract(from: url)
            print(url.lastPathComponent)
            printMetadata(md)
            #if canImport(AVFoundation)
            if args.flags.contains("--compare") {
                let portable = try PortableTagReader.read(url)
                let differences = compare(md, portable)
                print(differences.isEmpty ? "  portable reader: identical" : "  portable reader differs:\n" + differences.map { "    \($0)" }.joined(separator: "\n"))
            }
            #endif
        } catch {
            print("\(url.lastPathComponent): \(error.localizedDescription)")
        }
    }
}

func printMetadata(_ md: ExtractedMetadata) {
    let fields: [(String, String?)] = [
        ("title", md.title), ("artist", md.artist), ("album", md.album), ("album artist", md.albumArtist),
        ("genre", md.genre), ("composer", md.composer), ("grouping", md.grouping), ("comment", md.comment),
        ("year", md.year > 0 ? "\(md.year)" : nil),
        ("track", md.trackNumber > 0 ? "\(md.trackNumber)\(md.trackCount > 0 ? "/\(md.trackCount)" : "")" : nil),
        ("disc", md.discNumber > 0 ? "\(md.discNumber)\(md.discCount > 0 ? "/\(md.discCount)" : "")" : nil),
        ("duration", String(format: "%d:%02d", md.durationMs / 60000, (md.durationMs / 1000) % 60)),
        ("bitrate", "\(md.bitrate) kbit/s"), ("sample rate", "\(md.sampleRate) Hz"),
        ("lossless", md.isLossless ? "yes" : nil), ("compilation", md.compilation ? "yes" : nil),
        ("bpm", md.bpm > 0 ? "\(md.bpm)" : nil), ("lyrics", md.hasLyrics ? "yes" : nil),
        ("artwork", md.artworkData.map { formatBytes(Int64($0.count)) }),
    ]
    for (k, v) in fields { if let v { print("  \(k): \(v)") } }
}

/// Differences that matter between two readers (durations within half a second, bitrates within 5 %).
func compare(_ a: ExtractedMetadata, _ b: ExtractedMetadata) -> [String] {
    var out: [String] = []
    func check(_ name: String, _ x: String?, _ y: String?) { if (x ?? "") != (y ?? "") { out.append("\(name): \(x ?? "–") vs \(y ?? "–")") } }
    check("title", a.title, b.title); check("artist", a.artist, b.artist); check("album", a.album, b.album)
    check("album artist", a.albumArtist, b.albumArtist); check("genre", a.genre, b.genre); check("composer", a.composer, b.composer)
    check("year", "\(a.year)", "\(b.year)"); check("track", "\(a.trackNumber)/\(a.trackCount)", "\(b.trackNumber)/\(b.trackCount)")
    check("disc", "\(a.discNumber)/\(a.discCount)", "\(b.discNumber)/\(b.discCount)")
    check("compilation", "\(a.compilation)", "\(b.compilation)"); check("lyrics", "\(a.hasLyrics)", "\(b.hasLyrics)")
    check("lossless", "\(a.isLossless)", "\(b.isLossless)"); check("sample rate", "\(a.sampleRate)", "\(b.sampleRate)")
    check("artwork", a.artworkData.map { "\($0.count) bytes" }, b.artworkData.map { "\($0.count) bytes" })
    if abs(a.durationMs - b.durationMs) > 500 { out.append("duration: \(a.durationMs) ms vs \(b.durationMs) ms") }
    if a.bitrate > 0, abs(a.bitrate - b.bitrate) * 20 > a.bitrate { out.append("bitrate: \(a.bitrate) vs \(b.bitrate) kbit/s") }
    return out
}

/// Times the tag reader over a folder, in parallel like an import. On the Mac, also AVFoundation and
/// a field-by-field comparison of the two.
func bench(folder: URL) async {
    let files = FolderImporter.mediaFiles(in: folder).filter { MetadataExtractor.isAudioFile($0) }
    print("\(files.count) audio files")
    func time(_ name: String, _ read: @escaping @Sendable (URL) async -> ExtractedMetadata?) async -> [ExtractedMetadata?] {
        let start = Date()
        var results = [ExtractedMetadata?](repeating: nil, count: files.count)
        await withTaskGroup(of: (Int, ExtractedMetadata?).self) { group in
            var next = 0
            let workers = ProcessInfo.processInfo.activeProcessorCount
            func add() {
                guard next < files.count else { return }
                let i = next
                next += 1
                group.addTask { (i, await read(files[i])) }
            }
            for _ in 0..<workers { add() }
            for await (i, md) in group { results[i] = md; add() }
        }
        let read = results.compactMap { $0 }.count
        print(String(format: "%@: %.2f s, %d read, %d failed", name, Date().timeIntervalSince(start), read, files.count - read))
        return results
    }
    let portable = await time("portable reader") { try? PortableTagReader.read($0) }
    #if canImport(AVFoundation)
    let av = await time("AVFoundation") { try? await MetadataExtractor.extract(from: $0) }
    var differing = 0
    var byField: [String: Int] = [:]
    for i in files.indices {
        guard let a = av[i], let p = portable[i] else { continue }
        let d = compare(a, p)
        if !d.isEmpty {
            differing += 1
            for line in d { byField[String(line.prefix { $0 != ":" }), default: 0] += 1 }
            if differing <= 15 || ProcessInfo.processInfo.environment["IPODPROMAX_BENCH_ALL"] != nil {
                print("  \(files[i].path): \(d.joined(separator: "; "))")
            }
        }
    }
    print("\(differing) of \(files.count) files differ" + (byField.isEmpty ? "" : ": " + byField.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")))
    #else
    _ = portable
    #endif
}

func initSimulated(_ args: Arguments) {
    guard let path = args.positional.dropFirst().first else { fail("init-sim needs a folder.") }
    let folder = URL(fileURLWithPath: path, isDirectory: true)
    do {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try IPodDevice.createSimulatedIPod(at: folder, modelNumber: args.options["--model"] ?? "xA002",
                                           name: args.options["--name"] ?? folder.lastPathComponent)
        print("\(FileOps.nativePath(folder)) is now a simulated iPod. Try: ipodpromax sync <music folder> --ipod \"\(FileOps.nativePath(folder))\"")
    } catch {
        fail(error.localizedDescription)
    }
}

// MARK: - Entry point

let args = Arguments(Array(CommandLine.arguments.dropFirst()))
switch args.positional.first {
case "list": list()
case "info": info(args)
case "sync": await sync(args)
case "eject": await eject(resolveDevice(args))
case "watch": await watch()
case "tags": await tags(args)
case "init-sim": initSimulated(args)
case nil where args.flags.contains("--help") || args.flags.isEmpty: print(usage)
default:
    FileHandle.standardError.write(Data("Unknown command \(args.positional.first ?? "").\n\n".utf8))
    print(usage)
    exit(2)
}
