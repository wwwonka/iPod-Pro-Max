//
//  LibraryModels.swift
//  iPod Pro Max
//
//  The app's own library: songs, playlists and podcast subscriptions, persisted as JSON.
//

import Foundation

enum TrackSource: String, Codable {
    case file
    case musicApp
}

enum MediaKind: String, Codable {
    case song
    case video
    case audiobook
}

/// Which Videos submenu a video appears under on the iPod (Movies/TV Shows/Music Videos), driven by
/// the track's mediaType bits — no special playlist needed, unlike Podcasts.
enum VideoCategory: String, Codable, CaseIterable {
    case movie, tvShow, musicVideo

    var title: String {
        switch self {
        case .movie: return "Movie"
        case .tvShow: return "TV Show"
        case .musicVideo: return "Music Video"
        }
    }
}

struct LibraryTrack: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var path: String
    var source: TrackSource = .file
    var musicPersistentID: String?
    /// nil means song (older library files).
    var kind: MediaKind?
    var videoWidth: Int?
    var videoHeight: Int?
    /// nil defaults to Movie for backward compatibility with libraries saved before categories existed.
    var videoCategory: VideoCategory?

    var title: String
    var artist: String?
    var album: String?
    var albumArtist: String?
    var genre: String?
    var composer: String?
    var comment: String?
    var grouping: String?
    var year: Int = 0
    var trackNumber: Int = 0
    var trackCount: Int = 0
    var discNumber: Int = 0
    var discCount: Int = 0
    var durationMs: Int = 0
    /// kbit/s
    var bitrate: Int = 0
    var sampleRate: Int = 44100
    var fileSize: Int64 = 0
    var fileExtension: String
    var isLossless: Bool = false
    var compilation: Bool = false
    var bpm: Int = 0
    var hasLyrics: Bool = false
    /// 0…5 stars
    var rating: Int = 0
    var playCount: Int = 0
    var lastPlayed: Date?
    var dateAdded: Date = Date()
    var dateModified: Date?
    var artworkKey: String?
    var syncEnabled: Bool = true

    var url: URL { URL(fileURLWithPath: path) }

    var mediaKind: MediaKind { kind ?? .song }
    var isVideo: Bool { mediaKind == .video }
    var isAudiobook: Bool { mediaKind == .audiobook }

    /// Songs in non-iPod formats are converted to AAC; every video is converted to iPod H.264.
    var needsTranscode: Bool {
        if isVideo { return true }
        return !IPodFileType.nativeExtensions.contains(fileExtension.lowercased())
    }

    var displayArtist: String { artist ?? albumArtist ?? "Unknown Artist" }
    var displayAlbum: String { album ?? "Unknown Album" }

    var fileExists: Bool { FileManager.default.fileExists(atPath: path) }
}

struct LibraryPlaylist: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var trackIDs: [UUID] = []
    var syncEnabled: Bool = true
    var musicPersistentID: String?
    var dateCreated: Date = Date()
}

struct PodcastEpisode: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var guid: String
    var title: String
    var summary: String?
    var publishedAt: Date?
    var durationMs: Int?
    var enclosureURL: URL
    var enclosureLength: Int64?
    var mimeType: String?
    var localPath: String?
    var fileSize: Int64?
    var played: Bool = false
    var playbackPositionMs: Int = 0
    /// nil = follow the show's rule; true/false = explicit override.
    var syncOverride: Bool?
    var episodeNumber: Int?
    var seasonNumber: Int?

    var isDownloaded: Bool {
        guard let p = localPath else { return false }
        return FileManager.default.fileExists(atPath: p)
    }

    var localURL: URL? { localPath.map { URL(fileURLWithPath: $0) } }
}

/// Where a show's episodes come from. `rss` is a standard feed; `ohdio` and `youtube` are fetched
/// natively (Radio-Canada's OHdio API, a YouTube channel/playlist via yt-dlp) and converted into the
/// same shape, so the rest of the app (storage, UI, sync, download) never needs to know the difference.
enum PodcastSourceKind: String, Codable {
    case rss, ohdio, youtube

    static func detect(from url: URL) -> PodcastSourceKind {
        if OHdioFeed.isOHdioURL(url) { return .ohdio }
        if YouTubeFeed.isYouTubeURL(url) { return .youtube }
        return .rss
    }
}

struct PodcastShow: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var feedURL: URL
    var title: String
    var author: String?
    var summary: String?
    var imageURL: URL?
    var artworkKey: String?
    var sourceKind: PodcastSourceKind = .rss
    /// Number of most-recent episodes to keep downloaded and on the iPod (0 = all downloaded episodes).
    var keepLatest: Int = 5
    var syncEnabled: Bool = true
    var lastRefreshed: Date?
    var episodes: [PodcastEpisode] = []
    var dateSubscribed: Date = Date()

    /// Episodes newest first.
    var sortedEpisodes: [PodcastEpisode] {
        episodes.sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
    }

    /// Episodes that should be downloaded and synced under the current rule.
    func episodesToSync() -> [PodcastEpisode] {
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
}

/// What the app last put on a given iPod, so that syncs are incremental and play counts can be matched.
struct DeviceSyncRecord: Codable, Hashable {
    var deviceID: String
    var deviceName: String
    var lastSync: Date?
    /// Library track id → dbid on the device.
    var trackDBIDs: [UUID: UInt64] = [:]
    /// Podcast episode id → dbid on the device.
    var episodeDBIDs: [UUID: UInt64] = [:]
    /// Library playlist id → playlist id on the device.
    var playlistIDs: [UUID: UInt64] = [:]
    /// Per-device sync choices.
    var syncAllMusic: Bool = true
    var selectedPlaylistIDs: Set<UUID> = []
    var syncPodcasts: Bool = true
    var removeUnknownTracks: Bool = false
    var syncVideos: Bool? = true
    var syncPhotos: Bool? = true
    var syncAudiobooks: Bool? = true
    /// Whether syncing replaces a track's Artist with its Album Artist on this iPod (see SyncEngine);
    /// on by default since that's what keeps multi-artist albums from fragmenting on the device.
    var useAlbumArtistForGrouping: Bool? = true
    /// Track id → the `dateModified` it had when its lyrics tag was last confirmed/repaired on this
    /// iPod. Lets a sync re-copy a track to fix its lyrics exactly once per edit, not on every sync.
    var lyricsFixedDates: [UUID: Date] = [:]

    var videosEnabled: Bool { syncVideos ?? true }
    var photosEnabled: Bool { syncPhotos ?? true }
    var audiobooksEnabled: Bool { syncAudiobooks ?? true }
    var albumArtistGroupingEnabled: Bool { useAlbumArtistForGrouping ?? true }
}

/// Which Photos-app albums go to iPods (a library-wide choice; each iPod can turn photo syncing off).
struct PhotoSelection: Codable, Hashable {
    /// PHAssetCollection local identifiers.
    var albumIDs: [String] = []
    var includeAllPhotos: Bool = false
    /// Album names captured when selected, for display when Photos access is unavailable.
    var albumNames: [String: String] = [:]

    var isEmpty: Bool { albumIDs.isEmpty && !includeAllPhotos }
}

struct LibraryDocument: Codable {
    var version: Int = 1
    var tracks: [LibraryTrack] = []
    var playlists: [LibraryPlaylist] = []
    var shows: [PodcastShow] = []
    var deviceRecords: [String: DeviceSyncRecord] = [:]
    var photoSelection: PhotoSelection? = PhotoSelection()
    /// Folder the user pointed Audiobooks at; rescanned on demand.
    var audiobooksFolderPath: String? = nil
    /// Folder the music library lives in; scanned for new files at launch and from Library ▸ Scan.
    var musicFolderPath: String? = nil
}
