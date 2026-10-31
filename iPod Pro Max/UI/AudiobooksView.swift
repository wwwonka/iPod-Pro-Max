import Foundation
import iPodKit
import MediaKit

/// One book of the audiobooks folder: a subfolder with its chapters, or a loose file.
struct AudiobookEntry: Identifiable {
    var id: String
    var title: String
    var author: String
    var chapters: [LibraryTrack]

    /// The books of `tracks`, by title. Computed off the main thread when the library loads.
    static func books(from tracks: [LibraryTrack]) -> [AudiobookEntry] {
        AudiobookScanner.bookGroups(tracks).map { chapters in
            let first = chapters[0]
            return AudiobookEntry(id: first.id.uuidString, title: first.album ?? first.title, author: first.artist ?? "Unknown Author", chapters: chapters)
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// The chapters of every book as rows of the track table (which gives them selection and the
    /// platform's drag onto an iPod): book by book, in reading order. A chapter's id is its track id.
    static func rows(_ books: [AudiobookEntry]) -> [TrackRow] {
        books.flatMap { book in
            book.chapters.map { chapter in
                TrackRow(id: chapter.id.uuidString, title: chapter.title, artist: book.author, album: book.title,
                         number: chapter.trackNumber > 0 ? "\(chapter.trackNumber)" : "", year: "",
                         duration: duration(chapter.durationMs))
            }
        }
    }

    private static func duration(_ ms: Int) -> String {
        let s = ms / 1000
        let two = { (n: Int) in n < 10 ? "0\(n)" : "\(n)" }
        return s >= 3600 ? "\(s / 3600):\(two(s % 3600 / 60)):\(two(s % 60))" : "\(s / 60):\(two(s % 60))"
    }
}
