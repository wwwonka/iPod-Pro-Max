import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import iPodKit
import PluginKit

/// File placement, path sanitization, verification, tagging, artwork deduplication and lyrics embedding (`SUB-14`, `SUB-15`).
public enum DownloadPlacement {
    public static let maxComponentLength = 120
    public static let maxFileSizeBytes: Int64 = 4 * 1024 * 1024 * 1024

    public enum PlacementError: LocalizedError {
        case emptyOrMissingFile
        case fileTooLarge(Int64)
        case unplayableAudio(String)
        case durationMismatch(expectedMs: Int, actualMs: Int)
        case diskFull(String)

        public var isDiskFull: Bool {
            if case .diskFull = self { return true }
            return false
        }

        public var errorDescription: String? {
            switch self {
            case .emptyOrMissingFile: "Downloaded file was empty or missing"
            case .fileTooLarge: "Downloaded file exceeds 4 GB limit"
            case .unplayableAudio(let detail): "Audio file could not be decoded (\(detail))"
            case .durationMismatch(let expected, let actual):
                "Audio duration mismatch (expected \(expected / 1000)s, got \(actual / 1000)s)"
            case .diskFull(let detail): "Not enough disk space (\(detail))"
            }
        }
    }

    /// Strips characters forbidden on macOS, Windows, or Linux filesystems, clamps each segment to 120 characters,
    /// and prevents empty or reserved `.` / `..` names.
    public static func sanitizeComponent(_ raw: String?, fallback: String = "Unknown") -> String {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        let forbidden: Set<Character> = ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"]
        var cleaned = ""
        cleaned.reserveCapacity(trimmed.count)
        for ch in trimmed {
            if forbidden.contains(ch) || ch.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
                cleaned.append("_")
            } else {
                cleaned.append(ch)
            }
        }
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        if cleaned.isEmpty || cleaned == "." || cleaned == ".." {
            return fallback
        }
        if cleaned.count > maxComponentLength {
            cleaned = String(cleaned.prefix(maxComponentLength)).trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            if cleaned.isEmpty { return fallback }
        }
        return cleaned
    }

    /// Computes destination path `<folder>/<AlbumArtist or Artist>/<Album or "Singles">/<NN> <Title>.<ext>`
    /// (with `<D>-<NN>` for multi-disc releases) and resolves collisions with ` (2)`, ` (3)`, … (`SUB-14`).
    public static func uniqueDestinationURL(for ref: TrackRef, fileExtension ext: String, in rootFolder: URL) -> URL {
        let artistDir = sanitizeComponent(ref.albumArtist ?? ref.artists.first, fallback: "Unknown Artist")
        let albumDir = sanitizeComponent(ref.album, fallback: "Singles")
        let safeExt = ext.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let normalizedExt = safeExt.isEmpty ? "mp3" : safeExt

        let discPrefix = (ref.discNumber ?? 1) > 1 ? "\(ref.discNumber ?? 1)-" : ""
        let trackNumStr: String
        if let n = ref.trackNumber, n > 0 {
            trackNumStr = String(format: "%02d ", n)
        } else {
            trackNumStr = ""
        }
        let maxTitleLen = max(24, maxComponentLength - discPrefix.count - trackNumStr.count - normalizedExt.count - 8)
        var titlePart = sanitizeComponent(ref.title, fallback: "Track")
        if titlePart.count > maxTitleLen {
            titlePart = String(titlePart.prefix(maxTitleLen)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let baseStem = "\(discPrefix)\(trackNumStr)\(titlePart)"
        let parentDir = rootFolder.appendingPathComponent(artistDir, isDirectory: true)
            .appendingPathComponent(albumDir, isDirectory: true)

        let fm = FileManager.default
        var candidate = parentDir.appendingPathComponent("\(baseStem).\(normalizedExt)")
        var suffix = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = parentDir.appendingPathComponent("\(baseStem) (\(suffix)).\(normalizedExt)")
            suffix += 1
        }
        return candidate
    }

    /// Verifies size, decodability, and duration tolerance (±3s or ±5s for yt-dlp) on a `.part` file before
    /// promoting it (`SUB-14`).
    public static func verifyDownloadedPart(
        at partURL: URL,
        fileExtension: String,
        expectedDurationMs: Int,
        isYouTube: Bool
    ) async throws -> (metadata: ExtractedMetadata, fileSize: Int64) {
        let fm = FileManager.default
        let attrs: [FileAttributeKey: Any]
        do {
            attrs = try fm.attributesOfItem(atPath: partURL.path)
        } catch {
            if isOutOfSpaceError(error) { throw PlacementError.diskFull(error.localizedDescription) }
            throw PlacementError.emptyOrMissingFile
        }
        let fileSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        guard fileSize > 0 else { throw PlacementError.emptyOrMissingFile }
        guard fileSize <= maxFileSizeBytes else { throw PlacementError.fileTooLarge(fileSize) }

        // AVFoundation / PortableTagReader inspect the file extension to pick a parser, so create a
        // zero-copy hardlink (or symlink) with the real extension while `.part` stays untouched.
        let cleanExt = fileExtension.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let effectiveExt = cleanExt.isEmpty ? "mp3" : cleanExt
        var probeURL = partURL
        var temporaryProbeURL: URL?
        if partURL.pathExtension.lowercased() == "part" {
            let candidate = partURL.deletingLastPathComponent()
                .appendingPathComponent(".ippm-probe-\(UUID().uuidString).\(effectiveExt)")
            if (try? fm.linkItem(at: partURL, to: candidate)) != nil {
                probeURL = candidate
                temporaryProbeURL = candidate
            } else if (try? fm.createSymbolicLink(at: candidate, withDestinationURL: partURL)) != nil {
                probeURL = candidate
                temporaryProbeURL = candidate
            }
        }
        defer {
            if let temporaryProbeURL { try? fm.removeItem(at: temporaryProbeURL) }
        }

        let md: ExtractedMetadata
        do {
            md = try await MetadataExtractor.extract(from: probeURL)
        } catch {
            throw PlacementError.unplayableAudio(error.localizedDescription)
        }
        guard md.durationMs > 0 else {
            throw PlacementError.unplayableAudio("No decodable audio stream")
        }

        if expectedDurationMs > 0 {
            let tolerance = isYouTube ? 5000 : 3000
            if abs(md.durationMs - expectedDurationMs) > tolerance {
                throw PlacementError.durationMismatch(expectedMs: expectedDurationMs, actualMs: md.durationMs)
            }
        }
        return (md, fileSize)
    }

    /// Tags, embeds album artwork & optional LRCLIB lyrics, moves the verified audio file to its final library path,
    /// and builds the `LibraryTrack` ready for `PortableLibraryCache` (`SUB-14`, `SUB-15`).
    public static func finalizeTrack(
        partURL: URL,
        suggestedExtension: String?,
        ref: TrackRef,
        serviceName: String,
        downloadFolder: URL,
        artworkDir: URL,
        artworkCache: AlbumArtworkCache,
        isYouTube: Bool
    ) async throws -> LibraryTrack {
        let rawExt: String
        if let suggestedExtension, !suggestedExtension.isEmpty {
            rawExt = suggestedExtension.lowercased()
        } else {
            let partStem = partURL.deletingPathExtension()
            let innerExt = partStem.pathExtension.lowercased()
            rawExt = innerExt.isEmpty ? "mp3" : innerExt
        }

        let expectedMs = ref.durationMs ?? 0
        let verified = try await verifyDownloadedPart(
            at: partURL,
            fileExtension: rawExt,
            expectedDurationMs: expectedMs,
            isYouTube: isYouTube
        )

        let destination = uniqueDestinationURL(for: ref, fileExtension: rawExt, in: downloadFolder)
        let parentDir = destination.deletingLastPathComponent()
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
        } catch {
            if isOutOfSpaceError(error) { throw PlacementError.diskFull(error.localizedDescription) }
            throw error
        }

        // Rename `.part` to staged filename in destination folder so FFmpeg / TagWriter recognizes extension
        let stagedURL = parentDir.appendingPathComponent(".ippm-stage-\(UUID().uuidString).\(rawExt)")
        defer { try? fm.removeItem(at: stagedURL) }
        do {
            try fm.moveItem(at: partURL, to: stagedURL)
        } catch {
            if isOutOfSpaceError(error) { throw PlacementError.diskFull(error.localizedDescription) }
            throw error
        }

        let artworkData = await artworkCache.jpegData(for: ref, artworkDir: artworkDir)
        let artistDisplay = ref.artists.isEmpty ? nil : ref.artists.joined(separator: ", ")
        let primaryArtist = ref.artists.first ?? ref.albumArtist ?? ""
        let year = parseYear(from: ref.releaseDate) ?? verified.metadata.year

        var fetchedLyrics: String? = nil
        if !verified.metadata.hasLyrics && !primaryArtist.isEmpty {
            let lrclib = LRCLIBProvider()
            let durationSec = expectedMs > 0 ? expectedMs / 1000 : nil
            let match = try? await lrclib.fetchLyrics(query: LyricsQuery(
                title: ref.title,
                artist: primaryArtist,
                album: ref.album,
                durationSeconds: durationSec
            ))
            fetchedLyrics = match?.syncedLyrics?.nilIfEmpty ?? match?.plainLyrics?.nilIfEmpty
        }

        let sourceComment = "Source: \(serviceName)"
        let trackID = UUID()
        let finalDurationMs = verified.metadata.durationMs > 0 ? verified.metadata.durationMs : expectedMs
        var track = LibraryTrack(
            id: trackID,
            path: stagedURL.path,
            source: .file,
            kind: .song,
            title: ref.title,
            artist: artistDisplay ?? verified.metadata.artist,
            album: ref.album ?? verified.metadata.album,
            albumArtist: ref.albumArtist ?? ref.artists.first ?? verified.metadata.albumArtist,
            genre: verified.metadata.genre,
            composer: verified.metadata.composer,
            comment: sourceComment,
            year: year,
            trackNumber: ref.trackNumber ?? verified.metadata.trackNumber,
            trackCount: verified.metadata.trackCount,
            discNumber: ref.discNumber ?? verified.metadata.discNumber,
            discCount: verified.metadata.discCount,
            durationMs: finalDurationMs,
            bitrate: verified.metadata.bitrate,
            sampleRate: verified.metadata.sampleRate,
            fileSize: verified.fileSize,
            fileExtension: rawExt,
            isLossless: verified.metadata.isLossless,
            compilation: verified.metadata.compilation,
            bpm: verified.metadata.bpm,
            hasLyrics: !(fetchedLyrics ?? "").isEmpty || verified.metadata.hasLyrics,
            dateAdded: Date(),
            artworkKey: artworkData?.key,
            syncEnabled: true,
            lyrics: fetchedLyrics,
            customLyrics: !(fetchedLyrics ?? "").isEmpty ? true : nil,
            isrc: ref.isrc,
            sourcePluginID: ref.source,
            sourceTrackID: ref.sourceID
        )

        // Write clean tags (stripping prior non-technical downloader junk while keeping ReplayGain).
        // Some containers (e.g. wav/ogg without bundled encoder support) might decline attached_pic; ignore
        // tagging errors only if audio itself stays intact, while surfacing disk-full immediately.
        do {
            try await TagWriter.writeTags(
                for: track,
                customArtworkData: artworkData?.jpegBytes,
                isrc: ref.isrc,
                stripExistingNonTechnical: true
            )
        } catch {
            if isOutOfSpaceError(error) { throw PlacementError.diskFull(error.localizedDescription) }
        }

        do {
            try fm.moveItem(at: stagedURL, to: destination)
        } catch {
            if isOutOfSpaceError(error) { throw PlacementError.diskFull(error.localizedDescription) }
            throw error
        }

        let finalAttrs = try? fm.attributesOfItem(atPath: destination.path)
        track.path = destination.path
        track.fileSize = (finalAttrs?[.size] as? NSNumber)?.int64Value ?? verified.fileSize
        track.dateModified = finalAttrs?[.modificationDate] as? Date
        return track
    }

    private static func parseYear(from raw: String?) -> Int? {
        guard let raw, raw.count >= 4 else { return nil }
        return Int(raw.prefix(4))
    }

    public static func isOutOfSpaceError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError { return true }
        if ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOSPC) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error {
            return isOutOfSpaceError(underlying)
        }
        return false
    }
}

private extension String {
    var nilIfEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

/// Fetches and JPEG-encodes (max 600 px) album covers at most once per unique artwork URL / album (`SUB-15`).
public actor AlbumArtworkCache {
    public struct CachedArtwork: Sendable {
        public var key: String
        public var jpegBytes: Data
    }

    private var entries: [String: CachedArtwork] = [:]
    private var inFlight: [String: Task<CachedArtwork?, Never>] = [:]
    private let artworkDirURL: URL?

    public init(artworkDir: URL? = nil) {
        self.artworkDirURL = artworkDir
    }

    public func jpegData(for ref: TrackRef, artworkDir: URL) async -> CachedArtwork? {
        await jpegData(for: ref.artworkURL, artworkDir: artworkDir)
    }

    public func jpegData(for url: URL?, artworkDir: URL) async -> CachedArtwork? {
        guard let url else {
            return nil
        }
        let cacheKey = url.absoluteString
        if let cached = entries[cacheKey] {
            return cached
        }
        if let existing = inFlight[cacheKey] {
            return await existing.value
        }

        let targetDir = artworkDirURL ?? artworkDir
        let task = Task<CachedArtwork?, Never> {
            guard ["http", "https"].contains((url.scheme ?? "").lowercased()) || url.isFileURL else {
                return nil
            }
            let rawData: Data?
            if url.isFileURL {
                rawData = try? Data(contentsOf: url)
            } else {
                var request = URLRequest(url: url)
                request.timeoutInterval = 10
                rawData = try? await URLSession.shared.portableData(for: request).0
            }
            guard let rawData, !rawData.isEmpty,
                  let jpeg = ImageLoading.jpegData(from: rawData, maxDimension: 600, quality: 0.85) else {
                return nil
            }
            try? FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
            let store = ArtworkStore(directory: targetDir)
            guard let key = store.key(for: jpeg) else { return nil }
            return CachedArtwork(key: key, jpegBytes: jpeg)
        }
        inFlight[cacheKey] = task
        let result = await task.value
        inFlight[cacheKey] = nil
        if let result {
            entries[cacheKey] = result
        }
        return result
    }
}
