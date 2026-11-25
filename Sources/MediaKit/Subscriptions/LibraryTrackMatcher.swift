import Foundation
import iPodKit
import PluginKit

/// Shared title and artist normalization for local library matching (`SUB-10`) and candidate scoring (`SUB-11`).
public enum TrackTextNormalizer {
    private static let noiseBrackets: [String] = [
        "official video",
        "official music video",
        "official audio",
        "official lyric video",
        "lyric video",
        "lyrics",
        "audio",
        "video",
        "explicit",
        "clean",
        "hd",
        "hq",
        "4k",
        "visualizer",
        "official visualizer",
    ]

    /// Qualifiers that explicitly designate a video version rather than studio/album audio.
    private static let explicitVideoPhrases: [String] = [
        "official music video",
        "official lyric video",
        "official video",
        "music video",
        "lyric video",
        "video version",
        "clip officiel",
        "official clip",
    ]

    /// True when a track title/album explicitly asks for a music/lyric/official video version
    /// rather than a studio album track.
    public static func hasVideoVersionQualifier(title: String, album: String? = nil) -> Bool {
        let texts = [title, album].compactMap { $0 }.map(foldAndLowercase)
        for raw in texts where !raw.isEmpty {
            let collapsed = collapseWhitespaceAndPunctuation(raw)
            let padded = " " + collapsed + " "
            if explicitVideoPhrases.contains(where: { padded.contains(" \($0) ") }) {
                return true
            }
            // Match standalone `(video)` / `[video]` or trailing `- video` markers cleanly.
            var i = raw.startIndex
            while i < raw.endIndex {
                let ch = raw[i]
                if ch == "(" || ch == "[" {
                    let close: Character = ch == "(" ? ")" : "]"
                    if let end = raw[raw.index(after: i)...].firstIndex(of: close) {
                        let inner = collapseWhitespaceAndPunctuation(String(raw[raw.index(after: i)..<end]))
                        if inner == "video" || inner == "clip" || inner.contains("music video") || inner.contains("lyric video") {
                            return true
                        }
                        i = raw.index(after: end)
                        continue
                    }
                }
                i = raw.index(after: i)
            }
        }
        return false
    }

    /// Normalizes a track title for matching, stripping upload noise (`(Official Video)`,
    /// `[Explicit]`, `(Remastered 2021)`, etc.) while keeping remix / live / acoustic qualifiers.
    public static func normalizeTitle(_ raw: String) -> String {
        var text = foldAndLowercase(raw)
        // Strip trailing bracketed/parenthesized noise unless it describes a musical variant.
        text = stripNoiseParentheticals(in: text)
        // Strip "- Remastered YYYY" or "- YYYY Remaster" suffixes
        text = stripTrailingRemasterSuffix(in: text)
        return collapseWhitespaceAndPunctuation(text)
    }

    /// Normalizes a single artist name: folds case/diacritics, removes leading "The ".
    public static func normalizeSingleArtist(_ raw: String) -> String {
        var s = collapseWhitespaceAndPunctuation(foldAndLowercase(raw))
        if s.hasPrefix("the ") {
            s = String(s.dropFirst(4))
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Splits an artist string into normalized primary & collaborator names.
    public static func artistComponents(_ raw: String) -> [String] {
        var s = foldAndLowercase(raw)
        let separators = [
            " featuring ", " feat. ", " feat ", " ft. ", " ft ",
            " with ", " & ", " x ", " vs. ", " vs ", ",", ";", "/"
        ]
        for sep in separators {
            s = s.replacingOccurrences(of: sep, with: "\n")
        }
        let parts = s.split(separator: "\n")
            .map { normalizeSingleArtist(String($0)) }
            .filter { !$0.isEmpty }
        var seen = Set<String>()
        return parts.filter { seen.insert($0).inserted }
    }

    /// Normalized album name for secondary matching (`SUB-10`).
    public static func normalizeAlbum(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "" }
        var text = foldAndLowercase(raw)
        text = stripNoiseParentheticals(in: text, stripDeluxe: true)
        return collapseWhitespaceAndPunctuation(text)
    }

    /// Meaningful words (>= 3 chars, excluding "the" and "and") used by candidate rejection (`SUB-11`).
    public static func significantWords(in rawTitle: String) -> [String] {
        let normalized = normalizeTitle(rawTitle)
        let stop: Set<String> = ["the", "and"]
        return normalized.split(separator: " ")
            .map(String.init)
            .filter { $0.count >= 3 && !stop.contains($0) }
    }

    /// Words tokenized across the raw lowercase folded text (punctuation replaced by spaces).
    public static func rawWords(in raw: String) -> [String] {
        collapseWhitespaceAndPunctuation(foldAndLowercase(raw))
            .split(separator: " ")
            .map(String.init)
    }

    public static func foldAndLowercase(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
    }

    private static func stripNoiseParentheticals(in s: String, stripDeluxe: Bool = false) -> String {
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            let ch = s[i]
            if ch == "(" || ch == "[" {
                let close: Character = ch == "(" ? ")" : "]"
                if let end = s[s.index(after: i)...].firstIndex(of: close) {
                    let inner = collapseWhitespaceAndPunctuation(String(s[s.index(after: i)..<end]))
                    if isUploadNoise(inner, stripDeluxe: stripDeluxe) {
                        i = s.index(after: end)
                        continue
                    }
                }
            }
            out.append(ch)
            i = s.index(after: i)
        }
        return out
    }

    private static func isUploadNoise(_ inner: String, stripDeluxe: Bool) -> Bool {
        if inner.isEmpty { return true }
        if noiseBrackets.contains(inner) { return true }
        if inner.contains("remaster") { return true }
        if stripDeluxe && (inner.contains("deluxe") || inner.contains("expanded") || inner.contains("edition")) {
            return true
        }
        if inner.hasPrefix("feat ") || inner.hasPrefix("feat.") || inner.hasPrefix("ft ") || inner.hasPrefix("ft.") {
            return true
        }
        return false
    }

    private static func stripTrailingRemasterSuffix(in s: String) -> String {
        guard let dashRange = s.range(of: " - ", options: .backwards) else { return s }
        let tail = collapseWhitespaceAndPunctuation(String(s[dashRange.upperBound...]))
        if tail.contains("remaster") || tail.contains("mono") || tail.contains("stereo") || tail.contains("radio edit") {
            return String(s[..<dashRange.lowerBound])
        }
        return s
    }

    public static func collapseWhitespaceAndPunctuation(_ s: String) -> String {
        var result = ""
        result.reserveCapacity(s.count)
        var lastWasSpace = true
        for scalar in s.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
                lastWasSpace = false
            } else if !lastWasSpace {
                result.append(" ")
                lastWasSpace = true
            }
        }
        if result.hasSuffix(" ") { result.removeLast() }
        return result
    }
}

/// Fast in-memory matcher between plugin `TrackRef` entries and existing local `LibraryTrack` records (`SUB-10`).
public struct LibraryTrackMatcher: Sendable {
    private struct IndexedTrack {
        var track: LibraryTrack
        var normalizedTitle: String
        var normalizedAlbum: String
        var artists: [String]
        var inDownloadFolder: Bool
        var isVideoVersion: Bool
    }

    private let bySourceKey: [String: [IndexedTrack]]
    private let byISRC: [String: [IndexedTrack]]
    private let byArtistTitleKey: [String: [IndexedTrack]]
    private let byID: [UUID: IndexedTrack]

    public init(tracks: [LibraryTrack], downloadFolderPath: String? = nil) {
        let normalizedDownloadPrefix: String? = downloadFolderPath.map {
            let p = URL(fileURLWithPath: $0).standardizedFileURL.path
            return p.hasSuffix("/") ? p : p + "/"
        }

        var sourceMap: [String: [IndexedTrack]] = [:]
        var isrcMap: [String: [IndexedTrack]] = [:]
        var artistTitleMap: [String: [IndexedTrack]] = [:]
        var idMap: [UUID: IndexedTrack] = [:]

        for track in tracks where track.mediaKind == .song && FileManager.default.fileExists(atPath: track.path) {
            let normTitle = TrackTextNormalizer.normalizeTitle(track.title)
            let normAlbum = TrackTextNormalizer.normalizeAlbum(track.album)
            let artists = TrackTextNormalizer.artistComponents(track.artist ?? track.albumArtist ?? "")
            let inDownload = normalizedDownloadPrefix.map { track.path.hasPrefix($0) } ?? false
            let entry = IndexedTrack(
                track: track,
                normalizedTitle: normTitle,
                normalizedAlbum: normAlbum,
                artists: artists,
                inDownloadFolder: inDownload,
                isVideoVersion: TrackTextNormalizer.hasVideoVersionQualifier(title: track.title, album: track.album)
            )
            idMap[track.id] = entry

            if let sp = track.sourcePluginID, let sid = track.sourceTrackID, !sp.isEmpty, !sid.isEmpty {
                sourceMap["\(sp):\(sid)", default: []].append(entry)
            }
            if let isrc = track.isrc?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(), !isrc.isEmpty {
                isrcMap[isrc, default: []].append(entry)
            }
            if !normTitle.isEmpty {
                for artist in artists where !artist.isEmpty {
                    artistTitleMap["\(artist)\u{1}\(normTitle)", default: []].append(entry)
                }
            }
        }

        self.bySourceKey = sourceMap
        self.byISRC = isrcMap
        self.byArtistTitleKey = artistTitleMap
        self.byID = idMap
    }

    /// Finds the best local track matching `ref` (and optional previously linked ID), applying the `SUB-10`
    /// tie-breaker (in download folder > highest quality > newest).
    public func match(for ref: TrackRef, linkedTrackID: UUID? = nil) -> LibraryTrack? {
        if let linkedTrackID, let existing = byID[linkedTrackID] {
            return existing.track
        }

        // 1. Same (source, sourceID)
        if !ref.sourceID.isEmpty,
           let direct = bySourceKey["\(ref.source):\(ref.sourceID)"],
           let best = pickBest(from: direct) {
            return best
        }

        // Video entries (`MUSIC_VIDEO_TYPE_OMV`/`UGC`) must never fuzzy-match a studio album track by title/artist.
        if ref.isVideo == true {
            return nil
        }

        // 2. ISRC match
        let refIsVideo = TrackTextNormalizer.hasVideoVersionQualifier(title: ref.title, album: ref.album)
        if let rawISRC = ref.isrc?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
           !rawISRC.isEmpty,
           let isrcMatches = byISRC[rawISRC] {
            let compatible = refIsVideo ? isrcMatches.filter(\.isVideoVersion) : isrcMatches
            if let best = pickBest(from: compatible) {
                return best
            }
        }

        // 3. Normalized artist + title with duration ±3s OR matching album
        let targetTitle = TrackTextNormalizer.normalizeTitle(ref.title)
        guard !targetTitle.isEmpty else { return nil }
        let targetAlbum = TrackTextNormalizer.normalizeAlbum(ref.album)
        let refArtists = ref.artists.flatMap { TrackTextNormalizer.artistComponents($0) }
        guard !refArtists.isEmpty else { return nil }

        var candidates: [IndexedTrack] = []
        var seenIDs = Set<UUID>()
        for artist in refArtists {
            for item in byArtistTitleKey["\(artist)\u{1}\(targetTitle)", default: []] {
                guard seenIDs.insert(item.track.id).inserted else { continue }
                if refIsVideo && !item.isVideoVersion { continue }
                let durationMatch = (ref.durationMs ?? 0) > 0 && item.track.durationMs > 0
                    && abs((ref.durationMs ?? 0) - item.track.durationMs) <= 5000
                let albumMatch = !targetAlbum.isEmpty && !item.normalizedAlbum.isEmpty && targetAlbum == item.normalizedAlbum
                if durationMatch || albumMatch {
                    candidates.append(item)
                }
            }
        }

        return pickBest(from: candidates)
    }

    private func pickBest(from items: [IndexedTrack]) -> LibraryTrack? {
        items.max { lhs, rhs in
            if lhs.inDownloadFolder != rhs.inDownloadFolder {
                return !lhs.inDownloadFolder && rhs.inDownloadFolder
            }
            if lhs.track.isLossless != rhs.track.isLossless {
                return !lhs.track.isLossless && rhs.track.isLossless
            }
            if lhs.track.bitrate != rhs.track.bitrate {
                return lhs.track.bitrate < rhs.track.bitrate
            }
            return lhs.track.dateAdded < rhs.track.dateAdded
        }?.track
    }
}
