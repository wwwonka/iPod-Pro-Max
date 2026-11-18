import Foundation
import PluginKit

/// Parsed Spotify entity target supported by the playlist-source plug-in (`SPO-2`).
public struct SpotifyTarget: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case playlist
        case album

        var uriPrefix: String { "spotify:\(rawValue):" }
    }

    public var kind: Kind
    public var id: String

    public init(kind: Kind, id: String) {
        self.kind = kind
        self.id = id
    }

    public var uri: String { "\(kind.uriPrefix)\(id)" }
    public var webURLString: String { "https://open.spotify.com/\(kind.rawValue)/\(id)" }
    public var embedPlaylistURLString: String { "https://open.spotify.com/embed/playlist/\(id)" }
}

/// Pure, I/O-free parser for Spotify playlist and album URLs/URIs (`SPO-2`).
///
/// Accepts:
/// - `https://open.spotify.com/playlist/<id>` / `album/<id>` (and `play.spotify.com`)
/// - Optional `/embed/` and `/intl-<lang>/` path prefixes
/// - Optional `?si=…`, `?pi=…` query parameters or `#…` fragments
/// - Scheme-less `open.spotify.com/playlist/<id>`
/// - `spotify:playlist:<id>` and `spotify:album:<id>` URIs
///
/// Rejects track, artist, episode, show, short links (`spotify.link`, `spoti.fi`), and invalid IDs.
public enum SpotifyURL {
    private static let supportedHosts: Set<String> = ["open.spotify.com", "play.spotify.com"]

    public static func parse(_ raw: String) throws -> SpotifyTarget {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw PluginError(code: .unsupported, message: "This link isn't supported.")
        }

        if trimmed.lowercased().hasPrefix("spotify:") {
            return try parseURI(trimmed)
        }

        return try parseWebURL(trimmed)
    }

    public static func isValidSpotifyID(_ id: String) -> Bool {
        guard id.count == 22 else { return false }
        for scalar in id.unicodeScalars {
            let v = scalar.value
            let isDigit = (0x30...0x39).contains(v)
            let isUpper = (0x41...0x5A).contains(v)
            let isLower = (0x61...0x7A).contains(v)
            if !(isDigit || isUpper || isLower) {
                return false
            }
        }
        return true
    }

    public static func idFromURI(_ uri: String) -> String {
        guard let last = uri.split(separator: ":").last else { return "" }
        return String(last)
    }

    // MARK: - Helpers

    private static func parseURI(_ raw: String) throws -> SpotifyTarget {
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0].lowercased() == "spotify" else {
            throw PluginError(code: .unsupported, message: "This link isn't supported.")
        }
        guard let kind = SpotifyTarget.Kind(rawValue: parts[1].lowercased()) else {
            throw PluginError(code: .unsupported, message: "Only Spotify playlists and albums are supported.")
        }
        guard isValidSpotifyID(parts[2]) else {
            throw PluginError(code: .unsupported, message: "This link isn't supported.")
        }
        return SpotifyTarget(kind: kind, id: parts[2])
    }

    private static func parseWebURL(_ raw: String) throws -> SpotifyTarget {
        let candidate = raw.contains("://") ? raw : "https://\(raw)"
        guard let components = URLComponents(string: candidate),
              let host = components.host?.lowercased(),
              supportedHosts.contains(host) else {
            throw PluginError(code: .unsupported, message: "This link isn't supported.")
        }

        var segments = components.path
            .split(separator: "/")
            .map(String.init)

        if segments.first?.lowercased() == "embed" {
            segments.removeFirst()
        }

        if let first = segments.first, isIntlPrefix(first) {
            segments.removeFirst()
        }

        guard segments.count == 2 else {
            throw PluginError(code: .unsupported, message: "This link isn't supported.")
        }

        guard let kind = SpotifyTarget.Kind(rawValue: segments[0].lowercased()) else {
            throw PluginError(code: .unsupported, message: "Only Spotify playlists and albums are supported.")
        }
        let id = segments[1]
        guard isValidSpotifyID(id) else {
            throw PluginError(code: .unsupported, message: "This link isn't supported.")
        }
        return SpotifyTarget(kind: kind, id: id)
    }

    private static func isIntlPrefix(_ segment: String) -> Bool {
        let lower = segment.lowercased()
        guard lower.hasPrefix("intl-") else { return false }
        let suffix = String(lower.dropFirst(5))
        let parts = suffix.split(separator: "-")
        guard !parts.isEmpty && parts.count <= 2 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.unicodeScalars.allSatisfy { (0x61...0x7A).contains($0.value) }
        }
    }
}
