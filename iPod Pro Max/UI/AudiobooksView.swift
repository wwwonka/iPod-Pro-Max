import Foundation
import SwiftCrossUI
import iPodKit
import MediaKit

/// One book of the audiobooks folder: a subfolder with its chapters, or a loose file.
struct AudiobookEntry: Identifiable {
    var id: String
    var title: String
    var author: String
    var coverURL: URL?
    var chapters: [LibraryTrack]

    var durationMs: Int { chapters.reduce(0) { $0 + $1.durationMs } }
    var size: Int64 { chapters.reduce(0) { $0 + $1.fileSize } }

    /// Computed off the main thread when the library loads.
    static func books(from tracks: [LibraryTrack], artwork: URL) -> [AudiobookEntry] {
        AudiobookScanner.bookGroups(tracks).map { chapters in
            let first = chapters[0]
            let cover = chapters.compactMap(\.artworkKey).first.map { artwork.appendingPathComponent("\($0).jpg") }
            return AudiobookEntry(id: first.id.uuidString, title: first.album ?? first.title, author: first.artist ?? "Unknown Author",
                                  coverURL: cover.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }, chapters: chapters)
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}

/// The Audiobooks section, ported from the SwiftUI app: books from a chosen folder, chapters under each,
/// and a button to put a book (or all of them) on an iPod, where the chapters are merged into one .m4b.
struct AudiobooksView: View {
    var books: [AudiobookEntry]
    var folderPath: String?
    var scanning: Bool
    var devices: [String]
    var isBusy: (String) -> Bool
    var onChooseFolder: () -> Void
    var onRescan: () -> Void
    var onSync: ([UUID], String) -> Void

    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(folderPath == nil ? "Choose Folder…" : "Change Folder…") { onChooseFolder() }
                Button("Rescan") { onRescan() }.disabled(folderPath == nil || scanning)
                if let folderPath {
                    Text(folderPath).font(.system(size: 11)).foregroundColor(.gray).lineLimit(1)
                }
                Spacer()
                ForEach(devices, id: \.self) { name in
                    Button(devices.count > 1 ? "Sync all to \(name)" : "Sync all to iPod") {
                        onSync(books.flatMap { $0.chapters.map(\.id) }, name)
                    }
                    .disabled(isBusy(name) || books.isEmpty)
                }
            }
            .padding(8)
            Divider()
            if books.isEmpty {
                EmptyState(icon: "book", title: scanning ? "Scanning…" : "No Audiobooks Yet",
                           message: "Choose a folder with your audiobooks. A subfolder with several files becomes a book with chapters, merged into a single file with chapter marks on the iPod; a single file becomes a one-part book.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(books) { book in
                            bookRow(book)
                            if expanded.contains(book.id) {
                                ForEach(book.chapters) { chapter in chapterRow(chapter) }
                            }
                        }
                    }
                }
            }
        }
    }

    private func bookRow(_ book: AudiobookEntry) -> some View {
        HStack(spacing: 10) {
            Text(book.chapters.count > 1 ? (expanded.contains(book.id) ? "v" : ">") : " ")
                .font(.system(size: 11)).foregroundColor(.gray).frame(width: 14)
            Cover(url: book.coverURL, size: 36, symbol: "book")
            VStack(alignment: .leading, spacing: 2) {
                Text(book.title).lineLimit(1)
                Text(summary(book)).font(.system(size: 11)).foregroundColor(.gray).lineLimit(1)
            }
            Spacer()
            ForEach(devices, id: \.self) { name in
                Button(devices.count > 1 ? "Sync to \(name)" : "Sync to iPod") { onSync(book.chapters.map(\.id), name) }
                    .disabled(isBusy(name))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .onTapGesture {
            guard book.chapters.count > 1 else { return }
            if expanded.contains(book.id) { expanded.remove(book.id) } else { expanded.insert(book.id) }
        }
    }

    private func chapterRow(_ chapter: LibraryTrack) -> some View {
        HStack(spacing: 10) {
            Text(chapter.trackNumber > 0 ? "\(chapter.trackNumber)" : "–")
                .font(.system(size: 11)).foregroundColor(.gray).frame(width: 40, alignment: .trailing)
            Text(chapter.title).lineLimit(1)
            Spacer()
            Text(duration(chapter.durationMs)).font(.system(size: 11)).foregroundColor(.gray)
        }
        .padding(.horizontal, 10)
        .padding(.leading, 50)
        .padding(.vertical, 3)
    }

    private func summary(_ book: AudiobookEntry) -> String {
        var parts = [book.author]
        parts.append(book.chapters.count > 1 ? "\(book.chapters.count) chapters" : duration(book.durationMs))
        parts.append(bytes(book.size))
        return parts.joined(separator: " · ")
    }

    private func duration(_ ms: Int) -> String {
        let s = ms / 1000
        let two = { (n: Int) in n < 10 ? "0\(n)" : "\(n)" }
        return s >= 3600 ? "\(s / 3600):\(two(s % 3600 / 60)):\(two(s % 60))" : "\(s / 60):\(two(s % 60))"
    }
}
