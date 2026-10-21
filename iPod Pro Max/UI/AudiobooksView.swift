//
//  AudiobooksView.swift
//  iPod Pro Max
//
//  List (like Finder's list view) over tracks imported from a user-chosen Audiobooks folder.
//  A subfolder becomes a collapsible multi-chapter book; a loose audio file becomes a one-part book.
//

import SwiftUI

private struct AudiobookEntry: Identifiable {
    let id: String
    let title: String
    let author: String?
    let artworkKey: String?
    let chapters: [LibraryTrack]

    var totalDurationMs: Int { chapters.reduce(0) { $0 + $1.durationMs } }
    var totalSize: Int64 { chapters.reduce(0) { $0 + $1.fileSize } }
    var allSynced: Bool { chapters.allSatisfy(\.syncEnabled) }
}

struct AudiobooksView: View {
    @Environment(LibraryStore.self) private var envLibrary: LibraryStore?
    private var library: LibraryStore { envLibrary ?? AppServices.shared.library }
    @State private var expanded: Set<String> = []
    @State private var selection = Set<UUID>()

    /// Width of the arrow + artwork leading area on a book row (14 + 10 spacing + 32), so a chapter
    /// row's title lines up under the book's title instead of under its artwork.
    private static let leadingColumnWidth: CGFloat = 56

    private var books: [AudiobookEntry] {
        let byAlbum = Dictionary(grouping: library.audiobooks) { $0.album ?? $0.title }
        return byAlbum.map { title, chapters in
            let sorted = chapters.sorted { ($0.trackNumber, $0.title) < ($1.trackNumber, $1.title) }
            return AudiobookEntry(id: title, title: title, author: sorted.first?.artist, artworkKey: sorted.first(where: { $0.artworkKey != nil })?.artworkKey, chapters: sorted)
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        Group {
            if library.audiobooks.isEmpty {
                EmptyStateView(icon: "book.closed", title: "No Audiobooks Yet",
                               message: "Choose a folder with your audiobooks. A subfolder with several files becomes a collapsible book with chapters; a single file becomes a one-part book.") {
                    AnyView(Button("Choose Folder…") { Task { await chooseFolder() } })
                }
            } else {
                list
            }
        }
        .navigationTitle("Audiobooks")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup {
                if library.isImporting {
                    HStack(spacing: 6) {
                        ProgressView(value: library.importProgress).progressViewStyle(.linear).frame(width: 90)
                        Text(library.importStatus ?? "Scanning…").font(.caption).lineLimit(1).frame(maxWidth: 220, alignment: .leading)
                    }
                }
                Button { Task { await chooseFolder() } } label: { Label("Choose Folder", systemImage: "folder") }
                    .help("Point Audiobooks at a folder on your Mac")
                Button { Task { await library.rescanAudiobooks() } } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                    .disabled(library.audiobooksFolderPath == nil || library.isImporting)
            }
        }
    }

    private var subtitle: String {
        let n = library.audiobooks.count
        let books = self.books.count
        var s = "\(books) book\(books == 1 ? "" : "s"), \(n) file\(n == 1 ? "" : "s")"
        if let path = library.audiobooksFolderPath { s += " — \(path)" }
        return s
    }

    private var list: some View {
        List(selection: $selection) {
            ForEach(books) { book in
                if book.chapters.count > 1 {
                    bookRow(book)
                        .draggable(TrackIDsTransfer(ids: book.chapters.map(\.id)))
                    if expanded.contains(book.id) {
                        ForEach(book.chapters) { ch in
                            chapterRow(ch)
                                .tag(ch.id)
                                .draggable(dragPayload(for: ch.id))
                        }
                    }
                } else if let only = book.chapters.first {
                    bookRow(book, singleChapter: only)
                        .tag(only.id)
                        .draggable(dragPayload(for: only.id))
                }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }

    /// Drags the current multi-selection when the dragged row is part of it; otherwise just itself.
    private func dragPayload(for id: UUID) -> TrackIDsTransfer {
        TrackIDsTransfer(ids: selection.contains(id) && selection.count > 1 ? Array(selection) : [id])
    }

    /// Leading disclosure chevron, reserved width even for non-expandable (single-chapter) rows so
    /// titles still line up — rotates in place, so it stays vertically centered with the artwork.
    private func disclosureArrow(for book: AudiobookEntry) -> some View {
        Group {
            if book.chapters.count > 1 {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expanded.contains(book.id) ? 90 : 0))
            }
        }
        .frame(width: 14, alignment: .center)
    }

    private func bookRow(_ book: AudiobookEntry, singleChapter: LibraryTrack? = nil) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                disclosureArrow(for: book)
                ArtworkThumb(url: library.artworkURL(book.artworkKey), size: 32, cornerRadius: 4, placeholder: "book.closed")
                VStack(alignment: .leading, spacing: 2) {
                    Text(book.title).lineLimit(1)
                    HStack(spacing: 6) {
                        if let author = book.author, !author.isEmpty { Text(author) }
                        Text(book.chapters.count > 1 ? "\(book.chapters.count) chapters" : Format.duration(ms: book.totalDurationMs))
                        Text(Format.bytes(book.totalSize))
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard book.chapters.count > 1 else { return }
                if expanded.contains(book.id) { expanded.remove(book.id) } else { expanded.insert(book.id) }
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { singleChapter?.syncEnabled ?? book.allSynced },
                set: { v in library.setSync(v, forTracks: Set(book.chapters.map(\.id))) }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
            .frame(width: 40, alignment: .center)
        }
        .contextMenu {
            Button("Sync to iPod") { library.setSync(true, forTracks: Set(book.chapters.map(\.id))) }
            Button("Don't Sync") { library.setSync(false, forTracks: Set(book.chapters.map(\.id))) }
            Divider()
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(book.chapters.map(\.url)) }
        }
    }

    private func chapterRow(_ ch: LibraryTrack) -> some View {
        HStack(spacing: 10) {
            Text(ch.trackNumber > 0 ? "\(ch.trackNumber)" : "–")
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: Self.leadingColumnWidth, alignment: .trailing)
            Text(ch.title).lineLimit(1)
            if library.missingPaths.contains(ch.path) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help("File not found")
            }
            Spacer()
            Text(Format.duration(ms: ch.durationMs)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            Text(Format.bytes(ch.fileSize)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            Toggle("", isOn: Binding(get: { ch.syncEnabled }, set: { library.setSync($0, forTracks: [ch.id]) }))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .frame(width: 40, alignment: .center)
        }
        .contextMenu {
            Button("Sync to iPod") { library.setSync(true, forTracks: [ch.id]) }
            Button("Don't Sync") { library.setSync(false, forTracks: [ch.id]) }
            Divider()
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([ch.url]) }
        }
    }

    @MainActor
    private func chooseFolder() async {
        let panel = NSOpenPanel()
        panel.title = "Choose Audiobooks Folder"
        panel.message = "iPod Pro Max will scan this folder for audiobooks. A subfolder becomes a book with chapters; a loose file becomes a one-part book."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard await panel.begin() == .OK, let url = panel.urls.first else { return }
        await library.setAudiobooksFolder(url)
    }
}
