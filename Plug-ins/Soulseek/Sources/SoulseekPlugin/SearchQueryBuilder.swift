import Foundation
import PluginKit

/// Query normalization and multi-tier widening for Soulseek searches (`SLSK-6`, `SLSK-7`).
public enum SearchQueryBuilder {
    public static let audioExtensions: Set<String> = [
        "flac", "alac", "m4a", "mp3", "aac", "ogg", "opus", "wav", "aiff", "aif"
    ]

    /// Ordered queries per spec:
    /// 1. `<primaryArtist> <cleanTitle>`
    /// 2. `<cleanTitle> <cleanAlbum>`
    /// 3. `<cleanTitle>` alone if cleaned title has >= 3 words
    public static func queries(for track: TrackRef) -> [String] {
        var result: [String] = []
        let primary = primaryArtist(from: track.artists.first ?? "")
        let title = cleanTerm(track.title)
        let album = cleanTerm(track.album ?? "")

        let q1 = [primary, title].filter { !$0.isEmpty }.joined(separator: " ")
        if !q1.isEmpty { result.append(q1) }

        if !album.isEmpty && !title.isEmpty {
            let q2 = "\(title) \(album)"
            if !result.contains(q2) {
                result.append(q2)
            }
        }

        let titleWords = title.split(whereSeparator: \.isWhitespace)
        if titleWords.count >= 3, !title.isEmpty, !result.contains(title) {
            result.append(title)
        }
        return result
    }

    public static func primaryArtist(from raw: String) -> String {
        let separators = [",", " feat.", " feat ", " ft.", " ft ", " featuring ", " & ", " x "]
        let fold = raw.lowercased()
        var earliest = raw.endIndex
        for sep in separators {
            if let r = fold.range(of: sep) {
                let off = fold.distance(from: fold.startIndex, to: r.lowerBound)
                let idx = raw.index(raw.startIndex, offsetBy: off)
                if idx < earliest { earliest = idx }
            }
        }
        return cleanTerm(String(raw[..<earliest]))
    }

    public static func cleanTerm(_ raw: String) -> String {
        // Strip parenthetical / bracketed featuring credits, then replace punctuation with spaces.
        let stripped = raw
            .replacingOccurrences(of: "\\((feat|ft|featuring|with)\\b[^)]*\\)", with: " ", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "\\[(feat|ft|featuring|with)\\b[^\\]]*\\]", with: " ", options: [.regularExpression, .caseInsensitive])

        var out = ""
        out.reserveCapacity(stripped.count)
        var lastWasSpace = true
        for scalar in stripped.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.append(Character(scalar))
                lastWasSpace = false
            } else if !lastWasSpace {
                out.append(" ")
                lastWasSpace = true
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Maps a decoded `SearchResultFile` to a `PluginKit.Candidate` (`SLSK-6`).
    public static func makeCandidate(
        username: String,
        file: MessageParser.SearchResultFile,
        freeSlots: Bool,
        uploadSpeed: UInt32,
        queueLength: UInt32
    ) -> Candidate? {
        guard !file.isPrivate else { return nil }

        let ext = normalizedExtension(filename: file.filename, wireExtension: file.extension)
        guard audioExtensions.contains(ext) else { return nil }

        let bitrate: Int? = file.bitrate.map(Int.init) ?? inferBitrateFromPath(file.filename, ext: ext)
        let durationMs: Int? = file.duration.map { Int($0) * 1000 }
        let sampleRateHz: Int? = file.sampleRate.map(Int.init)
        let bitDepth: Int? = file.bitDepth.map(Int.init)

        let tokenObj = SlskCandidateToken(
            user: username,
            file: file.filename,
            size: Int64(clamping: file.size)
        )
        guard let tokenData = try? JSONEncoder().encode(tokenObj),
              let tokenStr = String(data: tokenData, encoding: .utf8) else {
            return nil
        }

        let (parsedArtist, parsedTitle) = inferArtistAndTitle(fromPath: file.filename)
        let codec: String? = switch ext {
        case "flac": "flac"
        case "alac": "alac"
        case "m4a", "aac": "aac"
        case "mp3": "mp3"
        case "ogg", "opus": "opus"
        default: nil
        }

        return Candidate(
            resolver: "soulseek",
            token: tokenStr,
            displayName: "\(username): \(file.filename)",
            title: parsedTitle,
            artist: parsedArtist,
            album: nil,
            durationMs: durationMs,
            container: ext,
            codec: codec,
            bitrateKbps: bitrate,
            sampleRateHz: sampleRateHz,
            bitDepth: bitDepth,
            sizeBytes: Int64(clamping: file.size),
            availability: Availability(
                freeSlot: freeSlots,
                queueLength: Int(queueLength),
                speedBytesPerSec: Int(uploadSpeed)
            ),
            hint: nil
        )
    }

    public static func normalizedExtension(filename: String, wireExtension: String) -> String {
        let cleanWire = wireExtension.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        if !cleanWire.isEmpty { return cleanWire }
        let replaced = filename.replacingOccurrences(of: "\\", with: "/")
        return URL(fileURLWithPath: replaced).pathExtension.lowercased()
    }

    public static func inferBitrateFromPath(_ path: String, ext: String) -> Int? {
        if ["flac", "alac", "wav", "aiff", "aif"].contains(ext) { return 1000 }
        let lower = path.lowercased()
        if lower.contains("320") { return 320 }
        if lower.contains("v0") { return 245 }
        if lower.contains("256") { return 256 }
        if lower.contains("192") { return 192 }
        if lower.contains("128") { return 128 }
        return nil
    }

    private static func inferArtistAndTitle(fromPath path: String) -> (artist: String?, title: String?) {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        let filename = URL(fileURLWithPath: normalized).deletingPathExtension().lastPathComponent
        let cleanFilename = filename.replacingOccurrences(of: "^\\d{1,3}[.\\s-]+", with: "", options: .regularExpression)
        if let dashRange = cleanFilename.range(of: " - ") {
            let left = String(cleanFilename[..<dashRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            let right = String(cleanFilename[dashRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            return (left.isEmpty ? nil : left, right.isEmpty ? nil : right)
        }
        return (nil, cleanFilename.isEmpty ? nil : cleanFilename)
    }
}
