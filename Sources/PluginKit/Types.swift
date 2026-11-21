import Foundation

// MARK: - Roles

/// Capabilities a plug-in can declare in `plugin.json` and implement in `PluginMain`.
public enum PluginRole: String, Codable, Sendable, CaseIterable, Hashable {
    case playlistSource
    case resolver
    case downloader
    case share
    case metadataProvider
    case lyricsProvider

    public var badgeLabel: String {
        switch self {
        case .playlistSource: "Playlists"
        case .resolver: "Search"
        case .downloader: "Download"
        case .share: "Sharing"
        case .metadataProvider: "Metadata"
        case .lyricsProvider: "Lyrics"
        }
    }
}

// MARK: - Core Data Types

public struct TrackRef: Codable, Sendable, Equatable, Hashable {
    public var source: String
    public var sourceID: String
    public var title: String
    public var artists: [String]
    public var album: String?
    public var albumArtist: String?
    public var trackNumber: Int?
    public var discNumber: Int?
    public var durationMs: Int?
    public var isrc: String?
    public var releaseDate: String?
    public var artworkURL: URL?
    public var explicit: Bool?
    /// Optional provider-native item identifier (e.g. Spotify playlist item UID) for remote reordering.
    public var remoteItemUID: String?

    public init(
        source: String,
        sourceID: String,
        title: String,
        artists: [String],
        album: String? = nil,
        albumArtist: String? = nil,
        trackNumber: Int? = nil,
        discNumber: Int? = nil,
        durationMs: Int? = nil,
        isrc: String? = nil,
        releaseDate: String? = nil,
        artworkURL: URL? = nil,
        explicit: Bool? = nil,
        remoteItemUID: String? = nil
    ) {
        self.source = source
        self.sourceID = sourceID
        self.title = title
        self.artists = artists
        self.album = album
        self.albumArtist = albumArtist
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.durationMs = durationMs
        self.isrc = isrc
        self.releaseDate = releaseDate
        self.artworkURL = artworkURL
        self.explicit = explicit
        self.remoteItemUID = remoteItemUID
    }
}

public struct Playlist: Codable, Sendable, Equatable, Hashable {
    public var source: String
    public var sourceID: String
    public var title: String
    public var owner: String?
    public var artworkURL: URL?
    public var revision: String

    public init(
        source: String,
        sourceID: String,
        title: String,
        owner: String? = nil,
        artworkURL: URL? = nil,
        revision: String
    ) {
        self.source = source
        self.sourceID = sourceID
        self.title = title
        self.owner = owner
        self.artworkURL = artworkURL
        self.revision = revision
    }
}

/// Request to resolve local tracks against a remote `PlaylistEditable` source and append them.
public struct PlaylistAddTrackInput: Codable, Sendable, Equatable, Hashable {
    public var title: String
    public var artist: String
    public var album: String?
    public var durationMs: Int?
    public var isrc: String?

    public init(
        title: String,
        artist: String,
        album: String? = nil,
        durationMs: Int? = nil,
        isrc: String? = nil
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.durationMs = durationMs
        self.isrc = isrc
    }
}

public struct PlaylistAddTracksRequest: Codable, Sendable, Equatable {
    public var playlistID: String
    public var tracks: [PlaylistAddTrackInput]

    public init(playlistID: String, tracks: [PlaylistAddTrackInput]) {
        self.playlistID = playlistID
        self.tracks = tracks
    }
}

public struct PlaylistAddedTrackResult: Codable, Sendable, Equatable {
    public var index: Int
    public var matchedTrack: TrackRef

    public init(index: Int, matchedTrack: TrackRef) {
        self.index = index
        self.matchedTrack = matchedTrack
    }
}

public struct PlaylistAddTracksResult: Codable, Sendable, Equatable {
    public var added: [PlaylistAddedTrackResult]
    public var notFoundTitles: [String]

    public init(added: [PlaylistAddedTrackResult], notFoundTitles: [String] = []) {
        self.added = added
        self.notFoundTitles = notFoundTitles
    }
}

public struct PlaylistRenameRequest: Codable, Sendable, Equatable {
    public var playlistID: String
    public var name: String

    public init(playlistID: String, name: String) {
        self.playlistID = playlistID
        self.name = name
    }
}

public struct PlaylistRemoveTracksRequest: Codable, Sendable, Equatable {
    public var playlistID: String
    public var trackIDs: [String]
    public var itemUIDs: [String]

    public init(playlistID: String, trackIDs: [String], itemUIDs: [String] = []) {
        self.playlistID = playlistID
        self.trackIDs = trackIDs
        self.itemUIDs = itemUIDs
    }
}

public struct PlaylistCreateRequest: Codable, Sendable, Equatable {
    public var name: String
    public var description: String?

    public init(name: String, description: String? = nil) {
        self.name = name
        self.description = description
    }
}

public struct PlaylistCreateResult: Codable, Sendable, Equatable {
    public var playlist: Playlist
    public var url: URL

    public init(playlist: Playlist, url: URL) {
        self.playlist = playlist
        self.url = url
    }
}

public struct PlaylistArtworkRequest: Codable, Sendable, Equatable {
    public var playlistID: String
    public var jpegData: Data?

    public init(playlistID: String, jpegData: Data?) {
        self.playlistID = playlistID
        self.jpegData = jpegData
    }
}

public struct Availability: Codable, Sendable, Equatable, Hashable {
    public var freeSlot: Bool
    public var queueLength: Int
    public var speedBytesPerSec: Int

    public init(freeSlot: Bool, queueLength: Int, speedBytesPerSec: Int) {
        self.freeSlot = freeSlot
        self.queueLength = queueLength
        self.speedBytesPerSec = speedBytesPerSec
    }
}

public struct Candidate: Codable, Sendable, Equatable, Hashable {
    public var resolver: String
    public var token: String
    public var displayName: String
    public var title: String?
    public var artist: String?
    public var album: String?
    public var durationMs: Int?
    public var container: String
    public var codec: String?
    public var bitrateKbps: Int?
    public var sampleRateHz: Int?
    public var bitDepth: Int?
    public var sizeBytes: Int64?
    public var availability: Availability?
    public var hint: Double? {
        didSet { hint = Self.clampHint(hint) }
    }

    public init(
        resolver: String,
        token: String,
        displayName: String,
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        durationMs: Int? = nil,
        container: String,
        codec: String? = nil,
        bitrateKbps: Int? = nil,
        sampleRateHz: Int? = nil,
        bitDepth: Int? = nil,
        sizeBytes: Int64? = nil,
        availability: Availability? = nil,
        hint: Double? = nil
    ) {
        self.resolver = resolver
        self.token = token
        self.displayName = displayName
        self.title = title
        self.artist = artist
        self.album = album
        self.durationMs = durationMs
        self.container = container
        self.codec = codec
        self.bitrateKbps = bitrateKbps
        self.sampleRateHz = sampleRateHz
        self.bitDepth = bitDepth
        self.sizeBytes = sizeBytes
        self.availability = availability
        self.hint = Self.clampHint(hint)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        resolver = try c.decode(String.self, forKey: .resolver)
        token = try c.decode(String.self, forKey: .token)
        displayName = try c.decode(String.self, forKey: .displayName)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        artist = try c.decodeIfPresent(String.self, forKey: .artist)
        album = try c.decodeIfPresent(String.self, forKey: .album)
        durationMs = try c.decodeIfPresent(Int.self, forKey: .durationMs)
        container = try c.decode(String.self, forKey: .container)
        codec = try c.decodeIfPresent(String.self, forKey: .codec)
        bitrateKbps = try c.decodeIfPresent(Int.self, forKey: .bitrateKbps)
        sampleRateHz = try c.decodeIfPresent(Int.self, forKey: .sampleRateHz)
        bitDepth = try c.decodeIfPresent(Int.self, forKey: .bitDepth)
        sizeBytes = try c.decodeIfPresent(Int64.self, forKey: .sizeBytes)
        availability = try c.decodeIfPresent(Availability.self, forKey: .availability)
        hint = Self.clampHint(try c.decodeIfPresent(Double.self, forKey: .hint))
    }

    public static func clampHint(_ value: Double?) -> Double? {
        guard let value else { return nil }
        if value.isNaN { return 0 }
        return min(max(value, 0), 1)
    }
}

public struct PlaylistFetchResult: Codable, Sendable, Equatable {
    public var playlist: Playlist
    public var tracks: [TrackRef]

    public init(playlist: Playlist, tracks: [TrackRef]) {
        self.playlist = playlist
        self.tracks = tracks
    }
}

public struct QualityPolicy: Codable, Sendable, Equatable {
    public static let defaultPreferredFormats = [
        "flac", "alac", "mp3-320", "aac-256", "mp3-v0", "other"
    ]

    public var preferredFormats: [String]
    public var minimumBitrateKbps: Int
    public var acceptYouTubeFallback: Bool

    public init(
        preferredFormats: [String] = QualityPolicy.defaultPreferredFormats,
        minimumBitrateKbps: Int = 192,
        acceptYouTubeFallback: Bool = true
    ) {
        self.preferredFormats = preferredFormats
        self.minimumBitrateKbps = minimumBitrateKbps
        self.acceptYouTubeFallback = acceptYouTubeFallback
    }
}

public struct ShareIndexEntry: Codable, Sendable, Equatable, Hashable {
    public var virtualPath: String
    public var realPath: String
    public var size: Int64
    public var bitrateKbps: Int?
    public var durationMs: Int?

    public init(
        virtualPath: String,
        realPath: String,
        size: Int64,
        bitrateKbps: Int? = nil,
        durationMs: Int? = nil
    ) {
        self.virtualPath = virtualPath
        self.realPath = realPath
        self.size = size
        self.bitrateKbps = bitrateKbps
        self.durationMs = durationMs
    }
}

// MARK: - Protocol Payloads & Notifications

public struct PluginHostInfo: Codable, Sendable, Equatable {
    public var os: String
    public var arch: String
    public var appVersion: String
    public var onIPod: Bool

    public init(os: String, arch: String, appVersion: String, onIPod: Bool) {
        self.os = os
        self.arch = arch
        self.appVersion = appVersion
        self.onIPod = onIPod
    }

    public static func current(appVersion: String = "0.1", onIPod: Bool = false) -> PluginHostInfo {
        #if os(macOS)
        let os = "macos"
        #elseif os(Windows)
        let os = "windows"
        #else
        let os = "linux"
        #endif
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        return PluginHostInfo(os: os, arch: arch, appVersion: appVersion, onIPod: onIPod)
    }
}

public struct PluginPaths: Codable, Sendable, Equatable {
    public var data: String
    public var cache: String
    public var temp: String
    public var ffmpeg: String?

    public init(data: String, cache: String, temp: String, ffmpeg: String? = nil) {
        self.data = data
        self.cache = cache
        self.temp = temp
        self.ffmpeg = ffmpeg
    }
}

public struct PluginInitializeParams: Codable, Sendable, Equatable {
    public var apiVersion: Int
    public var host: PluginHostInfo
    public var paths: PluginPaths
    public var settings: [String: JSONValue]
    public var config: [String: JSONValue]

    public init(
        apiVersion: Int = 1,
        host: PluginHostInfo,
        paths: PluginPaths,
        settings: [String: JSONValue] = [:],
        config: [String: JSONValue] = [:]
    ) {
        self.apiVersion = apiVersion
        self.host = host
        self.paths = paths
        self.settings = settings
        self.config = config
    }
}

public struct PluginInitializeResult: Codable, Sendable, Equatable {
    public var roles: [String]
    public var version: String

    public init(roles: [String], version: String) {
        self.roles = roles
        self.version = version
    }
}

public struct PluginProgress: Codable, Sendable, Equatable {
    public var requestID: String
    public var done: Double
    public var total: Double?
    public var message: String?

    public init(requestID: String = "", done: Double, total: Double? = nil, message: String? = nil) {
        self.requestID = requestID
        self.done = done
        self.total = total
        self.message = message
    }
}

public enum PluginLogLevel: String, Codable, Sendable {
    case debug, info, warning, error
}

public struct PluginLogMessage: Codable, Sendable, Equatable {
    public var level: PluginLogLevel
    public var message: String

    public init(level: PluginLogLevel, message: String) {
        self.level = level
        self.message = message
    }
}

public enum PluginRuntimeState: String, Codable, Sendable {
    case connecting, ready, error
}

public struct PluginStatusUpdate: Codable, Sendable, Equatable {
    public var state: PluginRuntimeState
    public var message: String?

    public init(state: PluginRuntimeState, message: String? = nil) {
        self.state = state
        self.message = message
    }
}

public struct PluginAccountStatus: Codable, Sendable, Equatable {
    public var status: String
    public var displayName: String?
    public var openURL: String?
    public var message: String?

    public init(status: String, displayName: String? = nil, openURL: String? = nil, message: String? = nil) {
        self.status = status
        self.displayName = displayName
        self.openURL = openURL
        self.message = message
    }
}

public struct PluginActionResult: Codable, Sendable, Equatable {
    public var message: String?

    public init(message: String? = nil) {
        self.message = message
    }
}

/// Request sent to `source/reorder` when the user drags items inside a subscribed playlist.
public struct PlaylistReorderRequest: Codable, Sendable, Equatable {
    public var playlistID: String
    public var movedItemUIDs: [String]
    public var beforeItemUID: String?
    public var afterItemUID: String?
    public var atStart: Bool
    public var atEnd: Bool
    public var rangeStart: Int
    public var rangeLength: Int
    public var insertBefore: Int

    public init(
        playlistID: String,
        movedItemUIDs: [String],
        beforeItemUID: String? = nil,
        afterItemUID: String? = nil,
        atStart: Bool = false,
        atEnd: Bool = false,
        rangeStart: Int,
        rangeLength: Int,
        insertBefore: Int
    ) {
        self.playlistID = playlistID
        self.movedItemUIDs = movedItemUIDs
        self.beforeItemUID = beforeItemUID
        self.afterItemUID = afterItemUID
        self.atStart = atStart
        self.atEnd = atEnd
        self.rangeStart = rangeStart
        self.rangeLength = rangeLength
        self.insertBefore = insertBefore
    }
}

// MARK: - Errors

public enum PluginErrorCode: String, Codable, Sendable, Equatable {
    case cancelled
    case notFound
    case unauthorized
    case rateLimited
    case network
    case apiChanged
    case unsupported
    case wrongResolver
    case `internal`
    case startTimeout
    case pluginCrashed
    case launchFailed
    case messageTooLarge
}

public struct PluginError: LocalizedError, Codable, Sendable, Equatable {
    public var code: PluginErrorCode
    public var message: String
    public var retryAfterSeconds: Int?

    public init(code: PluginErrorCode, message: String, retryAfterSeconds: Int? = nil) {
        self.code = code
        self.message = message
        self.retryAfterSeconds = retryAfterSeconds
    }

    public var errorDescription: String? { message }
}

// MARK: - Dynamic JSON Value

public enum JSONValue: Codable, Sendable, Equatable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? container.decode(Int.self) {
            self = .int(i)
        } else if let d = try? container.decode(Double.self) {
            self = .double(d)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let a = try? container.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? container.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let b): try container.encode(b)
        case .int(let i): try container.encode(i)
        case .double(let d): try container.encode(d)
        case .string(let s): try container.encode(s)
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        }
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var intValue: Int? {
        switch self {
        case .int(let i): return i
        case .double(let d) where d.rounded() == d: return Int(exactly: d)
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .double(let d): return d
        case .int(let i): return Double(i)
        default: return nil
        }
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var stringArrayValue: [String]? {
        guard case .array(let items) = self else { return nil }
        var out: [String] = []
        for item in items {
            guard case .string(let s) = item else { return nil }
            out.append(s)
        }
        return out
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }
}
