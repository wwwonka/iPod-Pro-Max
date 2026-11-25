import Foundation
import PluginKit

/// Parsed InnerTube playlist or album page result.
public struct ParsedBrowsePage: Sendable {
    public var title: String
    public var owner: String?
    public var artworkURL: URL?
    public var releaseDate: String?
    public var albumArtist: String?
    public var tracks: [TrackRef]
    public var continuationToken: String?
}

/// Parsed page of playlists from `browseId: "FEmusic_liked_playlists"`.
public struct ParsedUserPlaylistsPage: Sendable {
    public var playlists: [RemotePlaylistSummary]
    public var continuationToken: String?
}

/// Parsers for YouTube Music InnerTube (`WEB_REMIX`) browse, continuation, and search responses.
public enum YTMusicParsers {
    private static let nonArtistSeparators: Set<String> = [" • ", "•", ", ", ",", " & ", "&", " / ", "/", " - "]

    // MARK: - Browse & Continuation

    public static func parseBrowseInitial(
        data: Data,
        target: YouTubeMusicTarget
    ) throws -> ParsedBrowsePage {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw PluginError(code: .apiChanged, message: "YouTube Music browse response is not valid JSON.")
        }

        if let errorObj = root["error"] as? [String: Any] {
            let code = errorObj["code"] as? Int ?? 0
            let msg = errorObj["message"] as? String ?? "YouTube Music returned an error."
            if code == 404 {
                throw PluginError(code: .notFound, message: "This playlist doesn't exist or is private.")
            }
            if code == 401 || code == 403 {
                throw PluginError(code: .unauthorized, message: msg)
            }
        }

        if let alert = findUnavailableAlert(in: root) {
            let lower = alert.lowercased()
            if lower.contains("does not exist") || lower.contains("unavailable") || lower.contains("private") {
                throw PluginError(code: .notFound, message: "This playlist doesn't exist or is private.")
            }
        }

        guard let contents = root["contents"] as? [String: Any] else {
            throw PluginError(code: .notFound, message: "This playlist doesn't exist or is private.")
        }

        let headerInfo: ParsedHeaderInfo
        let sectionSources: [[String: Any]]
        if let twoCol = contents["twoColumnBrowseResultsRenderer"] as? [String: Any] {
            headerInfo = parseHeader(twoCol: twoCol, root: root, target: target)
            sectionSources = ((twoCol["secondaryContents"] as? [String: Any])?["sectionListRenderer"] as? [String: Any])?["contents"] as? [[String: Any]] ?? []
        } else if let singleCol = contents["singleColumnBrowseResultsRenderer"] as? [String: Any] {
            headerInfo = parseHeader(twoCol: singleCol, root: root, target: target)
            let tabs = singleCol["tabs"] as? [[String: Any]] ?? []
            sectionSources = (((tabs.first?["tabRenderer"] as? [String: Any])?["content"] as? [String: Any])?["sectionListRenderer"] as? [String: Any])?["contents"] as? [[String: Any]] ?? []
        } else {
            throw PluginError(code: .notFound, message: "This playlist doesn't exist or is private.")
        }

        var shelfDict: [String: Any]?
        for section in sectionSources {
            if let s = section["musicPlaylistShelfRenderer"] as? [String: Any] {
                shelfDict = s
                break
            }
            if let s = section["musicShelfRenderer"] as? [String: Any] {
                shelfDict = s
                break
            }
            if let nested = ((section["itemSectionRenderer"] as? [String: Any])?["contents"] as? [[String: Any]]) {
                for entry in nested {
                    if let s = (entry["musicPlaylistShelfRenderer"] as? [String: Any]) ?? (entry["musicShelfRenderer"] as? [String: Any]) {
                        shelfDict = s
                        break
                    }
                }
                if shelfDict != nil { break }
            }
        }

        let rawItems = shelfDict?["contents"] as? [[String: Any]] ?? []
        var tracks = parseTrackItems(rawItems, target: target, headerInfo: headerInfo, trackIndexOffset: 0)
        let nextToken = extractContinuationToken(shelf: shelfDict, items: rawItems)

        if tracks.isEmpty && nextToken == nil {
            // Empty owned playlists still have a valid header; nonexistent/private playlists either have error alerts or empty contents.
            if headerInfo.title == nil {
                throw PluginError(code: .notFound, message: "This playlist doesn't exist or is private.")
            }
        }

        // Preserve album track numbers on initial page when not explicitly populated.
        if target.kind == .album {
            for idx in tracks.indices where tracks[idx].trackNumber == nil {
                tracks[idx].trackNumber = idx + 1
            }
        }

        return ParsedBrowsePage(
            title: headerInfo.title ?? (target.kind == .album ? "YouTube Music Album" : "YouTube Music Playlist"),
            owner: headerInfo.owner,
            artworkURL: headerInfo.artworkURL,
            releaseDate: headerInfo.releaseDate,
            albumArtist: headerInfo.albumArtist,
            tracks: tracks,
            continuationToken: nextToken
        )
    }

    public static func parseBrowseContinuation(
        data: Data,
        target: YouTubeMusicTarget,
        headerInfo: ParsedHeaderInfo,
        trackIndexOffset: Int
    ) throws -> (tracks: [TrackRef], continuationToken: String?) {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw PluginError(code: .apiChanged, message: "YouTube Music continuation response is not valid JSON.")
        }

        var rawItems: [[String: Any]] = []
        var legacyShelf: [String: Any]?

        if let actions = root["onResponseReceivedActions"] as? [[String: Any]] {
            for action in actions {
                if let append = action["appendContinuationItemsAction"] as? [String: Any],
                   let items = append["continuationItems"] as? [[String: Any]] {
                    rawItems.append(contentsOf: items)
                }
            }
        }

        if rawItems.isEmpty, let cont = root["continuationContents"] as? [String: Any] {
            let shelf = (cont["musicPlaylistShelfContinuation"] as? [String: Any])
                ?? (cont["musicShelfContinuation"] as? [String: Any])
            legacyShelf = shelf
            rawItems = shelf?["contents"] as? [[String: Any]] ?? []
        }

        var tracks = parseTrackItems(rawItems, target: target, headerInfo: headerInfo, trackIndexOffset: trackIndexOffset)
        if target.kind == .album {
            for idx in tracks.indices where tracks[idx].trackNumber == nil {
                tracks[idx].trackNumber = trackIndexOffset + idx + 1
            }
        }
        let nextToken = extractContinuationToken(shelf: legacyShelf, items: rawItems)
        return (tracks, nextToken)
    }

    // MARK: - User Library Playlists (`FEmusic_liked_playlists` / `FEmusic_library_landing`)

    public static func isLoggedOutResponse(data: Data) -> Bool {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return false
        }
        if let rc = root["responseContext"] as? [String: Any],
           let main = rc["mainAppWebResponseContext"] as? [String: Any],
           let loggedOut = main["loggedOut"] as? Bool {
            return loggedOut
        }
        return false
    }

    public static func isHTMLPageLoggedOut(_ html: String) -> Bool {
        if let range = html.range(of: #""LOGGED_IN"\s*:\s*false"#, options: .regularExpression) {
            _ = range
            return true
        }
        return false
    }

    public static func parseLikedMusicSummary(data: Data, currentDisplayName: String? = nil) -> RemotePlaylistSummary? {
        guard !isLoggedOutResponse(data: data),
              let url = URL(string: "https://music.youtube.com/playlist?list=LM"),
              let target = try? YouTubeMusicURL.parse(url.absoluteString) else {
            return nil
        }
        let headerCount = extractTrackCountFromBrowseHeader(data: data)
        if let page = try? parseBrowseInitial(data: data, target: target) {
            let exactCount = headerCount ?? (page.continuationToken == nil && !page.tracks.isEmpty ? page.tracks.count : nil)
            return RemotePlaylistSummary(
                id: "LM",
                title: page.title.nilIfEmpty ?? "Liked Music",
                owner: page.owner ?? currentDisplayName,
                trackCount: exactCount,
                artworkURL: page.artworkURL,
                url: url,
                isLikedSongs: true,
                isOwned: true
            )
        }
        if let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           root["contents"] != nil {
            return RemotePlaylistSummary(
                id: "LM",
                title: "Liked Music",
                owner: currentDisplayName,
                trackCount: headerCount,
                artworkURL: nil,
                url: url,
                isLikedSongs: true,
                isOwned: true
            )
        }
        return nil
    }

    /// Parses playlist metadata (title, owner, track count, ownership) from an individual `browse` response (`VL...`).
    public static func parsePlaylistSummaryFromBrowse(
        id: String,
        data: Data,
        currentDisplayName: String? = nil
    ) -> RemotePlaylistSummary? {
        guard !isLoggedOutResponse(data: data),
              let url = URL(string: "https://music.youtube.com/playlist?list=\(id)"),
              let target = try? YouTubeMusicURL.parse(url.absoluteString),
              let page = try? parseBrowseInitial(data: data, target: target) else {
            return nil
        }
        let headerCount = extractTrackCountFromBrowseHeader(data: data)
        let count = headerCount ?? (page.continuationToken == nil ? page.tracks.count : nil)
        let isOwned: Bool? = hasEditablePlaylistHeader(data: data)
            ? true
            : matchesDisplayName(page.owner, currentDisplayName: currentDisplayName)
        return RemotePlaylistSummary(
            id: id,
            title: page.title,
            owner: page.owner,
            trackCount: count,
            artworkURL: page.artworkURL,
            url: url,
            isLikedSongs: id == "LM",
            isOwned: isOwned
        )
    }

    /// Extracts embedded playlist JSON (`initialData.push` / `ytInitialData`) from `https://music.youtube.com/playlist?list=...` HTML.
    public static func parsePlaylistHTML(html: String, target: YouTubeMusicTarget) -> ParsedBrowsePage? {
        for candidate in extractEmbeddedJSONCandidates(fromHTML: html) {
            guard let data = candidate.data(using: .utf8),
                  let parsed = try? parseBrowseInitial(data: data, target: target) else {
                continue
            }
            return parsed
        }
        return nil
    }

    private static func extractEmbeddedJSONCandidates(fromHTML html: String) -> [String] {
        var candidates = extractInitialDataPushPayloads(fromHTML: html)
        if let regex = try? NSRegularExpression(pattern: #"var\s+ytInitialData\s*=\s*"#) {
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            for match in regex.matches(in: html, range: range) {
                if let r = Range(match.range, in: html),
                   r.upperBound < html.endIndex,
                   html[r.upperBound] == "{",
                   let slice = balancedCurlyJSONSlice(in: html, from: r.upperBound) {
                    candidates.append(slice)
                }
            }
        }
        return candidates
    }

    /// Extracts initial browse JSON embedded in `https://music.youtube.com/library/playlists` HTML (`initialData.push` / `ytInitialData`).
    public static func parseLibraryHTMLPlaylists(
        html: String,
        currentDisplayName: String? = nil
    ) -> ParsedUserPlaylistsPage? {
        let jsonCandidates = extractEmbeddedJSONCandidates(fromHTML: html)

        var collected: [RemotePlaylistSummary] = []
        var seenIDs = Set<String>()
        var continuation: String?
        for candidate in jsonCandidates {
            guard let data = candidate.data(using: .utf8),
                  let parsed = try? parseUserPlaylistsInitial(data: data, currentDisplayName: currentDisplayName) else {
                continue
            }
            for item in parsed.playlists where seenIDs.insert(item.id).inserted {
                collected.append(item)
            }
            if continuation == nil {
                continuation = parsed.continuationToken
            }
        }
        return collected.isEmpty ? nil : ParsedUserPlaylistsPage(playlists: collected, continuationToken: continuation)
    }

    private static func extractInitialDataPushPayloads(fromHTML html: String) -> [String] {
        var payloads: [String] = []
        var searchRange = html.startIndex..<html.endIndex
        while let marker = html.range(of: "initialData.push(", range: searchRange) {
            var idx = marker.upperBound
            var inString: Character?
            var escaped = false
            var parenDepth = 1
            while idx < html.endIndex {
                let ch = html[idx]
                if let quote = inString {
                    if escaped {
                        escaped = false
                    } else if ch == "\\" {
                        escaped = true
                    } else if ch == quote {
                        inString = nil
                    }
                    idx = html.index(after: idx)
                    continue
                }
                if ch == "'" || ch == "\"" {
                    inString = ch
                    idx = html.index(after: idx)
                    continue
                }
                if ch == "(" {
                    parenDepth += 1
                    idx = html.index(after: idx)
                    continue
                }
                if ch == ")" {
                    parenDepth -= 1
                    if parenDepth <= 0 {
                        break
                    }
                    idx = html.index(after: idx)
                    continue
                }
                let isWordBoundary: Bool = {
                    guard idx > marker.upperBound else { return true }
                    let prev = html[html.index(before: idx)]
                    return !prev.isLetter && !prev.isNumber && prev != "_"
                }()
                if isWordBoundary && html[idx...].hasPrefix("data") {
                    let afterData = html.index(idx, offsetBy: 4)
                    var colonIdx = afterData
                    while colonIdx < html.endIndex && html[colonIdx].isWhitespace {
                        colonIdx = html.index(after: colonIdx)
                    }
                    if colonIdx < html.endIndex && html[colonIdx] == ":" {
                        var strStart = html.index(after: colonIdx)
                        while strStart < html.endIndex && html[strStart].isWhitespace {
                            strStart = html.index(after: strStart)
                        }
                        if strStart < html.endIndex && (html[strStart] == "'" || html[strStart] == "\"") {
                            let quoteChar = html[strStart]
                            let contentStart = html.index(after: strStart)
                            var cur = contentStart
                            var esc = false
                            while cur < html.endIndex {
                                let c = html[cur]
                                if esc {
                                    esc = false
                                } else if c == "\\" {
                                    esc = true
                                } else if c == quoteChar {
                                    let rawLiteral = String(html[contentStart..<cur])
                                    payloads.append(unescapeJSStringLiteral(rawLiteral))
                                    idx = cur
                                    break
                                }
                                cur = html.index(after: cur)
                            }
                            break
                        }
                    }
                }
                idx = html.index(after: idx)
            }
            searchRange = marker.upperBound..<html.endIndex
        }
        return payloads
    }

    private static func balancedCurlyJSONSlice(in text: String, from start: String.Index) -> String? {
        var depth = 0
        var inString = false
        var escaped = false
        var idx = start
        while idx < text.endIndex {
            let ch = text[idx]
            if inString {
                if escaped {
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "\"" {
                    inString = false
                }
            } else {
                if ch == "\"" {
                    inString = true
                } else if ch == "{" {
                    depth += 1
                } else if ch == "}" {
                    depth -= 1
                    if depth == 0 {
                        return String(text[start...idx])
                    }
                }
            }
            idx = text.index(after: idx)
        }
        return nil
    }

    private static func unescapeJSStringLiteral(_ raw: String) -> String {
        var out = ""
        out.reserveCapacity(raw.count)
        var i = raw.startIndex
        while i < raw.endIndex {
            let ch = raw[i]
            guard ch == "\\" else {
                out.append(ch)
                i = raw.index(after: i)
                continue
            }
            let next = raw.index(after: i)
            guard next < raw.endIndex else { break }
            let esc = raw[next]
            switch esc {
            case "'", "\"", "/", "\\":
                out.append(esc)
                i = raw.index(after: next)
            case "n":
                out.append("\n")
                i = raw.index(after: next)
            case "r":
                out.append("\r")
                i = raw.index(after: next)
            case "t":
                out.append("\t")
                i = raw.index(after: next)
            case "x":
                let hexStart = raw.index(after: next)
                if let hexEnd = raw.index(hexStart, offsetBy: 2, limitedBy: raw.endIndex),
                   let code = UInt32(raw[hexStart..<hexEnd], radix: 16),
                   let scalar = UnicodeScalar(code) {
                    out.append(Character(scalar))
                    i = hexEnd
                } else {
                    out.append(esc)
                    i = raw.index(after: next)
                }
            case "u":
                let hexStart = raw.index(after: next)
                if let hexEnd = raw.index(hexStart, offsetBy: 4, limitedBy: raw.endIndex),
                   let code = UInt32(raw[hexStart..<hexEnd], radix: 16),
                   let scalar = UnicodeScalar(code) {
                    out.append(Character(scalar))
                    i = hexEnd
                } else {
                    out.append(esc)
                    i = raw.index(after: next)
                }
            default:
                out.append(esc)
                i = raw.index(after: next)
            }
        }
        return out
    }

    public static func parseUserPlaylistsInitial(
        data: Data,
        currentDisplayName: String? = nil
    ) throws -> ParsedUserPlaylistsPage {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw PluginError(code: .apiChanged, message: "YouTube Music library response is not valid JSON.")
        }
        var playlists: [RemotePlaylistSummary] = []
        var continuation: String?
        if let contents = root["contents"] {
            collectUserPlaylists(in: contents, currentDisplayName: currentDisplayName, playlists: &playlists, continuation: &continuation)
        }
        return ParsedUserPlaylistsPage(playlists: playlists, continuationToken: continuation)
    }

    public static func parseUserPlaylistsContinuation(
        data: Data,
        currentDisplayName: String? = nil
    ) throws -> ParsedUserPlaylistsPage {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw PluginError(code: .apiChanged, message: "YouTube Music library continuation response is not valid JSON.")
        }

        var playlists: [RemotePlaylistSummary] = []
        var nextToken: String?
        if let actions = root["onResponseReceivedActions"] {
            collectUserPlaylists(in: actions, currentDisplayName: currentDisplayName, playlists: &playlists, continuation: &nextToken)
        }
        if playlists.isEmpty, let cont = root["continuationContents"] {
            collectUserPlaylists(in: cont, currentDisplayName: currentDisplayName, playlists: &playlists, continuation: &nextToken)
        }
        return ParsedUserPlaylistsPage(playlists: playlists, continuationToken: nextToken)
    }

    private static func collectUserPlaylists(
        in node: Any,
        currentDisplayName: String?,
        playlists: inout [RemotePlaylistSummary],
        continuation: inout String?
    ) {
        if let array = node as? [Any] {
            for element in array {
                collectUserPlaylists(in: element, currentDisplayName: currentDisplayName, playlists: &playlists, continuation: &continuation)
            }
            return
        }
        guard let dict = node as? [String: Any] else { return }

        if let summary = parseUserPlaylistEntry(dict, currentDisplayName: currentDisplayName) {
            playlists.append(summary)
            return
        }
        if continuation == nil {
            if let conts = dict["continuations"] as? [[String: Any]] {
                for c in conts {
                    if let token = (c["nextContinuationData"] as? [String: Any])?["continuation"] as? String, !token.isEmpty {
                        continuation = token
                        break
                    }
                }
            }
            if continuation == nil,
               let cir = dict["continuationItemRenderer"] as? [String: Any],
               let token = ((cir["continuationEndpoint"] as? [String: Any])?["continuationCommand"] as? [String: Any])?["token"] as? String,
               !token.isEmpty {
                continuation = token
            }
        }

        for (key, value) in dict where key != "header" && key != "responseContext" {
            collectUserPlaylists(in: value, currentDisplayName: currentDisplayName, playlists: &playlists, continuation: &continuation)
        }
    }

    private static func parseUserPlaylistEntry(
        _ entry: [String: Any],
        currentDisplayName: String?
    ) -> RemotePlaylistSummary? {
        if let card = entry["musicTwoRowItemRenderer"] as? [String: Any] {
            guard let targetID = extractPlaylistTargetID(from: card) else {
                return nil
            }
            return makeRemotePlaylistSummary(
                rawID: targetID,
                title: joinedRunsText(card["title"]),
                subtitleRuns: ((card["subtitle"] as? [String: Any])?["runs"] as? [[String: Any]]) ?? [],
                thumbnailObj: card["thumbnailRenderer"] ?? card["thumbnail"],
                menuObj: card["menu"],
                currentDisplayName: currentDisplayName
            )
        }
        if let row = entry["musicResponsiveListItemRenderer"] as? [String: Any] {
            let flexCols = row["flexColumns"] as? [[String: Any]] ?? []
            guard let targetID = extractPlaylistTargetID(from: row, flexCols: flexCols) else {
                return nil
            }
            let title = joinedRunsText((flexCols.first?["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any])?["text"])
            let subtitleRuns = flexColumnRuns(at: 1, in: flexCols)
            return makeRemotePlaylistSummary(
                rawID: targetID,
                title: title,
                subtitleRuns: subtitleRuns,
                thumbnailObj: row["thumbnail"],
                menuObj: row["menu"],
                currentDisplayName: currentDisplayName
            )
        }
        if let lockup = entry["lockupViewModel"] as? [String: Any] {
            let onTapCmd = ((lockup["rendererContext"] as? [String: Any])?["commandContext"] as? [String: Any])?["onTap"] as? [String: Any]
            let browseID = ((onTapCmd?["innertubeCommand"] as? [String: Any])?["browseEndpoint"] as? [String: Any])?["browseId"] as? String
            let contentID = lockup["contentId"] as? String
            guard let targetID = browseID?.nilIfEmpty ?? contentID?.nilIfEmpty else {
                return nil
            }
            let metaVM = (lockup["metadata"] as? [String: Any])?["lockupMetadataViewModel"] as? [String: Any]
            let title = (metaVM?["title"] as? [String: Any])?["content"] as? String
            let rows = ((metaVM?["metadata"] as? [String: Any])?["contentMetadataViewModel"] as? [String: Any])?["metadataRows"] as? [[String: Any]] ?? []
            var subtitleRuns: [[String: Any]] = []
            for row in rows {
                for part in (row["metadataParts"] as? [[String: Any]] ?? []) {
                    if let text = (part["text"] as? [String: Any])?["content"] as? String, !text.isEmpty {
                        subtitleRuns.append(["text": text])
                    }
                }
            }
            let imgSources = (((lockup["contentImage"] as? [String: Any])?["collectionThumbnailViewModel"] as? [String: Any])?["primaryThumbnail"] as? [String: Any])?["thumbnailViewModel"] as? [String: Any]
                ?? (lockup["contentImage"] as? [String: Any])?["thumbnailViewModel"] as? [String: Any]
            let thumbObj = ((imgSources?["image"] as? [String: Any])?["sources"] as? [[String: Any]]).map { ["thumbnails": $0] }
            return makeRemotePlaylistSummary(
                rawID: targetID,
                title: title,
                subtitleRuns: subtitleRuns,
                thumbnailObj: thumbObj,
                menuObj: nil,
                currentDisplayName: currentDisplayName
            )
        }
        return nil
    }

    private static func extractPlaylistTargetID(from renderer: [String: Any], flexCols: [[String: Any]] = []) -> String? {
        if let browseID = (((renderer["navigationEndpoint"] as? [String: Any])?["browseEndpoint"] as? [String: Any])?["browseId"] as? String)?.nilIfEmpty {
            return browseID
        }
        if let plID = (((renderer["navigationEndpoint"] as? [String: Any])?["watchPlaylistEndpoint"] as? [String: Any])?["playlistId"] as? String)?.nilIfEmpty {
            return plID
        }
        for run in (((renderer["title"] as? [String: Any])?["runs"] as? [[String: Any]]) ?? []) {
            if let browseID = (((run["navigationEndpoint"] as? [String: Any])?["browseEndpoint"] as? [String: Any])?["browseId"] as? String)?.nilIfEmpty {
                return browseID
            }
        }
        for run in flexColumnRuns(at: 0, in: flexCols) {
            if let browseID = (((run["navigationEndpoint"] as? [String: Any])?["browseEndpoint"] as? [String: Any])?["browseId"] as? String)?.nilIfEmpty {
                return browseID
            }
        }
        if let overlay = (renderer["thumbnailOverlay"] as? [String: Any]) ?? (renderer["overlay"] as? [String: Any]),
           let playBtn = ((overlay["musicItemThumbnailOverlayRenderer"] as? [String: Any])?["content"] as? [String: Any])?["musicPlayButtonRenderer"] as? [String: Any],
           let watchEp = (playBtn["playNavigationEndpoint"] as? [String: Any])?["watchPlaylistEndpoint"] as? [String: Any],
           let plID = (watchEp["playlistId"] as? String)?.nilIfEmpty {
            return plID
        }
        return nil
    }

    private static func makeRemotePlaylistSummary(
        rawID: String,
        title: String?,
        subtitleRuns: [[String: Any]],
        thumbnailObj: Any?,
        menuObj: Any?,
        currentDisplayName: String?
    ) -> RemotePlaylistSummary? {
        let cleanID: String
        if rawID == "FEmusic_liked_videos" || rawID == "VLLM" || rawID == "LM" {
            cleanID = "LM"
        } else if rawID == "VLSE" || rawID == "SE" {
            return nil
        } else if rawID.hasPrefix("VL"), rawID.count > 2 {
            cleanID = YouTubeMusicURL.stripVLPrefix(rawID)
        } else if rawID.hasPrefix("PL") || rawID.hasPrefix("RDCLAK5uy_") || rawID.hasPrefix("OLAK5uy_") {
            cleanID = rawID
        } else {
            return nil
        }

        guard YouTubeMusicURL.isValidID(cleanID),
              let cleanTitle = title?.nilIfEmpty,
              let url = URL(string: "https://music.youtube.com/playlist?list=\(cleanID)") else {
            return nil
        }

        var owner: String?
        var trackCount: Int?
        var markedPrivateOrOwned = false
        let rawSegments = subtitleRuns
            .compactMap { $0["text"] as? String }
            .flatMap { $0.replacingOccurrences(of: "·", with: "•").components(separatedBy: "•") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for seg in rawSegments {
            let lower = seg.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            if lower == "playlist" || lower == "auto playlist" || lower == "playlist automatique" {
                continue
            }
            if lower == "private" || lower == "privee" || lower == "unlisted" || lower == "non repertoriee" || lower == "public" || lower == "publique" {
                markedPrivateOrOwned = true
                continue
            }
            if let parsedCount = parsePlaylistTrackCount(seg) {
                trackCount = parsedCount
                continue
            }
            if owner == nil {
                owner = seg
            }
        }

        let isLiked = (cleanID == "LM")
        let isOwned: Bool?
        if isLiked || markedPrivateOrOwned || hasOwnedPlaylistMenu(menuObj) {
            isOwned = true
        } else {
            isOwned = matchesDisplayName(owner, currentDisplayName: currentDisplayName)
        }

        return RemotePlaylistSummary(
            id: cleanID,
            title: cleanTitle,
            owner: owner,
            trackCount: trackCount,
            artworkURL: largestThumbnailURL(in: thumbnailObj),
            url: url,
            isLikedSongs: isLiked,
            isOwned: isOwned
        )
    }

    private static func hasOwnedPlaylistMenu(_ menuObj: Any?) -> Bool {
        guard let items = ((menuObj as? [String: Any])?["menuRenderer"] as? [String: Any])?["items"] as? [[String: Any]] else {
            return false
        }
        for item in items {
            if let nav = item["menuNavigationItemRenderer"] as? [String: Any] {
                let icon = ((nav["icon"] as? [String: Any])?["iconType"] as? String) ?? ""
                if icon == "DELETE" || icon == "EDIT" { return true }
            }
            if let srv = item["menuServiceItemRenderer"] as? [String: Any] {
                let ep = srv["serviceEndpoint"] as? [String: Any]
                if ep?["deletePlaylistEndpoint"] != nil || ep?["playlistEditEndpoint"] != nil {
                    return true
                }
                if let confirm = (ep?["confirmDialogEndpoint"] as? [String: Any])?["content"] as? [String: Any],
                   let confirmData = try? JSONSerialization.data(withJSONObject: confirm),
                   let str = String(data: confirmData, encoding: .utf8),
                   str.contains("deletePlaylistEndpoint") {
                    return true
                }
            }
        }
        return false
    }

    private static func matchesDisplayName(_ owner: String?, currentDisplayName: String?) -> Bool? {
        guard let currentDisplayName = currentDisplayName?.nilIfEmpty,
              let owner = owner?.nilIfEmpty else {
            return nil
        }
        return owner.caseInsensitiveCompare(currentDisplayName) == .orderedSame
    }

    private static func extractTrackCountFromBrowseHeader(data: Data) -> Int? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let tabs = ((root["contents"] as? [String: Any])?["twoColumnBrowseResultsRenderer"] as? [String: Any])?["tabs"] as? [[String: Any]] ?? []
        let firstTab = (((tabs.first?["tabRenderer"] as? [String: Any])?["content"] as? [String: Any])?["sectionListRenderer"] as? [String: Any])?["contents"] as? [[String: Any]] ?? []
        var hdr: [String: Any]?
        for entry in firstTab {
            if let r = entry["musicResponsiveHeaderRenderer"] as? [String: Any] { hdr = r; break }
            if let e = entry["musicEditablePlaylistDetailHeaderRenderer"] as? [String: Any],
               let inner = (e["header"] as? [String: Any])?["musicResponsiveHeaderRenderer"] as? [String: Any] { hdr = inner; break }
            if let r = entry["musicDetailHeaderRenderer"] as? [String: Any] { hdr = r; break }
        }
        if hdr == nil, let topHeader = root["header"] as? [String: Any] {
            if let r = topHeader["musicResponsiveHeaderRenderer"] as? [String: Any] { hdr = r }
            else if let e = topHeader["musicEditablePlaylistDetailHeaderRenderer"] as? [String: Any],
                    let inner = ((e["header"] as? [String: Any])?["musicResponsiveHeaderRenderer"] as? [String: Any])
                        ?? ((e["header"] as? [String: Any])?["musicDetailHeaderRenderer"] as? [String: Any]) { hdr = inner }
            else if let r = topHeader["musicDetailHeaderRenderer"] as? [String: Any] { hdr = r }
        }
        guard let hdr else { return nil }
        for key in ["secondSubtitle", "subtitle"] {
            let runs = ((hdr[key] as? [String: Any])?["runs"] as? [[String: Any]]) ?? []
            for run in runs {
                if let text = run["text"] as? String, let count = parsePlaylistTrackCount(text) {
                    return count
                }
            }
        }
        return nil
    }

    private static func hasEditablePlaylistHeader(data: Data) -> Bool {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        if (root["header"] as? [String: Any])?["musicEditablePlaylistDetailHeaderRenderer"] != nil {
            return true
        }
        let tabs = ((root["contents"] as? [String: Any])?["twoColumnBrowseResultsRenderer"] as? [String: Any])?["tabs"] as? [[String: Any]] ?? []
        let firstTab = (((tabs.first?["tabRenderer"] as? [String: Any])?["content"] as? [String: Any])?["sectionListRenderer"] as? [String: Any])?["contents"] as? [[String: Any]] ?? []
        return firstTab.contains { $0["musicEditablePlaylistDetailHeaderRenderer"] != nil }
    }

    private static func parsePlaylistTrackCount(_ text: String) -> Int? {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let keywords = ["song", "track", "video", "titre", "chanson", "morceau", "element", "musique"]
        guard keywords.contains(where: { folded.contains($0) }) else {
            return nil
        }
        let digits = text.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }
        guard !digits.isEmpty else { return nil }
        return Int(String(String.UnicodeScalarView(digits)))
    }

    // MARK: - Search

    public static func parseSearchTracks(data: Data) throws -> [TrackRef] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw PluginError(code: .apiChanged, message: "YouTube Music search response is not valid JSON.")
        }
        let tabs = ((root["contents"] as? [String: Any])?["tabbedSearchResultsRenderer"] as? [String: Any])?["tabs"] as? [[String: Any]] ?? []
        var sections: [[String: Any]] = []
        for tab in tabs {
            if let s = (((tab["tabRenderer"] as? [String: Any])?["content"] as? [String: Any])?["sectionListRenderer"] as? [String: Any])?["contents"] as? [[String: Any]] {
                sections.append(contentsOf: s)
            }
        }

        var results: [TrackRef] = []
        for section in sections {
            guard let shelf = section["musicShelfRenderer"] as? [String: Any],
                  let contents = shelf["contents"] as? [[String: Any]] else { continue }
            for entry in contents {
                guard let renderer = entry["musicResponsiveListItemRenderer"] as? [String: Any],
                      let track = parseTrackRenderer(renderer, albumDefaults: nil, fallbackTrackNum: nil) else {
                    continue
                }
                results.append(track)
            }
        }
        return results
    }

    public static func selectBestMatch(
        candidates: [TrackRef],
        input: PlaylistAddTrackInput
    ) -> TrackRef? {
        guard !candidates.isEmpty else { return nil }
        let wantedTitle = normalizeMatchString(input.title)
        let wantedArtist = normalizeMatchString(input.artist)
        let wantedAlbum = input.album.map(normalizeMatchString)

        let rejectModifiers = ["remix", "live", "karaoke", "instrumental", "cover", "sped up", "slowed", "reverb", "8d", "nightcore"]
        let wantedTokens = wantedTitle + " " + (wantedAlbum ?? "")

        var best: TrackRef?
        var bestScore = Int.min

        for cand in candidates {
            let candTitle = normalizeMatchString(cand.title)
            let candArtists = cand.artists.map(normalizeMatchString)
            let candAlbum = cand.album.map(normalizeMatchString)
            var score = 0

            if candTitle == wantedTitle {
                score += 60
            } else if candTitle.contains(wantedTitle) || wantedTitle.contains(candTitle) {
                score += 30
            } else {
                score -= 25
            }

            if !wantedArtist.isEmpty {
                if candArtists.contains(where: { $0 == wantedArtist }) {
                    score += 45
                } else if candArtists.contains(where: { $0.contains(wantedArtist) || wantedArtist.contains($0) }) {
                    score += 25
                } else {
                    score -= 30
                }
            }

            if let wantedAlbum, !wantedAlbum.isEmpty, let candAlbum, !candAlbum.isEmpty {
                if candAlbum == wantedAlbum || candAlbum.contains(wantedAlbum) || wantedAlbum.contains(candAlbum) {
                    score += 12
                }
            }

            if let wantedMs = input.durationMs, wantedMs > 0, let candMs = cand.durationMs, candMs > 0 {
                let diffSec = abs(wantedMs - candMs) / 1000
                if diffSec <= 2 { score += 15 }
                else if diffSec <= 5 { score += 8 }
                else if diffSec > 20 { score -= 25 }
            }

            for mod in rejectModifiers {
                if candTitle.contains(mod) && !wantedTokens.contains(mod) {
                    score -= 40
                }
            }

            if score > bestScore {
                bestScore = score
                best = cand
            }
        }

        // Reject completely unrelated hits.
        return bestScore >= 20 ? best : nil
    }

    // MARK: - Helpers

    public struct ParsedHeaderInfo: Sendable {
        public var title: String?
        public var owner: String?
        public var artworkURL: URL?
        public var releaseDate: String?
        public var albumArtist: String?
    }

    public static func headerInfo(from page: ParsedBrowsePage, target: YouTubeMusicTarget) -> ParsedHeaderInfo {
        ParsedHeaderInfo(
            title: target.kind == .album ? page.title : nil,
            owner: page.owner,
            artworkURL: target.kind == .album ? page.artworkURL : nil,
            releaseDate: target.kind == .album ? page.releaseDate : nil,
            albumArtist: target.kind == .album ? page.albumArtist : nil
        )
    }

    private static func parseHeader(twoCol: [String: Any], root: [String: Any], target: YouTubeMusicTarget) -> ParsedHeaderInfo {
        let tabs = twoCol["tabs"] as? [[String: Any]] ?? []
        let firstTabContents = (((tabs.first?["tabRenderer"] as? [String: Any])?["content"] as? [String: Any])?["sectionListRenderer"] as? [String: Any])?["contents"] as? [[String: Any]] ?? []

        var hdr: [String: Any]?
        for entry in firstTabContents {
            if let r = entry["musicResponsiveHeaderRenderer"] as? [String: Any] {
                hdr = r
                break
            }
            if let editable = entry["musicEditablePlaylistDetailHeaderRenderer"] as? [String: Any],
               let inner = (editable["header"] as? [String: Any])?["musicResponsiveHeaderRenderer"] as? [String: Any] {
                hdr = inner
                break
            }
            if let r = entry["musicDetailHeaderRenderer"] as? [String: Any] {
                hdr = r
                break
            }
        }
        if hdr == nil, let topHeader = root["header"] as? [String: Any] {
            if let r = topHeader["musicResponsiveHeaderRenderer"] as? [String: Any] {
                hdr = r
            } else if let editable = topHeader["musicEditablePlaylistDetailHeaderRenderer"] as? [String: Any],
                      let inner = ((editable["header"] as? [String: Any])?["musicResponsiveHeaderRenderer"] as? [String: Any])
                        ?? ((editable["header"] as? [String: Any])?["musicDetailHeaderRenderer"] as? [String: Any]) {
                hdr = inner
            } else if let r = topHeader["musicDetailHeaderRenderer"] as? [String: Any] {
                hdr = r
            }
        }

        let micro = (root["microformat"] as? [String: Any])?["microformatDataRenderer"] as? [String: Any]
        let title = hdr.flatMap { joinedRunsText($0["title"]) }
            ?? (micro?["title"] as? String).flatMap { cleanMicroTitle($0) }

        var owner: String? = ((hdr?["facepile"] as? [String: Any])?["avatarStackViewModel"] as? [String: Any])
            .flatMap { ($0["text"] as? [String: Any])?["content"] as? String }
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        let straplineRuns = ((hdr?["straplineTextOne"] as? [String: Any])?["runs"] as? [[String: Any]]) ?? []
        let straplineArtists = extractArtists(fromRuns: straplineRuns)
        if owner == nil || owner?.isEmpty == true {
            if !straplineArtists.isEmpty {
                owner = straplineArtists.joined(separator: ", ")
            }
        }

        var releaseDate: String?
        let subtitleRuns = ((hdr?["subtitle"] as? [String: Any])?["runs"] as? [[String: Any]]) ?? []
        for run in subtitleRuns {
            guard let text = (run["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty, text != "•" else { continue }
            if isYearOrDateString(text) {
                releaseDate = text
            } else if owner == nil && target.kind == .playlist {
                let lower = text.lowercased()
                if lower != "playlist" && lower != "chart" && lower != "album" && lower != "ep" && lower != "single" {
                    owner = text
                }
            }
        }

        let artworkURL = hdr.flatMap { largestThumbnailURL(in: $0["thumbnail"]) }
            ?? largestThumbnailURL(in: micro?["thumbnail"])

        return ParsedHeaderInfo(
            title: title,
            owner: (owner?.isEmpty == false) ? owner : nil,
            artworkURL: artworkURL,
            releaseDate: releaseDate,
            albumArtist: target.kind == .album ? straplineArtists.first : nil
        )
    }

    private static func parseTrackItems(
        _ rawItems: [[String: Any]],
        target: YouTubeMusicTarget,
        headerInfo: ParsedHeaderInfo,
        trackIndexOffset: Int
    ) -> [TrackRef] {
        var out: [TrackRef] = []
        let albumDefaults: ParsedHeaderInfo? = (target.kind == .album) ? headerInfo : nil
        for (idx, item) in rawItems.enumerated() {
            guard let renderer = item["musicResponsiveListItemRenderer"] as? [String: Any] else { continue }
            if let track = parseTrackRenderer(
                renderer,
                albumDefaults: albumDefaults,
                fallbackTrackNum: target.kind == .album ? (trackIndexOffset + idx + 1) : nil
            ) {
                out.append(track)
            }
        }
        return out
    }

    private static func parseTrackRenderer(
        _ renderer: [String: Any],
        albumDefaults: ParsedHeaderInfo?,
        fallbackTrackNum: Int?
    ) -> TrackRef? {
        let itemData = renderer["playlistItemData"] as? [String: Any]
        let videoID = (itemData?["videoId"] as? String)
            ?? extractWatchVideoID(from: renderer)
            ?? ""
        guard !videoID.isEmpty else { return nil }

        let setVideoID = (itemData?["playlistSetVideoId"] as? String)
            ?? extractSetVideoIDFromMenu(renderer["menu"])

        let flexCols = renderer["flexColumns"] as? [[String: Any]] ?? []
        let col0Runs = flexColumnRuns(at: 0, in: flexCols)
        let col1Runs = flexColumnRuns(at: 1, in: flexCols)
        let col2Runs = flexColumnRuns(at: 2, in: flexCols)

        guard let title = col0Runs.compactMap({ $0["text"] as? String }).joined().nilIfEmpty else {
            return nil
        }

        var artists: [String] = []
        var album: String?
        var durationMs: Int?

        // In Search / Playlist responses, col1 may contain "Artist • Album • 3:34" or just "Artist".
        let col1Parsed = parseMetadataRuns(col1Runs)
        artists.append(contentsOf: col1Parsed.artists)
        if album == nil { album = col1Parsed.album }
        if durationMs == nil { durationMs = col1Parsed.durationMs }

        // In Playlist responses, col2 may hold an Album link OR a release date OR play count.
        let col2Parsed = parseMetadataRuns(col2Runs)
        if album == nil { album = col2Parsed.album }
        if durationMs == nil { durationMs = col2Parsed.durationMs }

        if durationMs == nil, let fixedCols = renderer["fixedColumns"] as? [[String: Any]] {
            for fc in fixedCols {
                if let fixed = fc["musicResponsiveListItemFixedColumnRenderer"] as? [String: Any],
                   let durText = joinedRunsText(fixed["text"]),
                   let parsed = parseDurationMs(durText) {
                    durationMs = parsed
                    break
                }
            }
        }

        if artists.isEmpty, let fallbackArtist = albumDefaults?.albumArtist {
            artists = [fallbackArtist]
        }
        if album == nil, let defaultAlbum = albumDefaults?.title {
            album = defaultAlbum
        }

        let explicit = hasExplicitBadge(in: renderer["badges"])
        let artworkURL = largestThumbnailURL(in: renderer["thumbnail"]) ?? albumDefaults?.artworkURL
        let indexText = joinedRunsText((renderer["index"] as? [String: Any]))
        let trackNum = indexText.flatMap { Int($0) } ?? fallbackTrackNum

        let videoType = extractWatchVideoType(from: renderer)
        let isVideo: Bool? = {
            if let videoType {
                if videoType == "MUSIC_VIDEO_TYPE_ATV" { return false }
                if videoType.hasPrefix("MUSIC_VIDEO_TYPE_") { return true }
            }
            if albumDefaults == nil && album == nil && hasYouTubeVideoThumbnail(in: renderer["thumbnail"]) {
                return true
            }
            return nil
        }()

        return TrackRef(
            source: "youtube-music",
            sourceID: videoID,
            title: title,
            artists: artists,
            album: album,
            albumArtist: albumDefaults?.albumArtist ?? artists.first,
            trackNumber: trackNum,
            discNumber: 1,
            durationMs: durationMs,
            isrc: nil,
            releaseDate: albumDefaults?.releaseDate,
            artworkURL: artworkURL,
            explicit: explicit,
            remoteItemUID: setVideoID,
            isVideo: isVideo
        )
    }

    private static func extractWatchVideoType(from renderer: [String: Any]) -> String? {
        func videoType(fromWatchEndpoint ep: [String: Any]?) -> String? {
            ((ep?["watchEndpointMusicSupportedConfigs"] as? [String: Any])?["watchEndpointMusicConfig"] as? [String: Any])?["musicVideoType"] as? String
        }
        if let playBtn = (((renderer["overlay"] as? [String: Any])?["musicItemThumbnailOverlayRenderer"] as? [String: Any])?["content"] as? [String: Any])?["musicPlayButtonRenderer"] as? [String: Any],
           let vt = videoType(fromWatchEndpoint: (playBtn["playNavigationEndpoint"] as? [String: Any])?["watchEndpoint"] as? [String: Any]) {
            return vt
        }
        let runs = flexColumnRuns(at: 0, in: (renderer["flexColumns"] as? [[String: Any]]) ?? [])
        for run in runs {
            if let vt = videoType(fromWatchEndpoint: (run["navigationEndpoint"] as? [String: Any])?["watchEndpoint"] as? [String: Any]) {
                return vt
            }
        }
        if let vt = videoType(fromWatchEndpoint: (renderer["navigationEndpoint"] as? [String: Any])?["watchEndpoint"] as? [String: Any]) {
            return vt
        }
        return nil
    }

    private static func hasYouTubeVideoThumbnail(in obj: Any?) -> Bool {
        guard let dict = obj as? [String: Any] else { return false }
        let thumbnails: [[String: Any]]? =
            ((dict["musicThumbnailRenderer"] as? [String: Any])?["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]]
            ?? (dict["thumbnails"] as? [[String: Any]])
        guard let thumbnails, !thumbnails.isEmpty else { return false }
        for entry in thumbnails {
            if let urlStr = entry["url"] as? String,
               (urlStr.contains("i.ytimg.com/vi") || urlStr.contains("ytimg.com/vi_webp")) {
                return true
            }
            if let w = entry["width"] as? Int, let h = entry["height"] as? Int, h > 0, w > Int(Double(h) * 1.2) {
                return true
            }
        }
        return false
    }

    private struct MetadataRunsResult {
        var artists: [String] = []
        var album: String?
        var durationMs: Int?
    }

    private static func parseMetadataRuns(_ runs: [[String: Any]]) -> MetadataRunsResult {
        var res = MetadataRunsResult()
        var currentSegmentIndex = 0
        for run in runs {
            guard let text = (run["text"] as? String) else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if text == " • " || trimmed == "•" {
                currentSegmentIndex += 1
                continue
            }
            if nonArtistSeparators.contains(text) || nonArtistSeparators.contains(trimmed) {
                continue
            }

            let browse = (run["navigationEndpoint"] as? [String: Any])?["browseEndpoint"] as? [String: Any]
            let browseID = browse?["browseId"] as? String ?? ""
            let pageType = ((browse?["browseEndpointContextSupportedConfigs"] as? [String: Any])?["browseEndpointContextMusicConfig"] as? [String: Any])?["pageType"] as? String ?? ""

            if browseID.hasPrefix("MPREb_") || pageType == "MUSIC_PAGE_TYPE_ALBUM" {
                if res.album == nil { res.album = trimmed }
                continue
            }
            if browseID.hasPrefix("UC") || pageType == "MUSIC_PAGE_TYPE_ARTIST" {
                res.artists.append(trimmed)
                continue
            }
            if let dur = parseDurationMs(trimmed) {
                res.durationMs = dur
                continue
            }
            if trimmed.lowercased().hasSuffix("plays") || trimmed.lowercased().hasSuffix("views") || isYearOrDateString(trimmed) {
                continue
            }

            // Heuristic fallback when artist has no linked browseId (e.g. "Topic" / compilation / unlinked artist):
            if currentSegmentIndex == 0 {
                res.artists.append(trimmed)
            } else if currentSegmentIndex == 1 && res.album == nil && browseID.isEmpty && !trimmed.contains(" • ") {
                // Only treat second bullet segment as album in search ("Artist • Album • 3:34").
                res.album = trimmed
            }
        }
        return res
    }

    private static func extractArtists(fromRuns runs: [[String: Any]]) -> [String] {
        var artists: [String] = []
        for run in runs {
            guard let text = (run["text"] as? String) else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || nonArtistSeparators.contains(text) || nonArtistSeparators.contains(trimmed) {
                continue
            }
            artists.append(trimmed)
        }
        return artists
    }

    private static func flexColumnRuns(at index: Int, in flexCols: [[String: Any]]) -> [[String: Any]] {
        guard index < flexCols.count else { return [] }
        let fc = flexCols[index]["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any]
        return ((fc?["text"] as? [String: Any])?["runs"] as? [[String: Any]]) ?? []
    }

    private static func joinedRunsText(_ obj: Any?) -> String? {
        guard let dict = obj as? [String: Any] else { return nil }
        if let simple = dict["simpleText"] as? String, !simple.isEmpty {
            return simple.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let runs = dict["runs"] as? [[String: Any]] {
            let joined = runs.compactMap { $0["text"] as? String }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            return joined.isEmpty ? nil : joined
        }
        return nil
    }

    private static func extractWatchVideoID(from renderer: [String: Any]) -> String? {
        if let playBtn = (((renderer["overlay"] as? [String: Any])?["musicItemThumbnailOverlayRenderer"] as? [String: Any])?["content"] as? [String: Any])?["musicPlayButtonRenderer"] as? [String: Any],
           let vid = ((playBtn["playNavigationEndpoint"] as? [String: Any])?["watchEndpoint"] as? [String: Any])?["videoId"] as? String {
            return vid
        }
        let runs = flexColumnRuns(at: 0, in: (renderer["flexColumns"] as? [[String: Any]]) ?? [])
        for run in runs {
            if let vid = ((run["navigationEndpoint"] as? [String: Any])?["watchEndpoint"] as? [String: Any])?["videoId"] as? String {
                return vid
            }
        }
        return nil
    }

    private static func extractSetVideoIDFromMenu(_ menuObj: Any?) -> String? {
        guard let items = ((menuObj as? [String: Any])?["menuRenderer"] as? [String: Any])?["items"] as? [[String: Any]] else {
            return nil
        }
        for item in items {
            guard let serviceItem = item["menuServiceItemRenderer"] as? [String: Any],
                  let edit = (serviceItem["serviceEndpoint"] as? [String: Any])?["playlistEditEndpoint"] as? [String: Any],
                  let actions = edit["actions"] as? [[String: Any]] else { continue }
            for act in actions {
                if let setID = act["setVideoId"] as? String, !setID.isEmpty {
                    return setID
                }
            }
        }
        return nil
    }

    private static func extractContinuationToken(shelf: [String: Any]?, items: [[String: Any]]) -> String? {
        if let conts = shelf?["continuations"] as? [[String: Any]] {
            for c in conts {
                if let token = (c["nextContinuationData"] as? [String: Any])?["continuation"] as? String, !token.isEmpty {
                    return token
                }
            }
        }
        for item in items.reversed() {
            if let cir = item["continuationItemRenderer"] as? [String: Any],
               let token = ((cir["continuationEndpoint"] as? [String: Any])?["continuationCommand"] as? [String: Any])?["token"] as? String,
               !token.isEmpty {
                return token
            }
        }
        return nil
    }

    private static func largestThumbnailURL(in obj: Any?) -> URL? {
        guard let dict = obj as? [String: Any] else { return nil }
        let thumbnails: [[String: Any]]? =
            ((dict["musicThumbnailRenderer"] as? [String: Any])?["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]]
            ?? (dict["thumbnails"] as? [[String: Any]])
        guard let thumbnails, !thumbnails.isEmpty else { return nil }
        var bestURL: URL?
        var bestArea = -1
        for entry in thumbnails {
            guard let urlStr = entry["url"] as? String,
                  let url = URL(string: urlStr) else { continue }
            let w = entry["width"] as? Int ?? 0
            let h = entry["height"] as? Int ?? 0
            let area = w * h
            if area >= bestArea {
                bestArea = area
                bestURL = url
            }
        }
        return bestURL
    }

    private static func hasExplicitBadge(in badgesObj: Any?) -> Bool {
        guard let badges = badgesObj as? [[String: Any]] else { return false }
        for b in badges {
            let iconType = ((b["musicInlineBadgeRenderer"] as? [String: Any])?["icon"] as? [String: Any])?["iconType"] as? String
            if iconType == "MUSIC_EXPLICIT_BADGE" {
                return true
            }
        }
        return false
    }

    private static func findUnavailableAlert(in root: [String: Any]) -> String? {
        guard let alerts = root["alerts"] as? [[String: Any]] else { return nil }
        for a in alerts {
            if let alertRenderer = a["alertRenderer"] as? [String: Any],
               let msg = joinedRunsText(alertRenderer["text"]) {
                return msg
            }
        }
        return nil
    }

    private static func cleanMicroTitle(_ raw: String) -> String? {
        let suffix = " - YouTube Music"
        let cleaned = raw.hasSuffix(suffix) ? String(raw.dropLast(suffix.count)) : raw
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Extracts the signed-in Google / YouTube account name (and handle when available) from `account/account_menu`.
    public static func extractAccountDisplayName(from json: Any) -> String? {
        if let header = findDictionary(named: "activeAccountHeaderRenderer", in: json),
           let resolved = displayName(fromAccountHeader: header) {
            return resolved
        }
        return findAccountNameFallback(in: json)
    }

    private static func displayName(fromAccountHeader header: [String: Any]) -> String? {
        let name = joinedRunsText(header["accountName"])?.nilIfEmpty
        let handle = joinedRunsText(header["channelHandle"])?.nilIfEmpty
        let email = joinedRunsText(header["email"])?.nilIfEmpty
        if let name {
            if let handle, !name.contains(handle) {
                return "\(name) (\(handle))"
            }
            return name
        }
        return handle ?? email
    }

    private static func findDictionary(named key: String, in node: Any) -> [String: Any]? {
        if let dict = node as? [String: Any] {
            if let match = dict[key] as? [String: Any] {
                return match
            }
            for value in dict.values {
                if let nested = findDictionary(named: key, in: value) {
                    return nested
                }
            }
        } else if let arr = node as? [Any] {
            for element in arr {
                if let nested = findDictionary(named: key, in: element) {
                    return nested
                }
            }
        }
        return nil
    }

    private static func findAccountNameFallback(in node: Any) -> String? {
        if let dict = node as? [String: Any] {
            if dict["accountName"] != nil, let resolved = displayName(fromAccountHeader: dict) {
                return resolved
            }
            for value in dict.values {
                if let nested = findAccountNameFallback(in: value) {
                    return nested
                }
            }
        } else if let arr = node as? [Any] {
            for element in arr {
                if let nested = findAccountNameFallback(in: element) {
                    return nested
                }
            }
        }
        return nil
    }

    private static func isYearOrDateString(_ s: String) -> Bool {
        if s.count == 4, let yr = Int(s), (1900...2100).contains(yr) {
            return true
        }
        let lower = s.lowercased()
        let months = ["jan ", "feb ", "mar ", "apr ", "may ", "jun ", "jul ", "aug ", "sep ", "oct ", "nov ", "dec "]
        return months.contains(where: { lower.hasPrefix($0) })
    }

    public static func parseDurationMs(_ raw: String) -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        let nums = parts.compactMap { Int($0) }
        guard nums.count == parts.count, nums.allSatisfy({ $0 >= 0 }) else { return nil }
        let seconds: Int
        if nums.count == 2 {
            guard nums[1] < 60 else { return nil }
            seconds = nums[0] * 60 + nums[1]
        } else {
            guard nums[1] < 60 && nums[2] < 60 else { return nil }
            seconds = nums[0] * 3600 + nums[1] * 60 + nums[2]
        }
        return seconds > 0 ? seconds * 1000 : nil
    }

    public static func computeRevision(title: String, trackIDs: [String]) -> String {
        let payload = ([title] + trackIDs).joined(separator: "\n")
        return SHA256.hex(Data(payload.utf8))
    }

    private static func normalizeMatchString(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "&", with: " and ")
        var scalars: [UnicodeScalar] = []
        var lastSpace = true
        for sc in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(sc) {
                scalars.append(sc)
                lastSpace = false
            } else if !lastSpace {
                scalars.append(" ")
                lastSpace = true
            }
        }
        return String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces)
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
