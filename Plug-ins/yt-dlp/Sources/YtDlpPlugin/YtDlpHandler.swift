import Foundation
#if os(Windows)
import WinSDK
#elseif canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import PluginKit

/// Portable `resolver`, `downloader`, and `action/update` plug-in backed by embedded `yt-dlp`,
/// `deno`, and the host's `ffmpeg` (`YTD-1`…`YTD-7`).
public actor YtDlpHandler: Resolver, Downloader, PluginConfigurable, PluginActionHandling {
    private var context: (any PluginRuntimeContext)?
    private var paths: PluginPaths?
    private var ytDlpURL: URL?
    private var denoURL: URL?
    private var lastKnownVersion: String?

    public init() {}

    // MARK: - PluginConfigurable

    public func initialize(params: PluginInitializeParams, context: any PluginRuntimeContext) async throws {
        self.context = context
        self.paths = params.paths

        let fm = FileManager.default
        try? fm.createDirectory(atPath: params.paths.data, withIntermediateDirectories: true)

        self.ytDlpURL = Self.locateVendorBinary(names: Self.ytDlpCandidatePaths)
        self.denoURL = Self.locateVendorBinary(names: Self.denoCandidatePaths)
        self.lastKnownVersion = Self.readCachedVersion(dataDir: params.paths.data)

        guard let ytDlpURL, fm.isExecutableFile(atPath: ytDlpURL.path) else {
            await context.reportStatus(.error, message: "yt-dlp is missing from the plug-in")
            await context.log(.error, "yt-dlp binary not found in vendor/ directory")
            return
        }

        if let denoURL {
            await context.log(.debug, "Resolved yt-dlp=\(ytDlpURL.path), deno=\(denoURL.path), ffmpeg=\(params.paths.ffmpeg ?? "none")")
        } else {
            await context.log(.warning, "Deno runtime not found in vendor/; falling back to yt-dlp defaults")
        }

        if let ver = lastKnownVersion {
            await context.reportStatus(.ready, message: "yt-dlp \(ver)")
        } else {
            await context.reportStatus(.ready, message: nil)
        }
    }

    public func settingsChanged(_ settings: [String: JSONValue]) async {
        // No mutable settings in v1 besides the `update` action.
    }

    // MARK: - Resolver (`YTD-3`)

    public func search(
        track: TrackRef,
        policy: QualityPolicy,
        onPartialCandidates: @escaping @Sendable ([Candidate]) async -> Void
    ) async throws -> [Candidate] {
        try Task.checkCancellation()

        if ProcessInfo.processInfo.environment["IPPM_PLUGIN_TEST_CANCEL"] == "1" {
            try await Task.sleep(nanoseconds: 5_000_000_000)
        }

        if ProcessInfo.processInfo.environment["IPPM_PLUGIN_OFFLINE"] == "1",
           let offline = Self.loadOfflineResolverCandidates() {
            await onPartialCandidates(offline)
            return offline
        }

        let ytDlp = try requireExecutableYtDlp()
        let artist = Self.primaryArtist(from: track.artists.first ?? "")

        // Direct lookup when the track comes from YouTube Music with an exact video ID.
        if track.source == "youtube-music", !track.sourceID.isEmpty {
            let directURL = (track.isVideo == true)
                ? "https://www.youtube.com/watch?v=\(track.sourceID)"
                : "https://music.youtube.com/watch?v=\(track.sourceID)"
            if let direct = try? await executeSearchQuery(
                ytDlp: ytDlp,
                target: directURL,
                isYTMusic: track.isVideo != true,
                primaryArtist: artist,
                track: track,
                directVideoLookup: true
            ), !direct.isEmpty {
                await onPartialCandidates(direct)
                if track.isVideo == true {
                    return direct
                }
                // For non-video YTMusic tracks, still validate direct match or continue to fallback search if needed.
                if direct.contains(where: { Self.isPlausibleMatch($0, for: track) }) {
                    return direct
                }
            }
        }

        let cleanTitle = Self.cleanSearchText(track.title)
        let combined = [artist, cleanTitle].filter { !$0.isEmpty }.joined(separator: " ")
        let preferVideo = Self.isVideoVersionTrack(track)

        let generalSearch = if !artist.isEmpty && !cleanTitle.isEmpty {
            preferVideo ? "ytsearch5:\"\(artist) \(cleanTitle)\"" : "ytsearch5:\"\(artist) - \(cleanTitle)\""
        } else {
            "ytsearch5:\"\(cleanTitle.isEmpty ? track.title : cleanTitle)\""
        }
        let encodedQuery = combined.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? combined
        let ytMusicURL = "https://music.youtube.com/search?q=\(encodedQuery)"

        if preferVideo {
            // Video-qualified tracks (`Official Video`, `Music Video`, etc.) search general YouTube first
            // so the video audio is preferred over studio `- Topic` album uploads.
            let videoResults = try await executeSearchQuery(
                ytDlp: ytDlp,
                target: generalSearch,
                isYTMusic: false,
                primaryArtist: artist,
                track: track,
                preferVideo: true
            )
            let plausibleVideo = videoResults.filter { Self.isPlausibleMatch($0, for: track) }
            if !plausibleVideo.isEmpty {
                await onPartialCandidates(videoResults)
                return videoResults
            }

            try Task.checkCancellation()

            let ytMusicResults = try await executeSearchQuery(
                ytDlp: ytDlp,
                target: ytMusicURL,
                isYTMusic: true,
                primaryArtist: artist,
                track: track,
                preferVideo: true
            )
            var combinedOut = videoResults
            for c in ytMusicResults where !combinedOut.contains(where: { $0.token == c.token }) {
                combinedOut.append(c)
            }
            if !combinedOut.isEmpty {
                await onPartialCandidates(combinedOut)
            }
            return combinedOut
        }

        // 1. Primary query: YouTube Music search (`- Topic` and album tracks).
        let primaryResults = try await executeSearchQuery(
            ytDlp: ytDlp,
            target: ytMusicURL,
            isYTMusic: true,
            primaryArtist: artist,
            track: track,
            preferVideo: false
        )
        let plausiblePrimary = primaryResults.filter { Self.isPlausibleMatch($0, for: track) }
        if !plausiblePrimary.isEmpty {
            await onPartialCandidates(primaryResults)
            return primaryResults
        }

        try Task.checkCancellation()

        // 2. Fallback query: general YouTube search (`ytsearch5:"<primaryArtist> - <title>"`).
        let fallbackResults = try await executeSearchQuery(
            ytDlp: ytDlp,
            target: generalSearch,
            isYTMusic: false,
            primaryArtist: artist,
            track: track,
            preferVideo: false
        )
        var combinedOut = fallbackResults
        for c in primaryResults where !combinedOut.contains(where: { $0.token == c.token }) {
            combinedOut.append(c)
        }
        if !combinedOut.isEmpty {
            await onPartialCandidates(combinedOut)
        }
        return combinedOut
    }

    private func executeSearchQuery(
        ytDlp: URL,
        target: String,
        isYTMusic: Bool,
        primaryArtist: String,
        track: TrackRef,
        directVideoLookup: Bool = false,
        preferVideo: Bool = false
    ) async throws -> [Candidate] {
        var args = [
            "--dump-json",
            "--no-warnings",
        ]
        if directVideoLookup {
            args.append("--no-playlist")
        } else {
            args += ["--flat-playlist", "--playlist-items", isYTMusic ? "1-10" : "1-5"]
        }
        if let denoURL {
            args += ["--js-runtimes", "deno:\(denoURL.path)"]
        }
        args.append(target)

        let result = try await ProcessRunner.run(executable: ytDlp, arguments: args)
        if result.exitCode != 0 {
            try handleFailureOutput(stdout: result.stdout, stderr: result.stderr, defaultMessage: "yt-dlp search failed.")
        }

        var candidates: [Candidate] = []
        var seenTokens = Set<String>()
        for line in result.stdout.split(whereSeparator: \.isNewline) {
            try Task.checkCancellation()
            guard let data = String(line).data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            guard let candidate = Self.parseSearchEntry(
                json,
                isYTMusic: isYTMusic,
                primaryArtist: primaryArtist,
                fallbackTrack: track,
                preferVideo: preferVideo
            ) else {
                continue
            }
            if seenTokens.insert(candidate.token).inserted {
                candidates.append(candidate)
            }
        }
        return candidates
    }

    // MARK: - Downloader (`YTD-4`, `YTD-5`)

    public func download(
        candidate: Candidate,
        destinationDir: URL,
        onProgress: @escaping @Sendable (PluginProgress) async -> Void
    ) async throws -> URL {
        try Task.checkCancellation()

        let fm = FileManager.default
        try fm.createDirectory(at: destinationDir, withIntermediateDirectories: true)

        if ProcessInfo.processInfo.environment["IPPM_PLUGIN_OFFLINE"] == "1" {
            let sampleURL = destinationDir.appendingPathComponent("offline-sample.m4a")
            // Small silent ISO-BMFF ftyp/moov placeholder file sufficient for offline CLI validation.
            let stub = Data("offline-ytdlp-m4a-fixture".utf8)
            try stub.write(to: sampleURL)
            await onProgress(PluginProgress(done: 100, total: 100, message: "Downloaded"))
            return sampleURL
        }

        let ytDlp = try requireExecutableYtDlp()
        let videoID = Self.extractVideoID(from: candidate.token)
        let outputTemplate = destinationDir.appendingPathComponent("\(videoID).%(ext)s").path
        let finalM4A = destinationDir.appendingPathComponent("\(videoID).m4a")

        do {
            try await runDownloadAttempt(
                ytDlp: ytDlp,
                formatSelector: "bestaudio[ext=m4a]/bestaudio",
                candidateURL: candidate.token,
                outputTemplate: outputTemplate,
                destinationDir: destinationDir,
                videoID: videoID,
                onProgress: onProgress
            )
        } catch let pErr as PluginError where pErr.code == .network || pErr.code == .unsupported {
            // Retry with generic bestaudio (e.g. Opus/WebM -> AAC 256 kbps via ffmpeg) if m4a stream HTTP 403s.
            Self.cleanupPartialFiles(in: destinationDir, prefix: videoID)
            try await runDownloadAttempt(
                ytDlp: ytDlp,
                formatSelector: "bestaudio",
                candidateURL: candidate.token,
                outputTemplate: outputTemplate,
                destinationDir: destinationDir,
                videoID: videoID,
                onProgress: onProgress
            )
        }

        if fm.fileExists(atPath: finalM4A.path) {
            await onProgress(PluginProgress(done: 100, total: 100, message: "Complete"))
            return finalM4A
        }

        // Locate produced audio file even if yt-dlp kept a different m4a casing/suffix.
        if let produced = try? fm.contentsOfDirectory(at: destinationDir, includingPropertiesForKeys: nil)
            .first(where: { $0.deletingPathExtension().lastPathComponent == videoID && !$0.lastPathComponent.hasSuffix(".part") }) {
            await onProgress(PluginProgress(done: 100, total: 100, message: "Complete"))
            return produced
        }

        throw PluginError(code: .network, message: "yt-dlp finished without writing an audio file.")
    }

    private func runDownloadAttempt(
        ytDlp: URL,
        formatSelector: String,
        candidateURL: String,
        outputTemplate: String,
        destinationDir: URL,
        videoID: String,
        onProgress: @escaping @Sendable (PluginProgress) async -> Void
    ) async throws {
        var args = [
            "--no-playlist",
            "--no-part",
            "--no-mtime",
            "--no-embed-thumbnail",
            "--no-warnings",
            "-f", formatSelector,
            "-x",
            "--audio-format", "m4a",
            "--audio-quality", "256K",
            "--newline",
            "--progress-template", "%(progress._percent_str)s",
        ]
        if let ffmpeg = paths?.ffmpeg, !ffmpeg.isEmpty {
            args += ["--ffmpeg-location", ffmpeg]
        }
        if let denoURL {
            args += ["--js-runtimes", "deno:\(denoURL.path)"]
        }
        args += ["-o", outputTemplate, candidateURL]

        do {
            let res = try await ProcessRunner.run(executable: ytDlp, arguments: args) { line in
                if let pct = Self.parseProgressPercent(line) {
                    Task { await onProgress(PluginProgress(done: pct, total: 100, message: "Downloading…")) }
                }
            }
            if res.exitCode != 0 {
                Self.cleanupPartialFiles(in: destinationDir, prefix: videoID)
                try handleFailureOutput(stdout: res.stdout, stderr: res.stderr, defaultMessage: "YouTube download failed.")
            }
        } catch is CancellationError {
            Self.cleanupPartialFiles(in: destinationDir, prefix: videoID)
            throw CancellationError()
        } catch {
            Self.cleanupPartialFiles(in: destinationDir, prefix: videoID)
            throw error
        }
    }

    // MARK: - Self-Update Action (`YTD-6`)

    public func performAction(key: String) async throws -> PluginActionResult {
        guard key == "update" else {
            throw PluginError(code: .unsupported, message: "Unknown action '\(key)'")
        }
        let ytDlp = try requireExecutableYtDlp()

        // Verify writeability before running -U so read-only media reports clearly.
        let parentDir = ytDlp.deletingLastPathComponent()
        if !FileManager.default.isWritableFile(atPath: ytDlp.path) || !FileManager.default.isWritableFile(atPath: parentDir.path) {
            throw PluginError(code: .unsupported, message: "Update failed: the iPod is read-only")
        }

        let beforeVersion = await readBinaryVersion(ytDlp: ytDlp)
        let updateRes = try await ProcessRunner.run(executable: ytDlp, arguments: ["-U"])
        let combined = (updateRes.stdout + "\n" + updateRes.stderr).lowercased()

        if combined.contains("read-only") || combined.contains("permission denied") {
            throw PluginError(code: .unsupported, message: "Update failed: the iPod is read-only")
        }

        if updateRes.exitCode != 0 {
            let reason = Self.extractConciseError(from: updateRes.stderr, fallback: updateRes.stdout)
            throw PluginError(code: .network, message: "Update failed: \(reason)")
        }

        Self.resignMacOSIfNeeded(binaryURL: ytDlp)
        let afterVersion = await readBinaryVersion(ytDlp: ytDlp) ?? beforeVersion

        if let afterVersion, let dataDir = paths?.data {
            Self.saveCachedVersion(afterVersion, dataDir: dataDir)
            self.lastKnownVersion = afterVersion
            await context?.reportStatus(.ready, message: "yt-dlp \(afterVersion)")
        }

        if let beforeVersion, let afterVersion, beforeVersion != afterVersion {
            return PluginActionResult(message: "Updated to \(afterVersion)")
        }
        if combined.contains("up to date") || combined.contains("up-to-date") {
            return PluginActionResult(message: "Already up to date")
        }
        if let afterVersion {
            return PluginActionResult(message: "Already up to date (\(afterVersion))")
        }
        return PluginActionResult(message: "Already up to date")
    }

    private func readBinaryVersion(ytDlp: URL) async -> String? {
        guard let res = try? await ProcessRunner.run(executable: ytDlp, arguments: ["--version"]),
              res.exitCode == 0 else {
            return nil
        }
        let trimmed = res.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Error Classification

    private func requireExecutableYtDlp() throws -> URL {
        guard let ytDlpURL, FileManager.default.isExecutableFile(atPath: ytDlpURL.path) else {
            throw PluginError(code: .unsupported, message: "yt-dlp is missing from the plug-in")
        }
        return ytDlpURL
    }

    private func handleFailureOutput(stdout: String, stderr: String, defaultMessage: String) throws -> Never {
        let full = stderr + "\n" + stdout
        let lower = full.lowercased()

        if lower.contains("sign in to confirm") || lower.contains("not a bot") || lower.contains("http error 429") {
            throw PluginError(
                code: .rateLimited,
                message: "YouTube asked for bot verification — pausing yt-dlp for this sync."
            )
        }

        if lower.contains("unable to extract") || lower.contains("signature extraction failed") || lower.contains("nsig extraction failed") {
            Task { await context?.reportStatus(.error, message: "yt-dlp needs an update") }
            throw PluginError(code: .apiChanged, message: "yt-dlp needs an update")
        }

        if lower.contains("http error 403") {
            throw PluginError(code: .network, message: "HTTP 403 Forbidden from YouTube.")
        }

        if lower.contains("video unavailable") || lower.contains("private video") || lower.contains("removed by the uploader") {
            throw PluginError(code: .notFound, message: "Video is unavailable on YouTube.")
        }

        let concise = Self.extractConciseError(from: stderr, fallback: stdout)
        throw PluginError(code: .network, message: concise.isEmpty ? defaultMessage : concise)
    }

    // MARK: - JSON Parsing & Candidate Mapping

    static func parseSearchEntry(
        _ json: [String: Any],
        isYTMusic: Bool,
        primaryArtist: String,
        fallbackTrack: TrackRef,
        preferVideo: Bool = false
    ) -> Candidate? {
        let ieKey = (json["ie_key"] as? String) ?? ""
        if ieKey == "YoutubeTab" { return nil }
        let entryType = (json["_type"] as? String) ?? ""
        if entryType == "playlist" { return nil }

        guard let id = json["id"] as? String, !id.isEmpty else { return nil }
        let rawTitle = (json["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !rawTitle.isEmpty else { return nil }

        // Skip age-gated / unavailable / upcoming premiere entries
        if let ageLimit = json["age_limit"] as? Int, ageLimit >= 18 { return nil }
        if let availability = (json["availability"] as? String)?.lowercased(),
           ["needs_auth", "subscriber_only", "premium_only", "unavailable"].contains(availability) {
            return nil
        }
        if let liveStatus = (json["live_status"] as? String)?.lowercased(),
           liveStatus == "is_upcoming" {
            return nil
        }

        let videoURL = (json["webpage_url"] as? String)
            ?? (json["url"] as? String).flatMap { $0.hasPrefix("http") ? $0 : nil }
            ?? "https://www.youtube.com/watch?v=\(id)"

        let channel = ((json["channel"] as? String) ?? (json["uploader"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let durationSec = (json["duration"] as? Double) ?? (json["duration"] as? Int).map(Double.init)
        let durationMs = durationSec.map { Int(($0 * 1000.0).rounded()) }

        let (bestContainer, bestBitrate) = extractBestAudioInfo(from: json)

        let displayName = channel.isEmpty ? rawTitle : "\(rawTitle) — \(channel)"
        let hint = computeHint(isYTMusic: isYTMusic, channel: channel, primaryArtist: primaryArtist, preferVideo: preferVideo)

        return Candidate(
            resolver: "yt-dlp",
            token: videoURL,
            displayName: displayName,
            title: rawTitle,
            artist: channel.isEmpty ? nil : channel,
            album: fallbackTrack.album,
            durationMs: durationMs,
            container: bestContainer,
            codec: bestContainer == "opus" ? "opus" : "aac",
            bitrateKbps: bestBitrate,
            availability: Availability(freeSlot: true, queueLength: 0, speedBytesPerSec: 0),
            hint: hint
        )
    }

    private static func extractBestAudioInfo(from json: [String: Any]) -> (container: String, bitrateKbps: Int?) {
        if let abr = (json["abr"] as? Double) ?? (json["abr"] as? Int).map(Double.init), abr > 0 {
            let ext = ((json["ext"] as? String) ?? "m4a").lowercased()
            let container = ext == "webm" ? "webm" : "m4a"
            return (container, Int(abr.rounded()))
        }
        return ("m4a", nil)
    }

    private static func computeHint(isYTMusic: Bool, channel: String, primaryArtist: String, preferVideo: Bool = false) -> Double {
        let lowerChannel = channel.lowercased()
        if preferVideo {
            if lowerChannel.hasSuffix("- topic") {
                return 0.2
            }
            let cleanArtist = primaryArtist.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleanArtist.isEmpty {
                let normalizedChannel = lowerChannel.replacingOccurrences(of: " ", with: "")
                let normalizedArtist = cleanArtist.replacingOccurrences(of: " ", with: "")
                if lowerChannel == cleanArtist || normalizedChannel == "\(normalizedArtist)vevo" || lowerChannel.contains(cleanArtist) {
                    return 0.9
                }
            }
            return isYTMusic ? 0.3 : 0.6
        }
        if isYTMusic || lowerChannel.hasSuffix("- topic") {
            return 0.9
        }
        let cleanArtist = primaryArtist.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanArtist.isEmpty {
            let normalizedChannel = lowerChannel.replacingOccurrences(of: " ", with: "")
            let normalizedArtist = cleanArtist.replacingOccurrences(of: " ", with: "")
            if lowerChannel == cleanArtist || normalizedChannel == "\(normalizedArtist)vevo" || lowerChannel.contains(cleanArtist) {
                return 0.6
            }
        }
        return 0.3
    }

    public static func isVideoVersionTrack(_ track: TrackRef) -> Bool {
        let markers = [
            "official music video",
            "official lyric video",
            "official video",
            "music video",
            "lyric video",
            "video version",
            "clip officiel",
            "official clip",
        ]
        for raw in [track.title, track.album].compactMap({ $0?.lowercased() }) where !raw.isEmpty {
            let collapsed = raw
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            let padded = " " + collapsed + " "
            if markers.contains(where: { padded.contains(" \($0) ") }) {
                return true
            }
            if raw.contains("(video)") || raw.contains("[video]") || raw.contains("(clip)") || raw.contains("[clip]") {
                return true
            }
        }
        return false
    }

    private static func isPlausibleMatch(_ candidate: Candidate, for track: TrackRef) -> Bool {
        if let cMs = candidate.durationMs, let tMs = track.durationMs, cMs > 0, tMs > 0 {
            if abs(cMs - tMs) > 5000 { return false }
        }
        let text = ((candidate.title ?? "") + " " + candidate.displayName).lowercased()
        let forbidden = ["live", "cover", "karaoke", "nightcore", "sped up", "slowed"]
        let refLower = (track.title + " " + (track.album ?? "")).lowercased()
        for word in forbidden where text.contains(word) && !refLower.contains(word) {
            return false
        }
        let titleWords = track.title.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 && $0 != "the" && $0 != "and" }
        guard !titleWords.isEmpty else { return true }
        return titleWords.allSatisfy { text.contains($0) }
    }

    // MARK: - Helpers

    private static func primaryArtist(from raw: String) -> String {
        let lower = raw
        let separators = [",", " feat.", " feat ", " ft.", " ft ", " featuring ", " & ", " x "]
        var earliest = lower.endIndex
        let fold = lower.lowercased()
        for sep in separators {
            if let range = fold.range(of: sep) {
                let offset = fold.distance(from: fold.startIndex, to: range.lowerBound)
                let idx = lower.index(lower.startIndex, offsetBy: offset)
                if idx < earliest { earliest = idx }
            }
        }
        return String(lower[..<earliest]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleanSearchText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\((feat|ft|with)\\.[^)]*\\)", with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "\\[(feat|ft|with)\\.[^\\]]*\\]", with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parseProgressPercent(_ line: String) -> Double? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix("%") else { return nil }
        let numeric = trimmed.dropLast().trimmingCharacters(in: .whitespaces)
        guard let val = Double(numeric), val.isFinite else { return nil }
        return min(max(val, 0), 100)
    }

    private static func extractVideoID(from urlString: String) -> String {
        if let components = URLComponents(string: urlString),
           let v = components.queryItems?.first(where: { $0.name == "v" })?.value,
           !v.isEmpty {
            return sanitizeFilenameComponent(v)
        }
        if let last = URL(string: urlString)?.lastPathComponent, !last.isEmpty, last != "watch" {
            return sanitizeFilenameComponent(last)
        }
        var hasher = SHA256()
        hasher.update(data: Data(urlString.utf8))
        return hasher.finalize().prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    private static func sanitizeFilenameComponent(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        return String(cleaned)
    }

    private static func extractConciseError(from primary: String, fallback: String) -> String {
        let lines = (primary + "\n" + fallback)
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if let errLine = lines.last(where: { $0.hasPrefix("ERROR:") }) {
            return errLine.replacingOccurrences(of: "ERROR:", with: "").trimmingCharacters(in: .whitespaces)
        }
        return lines.last ?? "Unknown error"
    }

    private static func cleanupPartialFiles(in dir: URL, prefix: String) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for item in items where item.lastPathComponent.hasPrefix(prefix) {
            try? fm.removeItem(at: item)
        }
    }

    // MARK: - Vendor Lookup & Version Cache

    private static var ytDlpCandidatePaths: [String] {
        #if os(macOS)
        return ["macos/yt-dlp"]
        #elseif os(Windows)
        return ["windows-x64/yt-dlp.exe", "windows-arm64/yt-dlp.exe"]
        #else
        #if arch(arm64)
        return ["linux-aarch64/yt-dlp"]
        #else
        return ["linux-x86_64/yt-dlp"]
        #endif
        #endif
    }

    private static var denoCandidatePaths: [String] {
        #if os(macOS)
        #if arch(arm64)
        return ["macos-arm64/deno", "macos/deno"]
        #else
        return ["macos-x64/deno", "macos/deno"]
        #endif
        #elseif os(Windows)
        #if arch(arm64)
        return ["windows-arm64/deno.exe", "windows-x64/deno.exe"]
        #else
        return ["windows-x64/deno.exe"]
        #endif
        #else
        #if arch(arm64)
        return ["linux-aarch64/deno"]
        #else
        return ["linux-x86_64/deno"]
        #endif
        #endif
    }

    private static func locateVendorBinary(names: [String]) -> URL? {
        let fm = FileManager.default
        let execURL = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).standardizedFileURL
        let pluginRootFromBin = execURL
            .deletingLastPathComponent() // bin/<os>
            .deletingLastPathComponent() // bin
            .deletingLastPathComponent() // <pluginRoot>
        let cwdURL = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)

        let roots = [
            pluginRootFromBin.appendingPathComponent("vendor", isDirectory: true),
            cwdURL.appendingPathComponent("vendor", isDirectory: true),
            cwdURL.appendingPathComponent("Plug-ins/yt-dlp/vendor", isDirectory: true),
            execURL.deletingLastPathComponent().appendingPathComponent("vendor", isDirectory: true),
        ]

        for root in roots {
            for rel in names {
                let candidate = root.appendingPathComponent(rel)
                if fm.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }
        }
        return nil
    }

    private static func readCachedVersion(dataDir: String) -> String? {
        let file = URL(fileURLWithPath: dataDir, isDirectory: true).appendingPathComponent("ytdlp_version.txt")
        guard let str = try? String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              !str.isEmpty else {
            return nil
        }
        return str
    }

    private static func saveCachedVersion(_ version: String, dataDir: String) {
        let file = URL(fileURLWithPath: dataDir, isDirectory: true).appendingPathComponent("ytdlp_version.txt")
        try? version.write(to: file, atomically: true, encoding: .utf8)
    }

    private static func resignMacOSIfNeeded(binaryURL: URL) {
        #if os(macOS)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        proc.arguments = ["--force", "--sign", "-", binaryURL.path]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        proc.waitUntilExit()
        #endif
    }

    private static func loadOfflineResolverCandidates() -> [Candidate]? {
        guard let path = ProcessInfo.processInfo.environment["IPPM_PLUGIN_FIXTURES"],
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let fixtures = try? JSONDecoder().decode(PluginTestFixtures.self, from: data) else {
            return nil
        }
        return fixtures.resolver?.offlineResponse
    }
}

// MARK: - Cancellation-Safe Subprocess Runner (`YTD-5`)

enum ProcessRunner {
    struct Output: Sendable {
        var exitCode: Int32
        var stdout: String
        var stderr: String
    }

    private final class StateBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stdoutData = Data()
        private var stderrData = Data()
        private var lineBuffer = Data()
        private var process: Process?
        private var cancelled = false

        func setProcess(_ proc: Process) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if cancelled { return false }
            process = proc
            return true
        }

        func appendStdout(_ chunk: Data, onLine: (@Sendable (String) -> Void)?) {
            var completeLines: [String] = []
            lock.lock()
            stdoutData.append(chunk)
            if onLine != nil {
                lineBuffer.append(chunk)
                while let idx = lineBuffer.firstIndex(of: 0x0A) {
                    let slice = lineBuffer[lineBuffer.startIndex..<idx]
                    lineBuffer.removeSubrange(lineBuffer.startIndex...idx)
                    if let s = String(data: slice, encoding: .utf8) {
                        completeLines.append(s.trimmingCharacters(in: CharacterSet(charactersIn: "\r")))
                    }
                }
            }
            lock.unlock()
            if let onLine {
                for line in completeLines where !line.isEmpty {
                    onLine(line)
                }
            }
        }

        func appendStderr(_ chunk: Data) {
            lock.lock()
            stderrData.append(chunk)
            lock.unlock()
        }

        func cancelAndTerminate() {
            lock.lock()
            cancelled = true
            let proc = process
            lock.unlock()
            guard let proc, proc.isRunning else { return }
            proc.terminate()
            #if !os(Windows)
            let pid = proc.processIdentifier
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2.0) {
                if proc.isRunning {
                    kill(pid, SIGKILL)
                }
            }
            #endif
        }

        func snapshot() -> (stdout: String, stderr: String) {
            lock.lock()
            defer { lock.unlock() }
            return (
                String(data: stdoutData, encoding: .utf8) ?? "",
                String(data: stderrData, encoding: .utf8) ?? ""
            )
        }
    }

    static func run(
        executable: URL,
        arguments: [String],
        onStdoutLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> Output {
        try Task.checkCancellation()
        let box = StateBox()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    let proc = Process()
                    proc.executableURL = executable
                    proc.arguments = arguments
                    proc.standardOutput = stdoutPipe
                    proc.standardError = stderrPipe
                    proc.standardInput = FileHandle.nullDevice

                    guard box.setProcess(proc) else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }

                    let group = DispatchGroup()
                    group.enter()
                    DispatchQueue.global(qos: .utility).async {
                        let fh = stdoutPipe.fileHandleForReading
                        while true {
                            let chunk = fh.availableData
                            if chunk.isEmpty { break }
                            box.appendStdout(chunk, onLine: onStdoutLine)
                        }
                        group.leave()
                    }

                    group.enter()
                    DispatchQueue.global(qos: .utility).async {
                        let fh = stderrPipe.fileHandleForReading
                        while true {
                            let chunk = fh.availableData
                            if chunk.isEmpty { break }
                            box.appendStderr(chunk)
                        }
                        group.leave()
                    }

                    do {
                        try proc.run()
                    } catch {
                        try? stdoutPipe.fileHandleForWriting.close()
                        try? stderrPipe.fileHandleForWriting.close()
                        continuation.resume(throwing: error)
                        return
                    }

                    proc.waitUntilExit()
                    group.wait()

                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    let snap = box.snapshot()
                    continuation.resume(returning: Output(
                        exitCode: proc.terminationStatus,
                        stdout: snap.stdout,
                        stderr: snap.stderr
                    ))
                }
            }
        } onCancel: {
            box.cancelAndTerminate()
        }
    }
}
