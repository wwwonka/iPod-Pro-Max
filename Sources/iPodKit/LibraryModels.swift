//
//  LibraryModels.swift
//  iPod Pro Max
//
//  The app's own library: songs, playlists and podcast subscriptions, persisted as JSON.
//

import Foundation

public enum TrackSource: String, Codable, Sendable {
    case file
    case musicApp
}

public enum MediaKind: String, Codable, Sendable {
    case song
    case video
    case audiobook
}

/// Which Videos submenu a video appears under on the iPod (Movies/TV Shows/Music Videos), driven by
/// the track's mediaType bits — no special playlist needed, unlike Podcasts.
public enum VideoCategory: String, Codable, CaseIterable, Sendable {
    case movie, tvShow, musicVideo

    public var title: String {
        switch self {
        case .movie: return "Movie"
        case .tvShow: return "TV Show"
        case .musicVideo: return "Music Video"
        }
    }
}

public struct LibraryTrack: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var path: String
    public var source: TrackSource = .file
    public var musicPersistentID: String?
    /// nil means song (older library files).
    public var kind: MediaKind?
    public var videoWidth: Int?
    public var videoHeight: Int?
    /// nil defaults to Movie for backward compatibility with libraries saved before categories existed.
    public var videoCategory: VideoCategory?

    public var title: String
    public var artist: String?
    public var album: String?
    public var albumArtist: String?
    public var genre: String?
    public var composer: String?
    public var comment: String?
    public var grouping: String?
    public var year: Int = 0
    public var trackNumber: Int = 0
    public var trackCount: Int = 0
    public var discNumber: Int = 0
    public var discCount: Int = 0
    public var durationMs: Int = 0
    /// kbit/s
    public var bitrate: Int = 0
    public var sampleRate: Int = 44100
    public var fileSize: Int64 = 0
    public var fileExtension: String
    public var isLossless: Bool = false
    public var compilation: Bool = false
    public var bpm: Int = 0
    public var hasLyrics: Bool = false
    /// 0…5 stars
    public var rating: Int = 0
    public var playCount: Int = 0
    public var lastPlayed: Date?
    public var dateAdded: Date = Date()
    public var dateModified: Date?
    public var artworkKey: String?
    public var syncEnabled: Bool = true

    public var url: URL { URL(fileURLWithPath: path) }

    public var mediaKind: MediaKind { kind ?? .song }
    public var isVideo: Bool { mediaKind == .video }
    public var isAudiobook: Bool { mediaKind == .audiobook }

    /// Songs in non-iPod formats are converted to AAC; every video is converted to iPod H.264.
    public var needsTranscode: Bool {
        if isVideo { return true }
        return !IPodFileType.nativeExtensions.contains(fileExtension.lowercased())
    }

    public var displayArtist: String { artist ?? albumArtist ?? "Unknown Artist" }
    public var displayAlbum: String { album ?? "Unknown Album" }

    public var fileExists: Bool { FileManager.default.fileExists(atPath: path) }

    public init(id: UUID = UUID(), path: String, source: TrackSource = .file, musicPersistentID: String? = nil, kind: MediaKind? = nil, videoWidth: Int? = nil, videoHeight: Int? = nil, videoCategory: VideoCategory? = nil, title: String, artist: String? = nil, album: String? = nil, albumArtist: String? = nil, genre: String? = nil, composer: String? = nil, comment: String? = nil, grouping: String? = nil, year: Int = 0, trackNumber: Int = 0, trackCount: Int = 0, discNumber: Int = 0, discCount: Int = 0, durationMs: Int = 0, bitrate: Int = 0, sampleRate: Int = 44100, fileSize: Int64 = 0, fileExtension: String, isLossless: Bool = false, compilation: Bool = false, bpm: Int = 0, hasLyrics: Bool = false, rating: Int = 0, playCount: Int = 0, lastPlayed: Date? = nil, dateAdded: Date = Date(), dateModified: Date? = nil, artworkKey: String? = nil, syncEnabled: Bool = true) {
        self.id = id
        self.path = path
        self.source = source
        self.musicPersistentID = musicPersistentID
        self.kind = kind
        self.videoWidth = videoWidth
        self.videoHeight = videoHeight
        self.videoCategory = videoCategory
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
        self.genre = genre
        self.composer = composer
        self.comment = comment
        self.grouping = grouping
        self.year = year
        self.trackNumber = trackNumber
        self.trackCount = trackCount
        self.discNumber = discNumber
        self.discCount = discCount
        self.durationMs = durationMs
        self.bitrate = bitrate
        self.sampleRate = sampleRate
        self.fileSize = fileSize
        self.fileExtension = fileExtension
        self.isLossless = isLossless
        self.compilation = compilation
        self.bpm = bpm
        self.hasLyrics = hasLyrics
        self.rating = rating
        self.playCount = playCount
        self.lastPlayed = lastPlayed
        self.dateAdded = dateAdded
        self.dateModified = dateModified
        self.artworkKey = artworkKey
        self.syncEnabled = syncEnabled
    }
}

public struct LibraryPlaylist: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var name: String
    public var trackIDs: [UUID] = []
    public var syncEnabled: Bool = true
    public var musicPersistentID: String?
    public var dateCreated: Date = Date()

    public init(id: UUID = UUID(), name: String, trackIDs: [UUID] = [], syncEnabled: Bool = true, musicPersistentID: String? = nil, dateCreated: Date = Date()) {
        self.id = id
        self.name = name
        self.trackIDs = trackIDs
        self.syncEnabled = syncEnabled
        self.musicPersistentID = musicPersistentID
        self.dateCreated = dateCreated
    }
}

public struct PodcastEpisode: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var guid: String
    public var title: String
    public var summary: String?
    public var publishedAt: Date?
    public var durationMs: Int?
    public var enclosureURL: URL
    public var enclosureLength: Int64?
    public var mimeType: String?
    public var localPath: String?
    public var fileSize: Int64?
    public var played: Bool = false
    public var playbackPositionMs: Int = 0
    /// nil = follow the show's rule; true/false = explicit override.
    public var syncOverride: Bool?
    public var episodeNumber: Int?
    public var seasonNumber: Int?

    public var isDownloaded: Bool {
        guard let p = localPath else { return false }
        return FileManager.default.fileExists(atPath: p)
    }

    public var localURL: URL? { localPath.map { URL(fileURLWithPath: $0) } }

    public init(id: UUID = UUID(), guid: String, title: String, summary: String? = nil, publishedAt: Date? = nil, durationMs: Int? = nil, enclosureURL: URL, enclosureLength: Int64? = nil, mimeType: String? = nil, localPath: String? = nil, fileSize: Int64? = nil, played: Bool = false, playbackPositionMs: Int = 0, syncOverride: Bool? = nil, episodeNumber: Int? = nil, seasonNumber: Int? = nil) {
        self.id = id
        self.guid = guid
        self.title = title
        self.summary = summary
        self.publishedAt = publishedAt
        self.durationMs = durationMs
        self.enclosureURL = enclosureURL
        self.enclosureLength = enclosureLength
        self.mimeType = mimeType
        self.localPath = localPath
        self.fileSize = fileSize
        self.played = played
        self.playbackPositionMs = playbackPositionMs
        self.syncOverride = syncOverride
        self.episodeNumber = episodeNumber
        self.seasonNumber = seasonNumber
    }
}

/// Where a show's episodes come from. `rss` is a standard feed; `ohdio` and `youtube` are fetched
/// natively (Radio-Canada's OHdio API, a YouTube channel/playlist via yt-dlp) and converted into the
/// same shape, so the rest of the app (storage, UI, sync, download) never needs to know the difference.
public enum PodcastSourceKind: String, Codable, Sendable {
    case rss, ohdio, youtube
}

public struct PodcastShow: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var feedURL: URL
    public var title: String
    public var author: String?
    public var summary: String?
    public var imageURL: URL?
    public var artworkKey: String?
    public var sourceKind: PodcastSourceKind = .rss
    /// Number of most-recent episodes to keep downloaded and on the iPod (0 = all downloaded episodes).
    public var keepLatest: Int = 5
    public var syncEnabled: Bool = true
    public var lastRefreshed: Date?
    public var episodes: [PodcastEpisode] = []
    public var dateSubscribed: Date = Date()

    /// Episodes newest first.
    public var sortedEpisodes: [PodcastEpisode] {
        episodes.sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
    }

    /// Episodes that should be downloaded and synced under the current rule.
    public func episodesToSync() -> [PodcastEpisode] {
        guard syncEnabled else { return [] }
        var result: [PodcastEpisode] = []
        var autoCount = 0
        for e in sortedEpisodes {
            if let o = e.syncOverride {
                if o { result.append(e) }
                continue
            }
            if keepLatest == 0 || autoCount < keepLatest {
                result.append(e)
                autoCount += 1
            }
        }
        return result
    }

    public init(id: UUID = UUID(), feedURL: URL, title: String, author: String? = nil, summary: String? = nil, imageURL: URL? = nil, artworkKey: String? = nil, sourceKind: PodcastSourceKind = .rss, keepLatest: Int = 5, syncEnabled: Bool = true, lastRefreshed: Date? = nil, episodes: [PodcastEpisode] = [], dateSubscribed: Date = Date()) {
        self.id = id
        self.feedURL = feedURL
        self.title = title
        self.author = author
        self.summary = summary
        self.imageURL = imageURL
        self.artworkKey = artworkKey
        self.sourceKind = sourceKind
        self.keepLatest = keepLatest
        self.syncEnabled = syncEnabled
        self.lastRefreshed = lastRefreshed
        self.episodes = episodes
        self.dateSubscribed = dateSubscribed
    }
}

/// What the app last put on a given iPod, so that syncs are incremental and play counts can be matched.
public struct DeviceSyncRecord: Codable, Hashable, Sendable {
    public var deviceID: String
    public var deviceName: String
    public var lastSync: Date?
    /// Library track id → dbid on the device.
    public var trackDBIDs: [UUID: UInt64] = [:]
    /// Podcast episode id → dbid on the device.
    public var episodeDBIDs: [UUID: UInt64] = [:]
    /// Library playlist id → playlist id on the device.
    public var playlistIDs: [UUID: UInt64] = [:]
    /// Per-device sync choices.
    public var syncAllMusic: Bool = true
    public var selectedPlaylistIDs: Set<UUID> = []
    public var syncPodcasts: Bool = true
    public var removeUnknownTracks: Bool = false
    public var syncVideos: Bool? = true
    public var syncPhotos: Bool? = true
    public var syncAudiobooks: Bool? = true
    /// Whether syncing replaces a track's Artist with its Album Artist on this iPod (see SyncEngine);
    /// on by default since that's what keeps multi-artist albums from fragmenting on the device.
    public var useAlbumArtistForGrouping: Bool? = true
    /// Track id → the `dateModified` it had when its lyrics tag was last confirmed/repaired on this
    /// iPod. Lets a sync re-copy a track to fix its lyrics exactly once per edit, not on every sync.
    public var lyricsFixedDates: [UUID: Date] = [:]

    public var videosEnabled: Bool { syncVideos ?? true }
    public var photosEnabled: Bool { syncPhotos ?? true }
    public var audiobooksEnabled: Bool { syncAudiobooks ?? true }
    public var albumArtistGroupingEnabled: Bool { useAlbumArtistForGrouping ?? true }

    public init(deviceID: String, deviceName: String, lastSync: Date? = nil, trackDBIDs: [UUID: UInt64] = [:], episodeDBIDs: [UUID: UInt64] = [:], playlistIDs: [UUID: UInt64] = [:], syncAllMusic: Bool = true, selectedPlaylistIDs: Set<UUID> = [], syncPodcasts: Bool = true, removeUnknownTracks: Bool = false, syncVideos: Bool? = true, syncPhotos: Bool? = true, syncAudiobooks: Bool? = true, useAlbumArtistForGrouping: Bool? = true, lyricsFixedDates: [UUID: Date] = [:]) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.lastSync = lastSync
        self.trackDBIDs = trackDBIDs
        self.episodeDBIDs = episodeDBIDs
        self.playlistIDs = playlistIDs
        self.syncAllMusic = syncAllMusic
        self.selectedPlaylistIDs = selectedPlaylistIDs
        self.syncPodcasts = syncPodcasts
        self.removeUnknownTracks = removeUnknownTracks
        self.syncVideos = syncVideos
        self.syncPhotos = syncPhotos
        self.syncAudiobooks = syncAudiobooks
        self.useAlbumArtistForGrouping = useAlbumArtistForGrouping
        self.lyricsFixedDates = lyricsFixedDates
    }
}

/// Which Photos-app albums go to iPods (a library-wide choice; each iPod can turn photo syncing off).
public struct PhotoSelection: Codable, Hashable, Sendable {
    /// PHAssetCollection local identifiers.
    public var albumIDs: [String] = []
    public var includeAllPhotos: Bool = false
    /// Album names captured when selected, for display when Photos access is unavailable.
    public var albumNames: [String: String] = [:]

    public var isEmpty: Bool { albumIDs.isEmpty && !includeAllPhotos }

    public init(albumIDs: [String] = [], includeAllPhotos: Bool = false, albumNames: [String: String] = [:]) {
        self.albumIDs = albumIDs
        self.includeAllPhotos = includeAllPhotos
        self.albumNames = albumNames
    }
}

public struct LibraryDocument: Codable, Sendable {
    public var version: Int = 1
    public var tracks: [LibraryTrack] = []
    public var playlists: [LibraryPlaylist] = []
    public var shows: [PodcastShow] = []
    public var deviceRecords: [String: DeviceSyncRecord] = [:]
    public var photoSelection: PhotoSelection? = PhotoSelection()
    /// Folder the user pointed Audiobooks at; rescanned on demand.
    public var audiobooksFolderPath: String? = nil
    /// Folder the music library lives in; scanned for new files at launch and from Library ▸ Scan.
    public var musicFolderPath: String? = nil

    public init(version: Int = 1, tracks: [LibraryTrack] = [], playlists: [LibraryPlaylist] = [], shows: [PodcastShow] = [], deviceRecords: [String: DeviceSyncRecord] = [:], photoSelection: PhotoSelection? = PhotoSelection(), audiobooksFolderPath: String? = nil, musicFolderPath: String? = nil) {
        self.version = version
        self.tracks = tracks
        self.playlists = playlists
        self.shows = shows
        self.deviceRecords = deviceRecords
        self.photoSelection = photoSelection
        self.audiobooksFolderPath = audiobooksFolderPath
        self.musicFolderPath = musicFolderPath
    }
}
