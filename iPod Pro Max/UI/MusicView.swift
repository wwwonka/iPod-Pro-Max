//
//  MusicView.swift
//  iPod Pro Max
//

import SwiftUI
import UniformTypeIdentifiers

private enum MusicViewMode: String {
    case byArtist, allSongs
}

/// All of one artist's (by Album Artist, like the iPod groups them) tracks, split into albums.
private struct ArtistGroup: Identifiable {
    let id: String
    let name: String
    let artworkKey: String?
    let albums: [AlbumGroup]

    var trackCount: Int { albums.reduce(0) { $0 + $1.tracks.count } }
    var allSynced: Bool { albums.allSatisfy(\.allSynced) }
    var allTrackIDs: [UUID] { albums.flatMap { $0.tracks.map(\.id) } }
}

private struct AlbumGroup: Identifiable {
    let id: String
    let title: String
    let year: Int
    let genre: String?
    let artworkKey: String?
    let tracks: [LibraryTrack]

    var allSynced: Bool { tracks.allSatisfy(\.syncEnabled) }
}

/// Key used to group by Album Artist (falling back to Artist), matching how the iPod itself groups
/// multi-artist albums when "Use Album Artist for Grouping" is on for a sync.
private func groupArtistName(_ t: LibraryTrack) -> String {
    let name = (t.albumArtist?.isEmpty == false ? t.albumArtist : t.artist) ?? ""
    return name.isEmpty ? "Unknown Artist" : name
}

struct MusicView: View {
    @Environment(LibraryStore.self) private var envLibrary: LibraryStore?
    private var library: LibraryStore { envLibrary ?? AppServices.shared.library }
    @Environment(AppState.self) private var envAppState: AppState?
    private var appState: AppState { envAppState ?? AppServices.shared.appState }
    @State private var selection = Set<UUID>()
    @State private var sortOrder = [KeyPathComparator(\LibraryTrack.title)]
    @State private var search = ""
    @State private var showNewPlaylistFromSelection = false
    @State private var isDropTargeted = false
    @State private var confirmRemoveMissing = false
    @FocusState private var searchFieldFocused: Bool
    @State private var mode: MusicViewMode = MusicViewMode(rawValue: UserDefaults.standard.string(forKey: "musicViewMode") ?? "") ?? .byArtist
    @State private var selectedArtistID: String?

    // Grouping and sorting a few thousand tracks isn't free; cache it and only redo the work when the
    // underlying data actually changes; a toggle on one track re-renders this view but shouldn't repeat it.
    @State private var cachedArtistGroups: [ArtistGroup] = []
    @State private var cachedVisibleTracks: [LibraryTrack] = []

    private var searchedTracks: [LibraryTrack] {
        guard !search.isEmpty else { return library.songs }
        let q = search.lowercased()
        return library.songs.filter {
            $0.title.lowercased().contains(q) || ($0.artist?.lowercased().contains(q) ?? false) || ($0.album?.lowercased().contains(q) ?? false) || ($0.genre?.lowercased().contains(q) ?? false)
        }
    }

    var body: some View {
        Group {
            if library.songs.isEmpty {
                EmptyStateView(icon: "music.note", title: "No Music Yet",
                               message: "Add MP3, AAC, Apple Lossless, WAV or AIFF files, or import your Music app library. FLAC and other formats are converted to AAC when syncing.") {
                    AnyView(HStack {
                        Button("Add Files…") { appState.requestAddFiles = true }
                        Button("Import from Music App…") { appState.showMusicImport = true }
                    })
                }
            } else if mode == .byArtist {
                artistsSplitView
            } else {
                table
            }
        }
        .navigationTitle("Music")
        .navigationSubtitle(subtitle)
        .searchable(text: $search, placement: .toolbar, prompt: "Search songs")
        .searchFocused($searchFieldFocused)
        .background {
            Button("") { searchFieldFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
        }
        .toolbar {
            ToolbarItemGroup {
                if library.isImporting {
                    HStack(spacing: 6) {
                        ProgressView(value: library.importProgress).progressViewStyle(.linear).frame(width: 90)
                        Text(library.importStatus ?? "Importing…").font(.caption).lineLimit(1).frame(maxWidth: 220, alignment: .leading)
                    }
                }
                Picker("View", selection: $mode) {
                    Text("By Artist").tag(MusicViewMode.byArtist)
                    Text("All Songs").tag(MusicViewMode.allSongs)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: mode) { _, v in UserDefaults.standard.set(v.rawValue, forKey: "musicViewMode") }
                Button { appState.requestAddFiles = true } label: { Label("Add Files", systemImage: "plus") }
                    .help("Add audio files or folders to the library")
                Button { appState.showMusicImport = true } label: { Label("Import from Music", systemImage: "square.and.arrow.down") }
                    .help("Import songs and playlists from the Music app")
                if !library.missingPaths.isEmpty {
                    Button(role: .destructive) { confirmRemoveMissing = true } label: { Label("Remove Missing Files", systemImage: "exclamationmark.triangle") }
                        .help("Remove songs whose files were deleted or moved outside iPod Pro Max")
                }
            }
        }
        .confirmationDialog("Remove missing files from your library?", isPresented: $confirmRemoveMissing) {
            Button("Remove", role: .destructive) { library.removeMissingTracks() }
        } message: {
            Text("Copies already on an iPod stay there — turn on “Remove songs that aren't in this library” in that iPod's sync options to clear them too.")
        }
        .task { await library.refreshMissingFiles() }
        .task(id: searchedTracks) { recomputeDerived() }
        .task(id: sortOrder) { recomputeDerived() }
        .onAppear { recomputeDerived() }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            Task {
                var urls: [URL] = []
                for p in providers {
                    if let url = try? await p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? URL {
                        urls.append(url)
                    } else if let data = try? await p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                        urls.append(url)
                    }
                }
                if !urls.isEmpty { await library.importFiles(urls) }
            }
            return true
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, lineWidth: 3).padding(6)
                    .overlay(Text("Drop audio files or folders to add them").font(.title3).padding(12).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8)))
                    .allowsHitTesting(false)
            }
        }
        .sheet(isPresented: $showNewPlaylistFromSelection) {
            NewPlaylistSheet(initialTrackIDs: Array(selection))
        }
    }

    private func recomputeDerived() {
        cachedVisibleTracks = searchedTracks.sorted(using: sortOrder)
        let byArtist = Dictionary(grouping: searchedTracks, by: groupArtistName)
        var groups: [ArtistGroup] = []
        for (name, tracks) in byArtist {
            groups.append(Self.makeArtistGroup(name: name, tracks: tracks))
        }
        groups.sort { SortKey.collate($0.name) < SortKey.collate($1.name) }
        cachedArtistGroups = groups
    }

    private static func makeArtistGroup(name: String, tracks: [LibraryTrack]) -> ArtistGroup {
        let byAlbum = Dictionary(grouping: tracks) { $0.album ?? "" }
        var albums: [AlbumGroup] = []
        for (albumTitle, albumTracks) in byAlbum {
            albums.append(makeAlbumGroup(artistName: name, title: albumTitle, tracks: albumTracks))
        }
        albums.sort { a, b in
            if a.year != b.year { return a.year > b.year }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
        let artwork = albums.first(where: { $0.artworkKey != nil })?.artworkKey
        return ArtistGroup(id: name, name: name, artworkKey: artwork, albums: albums)
    }

    private static func makeAlbumGroup(artistName: String, title: String, tracks: [LibraryTrack]) -> AlbumGroup {
        let sorted = tracks.sorted { a, b in
            if a.discNumber != b.discNumber { return a.discNumber < b.discNumber }
            if a.trackNumber != b.trackNumber { return a.trackNumber < b.trackNumber }
            return a.title < b.title
        }
        let year = sorted.first(where: { $0.year > 0 })?.year ?? 0
        let genre = sorted.first(where: { $0.genre != nil })?.genre
        let artworkKey = sorted.first(where: { $0.artworkKey != nil })?.artworkKey
        return AlbumGroup(id: "\(artistName)\u{1}\(title)", title: title.isEmpty ? "Unknown Album" : title,
                           year: year, genre: genre, artworkKey: artworkKey, tracks: sorted)
    }

    private var subtitle: String {
        let n = library.songs.count
        let synced = library.songs.filter(\.syncEnabled).count
        let bytes = library.songs.filter(\.syncEnabled).reduce(Int64(0)) { $0 + $1.fileSize }
        return "\(n) song\(n == 1 ? "" : "s"), \(synced) set to sync, \(Format.bytes(bytes))"
    }

    // MARK: - By Artist (master-detail, like the iPod's own Artists list)

    private var artistsSplitView: some View {
        HSplitView {
            artistSidebar
                .frame(minWidth: 200, idealWidth: 240, maxWidth: 320)
            if let id = selectedArtistID, let group = cachedArtistGroups.first(where: { $0.id == id }) {
                ArtistDetailView(group: group, library: library, selection: $selection)
                    .frame(minWidth: 420)
            } else {
                Text("Select an artist").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { if selectedArtistID == nil { selectedArtistID = cachedArtistGroups.first?.id } }
        .onChange(of: cachedArtistGroups.map(\.id)) { _, ids in
            if let id = selectedArtistID, !ids.contains(id) { selectedArtistID = ids.first }
            else if selectedArtistID == nil { selectedArtistID = ids.first }
        }
    }

    private var artistSidebar: some View {
        List(selection: $selectedArtistID) {
            ForEach(cachedArtistGroups) { group in
                HStack(spacing: 10) {
                    ArtworkThumb(url: library.artworkURL(group.artworkKey), size: 28, cornerRadius: 14)
                    Text(group.name).lineLimit(1)
                    Spacer()
                }
                .tag(group.id)
                .contextMenu {
                    Button("Sync to iPod") { library.setSync(true, forTracks: Set(group.allTrackIDs)) }
                    Button("Don't Sync") { library.setSync(false, forTracks: Set(group.allTrackIDs)) }
                }
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: - All Songs (flat table)

    private var table: some View {
        Table(cachedVisibleTracks, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Sync") { t in
                Toggle("", isOn: Binding(get: { t.syncEnabled }, set: { library.setSync($0, forTracks: selection.contains(t.id) ? selection : [t.id]) }))
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .width(40)
            TableColumn("Title", value: \.title) { t in
                HStack(spacing: 8) {
                    ArtworkThumb(url: library.artworkURL(t.artworkKey), size: 22, cornerRadius: 3)
                    Text(t.title).lineLimit(1)
                    if library.missingPaths.contains(t.path) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help("File not found")
                    }
                }
            }
            .width(min: 180, ideal: 300)
            TableColumn("Artist", value: \.artistForSort) { t in Text(t.displayArtist).lineLimit(1) }
            TableColumn("Album", value: \.albumForSort) { t in Text(t.displayAlbum).lineLimit(1) }
            TableColumn("Time", value: \.durationMs) { t in Text(Format.duration(ms: t.durationMs)).monospacedDigit() }
                .width(60)
            TableColumn("Genre", value: \.genreForSort) { t in Text(t.genre ?? "").lineLimit(1) }
                .width(min: 60, ideal: 100)
            TableColumn("Format", value: \.fileExtension) { t in
                Text(t.formatLabel).foregroundStyle(t.needsTranscode ? .orange : .primary)
            }
            .width(min: 60, ideal: 90)
            TableColumn("Plays", value: \.playCount) { t in Text(t.playCount == 0 ? "" : "\(t.playCount)").monospacedDigit() }
                .width(45)
            TableColumn("Size", value: \.fileSize) { t in Text(Format.bytes(t.fileSize)).monospacedDigit() }
                .width(70)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            let target = ids.isEmpty ? selection : ids
            Menu("Add to Playlist") {
                ForEach(library.playlists) { pl in
                    Button(pl.name) { library.addTracks(Array(target), toPlaylist: pl.id) }
                }
                if !library.playlists.isEmpty { Divider() }
                Button("New Playlist…") {
                    selection = target
                    showNewPlaylistFromSelection = true
                }
            }
            Button("Sync to iPod") { library.setSync(true, forTracks: target) }
            Button("Don't Sync") { library.setSync(false, forTracks: target) }
            Divider()
            Button("Show in Finder") {
                let urls = library.tracks.filter { target.contains($0.id) }.map(\.url)
                NSWorkspace.shared.activateFileViewerSelecting(urls)
            }
            Button("Remove from Library", role: .destructive) {
                library.removeTracks(ids: target)
                selection.subtract(target)
            }
        }
    }
}

/// Right-hand pane for the selected artist: one section per album, big artwork, numbered tracklist —
/// everything needed to decide what of theirs goes on the iPod.
private struct ArtistDetailView: View {
    let group: ArtistGroup
    let library: LibraryStore
    @Binding var selection: Set<UUID>

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                header
                ForEach(group.albums) { album in
                    albumSection(album)
                }
            }
            .padding(20)
        }
    }

    private var header: some View {
        HStack {
            Text(group.name).font(.title.bold())
            Spacer()
            Toggle("Sync all", isOn: Binding(
                get: { group.allSynced },
                set: { v in library.setSync(v, forTracks: Set(group.allTrackIDs)) }
            ))
            .toggleStyle(.checkbox)
        }
    }

    private func albumSection(_ album: AlbumGroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                ArtworkThumb(url: library.artworkURL(album.artworkKey), size: 72, cornerRadius: 6)
                VStack(alignment: .leading, spacing: 2) {
                    Text(album.title).font(.headline)
                    HStack(spacing: 6) {
                        if let g = album.genre { Text(g) }
                        if album.year > 0 { Text(String(album.year)) }
                        Text("\(album.tracks.count) song\(album.tracks.count == 1 ? "" : "s")")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(get: { album.allSynced }, set: { v in library.setSync(v, forTracks: Set(album.tracks.map(\.id))) }))
                    .labelsHidden().toggleStyle(.checkbox)
            }
            VStack(spacing: 0) {
                ForEach(album.tracks) { t in
                    trackRow(t)
                    if t.id != album.tracks.last?.id { Divider() }
                }
            }
            .padding(.leading, 86)
        }
    }

    private func trackRow(_ t: LibraryTrack) -> some View {
        HStack(spacing: 10) {
            Text(t.trackNumber > 0 ? "\(t.trackNumber)" : "–")
                .font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 20, alignment: .trailing)
            Text(t.title).lineLimit(1)
            if library.missingPaths.contains(t.path) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help("File not found")
            }
            Spacer()
            Text(Format.duration(ms: t.durationMs)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            Toggle("", isOn: Binding(get: { t.syncEnabled }, set: { v in library.setSync(v, forTracks: [t.id]) }))
                .labelsHidden().toggleStyle(.checkbox)
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Sync to iPod") { library.setSync(true, forTracks: [t.id]) }
            Button("Don't Sync") { library.setSync(false, forTracks: [t.id]) }
            Divider()
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([t.url]) }
            Button("Remove from Library", role: .destructive) { library.removeTracks(ids: [t.id]) }
        }
    }
}
