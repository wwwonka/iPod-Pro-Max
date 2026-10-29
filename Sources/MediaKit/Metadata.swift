//
//  Metadata.swift
//  iPod Pro Max
//
//  What MediaKit reads from a media file, whatever the reader (AVFoundation on the Mac, the
//  pure-Swift reader elsewhere), plus the parsing helpers both share.
//

import Foundation
import iPodKit

public struct VideoInfo: Sendable {
    public var width: Int
    public var height: Int
    public var durationMs: Int
    public var hasAudio: Bool

    public init(width: Int, height: Int, durationMs: Int, hasAudio: Bool) {
        self.width = width
        self.height = height
        self.durationMs = durationMs
        self.hasAudio = hasAudio
    }
}

public struct ExtractedMetadata: Sendable {
    public var title: String?
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
    public var bitrate: Int = 0
    public var sampleRate: Int = 44100
    public var isLossless = false
    public var compilation = false
    public var bpm: Int = 0
    public var artworkData: Data?
    public var isPodcast = false
    public var releaseDate: Date?
    /// Whether the file carries a lyrics tag (USLT / ©lyr / Vorbis LYRICS), so the iPod shows its Lyrics screen.
    public var hasLyrics = false

    public init(title: String? = nil, artist: String? = nil, album: String? = nil, albumArtist: String? = nil, genre: String? = nil, composer: String? = nil, comment: String? = nil, grouping: String? = nil, year: Int = 0, trackNumber: Int = 0, trackCount: Int = 0, discNumber: Int = 0, discCount: Int = 0, durationMs: Int = 0, bitrate: Int = 0, sampleRate: Int = 44100, bpm: Int = 0, artworkData: Data? = nil, releaseDate: Date? = nil) {
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
        self.bpm = bpm
        self.artworkData = artworkData
        self.releaseDate = releaseDate
    }
}

public enum DateParsing: Sendable {
    private static let isoFormatters: [DateFormatter] = {
        let fmts = ["yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd", "yyyy"]
        return fmts.map { f in
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = TimeZone(secondsFromGMT: 0)
            df.dateFormat = f
            return df
        }
    }()

    public static func parseISO(_ s: String) -> Date? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        for f in isoFormatters {
            if let d = f.date(from: trimmed) { return d }
        }
        return nil
    }

    private static let rfc822Formatters: [DateFormatter] = {
        let fmts = ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss zzz", "EEE, d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss zzz",
                    "dd MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm Z", "EEE, dd MMM yyyy", "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd'T'HH:mm:ssXXXXX", "yyyy-MM-dd HH:mm:ss"]
        return fmts.map { f in
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = TimeZone(secondsFromGMT: 0)
            df.dateFormat = f
            return df
        }
    }()

    public static func parseRFC822(_ s: String) -> Date? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        for f in rfc822Formatters {
            if let d = f.date(from: trimmed) { return d }
        }
        return parseISO(trimmed)
    }
}

public enum ID3Genres: Sendable {
    public static let names: [String] = [
        "Blues", "Classic Rock", "Country", "Dance", "Disco", "Funk", "Grunge", "Hip-Hop", "Jazz", "Metal", "New Age", "Oldies", "Other", "Pop", "R&B",
        "Rap", "Reggae", "Rock", "Techno", "Industrial", "Alternative", "Ska", "Death Metal", "Pranks", "Soundtrack", "Euro-Techno", "Ambient",
        "Trip-Hop", "Vocal", "Jazz+Funk", "Fusion", "Trance", "Classical", "Instrumental", "Acid", "House", "Game", "Sound Clip", "Gospel", "Noise",
        "AlternRock", "Bass", "Soul", "Punk", "Space", "Meditative", "Instrumental Pop", "Instrumental Rock", "Ethnic", "Gothic", "Darkwave",
        "Techno-Industrial", "Electronic", "Pop-Folk", "Eurodance", "Dream", "Southern Rock", "Comedy", "Cult", "Gangsta", "Top 40", "Christian Rap",
        "Pop/Funk", "Jungle", "Native American", "Cabaret", "New Wave", "Psychadelic", "Rave", "Showtunes", "Trailer", "Lo-Fi", "Tribal", "Acid Punk",
        "Acid Jazz", "Polka", "Retro", "Musical", "Rock & Roll", "Hard Rock", "Folk", "Folk-Rock", "National Folk", "Swing", "Fast Fusion", "Bebob",
        "Latin", "Revival", "Celtic", "Bluegrass", "Avantgarde", "Gothic Rock", "Progressive Rock", "Psychedelic Rock", "Symphonic Rock", "Slow Rock",
        "Big Band", "Chorus", "Easy Listening", "Acoustic", "Humour", "Speech", "Chanson", "Opera", "Chamber Music", "Sonata", "Symphony", "Booty Bass",
        "Primus", "Porn Groove", "Satire", "Slow Jam", "Club", "Tango", "Samba", "Folklore", "Ballad", "Power Ballad", "Rhythmic Soul", "Freestyle",
        "Duet", "Punk Rock", "Drum Solo", "A capella", "Euro-House", "Dance Hall",
    ]

    public static func name(forIndex i: Int) -> String? {
        guard i >= 0, i < names.count else { return nil }
        return names[i]
    }

    /// Converts "(17)" style genre references into names.
    public static func normalize(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("("), let close = trimmed.firstIndex(of: ")"), let n = Int(trimmed[trimmed.index(after: trimmed.startIndex)..<close]) {
            let rest = trimmed[trimmed.index(after: close)...].trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty { return rest }
            return name(forIndex: n) ?? trimmed
        }
        if let n = Int(trimmed), let name = name(forIndex: n) { return name }
        return trimmed
    }
}
