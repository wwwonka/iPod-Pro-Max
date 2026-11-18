import Foundation
import PluginKit

/// Pure parsers turning Spotify Pathfinder JSON dictionaries into `PluginKit.Playlist` and `[PluginKit.TrackRef]` (`SPO-5`, `SPO-7`).
public enum SpotifyParsers {
    public struct ParsedPlaylistPage: Sendable {
        public var title: String
        public var sourceID: String
        public var owner: String?
        public var artworkURL: URL?
        public var tracks: [TrackRef]
        public var totalCount: Int
        public var nextOffset: Int?
        public var warnings: [String]
    }

    public struct ParsedTracksPage: Sendable {
        public var tracks: [TrackRef]
        public var totalCount: Int
        public var nextOffset: Int?
        public var warnings: [String]
    }

    // MARK: - Playlist

    public static func parsePlaylistInitial(
        data: [String: Any],
        requestedID: String
    ) throws -> ParsedPlaylistPage {
        guard let playlistV2 = data["playlistV2"] as? [String: Any] else {
            throw PluginError(code: .apiChanged, message: SpotifyMessages.apiChanged)
        }

        if let typename = playlistV2["__typename"] as? String,
           typename == "GenericError" || typename == "NotFound" {
            throw PluginError(code: .notFound, message: "Spotify playlist not found or is private.")
        }

        let payload = (playlistV2["data"] as? [String: Any]) ?? playlistV2
        if let typename = payload["__typename"] as? String,
           typename == "GenericError" || typename == "NotFound" {
            throw PluginError(code: .notFound, message: "Spotify playlist not found or is private.")
        }

        guard let title = payload["name"] as? String, !title.isEmpty else {
            throw PluginError(code: .apiChanged, message: SpotifyMessages.apiChanged)
        }

        let uri = (payload["uri"] as? String) ?? ""
        let sourceID = !uri.isEmpty ? SpotifyURL.idFromURI(uri) : requestedID

        let ownerData = (payload["ownerV2"] as? [String: Any])?["data"] as? [String: Any]
        let ownerObj = payload["owner"] as? [String: Any]
        let owner = (ownerData?["name"] as? String)?.nonEmpty
            ?? (ownerData?["username"] as? String)?.nonEmpty
            ?? (ownerObj?["display_name"] as? String)?.nonEmpty
            ?? (ownerObj?["name"] as? String)?.nonEmpty
            ?? (ownerObj?["id"] as? String)?.nonEmpty

        let artworkURL = parsePlaylistArtworkURL(from: payload["images"])

        let contents = (payload["content"] as? [String: Any]) ?? (payload["contents"] as? [String: Any]) ?? [:]
        let page = parsePlaylistItems(from: contents)

        return ParsedPlaylistPage(
            title: title,
            sourceID: sourceID.isEmpty ? requestedID : sourceID,
            owner: owner,
            artworkURL: artworkURL,
            tracks: page.tracks,
            totalCount: page.totalCount,
            nextOffset: page.nextOffset,
            warnings: page.warnings
        )
    }

    public static func parsePlaylistContinuation(data: [String: Any]) throws -> ParsedTracksPage {
        guard let playlistV2 = data["playlistV2"] as? [String: Any] else {
            throw PluginError(code: .apiChanged, message: SpotifyMessages.apiChanged)
        }
        let payload = (playlistV2["data"] as? [String: Any]) ?? playlistV2
        let contents = (payload["content"] as? [String: Any]) ?? (payload["contents"] as? [String: Any]) ?? [:]
        return parsePlaylistItems(from: contents)
    }

    public static func parsePlaylistItems(from contents: [String: Any]) -> ParsedTracksPage {
        let totalCount = (contents["totalCount"] as? NSNumber)?.intValue ?? 0
        let rawItems = (contents["items"] as? [[String: Any]]) ?? []
        var tracks: [TrackRef] = []
        var warnings: [String] = []
        tracks.reserveCapacity(rawItems.count)

        for item in rawItems {
            let itemV2 = (item["itemV2"] as? [String: Any])
                ?? (item["itemV3"] as? [String: Any])
                ?? (item["track"] as? [String: Any])
                ?? (item["item"] as? [String: Any])
                ?? item

            let itemTypename = itemV2["__typename"] as? String ?? ""
            if itemTypename.contains("Episode") || itemTypename.contains("LocalTrack") {
                continue
            }

            let trackNode = (itemV2["data"] as? [String: Any])
                ?? (itemV2["trackUnion"] as? [String: Any])
                ?? itemV2

            let dataTypename = trackNode["__typename"] as? String ?? ""
            if dataTypename == "Episode" || dataTypename == "LocalTrack" || dataTypename == "RestrictedContent" {
                continue
            }

            if var parsed = parseTrackNode(
                trackNode,
                defaultAlbumName: nil,
                defaultAlbumArtist: nil,
                defaultArtworkURL: nil,
                defaultReleaseDate: nil,
                warnings: &warnings
            ) {
                parsed.remoteItemUID = (item["uid"] as? String)?.nonEmpty
                tracks.append(parsed)
            }
        }

        let offsets = contents["offsets"] as? [String: Any]
        let nextOffset = (offsets?["nextOffset"] as? NSNumber)?.intValue
        return ParsedTracksPage(tracks: tracks, totalCount: max(totalCount, tracks.count), nextOffset: nextOffset, warnings: warnings)
    }

    // MARK: - Album

    public static func parseAlbumInitial(
        data: [String: Any],
        requestedID: String
    ) throws -> ParsedPlaylistPage {
        guard let albumUnion = data["albumUnion"] as? [String: Any] else {
            throw PluginError(code: .apiChanged, message: SpotifyMessages.apiChanged)
        }

        if let typename = albumUnion["__typename"] as? String,
           typename == "GenericError" || typename == "NotFound" {
            throw PluginError(code: .notFound, message: "Spotify album not found or unavailable.")
        }

        guard let title = albumUnion["name"] as? String, !title.isEmpty else {
            throw PluginError(code: .apiChanged, message: SpotifyMessages.apiChanged)
        }

        let uri = (albumUnion["uri"] as? String) ?? ""
        let rawID = (albumUnion["id"] as? String) ?? SpotifyURL.idFromURI(uri)
        let sourceID = rawID.isEmpty ? requestedID : rawID

        let albumArtists = parseArtistNames(from: albumUnion["artists"])
        let primaryAlbumArtist = albumArtists.first
        let artworkURL = parseCoverArtLargestURL(from: albumUnion["coverArt"]) ?? parseCoverArtLargestURL(from: albumUnion["images"])
        let releaseDate = parseISODate(from: albumUnion["date"] as? [String: Any])

        let tracksContainer = (albumUnion["tracksV2"] as? [String: Any]) ?? (albumUnion["tracks"] as? [String: Any]) ?? [:]
        let page = parseAlbumTrackItems(
            from: tracksContainer,
            albumName: title,
            albumArtist: primaryAlbumArtist,
            artworkURL: artworkURL,
            releaseDate: releaseDate
        )

        return ParsedPlaylistPage(
            title: title,
            sourceID: sourceID,
            owner: primaryAlbumArtist,
            artworkURL: artworkURL,
            tracks: page.tracks,
            totalCount: page.totalCount,
            nextOffset: page.nextOffset,
            warnings: page.warnings
        )
    }

    public static func parseAlbumContinuation(
        data: [String: Any],
        albumName: String,
        albumArtist: String?,
        artworkURL: URL?,
        releaseDate: String?
    ) throws -> ParsedTracksPage {
        guard let albumUnion = data["albumUnion"] as? [String: Any] else {
            throw PluginError(code: .apiChanged, message: SpotifyMessages.apiChanged)
        }
        let tracksContainer = (albumUnion["tracksV2"] as? [String: Any]) ?? (albumUnion["tracks"] as? [String: Any]) ?? [:]
        return parseAlbumTrackItems(
            from: tracksContainer,
            albumName: albumName,
            albumArtist: albumArtist,
            artworkURL: artworkURL,
            releaseDate: releaseDate
        )
    }

    public static func parseAlbumTrackItems(
        from tracksContainer: [String: Any],
        albumName: String?,
        albumArtist: String?,
        artworkURL: URL?,
        releaseDate: String?
    ) -> ParsedTracksPage {
        let totalCount = (tracksContainer["totalCount"] as? NSNumber)?.intValue ?? 0
        let rawItems = (tracksContainer["items"] as? [[String: Any]]) ?? []
        var tracks: [TrackRef] = []
        var warnings: [String] = []
        tracks.reserveCapacity(rawItems.count)

        for item in rawItems {
            let trackNode = (item["track"] as? [String: Any])
                ?? (item["trackUnion"] as? [String: Any])
                ?? (item["data"] as? [String: Any])
                ?? item

            if let parsed = parseTrackNode(
                trackNode,
                defaultAlbumName: albumName,
                defaultAlbumArtist: albumArtist,
                defaultArtworkURL: artworkURL,
                defaultReleaseDate: releaseDate,
                warnings: &warnings
            ) {
                tracks.append(parsed)
            }
        }

        let offsets = tracksContainer["offsets"] as? [String: Any]
        let nextOffset = (offsets?["nextOffset"] as? NSNumber)?.intValue
        return ParsedTracksPage(tracks: tracks, totalCount: max(totalCount, tracks.count), nextOffset: nextOffset, warnings: warnings)
    }

    // MARK: - Revision Hash (`SPO-7`)

    /// Computes a deterministic portable SHA-256 hex digest over `<title>\n<trackID1>\n<trackID2>…`.
    public static func computeRevision(title: String, trackIDs: [String]) -> String {
        let canonical = ([title] + trackIDs).joined(separator: "\n")
        return SHA256.hex(Data(canonical.utf8))
    }

    // MARK: - Field Extraction

    private static func parseTrackNode(
        _ node: [String: Any],
        defaultAlbumName: String?,
        defaultAlbumArtist: String?,
        defaultArtworkURL: URL?,
        defaultReleaseDate: String?,
        warnings: inout [String]
    ) -> TrackRef? {
        let uri = (node["uri"] as? String) ?? ""
        // Ignore local files and non-track entities (`SPO-5`)
        if !uri.isEmpty && !uri.hasPrefix("spotify:track:") {
            return nil
        }

        let rawID = (node["id"] as? String) ?? SpotifyURL.idFromURI(uri)
        guard !rawID.isEmpty, SpotifyURL.isValidSpotifyID(rawID) else {
            return nil
        }
        guard let title = node["name"] as? String, !title.isEmpty else {
            return nil
        }

        if let playability = node["playability"] as? [String: Any],
           let playable = playability["playable"] as? Bool,
           !playable {
            warnings.append("Track '\(title)' (\(rawID)) is marked unplayable on Spotify.")
        }

        let albumNode = node["albumOfTrack"] as? [String: Any]
        let albumName = (albumNode?["name"] as? String)?.nonEmpty ?? defaultAlbumName
        let albumArtists = parseArtistNames(from: albumNode?["artists"])
        var artists = parseArtistNames(from: node["artists"])
        if artists.isEmpty { artists = parseArtistNames(from: node["artistsItems"]) }
        if artists.isEmpty { artists = albumArtists }
        if artists.isEmpty, let fallback = defaultAlbumArtist { artists = [fallback] }

        let albumArtist = albumArtists.first ?? defaultAlbumArtist ?? artists.first

        let durationNode = (node["duration"] as? [String: Any]) ?? (node["trackDuration"] as? [String: Any])
        let durationMs = (durationNode?["totalMilliseconds"] as? NSNumber)?.intValue
            ?? (durationNode?["totalMs"] as? NSNumber)?.intValue

        let trackNumber = (node["trackNumber"] as? NSNumber)?.intValue
        let discNumber = (node["discNumber"] as? NSNumber)?.intValue
        let artworkURL = parseCoverArtLargestURL(from: albumNode?["coverArt"]) ?? defaultArtworkURL
        let releaseDate = parseISODate(from: albumNode?["date"] as? [String: Any]) ?? defaultReleaseDate

        let ratingLabel = (node["contentRating"] as? [String: Any])?["label"] as? String
        let explicit = (ratingLabel == "EXPLICIT") || ((node["explicit"] as? Bool) ?? false)

        let isrc = ((node["externalIds"] as? [String: Any])?["isrc"] as? String)?.nonEmpty
            ?? ((node["external_ids"] as? [String: Any])?["isrc"] as? String)?.nonEmpty
            ?? (node["isrc"] as? String)?.nonEmpty

        return TrackRef(
            source: "spotify",
            sourceID: rawID,
            title: title,
            artists: artists,
            album: albumName,
            albumArtist: albumArtist,
            trackNumber: trackNumber,
            discNumber: discNumber,
            durationMs: durationMs,
            isrc: isrc,
            releaseDate: releaseDate,
            artworkURL: artworkURL,
            explicit: explicit
        )
    }

    private static func parseArtistNames(from node: Any?) -> [String] {
        let items: [[String: Any]]
        if let arr = node as? [[String: Any]] {
            items = arr
        } else if let dict = node as? [String: Any], let inner = dict["items"] as? [[String: Any]] {
            items = inner
        } else {
            return []
        }

        var out: [String] = []
        for item in items {
            if let direct = (item["name"] as? String)?.nonEmpty {
                out.append(direct)
            } else if let profile = item["profile"] as? [String: Any],
                      let name = (profile["name"] as? String)?.nonEmpty {
                out.append(name)
            } else if let data = item["data"] as? [String: Any],
                      let profileName = ((data["profile"] as? [String: Any])?["name"] as? String)?.nonEmpty ?? (data["name"] as? String)?.nonEmpty {
                out.append(profileName)
            }
        }
        return out
    }

    private static func parseCoverArtLargestURL(from node: Any?) -> URL? {
        guard let raw = node else { return nil }
        var candidates: [[String: Any]] = []
        if let dict = raw as? [String: Any] {
            if let sources = dict["sources"] as? [[String: Any]] {
                candidates = sources
            } else if let images = dict["images"] as? [[String: Any]] {
                candidates = images
            }
        } else if let arr = raw as? [[String: Any]] {
            candidates = arr
        }
        return largestImageURL(in: candidates)
    }

    private static func parsePlaylistArtworkURL(from node: Any?) -> URL? {
        guard let raw = node else { return nil }
        var candidates: [[String: Any]] = []
        if let dict = raw as? [String: Any] {
            if let items = dict["items"] as? [[String: Any]] {
                for item in items {
                    if let sources = item["sources"] as? [[String: Any]] {
                        candidates.append(contentsOf: sources)
                    } else {
                        candidates.append(item)
                    }
                }
            } else if let sources = dict["sources"] as? [[String: Any]] {
                candidates = sources
            }
        } else if let arr = raw as? [[String: Any]] {
            candidates = arr
        }
        return largestImageURL(in: candidates)
    }

    private static func largestImageURL(in list: [[String: Any]]) -> URL? {
        var bestURL: URL?
        var bestArea = -1
        for img in list {
            guard let urlStr = (img["url"] as? String)?.nonEmpty,
                  let url = URL(string: urlStr) else { continue }
            let w = (img["width"] as? NSNumber)?.intValue ?? 0
            let h = (img["height"] as? NSNumber)?.intValue ?? 0
            let area = w * h
            if area > bestArea {
                bestArea = area
                bestURL = url
            }
        }
        return bestURL
    }

    private static func parseISODate(from node: [String: Any]?) -> String? {
        guard let node else { return nil }
        if let iso = (node["isoString"] as? String)?.nonEmpty {
            return String(iso.prefix(10))
        }
        guard let year = (node["year"] as? NSNumber)?.intValue, year > 0 else {
            return nil
        }
        if let month = (node["month"] as? NSNumber)?.intValue,
           let day = (node["day"] as? NSNumber)?.intValue,
           month > 0, day > 0 {
            return String(format: "%04d-%02d-%02d", year, month, day)
        }
        return "\(year)"
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
