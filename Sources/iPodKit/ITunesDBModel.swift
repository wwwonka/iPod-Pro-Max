//
//  ITunesDBModel.swift
//  iPod Pro Max
//
//  In-memory model of the iPod's iTunesDB (tracks + playlists). Field names and semantics
//  follow the documented format (ipodlinux wiki / libgpod) so behavior matches what iTunes wrote.
//

import Foundation

public enum IPodMediaType: Sendable {
    public static let audio: UInt32 = 1 << 0
    public static let movie: UInt32 = 1 << 1
    public static let podcast: UInt32 = 1 << 2
    public static let audiobook: UInt32 = 1 << 3
    public static let musicVideo: UInt32 = 1 << 5
    public static let tvShow: UInt32 = 1 << 6
}

public enum MHODType: Sendable {
    public static let title: UInt32 = 1
    public static let path: UInt32 = 2
    public static let album: UInt32 = 3
    public static let artist: UInt32 = 4
    public static let genre: UInt32 = 5
    public static let filetype: UInt32 = 6
    public static let comment: UInt32 = 8
    public static let category: UInt32 = 9
    public static let composer: UInt32 = 12
    public static let grouping: UInt32 = 13
    public static let description: UInt32 = 14
    public static let podcastURL: UInt32 = 15
    public static let podcastRSS: UInt32 = 16
    public static let chapterData: UInt32 = 17
    public static let subtitle: UInt32 = 18
    public static let tvShow: UInt32 = 19
    public static let tvEpisode: UInt32 = 20
    public static let tvNetwork: UInt32 = 21
    public static let albumArtist: UInt32 = 22
    public static let sortArtist: UInt32 = 23
    public static let keywords: UInt32 = 24
    public static let sortTitle: UInt32 = 27
    public static let sortAlbum: UInt32 = 28
    public static let sortAlbumArtist: UInt32 = 29
    public static let sortComposer: UInt32 = 30
    public static let sortTVShow: UInt32 = 31
    public static let smartPlaylistPrefs: UInt32 = 50
    public static let smartPlaylistRules: UInt32 = 51
    public static let libraryPlaylistIndex: UInt32 = 52
    public static let libraryPlaylistJumpTable: UInt32 = 53
    public static let playlistPosition: UInt32 = 100
    public static let albumListAlbum: UInt32 = 200
    public static let albumListArtist: UInt32 = 201
    public static let albumListSortArtist: UInt32 = 202
    public static let artistListName: UInt32 = 300

    /// mhod types whose payload is a UTF-16 string with the standard 16-byte string header.
    public static let stringTypes: Set<UInt32> = [1, 2, 3, 4, 5, 6, 8, 9, 12, 13, 14, 18, 19, 20, 21, 22, 23, 24, 27, 28, 29, 30, 31, 200, 201, 202, 300]
}

/// A track record (mhit) with its string objects.
public struct IPodTrack: Identifiable, Hashable, Sendable {
    /// Unique database id; persists across syncs and links to ArtworkDB.
    public var dbid: UInt64
    public var id: UInt64 { dbid }

    /// Transient id assigned when the database is written (mhit "track id"). Set by the reader/writer.
    public var trackID: UInt32 = 0

    public var title: String?
    public var artist: String?
    public var album: String?
    public var albumArtist: String?
    public var genre: String?
    public var composer: String?
    public var comment: String?
    public var grouping: String?
    public var description: String?
    public var category: String?
    public var subtitle: String?
    public var podcastURL: String?
    public var podcastRSS: String?
    public var sortTitle: String?
    public var sortArtist: String?
    public var sortAlbum: String?
    public var sortAlbumArtist: String?
    public var sortComposer: String?
    public var filetypeDescription: String?
    /// Path on the iPod using ':' separators, e.g. ":iPod_Control:Music:F03:ABCD.mp3"
    public var ipodPath: String = ""

    public var filetypeMarker: UInt32 = 0
    public var type1: UInt8 = 0
    public var type2: UInt8 = 0
    public var compilation: UInt8 = 0
    /// 0-100 in steps of 20 (stars * 20)
    public var rating: UInt8 = 0

    public var timeModified: Date?
    public var timeAdded: Date?
    public var timePlayed: Date?
    public var timeReleased: Date?
    public var lastSkipped: Date?

    public var fileSize: UInt32 = 0
    public var durationMs: UInt32 = 0
    public var trackNumber: UInt32 = 0
    public var trackCount: UInt32 = 0
    public var year: UInt32 = 0
    public var bitrate: UInt32 = 0
    public var sampleRate: UInt32 = 44100
    public var volume: Int32 = 0
    public var startTime: UInt32 = 0
    public var stopTime: UInt32 = 0
    public var soundCheck: UInt32 = 0
    public var playCount: UInt32 = 0
    public var playCount2: UInt32 = 0
    public var discNumber: UInt32 = 0
    public var discCount: UInt32 = 0
    public var drmUserID: UInt32 = 0
    public var bookmarkTimeMs: UInt32 = 0
    public var checked: UInt8 = 0
    public var appRating: UInt8 = 0
    public var bpm: UInt16 = 0
    public var artworkCount: UInt16 = 0
    public var unk126: UInt16 = 0xFFFF
    public var artworkSize: UInt32 = 0
    public var unk132: UInt32 = 0
    public var unk144: UInt16 = 0
    public var explicitFlag: UInt16 = 0
    public var unk148: UInt32 = 0
    public var unk152: UInt32 = 0
    public var skipCount: UInt32 = 0
    /// 0x01 has artwork, 0x02 no artwork
    public var hasArtwork: UInt8 = 0x02
    public var skipWhenShuffling: UInt8 = 0
    public var rememberPlaybackPosition: UInt8 = 0
    public var flag4: UInt8 = 0
    public var dbid2: UInt64 = 0
    public var lyricsFlag: UInt8 = 0
    public var movieFlag: UInt8 = 0
    /// 0x02 = unplayed (podcast bullet), 0x01 = played / normal track
    public var markUnplayed: UInt8 = 0x01
    public var unk179: UInt8 = 0
    public var unk180: UInt32 = 0
    public var pregap: UInt32 = 0
    public var sampleCount: UInt64 = 0
    public var unk196: UInt32 = 0
    public var postgap: UInt32 = 0
    public var unk204: UInt32 = 0
    public var mediaType: UInt32 = IPodMediaType.audio
    public var seasonNumber: UInt32 = 0
    public var episodeNumber: UInt32 = 0
    public var gaplessData: UInt32 = 0
    public var gaplessTrackFlag: UInt16 = 0
    public var gaplessAlbumFlag: UInt16 = 0
    /// Image id in ArtworkDB (mhii) for this track; 0 when no artwork.
    public var mhiiLink: UInt32 = 0

    /// Transient ids assigned during write (album/artist/composer lists).
    public var albumID: UInt32 = 0
    public var artistID: UInt32 = 0
    public var composerID: UInt32 = 0

    public init(dbid: UInt64) {
        self.dbid = dbid
        self.dbid2 = dbid
    }

    public var isPodcast: Bool { mediaType & IPodMediaType.podcast != 0 }

    public static func randomDBID() -> UInt64 {
        var v: UInt64 = 0
        repeat { v = UInt64.random(in: 1...UInt64.max) } while v == 0
        return v
    }

    /// Full path of the track's file on a mounted iPod volume.
    public func fileURL(mountPoint: URL) -> URL? {
        var path = ipodPath
        if path.hasPrefix(":") { path.removeFirst() }
        if path.isEmpty { return nil }
        let components = path.split(separator: ":").map(String.init)
        var url = mountPoint
        for c in components { url.appendPathComponent(c) }
        return url
    }
}

public struct IPodPlaylist: Identifiable, Hashable, Sendable {
    public var id: UInt64
    public var name: String
    public var isMaster: Bool = false
    public var isPodcasts: Bool = false
    public var isSmart: Bool = false
    /// Smart-playlist preference/rule MHODs retained verbatim across a rewrite.
    public var smartMetadata: [Data] = []
    public var flag1: UInt8 = 0
    public var flag2: UInt8 = 0
    public var flag3: UInt8 = 0
    public var sortOrder: UInt32 = 1
    public var timestamp: Date?
    /// Members referenced by track dbid, in playlist order.
    public var memberDBIDs: [UInt64] = []

    public init(id: UInt64 = IPodTrack.randomDBID(), name: String) {
        self.id = id
        self.name = name
    }
}

/// The whole iTunesDB.
public struct ITunesDatabase: Sendable {
    public var tracks: [IPodTrack] = []
    /// Master playlist first.
    public var playlists: [IPodPlaylist] = []
    public var version: UInt32 = 0x30
    public var databaseID: UInt64 = IPodTrack.randomDBID()
    public var libraryPersistentID: UInt64 = IPodTrack.randomDBID()
    public var id0x24: UInt64 = 0
    public var platform: UInt16 = 1 // 1 = macOS, 2 = Windows
    public var unk0x22: UInt16 = 0
    public var language: UInt16 = 0x656E
    public var unk0x50: UInt32 = 0
    public var unk0x54: UInt32 = 0
    /// Time zone offset (seconds from GMT) used to translate timestamps.
    public var tzOffset: Int32 = Int32(TimeZone.current.secondsFromGMT())
    public var audioLanguage: UInt16 = 0
    public var subtitleLanguage: UInt16 = 0

    public init() {}

    public var masterPlaylist: IPodPlaylist? { playlists.first(where: { $0.isMaster }) }

    public var name: String {
        get { masterPlaylist?.name ?? "iPod" }
        set {
            if let idx = playlists.firstIndex(where: { $0.isMaster }) {
                playlists[idx].name = newValue
            } else {
                var mpl = IPodPlaylist(name: newValue)
                mpl.isMaster = true
                playlists.insert(mpl, at: 0)
            }
        }
    }

    public var podcastPlaylist: IPodPlaylist? { playlists.first(where: { $0.isPodcasts }) }

    public func track(dbid: UInt64) -> IPodTrack? { tracks.first(where: { $0.dbid == dbid }) }

    /// Creates a minimal database with an empty master playlist.
    public static func empty(named name: String) -> ITunesDatabase {
        var db = ITunesDatabase()
        var mpl = IPodPlaylist(name: name)
        mpl.isMaster = true
        mpl.timestamp = Date()
        db.playlists = [mpl]
        return db
    }
}

/// File-type helpers shared by the writer and the sync engine.
public enum IPodFileType: Sendable {
    public struct Info: Sendable {
        public let ext: String
        public let description: String
        public let marker: UInt32
        public let type2: UInt8
        public let unk144: UInt16
        public let unk126: UInt16
        public let isNative: Bool

        public init(ext: String, description: String, marker: UInt32, type2: UInt8, unk144: UInt16, unk126: UInt16, isNative: Bool) {
            self.ext = ext
            self.description = description
            self.marker = marker
            self.type2 = type2
            self.unk144 = unk144
            self.unk126 = unk126
            self.isNative = isNative
        }
    }

    /// Big-endian-looking marker stored in the little-endian field, e.g. "MP3 " -> 0x4D503320.
    public static func marker(forExtension ext: String) -> UInt32 {
        var m: UInt32 = 0
        let chars = Array(ext.uppercased().utf8)
        for i in 0..<4 {
            m <<= 8
            if i < chars.count { m |= UInt32(chars[i]) } else { m |= 0x20 }
        }
        return m
    }

    public static func info(forExtension rawExt: String, isLossless: Bool = false) -> Info {
        let ext = rawExt.lowercased()
        switch ext {
        case "mp3":
            return Info(ext: ext, description: "MPEG audio file", marker: marker(forExtension: "MP3"), type2: 1, unk144: 0x0C, unk126: 0xFFFF, isNative: true)
        case "m4a", "mp4", "aac":
            if isLossless {
                return Info(ext: "m4a", description: "Apple Lossless audio file", marker: marker(forExtension: "M4A"), type2: 0, unk144: 0x33, unk126: 0xFFFF, isNative: true)
            }
            return Info(ext: "m4a", description: "AAC audio file", marker: marker(forExtension: "M4A"), type2: 0, unk144: 0x33, unk126: 0xFFFF, isNative: true)
        case "m4b":
            return Info(ext: ext, description: "AAC audio file", marker: marker(forExtension: "M4B"), type2: 0, unk144: 0x33, unk126: 0xFFFF, isNative: true)
        case "m4p":
            return Info(ext: ext, description: "Protected AAC audio file", marker: marker(forExtension: "M4P"), type2: 0, unk144: 0x33, unk126: 0xFFFF, isNative: true)
        case "wav":
            return Info(ext: ext, description: "WAV audio file", marker: marker(forExtension: "WAV"), type2: 0, unk144: 0, unk126: 0, isNative: true)
        case "aif", "aiff", "aifc":
            return Info(ext: ext, description: "AIFF audio file", marker: marker(forExtension: "AIFF"), type2: 0, unk144: 0, unk126: 0, isNative: true)
        case "aa":
            return Info(ext: ext, description: "Audible file", marker: marker(forExtension: "AA"), type2: 0, unk144: 0x29, unk126: 1, isNative: true)
        default:
            return Info(ext: ext, description: "\(ext.uppercased()) audio file", marker: marker(forExtension: ext), type2: 0, unk144: 0, unk126: 0xFFFF, isNative: false)
        }
    }

    public static let nativeExtensions: Set<String> = ["mp3", "m4a", "m4b", "m4p", "mp4", "aac", "wav", "aif", "aiff", "aifc", "aa"]
    /// Formats AVFoundation can decode that need transcoding to AAC before going onto the iPod.
    public static let transcodableExtensions: Set<String> = ["flac", "caf", "ac3", "eac3", "amr", "3gp", "m4r", "mp2", "mp1", "snd", "au", "sd2", "w64", "ogg", "oga", "opus", "wma"]
}
