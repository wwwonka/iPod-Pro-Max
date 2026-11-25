import Foundation
import PluginKit

/// Parsed YouTube Music playlist or album target (`youtube-music` source).
public struct YouTubeMusicTarget: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case playlist
        case album
    }

    public var kind: Kind
    /// Canonical storage identifier (`PL...`, `RDCLAK5uy_...`, `OLAK5uy_...`, or `MPREb_...`).
    public var id: String
    /// InnerTube browse identifier (`VL<id>` for playlists, `MPREb_<id>` for albums).
    public var browseID: String

    public init(kind: Kind, id: String, browseID: String) {
        self.kind = kind
        self.id = id
        self.browseID = browseID
    }

    public var webURLString: String {
        if id.hasPrefix("MPREb_") {
            return "https://music.youtube.com/browse/\(id)"
        }
        return "https://music.youtube.com/playlist?list=\(id)"
    }
}

/// Pure, I/O-free parser for YouTube Music playlist and album URLs and URIs.
///
/// Accepts:
/// - `https://music.youtube.com/playlist?list=<id>` (`www.youtube.com`, `m.youtube.com`, scheme-less)
/// - `https://music.youtube.com/browse/VL<id>` / `browse/MPREb_<id>` / `browse/OLAK5uy_<id>`
/// - `https://youtu.be/<video>?list=<id>`
/// - `ytmusic:playlist:<id>` and `ytmusic:album:<id>`
public enum YouTubeMusicURL {
    private static let supportedWebHosts: Set<String> = [
        "music.youtube.com",
        "www.youtube.com",
        "youtube.com",
        "m.youtube.com",
        "youtu.be",
    ]

    public static func parse(_ raw: String) throws -> YouTubeMusicTarget {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw PluginError(code: .unsupported, message: "This link isn't supported.")
        }

        if trimmed.lowercased().hasPrefix("ytmusic:") {
            return try parseURI(trimmed)
        }

        return try parseWebURL(trimmed)
    }

    public static func isValidID(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 128 else { return false }
        return id.unicodeScalars.allSatisfy { scalar in
            let v = scalar.value
            return (0x30...0x39).contains(v) // 0-9
                || (0x41...0x5A).contains(v) // A-Z
                || (0x61...0x7A).contains(v) // a-z
                || v == 0x5F // _
                || v == 0x2D // -
        }
    }

    public static func stripVLPrefix(_ id: String) -> String {
        id.hasPrefix("VL") && id.count > 2 ? String(id.dropFirst(2)) : id
    }

    // MARK: - Helpers

    private static func parseURI(_ raw: String) throws -> YouTubeMusicTarget {
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0].lowercased() == "ytmusic" else {
            throw PluginError(code: .unsupported, message: "This link isn't supported.")
        }
        guard let kind = YouTubeMusicTarget.Kind(rawValue: parts[1].lowercased()) else {
            throw PluginError(code: .unsupported, message: "Only YouTube Music playlists and albums are supported.")
        }
        let cleanID = stripVLPrefix(parts[2])
        guard isValidID(cleanID) else {
            throw PluginError(code: .unsupported, message: "This link isn't supported.")
        }
        let browseID = targetBrowseID(kind: kind, cleanID: cleanID)
        return YouTubeMusicTarget(kind: kind, id: cleanID, browseID: browseID)
    }

    private static func parseWebURL(_ raw: String) throws -> YouTubeMusicTarget {
        let candidate = raw.contains("://") ? raw : "https://\(raw)"
        guard let components = URLComponents(string: candidate),
              let host = components.host?.lowercased(),
              supportedWebHosts.contains(host) else {
            throw PluginError(code: .unsupported, message: "This link isn't supported.")
        }

        let segments = components.path.split(separator: "/").map(String.init)

        // /browse/<browseId> (albums: MPREb_..., playlists: VL..., OLAK5uy_...)
        if segments.count >= 2, segments[0].lowercased() == "browse" {
            let rawBrowse = segments[1]
            guard isValidID(rawBrowse) else {
                throw PluginError(code: .unsupported, message: "This link isn't supported.")
            }
            if rawBrowse.hasPrefix("MPREb_") {
                return YouTubeMusicTarget(kind: .album, id: rawBrowse, browseID: rawBrowse)
            }
            if rawBrowse.hasPrefix("OLAK5uy_") {
                return YouTubeMusicTarget(kind: .album, id: rawBrowse, browseID: "VL\(rawBrowse)")
            }
            if rawBrowse.hasPrefix("VL") && rawBrowse.count > 2 {
                let clean = stripVLPrefix(rawBrowse)
                let kind: YouTubeMusicTarget.Kind = clean.hasPrefix("OLAK5uy_") ? .album : .playlist
                return YouTubeMusicTarget(kind: kind, id: clean, browseID: rawBrowse)
            }
            throw PluginError(code: .unsupported, message: "Only YouTube Music playlists and albums are supported.")
        }

        // /playlist?list=... or watch/youtu.be link carrying ?list=...
        if let listValue = components.queryItems?.first(where: { $0.name == "list" })?.value {
            let clean = stripVLPrefix(listValue.trimmingCharacters(in: .whitespacesAndNewlines))
            guard isValidID(clean) else {
                throw PluginError(code: .unsupported, message: "This link isn't supported.")
            }
            let kind: YouTubeMusicTarget.Kind = clean.hasPrefix("OLAK5uy_") ? .album : .playlist
            return YouTubeMusicTarget(kind: kind, id: clean, browseID: "VL\(clean)")
        }

        throw PluginError(code: .unsupported, message: "Only YouTube Music playlists and albums are supported.")
    }

    private static func targetBrowseID(kind: YouTubeMusicTarget.Kind, cleanID: String) -> String {
        if cleanID.hasPrefix("MPREb_") { return cleanID }
        if kind == .album && !cleanID.hasPrefix("OLAK5uy_") { return cleanID }
        return cleanID.hasPrefix("VL") ? cleanID : "VL\(cleanID)"
    }
}
