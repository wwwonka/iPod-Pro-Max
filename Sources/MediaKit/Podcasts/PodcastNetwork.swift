//
//  PodcastNetwork.swift
//  iPod Pro Max
//
//  Fetching and downloading for podcasts, the same code on every OS: plain URLSession tasks (the async
//  URLSession API needs macOS 12), no AppKit. Three kinds of source, as in the former app: a standard RSS
//  feed, Radio-Canada's OHdio and a YouTube channel (through yt-dlp).
//

import Foundation
import iPodKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum PodcastHTTP {
    public static let userAgent = "iPod Pro Max/1.0"

    public static func request(_ url: URL, userAgent: String = userAgent) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        return request
    }

    public static func data(_ request: URLRequest, session: URLSession = .shared) async throws -> Data {
        let box = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                let task = session.dataTask(with: request) { data, response, error in
                    if let error { cont.resume(throwing: error); return }
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        cont.resume(throwing: IPodDBError.io("The server returned status \(http.statusCode)."))
                        return
                    }
                    cont.resume(returning: data ?? Data())
                }
                box.set(task)
                task.resume()
            }
        } onCancel: { box.cancel() }
    }

    /// Downloads to `destination`, reporting 0…1 (no calls when the server sends no length).
    public static func download(_ request: URLRequest, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let box = TaskBox()
        let delegate = DownloadDelegate(destination: destination, progress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                delegate.completion = { cont.resume(with: $0) }
                let task = session.downloadTask(with: request)
                box.set(task)
                task.resume()
            }
        } onCancel: { box.cancel() }
    }

    final class TaskBox: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionTask?
        private var cancelled = false
        func set(_ task: URLSessionTask) {
            lock.lock(); defer { lock.unlock() }
            self.task = task
            if cancelled { task.cancel() }
        }
        func cancel() {
            lock.lock(); defer { lock.unlock() }
            cancelled = true; task?.cancel()
        }
    }

    final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let destination: URL
        let progress: @Sendable (Double) -> Void
        var completion: ((Result<Void, Error>) -> Void)?
        private var moveError: Error?
        init(destination: URL, progress: @escaping @Sendable (Double) -> Void) {
            self.destination = destination; self.progress = progress
        }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            if totalBytesExpectedToWrite > 0 { progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
        }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                moveError = IPodDBError.io("The server returned status \(http.statusCode).")
                return
            }
            // The temporary file is deleted when this returns: move it now.
            do {
                let fm = FileManager.default
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                try fm.moveItem(at: location, to: destination)
            } catch { moveError = error }
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            let result: Result<Void, Error>
            if let error { result = .failure(error) }
            else if let moveError { result = .failure(moveError) }
            else { result = .success(()) }
            completion?(result); completion = nil
        }
    }
}

public enum PodcastSources {
    public static func kind(for url: URL) -> PodcastSourceKind {
        if OHdioFeed.isOHdioURL(url) { return .ohdio }
        if YouTubeFeed.isYouTubeURL(url) { return .youtube }
        return .rss
    }

    public static func fetchFeed(_ url: URL, kind: PodcastSourceKind) async throws -> ParsedFeed {
        switch kind {
        case .rss:
            let data = try await PodcastHTTP.data(PodcastHTTP.request(url))
            return try await Task.detached { try PodcastFeedParser.parse(data: data) }.value
        case .ohdio: return try await OHdioFeed.fetch(url: url)
        case .youtube: return try await YouTubeFeed.fetch(url: url)
        }
    }

    /// A pasted `feed://` link is an ordinary https feed.
    public static func normalizedFeedURL(_ text: String) -> URL? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("feed://") { s = "https://" + s.dropFirst(7) }
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    /// Stores a show's cover in `artworkDir` under a key made of its content, like the library's covers.
    public static func downloadArtwork(_ url: URL, into artworkDir: URL) async -> String? {
        // Re-encoded as a bounded JPEG: covers can be several megabytes, and the list decodes them on screen.
        guard let original = try? await PodcastHTTP.data(PodcastHTTP.request(url)), !original.isEmpty,
              let data = ImageLoading.jpegData(from: original, maxDimension: 300) else { return nil }
        var digest = SHA1()
        digest.update(data: data)
        let key = digest.finalize().prefix(12).map { String(format: "%02x", $0) }.joined()
        let file = artworkDir.appendingPathComponent("\(key).jpg")
        do {
            try FileManager.default.createDirectory(at: artworkDir, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: file.path) { try data.write(to: file, options: .atomic) }
        } catch { return nil }
        return key
    }

    /// Turns a parsed feed into the library's shape; episodes already known keep their state.
    public static func merge(_ feed: ParsedFeed, into show: PodcastShow) -> PodcastShow {
        var show = show
        show.title = feed.title.isEmpty ? show.title : feed.title
        show.author = feed.author ?? show.author
        show.summary = feed.summary ?? show.summary
        if show.imageURL == nil { show.imageURL = feed.imageURL }
        let existing = Dictionary(show.episodes.map { ($0.guid, $0) }, uniquingKeysWith: { a, _ in a })
        var merged: [PodcastEpisode] = []
        var seen = Set<String>()
        for parsed in feed.episodes {
            guard let enclosure = parsed.enclosureURL else { continue }
            let guid = parsed.guid.isEmpty ? enclosure.absoluteString : parsed.guid
            guard seen.insert(guid).inserted else { continue }
            if var old = existing[guid] {
                old.title = parsed.title
                old.summary = parsed.summary ?? old.summary
                old.durationMs = parsed.durationMs ?? old.durationMs
                old.enclosureURL = enclosure
                merged.append(old)
            } else {
                var episode = PodcastEpisode(guid: guid, title: parsed.title, summary: parsed.summary, publishedAt: parsed.publishedAt,
                                             durationMs: parsed.durationMs, enclosureURL: enclosure, enclosureLength: parsed.enclosureLength,
                                             mimeType: parsed.mimeType)
                episode.episodeNumber = parsed.episodeNumber
                episode.seasonNumber = parsed.seasonNumber
                merged.append(episode)
            }
        }
        // A downloaded episode that dropped out of the feed stays until the user deletes it.
        for old in show.episodes where !seen.contains(old.guid) && old.isDownloaded { merged.append(old) }
        show.episodes = merged
        show.lastRefreshed = Date()
        return show
    }

    /// Downloads one episode into `directory` and returns the file. Progress is 0…1.
    public static func download(_ episode: PodcastEpisode, of show: PodcastShow, into directory: URL,
                                progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        switch show.sourceKind {
        case .youtube:
            let destination = directory.appendingPathComponent("\(episode.id.uuidString).m4a")
            try await YouTubeFeed.downloadAudio(videoID: episode.enclosureURL.lastPathComponent, to: destination, progress: progress)
            return destination
        case .rss, .ohdio:
            let source = show.sourceKind == .ohdio ? try await OHdioFeed.resolveMediaURL(from: episode.enclosureURL) : episode.enclosureURL
            var ext = source.pathExtension.lowercased()
            if ext.isEmpty || ext.count > 4 {
                let mime = episode.mimeType?.lowercased() ?? ""
                ext = mime.contains("mp4") || mime.contains("m4a") || mime.contains("aac") ? "m4a" : "mp3"
            }
            let destination = directory.appendingPathComponent("\(episode.id.uuidString).\(ext)")
            var request = PodcastHTTP.request(source)
            request.timeoutInterval = 120
            try await PodcastHTTP.download(request, to: destination, progress: progress)
            return destination
        }
    }
}

// MARK: - OHdio

/// Native client for Radio-Canada's OHdio "balados" (the GraphQL API behind ohdio.radio-canada.ca).
/// Episodes carry a synthetic `ohdio://media/<id>` enclosure, resolved to a CDN URL right before download.
enum OHdioFeed {
    private static let baseURL = "https://services.radio-canada.ca"
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"
    private static let baladoQueryHash = "3b505d1f3b3935981802bccab9c9ee63bbf6c5c55a0b996287fb789e1a90e660"
    private static let maxPages = 20

    static func isOHdioURL(_ url: URL) -> Bool {
        (url.host?.lowercased().hasSuffix("radio-canada.ca") ?? false) && programmeID(from: url) != nil
    }

    static func programmeID(from url: URL) -> Int? {
        let comps = url.pathComponents
        guard let idx = comps.firstIndex(of: "balados"), idx + 1 < comps.count else { return nil }
        return Int(comps[idx + 1])
    }

    static func fetch(url: URL) async throws -> ParsedFeed {
        guard let id = programmeID(from: url) else { throw IPodDBError.io("This doesn't look like an OHdio balado link.") }
        var feed = ParsedFeed()
        var page = 1
        var total = Int.max
        while page <= maxPages, feed.episodes.count < total {
            let data = try await graphQLRequest(id: id, page: page)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let programme = (root["data"] as? [String: Any])?["programmeById"] as? [String: Any] else {
                throw IPodDBError.io("OHdio returned an unexpected response for this show.")
            }
            if page == 1, let header = programme["header"] as? [String: Any] {
                feed.title = header["title"] as? String ?? ""
                feed.author = header["subtitle"] as? String
                feed.summary = (header["summary"] as? String).map(PodcastFeedParser.stripHTML)
                if let pattern = (header["picture"] as? [String: Any])?["pattern"] as? String {
                    feed.imageURL = URL(string: pattern.replacingOccurrences(of: "{width}", with: "600").replacingOccurrences(of: "{ratio}", with: "1x1"))
                }
            }
            guard let detail = (programme["content"] as? [String: Any])?["contentDetail"] as? [String: Any] else { break }
            total = (detail["pagedConfiguration"] as? [String: Any])?["totalNumberOfItems"] as? Int ?? feed.episodes.count
            let items = (detail["items"] as? [[String: Any]]) ?? []
            guard !items.isEmpty else { break }
            feed.episodes += items.compactMap(episode(from:))
            page += 1
        }
        if feed.title.isEmpty { throw IPodDBError.io("This doesn't look like an OHdio balado.") }
        return feed
    }

    static func resolveMediaURL(from synthetic: URL) async throws -> URL {
        var comps = URLComponents(string: "\(baseURL)/media/validation/v2")!
        comps.queryItems = [
            URLQueryItem(name: "appCode", value: "medianet"), URLQueryItem(name: "connectionType", value: "hd"),
            URLQueryItem(name: "deviceType", value: "ipad"), URLQueryItem(name: "idMedia", value: synthetic.lastPathComponent),
            URLQueryItem(name: "multibitrate", value: "true"), URLQueryItem(name: "output", value: "json"),
            URLQueryItem(name: "tech", value: "progressive"),
        ]
        let data = try await PodcastHTTP.data(PodcastHTTP.request(comps.url!, userAgent: userAgent))
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let urlString = obj["url"] as? String, let url = URL(string: urlString) else {
            throw IPodDBError.io("OHdio didn't return a playable stream for this episode.")
        }
        return url
    }

    private static func episode(from item: [String: Any]) -> ParsedEpisode? {
        guard let playlistItemId = item["playlistItemId"] as? [String: Any],
              let mediaId = playlistItemId["mediaId"] as? String,
              let globalId = (playlistItemId["globalId2"] as? [String: Any])?["id"] as? String,
              let title = (item["share"] as? [String: Any])?["title"] as? String else { return nil }
        var ep = ParsedEpisode(guid: globalId, title: title, enclosureURL: URL(string: "ohdio://media/\(mediaId)"))
        ep.summary = (item["summary"] as? String).map(PodcastFeedParser.stripHTML)
        if let seconds = (item["duration"] as? [String: Any])?["durationInSeconds"] as? Int { ep.durationMs = seconds * 1000 }
        if let broadcast = item["broadcastedFirstTimeAt"] as? String { ep.publishedAt = DateParsing.parseISO(String(broadcast.prefix(19))) }
        return ep
    }

    /// The gateway's persisted-query cache is eventually consistent: it sometimes answers
    /// "PersistedQueryNotFound" for a valid hash, so a few retries (on fresh connections) ride over it.
    private static func graphQLRequest(id: Int, page: Int) async throws -> Data {
        let extensions: [String: Any] = ["persistedQuery": ["version": 1, "sha256Hash": baladoQueryHash]]
        let variables: [String: Any] = ["params": ["context": "web", "forceWithoutCueSheet": true, "id": id, "pageNumber": page]]
        var comps = URLComponents(string: "\(baseURL)/bff/audio/graphql")!
        comps.queryItems = [
            URLQueryItem(name: "opname", value: "programmeById"),
            URLQueryItem(name: "extensions", value: try jsonString(extensions)),
            URLQueryItem(name: "variables", value: try jsonString(variables)),
        ]
        var request = PodcastHTTP.request(comps.url!, userAgent: userAgent)
        request.setValue("true", forHTTPHeaderField: "apollo-require-preflight")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let maxAttempts = 10
        for attempt in 1...maxAttempts {
            let session = URLSession(configuration: .ephemeral)
            defer { session.finishTasksAndInvalidate() }
            let data = try await PodcastHTTP.data(request, session: session)
            if let text = String(data: data, encoding: .utf8), text.contains("PersistedQueryNotFound") {
                if attempt < maxAttempts { try await Task.sleep(nanoseconds: UInt64(150_000_000 * attempt)) }
                continue
            }
            return data
        }
        throw IPodDBError.io("OHdio's server didn't recognize this request after several tries. Try again in a moment.")
    }

    private static func jsonString(_ obj: [String: Any]) throws -> String {
        String(data: try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]), encoding: .utf8) ?? "{}"
    }
}

// MARK: - YouTube (yt-dlp)

/// A YouTube channel or playlist as a podcast. Both steps shell out to yt-dlp, found next to the app
/// (`Tools/<OS>/`, like ffmpeg), through `IPODPROMAX_YTDLP`, or on the PATH.
enum YouTubeFeed {
    static func isYouTubeURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host.hasSuffix("youtube.com") || host == "youtu.be"
    }

    static func fetch(url: URL) async throws -> ParsedFeed {
        guard let bin = binaryPath() else { throw missingBinaryError }
        let output = try await run(bin, ["--dump-json", "--flat-playlist", "--no-warnings", "--ignore-errors", url.absoluteString])
        var episodes: [ParsedEpisode] = []
        var channelTitle: String?
        for line in output.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = obj["id"] as? String, let title = obj["title"] as? String else { continue }
            if channelTitle == nil { channelTitle = (obj["playlist_title"] ?? obj["channel"] ?? obj["uploader"]) as? String }
            var ep = ParsedEpisode(guid: id, title: title, enclosureURL: URL(string: "ytdlp://video/\(id)"))
            if let seconds = obj["duration"] as? Double { ep.durationMs = Int(seconds * 1000) }
            else if let seconds = obj["duration"] as? Int { ep.durationMs = seconds * 1000 }
            if let upload = obj["upload_date"] as? String { ep.publishedAt = DateParsing.parseISO(upload.count == 8 ? "\(upload.prefix(4))-\(upload.dropFirst(4).prefix(2))-\(upload.suffix(2))" : upload) }
            if let thumb = (obj["thumbnail"] as? String) ?? ((obj["thumbnails"] as? [[String: Any]])?.last?["url"] as? String) {
                ep.imageURL = URL(string: thumb)
            }
            episodes.append(ep)
        }
        guard !episodes.isEmpty else { throw IPodDBError.io("No videos found at that YouTube link.") }
        var feed = ParsedFeed()
        feed.title = channelTitle ?? "YouTube"
        feed.imageURL = await channelAvatarURL(url: url) ?? episodes.first?.imageURL
        feed.episodes = episodes
        return feed
    }

    private static func channelAvatarURL(url: URL) async -> URL? {
        guard let bin = binaryPath(),
              let output = try? await run(bin, ["--dump-single-json", "--flat-playlist", "--playlist-items", "0", "--no-warnings", url.absoluteString]),
              let data = output.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let thumbnails = obj["thumbnails"] as? [[String: Any]] else { return nil }
        let avatar = thumbnails.first { ($0["id"] as? String) == "avatar_uncropped" }
            ?? thumbnails.last { ($0["id"] as? String) != "banner_uncropped" && (($0["width"] as? Int) ?? 0) == (($0["height"] as? Int) ?? -1) }
        return (avatar?["url"] as? String).flatMap { URL(string: $0) }
    }

    static func downloadAudio(videoID: String, to dest: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let bin = binaryPath() else { throw missingBinaryError }
        try await runStreaming(bin, ["-f", "bestaudio", "--extract-audio", "--audio-format", "m4a", "--no-warnings", "--newline",
                                     "-o", dest.path, "https://www.youtube.com/watch?v=\(videoID)"], progress: progress)
        guard FileManager.default.fileExists(atPath: dest.path) else {
            throw IPodDBError.io("yt-dlp didn't produce an audio file for this video.")
        }
    }

    private static var missingBinaryError: Error {
        IPodDBError.unsupported("YouTube subscriptions need yt-dlp. Put it in the app's Tools folder or install it (for example “brew install yt-dlp”), then try again.")
    }

    static func binaryPath() -> String? {
        let fm = FileManager.default
        #if os(Windows)
        let name = "yt-dlp.exe"; let separator: Character = ";"; let platform = "Windows"
        #elseif os(macOS)
        let name = "yt-dlp"; let separator: Character = ":"; let platform = "macOS"
        #else
        let name = "yt-dlp"; let separator: Character = ":"; let platform = "Linux"
        #endif
        var candidates: [String] = []
        if let explicit = ProcessInfo.processInfo.environment["IPODPROMAX_YTDLP"], !explicit.isEmpty { candidates.append(explicit) }
        let exeURL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments.first ?? "")
        var base = exeURL.resolvingSymlinksInPath().deletingLastPathComponent()
        candidates.append(base.appendingPathComponent(name).path)
        for _ in 0..<3 {
            candidates.append(base.appendingPathComponent("Tools").appendingPathComponent(platform).appendingPathComponent(name).path)
            base = base.deletingLastPathComponent()
        }
        for directory in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: separator) {
            candidates.append(URL(fileURLWithPath: String(directory)).appendingPathComponent(name).path)
        }
        candidates += ["/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp", "/usr/bin/yt-dlp"]
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    private static func run(_ binary: String, _ arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            process.terminationHandler = { _ in
                cont.resume(returning: String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
            }
            do { try process.run() } catch { cont.resume(throwing: error) }
        }
    }

    /// Progress comes from yt-dlp's own "NN.N% of" lines; a failure reports its last output line
    /// (sign-in wall, region lock…) rather than a bare exit status.
    private static func runStreaming(_ binary: String, _ arguments: [String], progress: @escaping @Sendable (Double) -> Void) async throws {
        let box = ProcessBox()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: binary)
                process.arguments = arguments
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                let output = OutputBox()
                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                    output.append(text)
                    if let pct = percent(in: text) { progress(pct) }
                }
                process.terminationHandler = { p in
                    pipe.fileHandleForReading.readabilityHandler = nil
                    if p.terminationStatus == 0 { cont.resume() }
                    else if box.cancelled { cont.resume(throwing: CancellationError()) }
                    else {
                        let last = output.text.split(whereSeparator: { $0 == "\r" || $0 == "\n" }).last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
                        cont.resume(throwing: IPodDBError.io("yt-dlp: \(last.map(String.init) ?? "exited with status \(p.terminationStatus)")"))
                    }
                }
                box.set(process)
                do { try process.run() } catch { cont.resume(throwing: error) }
            }
        } onCancel: { box.cancel() }
    }

    private final class OutputBox: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = ""
        func append(_ s: String) { lock.lock(); buffer += s; lock.unlock() }
        var text: String { lock.lock(); defer { lock.unlock() }; return buffer }
    }

    private final class ProcessBox: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private(set) var cancelled = false
        func set(_ p: Process) { lock.lock(); defer { lock.unlock() }; process = p; if cancelled { p.terminate() } }
        func cancel() { lock.lock(); defer { lock.unlock() }; cancelled = true; process?.terminate() }
    }

    private static func percent(in text: String) -> Double? {
        guard let range = text.range(of: #"\d+\.\d+% of"#, options: .regularExpression) else { return nil }
        let match = text[range]
        guard let index = match.firstIndex(of: "%") else { return nil }
        return Double(match[match.startIndex..<index]).map { $0 / 100 }
    }
}
