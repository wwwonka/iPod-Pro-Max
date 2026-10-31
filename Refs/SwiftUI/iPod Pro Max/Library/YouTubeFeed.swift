//
//  YouTubeFeed.swift
//  iPod Pro Max
//
//  Treats a YouTube channel or playlist URL as a podcast: lists its videos as episodes, and extracts
//  audio on download. YouTube has no public API for this, so both steps shell out to yt-dlp (expected
//  to be already installed, e.g. via Homebrew) rather than reimplementing YouTube's private player API
//  — that keeps this file a thin wrapper instead of a second yt-dlp.
//
//  Like OHdio, listing is cheap (metadata only) but doesn't give a downloadable URL up front, so
//  episodes carry a synthetic "ytdlp://video/<id>" enclosure that download time turns into a real file.
//

import Foundation
import iPodKit
import MediaKit
import DeviceKit

enum YouTubeFeed {
    static func isYouTubeURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host.hasSuffix("youtube.com") || host == "youtu.be"
    }

    /// "Signing in" to YouTube means reusing an already-logged-in browser's cookies — YouTube has no
    /// sign-in API for third-party tools. Persisted in Settings › YouTube, so it survives relaunches.
    private static var cookieArguments: [String] {
        let browser = UserDefaults.standard.string(forKey: "youtubeCookiesBrowser") ?? ""
        guard !browser.isEmpty else { return [] }
        return ["--cookies-from-browser", browser]
    }

    static func fetch(url: URL) async throws -> ParsedFeed {
        guard let bin = binaryPath() else { throw Self.missingBinaryError }
        let output = try await run(bin, cookieArguments + ["--dump-json", "--flat-playlist", "--no-warnings", "--ignore-errors", url.absoluteString])
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
            if let upload = obj["upload_date"] as? String { ep.publishedAt = uploadDateFormatter.date(from: upload) }
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

    /// The channel's profile picture (not a video thumbnail), so the "show" art matches what you'd see
    /// on the channel page rather than whatever the most recent upload happens to look like.
    /// `--playlist-items 0` fetches zero videos — just the channel/playlist metadata — so this is cheap.
    private static func channelAvatarURL(url: URL) async -> URL? {
        guard let bin = binaryPath(),
              let output = try? await run(bin, cookieArguments + ["--dump-single-json", "--flat-playlist", "--playlist-items", "0", "--no-warnings", url.absoluteString]),
              let data = output.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let thumbnails = obj["thumbnails"] as? [[String: Any]] else { return nil }
        let avatar = thumbnails.first { ($0["id"] as? String) == "avatar_uncropped" }
            ?? thumbnails.last { ($0["id"] as? String) != "banner_uncropped" && (($0["width"] as? Int) ?? 0) == (($0["height"] as? Int) ?? -1) }
        guard let urlString = avatar?["url"] as? String else { return nil }
        return URL(string: urlString)
    }

    /// Extracts the best available audio track to `dest` (always produced as .m4a).
    static func downloadAudio(videoID: String, to dest: URL, progress: @escaping (Double) -> Void) async throws {
        guard let bin = binaryPath() else { throw Self.missingBinaryError }
        try await runStreaming(bin, cookieArguments + ["-f", "bestaudio", "--extract-audio", "--audio-format", "m4a", "--no-warnings",
                                      "-o", dest.path, "https://www.youtube.com/watch?v=\(videoID)"], progress: progress)
        guard FileManager.default.fileExists(atPath: dest.path) else {
            throw IPodDBError.io("yt-dlp didn't produce an audio file for this video.")
        }
    }

    private static var missingBinaryError: Error {
        IPodDBError.unsupported("YouTube subscriptions need yt-dlp. Install it with “brew install yt-dlp”, then try again.")
    }

    private static let uploadDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd"
        return f
    }()

    private static func binaryPath() -> String? {
        for candidate in ["/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp", "/usr/bin/yt-dlp"] {
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    // MARK: - Process plumbing

    private static func run(_ binary: String, _ arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            process.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                cont.resume(returning: String(data: data, encoding: .utf8) ?? "")
            }
            do { try process.run() } catch { cont.resume(throwing: error) }
        }
    }

    /// Like `run`, but reports fractional progress parsed from yt-dlp's own "NN.N% of" download lines,
    /// and — since yt-dlp's exit code alone is useless — surfaces its actual last output line on failure
    /// (e.g. "Sign in to confirm you're not a bot", age/region restriction, format unavailable) instead
    /// of a bare status number.
    private static func runStreaming(_ binary: String, _ arguments: [String], progress: @escaping (Double) -> Void) async throws {
        try await withCheckedThrowingContinuation { cont in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            final class OutputBox: @unchecked Sendable { var text = "" }
            let box = OutputBox()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                box.text += text
                if let pct = percent(in: text) { progress(pct) }
            }
            process.terminationHandler = { p in
                pipe.fileHandleForReading.readabilityHandler = nil
                if p.terminationStatus == 0 {
                    cont.resume()
                } else {
                    let lastLine = box.text.split(separator: "\r").flatMap { $0.split(separator: "\n") }.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
                    let detail = lastLine.map(String.init) ?? "exited with status \(p.terminationStatus)"
                    cont.resume(throwing: IPodDBError.io("yt-dlp: \(detail)"))
                }
            }
            do { try process.run() } catch { cont.resume(throwing: error) }
        }
    }

    private static func percent(in text: String) -> Double? {
        guard let range = text.range(of: #"\d+\.\d+% of"#, options: .regularExpression) else { return nil }
        let match = text[range]
        guard let percentIndex = match.firstIndex(of: "%") else { return nil }
        return Double(match[match.startIndex..<percentIndex]).map { $0 / 100 }
    }
}
