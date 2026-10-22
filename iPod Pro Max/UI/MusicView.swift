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
    var totalDurationMs: Int { albums.reduce(0) { $0 + $1.totalDurationMs } }
}

private struct AlbumGroup: Identifiable {
    let id: String
    let title: String
    let year: Int
    let genre: String?
    let artworkKey: String?
    let tracks: [LibraryTrack]

    var allSynced: Bool { tracks.allSatisfy(\.syncEnabled) }
    var totalDurationMs: Int { tracks.reduce(0) { $0 + $1.durationMs } }
}

/// Key used to group by Album Artist (falling back to Artist), matching how the iPod itself groups
/// multi-artist albums when "Use Album Artist for Grouping" is on for a sync.
private func groupArtistName(_ t: LibraryTrack) -> String {
    let name = (t.albumArtist?.isEmpty == false ? t.albumArtist : t.artist) ?? ""
    return name.isEmpty ? "Unknown Artist" : name
}

/// "12 songs, 48 min" style summary.
private func songsSummary(count: Int, durationMs: Int) -> String {
    let minutes = durationMs / 60_000
    let time = minutes >= 60 ? "\(minutes / 60) hr \(minutes % 60) min" : "\(minutes) min"
    return "\(count) song\(count == 1 ? "" : "s"), \(time)"
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
    @State private var selectedArtistIDs: Set<String> = []
    private var artistPhotos: ArtistPhotoStore { AppServices.shared.artistPhotos }

    // Grouping and sorting a few thousand tracks isn't free; cache it and only redo the work when the
    // underlying data actually changes; a toggle on one track re-renders this view but shouldn't repeat it.
    @State private var cachedArtistGroups: [ArtistGroup] = []
    @State private var cachedVisibleTracks: [LibraryTrack] = []
    @State private var cachedSubtitle = ""
    /// Bumped whenever `cachedArtistGroups` is rebuilt, so the artist list can skip re-rendering otherwise.
    @State private var groupsVersion = 0

    /// What the cached data depends on. Keyed on the library's revision counter rather than the tracks
    /// themselves: comparing thousands of tracks on every render was itself a noticeable cost.
    private struct DerivedKey: Equatable {
        var revision: Int
        var search: String
        var sortOrder: [KeyPathComparator<LibraryTrack>]
    }

    private func searchedTracks(in songs: [LibraryTrack]) -> [LibraryTrack] {
        guard !search.isEmpty else { return songs }
        let q = search.lowercased()
        return songs.filter {
            $0.title.lowercased().contains(q) || ($0.artist?.lowercased().contains(q) ?? false) || ($0.album?.lowercased().contains(q) ?? false) || ($0.genre?.lowercased().contains(q) ?? false)
        }
    }

    var body: some View {
        Group {
            if !library.tracks.contains(where: { !$0.isVideo && !$0.isAudiobook }) {
                EmptyStateView(icon: "music.note", title: "No Music Yet",
                               message: "Add MP3, AAC, Apple Lossless, WAV or AIFF files, or import your Music app library. FLAC and other formats are converted to AAC when syncing.") {
                    AnyView(HStack {
                        Button("Add Files…") { appState.requestAddFiles = true }
                        Button("Choose Library Folder…") { appState.requestChooseLibraryFolder = true }
                        Button("Import from Music App…") { appState.showMusicImport = true }
                    })
                }
            } else if mode == .byArtist {
                artistsSplitView
            } else {
                table
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !selection.isEmpty {
                SelectionBar(selection: $selection, library: library, onNewPlaylist: { showNewPlaylistFromSelection = true })
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.25), value: selection.isEmpty)
        .navigationTitle("Music")
        .navigationSubtitle(cachedSubtitle)
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
                    Label("By Artist", systemImage: "music.mic").tag(MusicViewMode.byArtist)
                    Label("All Songs", systemImage: "list.bullet").tag(MusicViewMode.allSongs)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("Browse by artist or as a list of all songs")
                .onChange(of: mode) { _, v in UserDefaults.standard.set(v.rawValue, forKey: "musicViewMode") }
                Button { appState.requestScanLibrary = true } label: { Label("Scan Library Folder", systemImage: "arrow.clockwise") }
                    .help("Check the library folder for new files")
                    .disabled(library.isScanningLibrary)
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
        .task(id: DerivedKey(revision: library.tracksRevision, search: search, sortOrder: sortOrder)) { recomputeDerived() }
        .onChange(of: library.tracksRevision) {
            // Drop selected IDs whose tracks were removed, so the selection bar never counts ghosts.
            guard !selection.isEmpty else { return }
            let live = Set(library.tracks.map(\.id))
            if !selection.isSubset(of: live) { selection.formIntersection(live) }
        }
        .onExitCommand { selection.removeAll() }
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
        let songs = library.songs
        let searched = searchedTracks(in: songs)
        cachedVisibleTracks = searched.sorted(using: sortOrder)
        let byArtist = Dictionary(grouping: searched, by: groupArtistName)
        var groups: [ArtistGroup] = []
        for (name, tracks) in byArtist {
            groups.append(Self.makeArtistGroup(name: name, tracks: tracks))
        }
        groups.sort { SortKey.collate($0.name) < SortKey.collate($1.name) }
        cachedArtistGroups = groups
        groupsVersion &+= 1
        cachedSubtitle = Self.subtitle(for: songs)
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

    private static func subtitle(for songs: [LibraryTrack]) -> String {
        var synced = 0
        var bytes: Int64 = 0
        for t in songs where t.syncEnabled {
            synced += 1
            bytes += t.fileSize
        }
        return "\(songs.count) song\(songs.count == 1 ? "" : "s"), \(synced) set to sync, \(Format.bytes(bytes))"
    }

    // MARK: - By Artist (master-detail, like the iPod's own Artists list)

    private var selectedGroups: [ArtistGroup] {
        cachedArtistGroups.filter { selectedArtistIDs.contains($0.id) }
    }

    private var artistsSplitView: some View {
        HSplitView {
            artistSidebar
                .frame(minWidth: 200, idealWidth: 250, maxWidth: 340)
            let groups = selectedGroups
            if groups.isEmpty {
                ContentUnavailableView("Select an Artist", systemImage: "music.mic",
                                       description: Text("⌘-click or ⇧-click to see several artists at once."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ArtistDetailView(groups: groups, library: library, photos: artistPhotos, selection: $selection,
                                 onNewPlaylist: { showNewPlaylistFromSelection = true })
                    .id(groups.map(\.id))
                    .frame(minWidth: 460)
            }
        }
        .onAppear {
            if selectedArtistIDs.isEmpty, let first = cachedArtistGroups.first?.id { selectedArtistIDs = [first] }
            fetchArtistPhotos()
        }
        .onChange(of: groupsVersion) {
            let ids = Set(cachedArtistGroups.map(\.id))
            selectedArtistIDs.formIntersection(ids)
            if selectedArtistIDs.isEmpty, let first = cachedArtistGroups.first?.id { selectedArtistIDs = [first] }
            fetchArtistPhotos()
        }
        .onChange(of: selectedArtistIDs) { selection.removeAll() }
    }

    /// Fills in photos for artists that don't have one yet; a no-op once every artist has been looked up.
    private func fetchArtistPhotos() {
        guard search.isEmpty else { return }
        artistPhotos.fetchMissingInBackground(cachedArtistGroups.map(\.name))
    }

    private var artistSidebar: some View {
        ArtistListView(groups: cachedArtistGroups, version: groupsVersion, photosRevision: artistPhotos.revision,
                       selectedArtistIDs: $selectedArtistIDs, library: library, photos: artistPhotos)
            .equatable()
    }
}

/// The artist column. Equatable on purpose: hundreds of rows with drag and context-menu modifiers are
/// expensive to rebuild, and without this every change in the Music view (selecting a song, the
/// selection bar appearing) rebuilt the whole list.
///
/// ⌘-click / ⇧-click select several artists; dragging any selected artist onto an iPod carries all of them.
private struct ArtistListView: View, Equatable {
    let groups: [ArtistGroup]
    let version: Int
    let photosRevision: Int
    @Binding var selectedArtistIDs: Set<String>
    let library: LibraryStore
    let photos: ArtistPhotoStore

    static func == (a: Self, b: Self) -> Bool {
        a.version == b.version && a.photosRevision == b.photosRevision && a.selectedArtistIDs == b.selectedArtistIDs
    }

    var body: some View {
        List(selection: $selectedArtistIDs) {
            ForEach(groups) { group in
                HStack(spacing: 10) {
                    ArtworkThumb(url: photos.photoURL(for: group.name) ?? library.artworkURL(group.artworkKey),
                                 size: 34, cornerRadius: 17, placeholder: "music.mic")
                    VStack(alignment: .leading, spacing: 1) {
                        Text(group.name).lineLimit(1)
                        Text("\(group.albums.count) album\(group.albums.count == 1 ? "" : "s") · \(group.trackCount) song\(group.trackCount == 1 ? "" : "s")")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .padding(.vertical, 2)
                .tag(group.id)
                .draggable(dragPayload(for: group)) {
                    dragPreview(for: group)
                }
                .contextMenu {
                    let ids = Set(targetGroups(for: group).flatMap(\.allTrackIDs))
                    Button("Sync to iPod") { library.setSync(true, forTracks: ids) }
                    Button("Don't Sync") { library.setSync(false, forTracks: ids) }
                    if !selectedArtistIDs.contains(group.id) || selectedArtistIDs.count == 1 {
                        Divider()
                        Button("Choose Artist Photo…") { Task { await choosePhoto(for: group.name) } }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    /// The artists a drag or context menu on `group` acts on: the whole selection if it's part of it.
    private func targetGroups(for group: ArtistGroup) -> [ArtistGroup] {
        guard selectedArtistIDs.contains(group.id), selectedArtistIDs.count > 1 else { return [group] }
        return groups.filter { selectedArtistIDs.contains($0.id) }
    }

    private func dragPayload(for group: ArtistGroup) -> TrackIDsTransfer {
        TrackIDsTransfer(ids: targetGroups(for: group).flatMap(\.allTrackIDs))
    }

    private func dragPreview(for group: ArtistGroup) -> some View {
        let targets = targetGroups(for: group)
        return DragPreview(count: targets.reduce(0) { $0 + $1.trackCount },
                           artworkURL: photos.photoURL(for: group.name) ?? library.artworkURL(group.artworkKey),
                           title: targets.count > 1 ? "\(targets.count) artists" : group.name)
    }

    @MainActor
    private func choosePhoto(for artist: String) async {
        let panel = NSOpenPanel()
        panel.title = "Choose a Photo of \(artist)"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard await panel.begin() == .OK, let url = panel.url,
              let stored = await photos.setCustomPhoto(url, for: artist) else { return }
        ThumbnailCache.shared.remove(stored)
    }
}

extension MusicView {
    // MARK: - All Songs (flat table)

    private var table: some View {
        Table(of: LibraryTrack.self, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Sync") { t in
                Toggle("", isOn: Binding(get: { t.syncEnabled }, set: { library.setSync($0, forTracks: selection.contains(t.id) ? selection : [t.id]) }))
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .width(40)
            TableColumn("Title", value: \.title) { t in
                HStack(spacing: 8) {
                    ArtworkThumb(url: library.artworkURL(t.artworkKey), size: 24, cornerRadius: 4)
                    Text(t.title).lineLimit(1)
                    if library.missingPaths.contains(t.path) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help("File not found")
                    }
                }
            }
            .width(min: 180, ideal: 300)
            TableColumn("Artist", value: \.artistForSort) { t in Text(t.displayArtist).lineLimit(1) }
            TableColumn("Album", value: \.albumForSort) { t in Text(t.displayAlbum).lineLimit(1) }
            TableColumn("Time", value: \.durationMs) { t in Text(Format.duration(ms: t.durationMs)).monospacedDigit().foregroundStyle(.secondary) }
                .width(60)
            TableColumn("Genre", value: \.genreForSort) { t in Text(t.genre ?? "").lineLimit(1).foregroundStyle(.secondary) }
                .width(min: 60, ideal: 100)
            TableColumn("Format", value: \.fileExtension) { t in
                Text(t.formatLabel).foregroundStyle(t.needsTranscode ? .orange : .secondary)
            }
            .width(min: 60, ideal: 90)
            TableColumn("Plays", value: \.playCount) { t in Text(t.playCount == 0 ? "" : "\(t.playCount)").monospacedDigit().foregroundStyle(.secondary) }
                .width(45)
            TableColumn("Size", value: \.fileSize) { t in Text(Format.bytes(t.fileSize)).monospacedDigit().foregroundStyle(.secondary) }
                .width(70)
        } rows: {
            ForEach(cachedVisibleTracks) { t in
                TableRow(t).draggable(TrackIDsTransfer(ids: selection.contains(t.id) ? Array(selection) : [t.id]))
            }
        }
        .alternatingRowBackgrounds()
        .contextMenu(forSelectionType: UUID.self) { ids in
            TrackContextMenu(ids: ids.isEmpty ? selection : ids, library: library, selection: $selection,
                             onNewPlaylist: { showNewPlaylistFromSelection = true })
        }
    }
}

/// Context menu shared by the table and the artist view; acts on `ids`.
private struct TrackContextMenu: View {
    let ids: Set<UUID>
    let library: LibraryStore
    @Binding var selection: Set<UUID>
    let onNewPlaylist: () -> Void

    var body: some View {
        Menu("Add to Playlist") {
            ForEach(library.playlists) { pl in
                Button(pl.name) { library.addTracks(orderedIDs, toPlaylist: pl.id) }
            }
            if !library.playlists.isEmpty { Divider() }
            Button("New Playlist…") {
                selection = ids
                onNewPlaylist()
            }
        }
        Button("Sync to iPod") { library.setSync(true, forTracks: ids) }
        Button("Don't Sync") { library.setSync(false, forTracks: ids) }
        Divider()
        Button("Show in Finder") {
            let urls = library.tracks.filter { ids.contains($0.id) }.map(\.url)
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
        Button("Remove from Library", role: .destructive) {
            library.removeTracks(ids: ids)
            selection.subtract(ids)
        }
    }

    /// Library order rather than Set order, so a playlist built from a selection keeps album order.
    private var orderedIDs: [UUID] { library.tracks.filter { ids.contains($0.id) }.map(\.id) }
}

/// Floating bar shown while songs are selected: what's selected, plus the common actions on it.
private struct SelectionBar: View {
    @Binding var selection: Set<UUID>
    let library: LibraryStore
    let onNewPlaylist: () -> Void

    var body: some View {
        let tracks = library.tracks.filter { selection.contains($0.id) }
        let allSynced = tracks.allSatisfy(\.syncEnabled)
        HStack(spacing: 12) {
            Image(systemName: "music.note.list")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 0) {
                Text("\(tracks.count) song\(tracks.count == 1 ? "" : "s") selected").font(.callout.weight(.semibold))
                Text("\(Format.bytes(tracks.reduce(Int64(0)) { $0 + $1.fileSize })) · drag onto an iPod in the sidebar to add")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Menu {
                ForEach(library.playlists) { pl in
                    Button(pl.name) { library.addTracks(tracks.map(\.id), toPlaylist: pl.id) }
                }
                if !library.playlists.isEmpty { Divider() }
                Button("New Playlist…", action: onNewPlaylist)
            } label: {
                Label("Add to Playlist", systemImage: "text.badge.plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Button {
                library.setSync(!allSynced, forTracks: selection)
            } label: {
                Label(allSynced ? "Don't Sync" : "Sync to iPod", systemImage: allSynced ? "minus.circle" : "checkmark.circle")
            }
            Button {
                selection.removeAll()
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Deselect (Esc)")
        }
        .controlSize(.regular)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }
}

/// What follows the pointer while dragging songs toward an iPod.
private struct DragPreview: View {
    let count: Int
    let artworkURL: URL?
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            ArtworkThumb(url: artworkURL, size: 32, cornerRadius: 5)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.callout.weight(.semibold)).lineLimit(1)
                Text("\(count) song\(count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .frame(maxWidth: 260, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
    }
}

/// Row frames in the track list's coordinate space, for hit-testing a click-and-drag sweep. A plain
/// reference type on purpose: rows reporting their frames while scrolling shouldn't re-render the view.
private final class RowFrames {
    var frames: [UUID: CGRect] = [:]

    /// The row under `y`, or the nearest one when `y` falls in a gap (e.g. on an album header).
    func row(atY y: CGFloat) -> UUID? {
        if let hit = frames.first(where: { $0.value.minY <= y && y < $0.value.maxY }) { return hit.key }
        return frames.min { abs($0.value.midY - y) < abs($1.value.midY - y) }?.key
    }
}

/// Right-hand pane for the selected artist: one section per album, big artwork, numbered tracklist —
/// everything needed to decide what of theirs goes on the iPod.
///
/// Track selection works like a Finder list: click selects, ⌘-click toggles, ⇧-click extends, and
/// click-and-drag starting on an unselected song sweeps a range. Dragging a selected song instead
/// picks up the whole selection, which can be dropped onto an iPod in the sidebar.
private struct ArtistDetailView: View {
    /// One artist, or several when they're ⌘/⇧-selected together — then their albums follow each other,
    /// each artist under its own small heading.
    let groups: [ArtistGroup]
    let library: LibraryStore
    let photos: ArtistPhotoStore
    @Binding var selection: Set<UUID>
    let onNewPlaylist: () -> Void

    @State private var rowFrames = RowFrames()
    @State private var anchorID: UUID?
    @State private var sweepBase: Set<UUID>?
    private let orderedIDs: [UUID]

    init(groups: [ArtistGroup], library: LibraryStore, photos: ArtistPhotoStore, selection: Binding<Set<UUID>>, onNewPlaylist: @escaping () -> Void) {
        self.groups = groups
        self.library = library
        self.photos = photos
        _selection = selection
        self.onNewPlaylist = onNewPlaylist
        orderedIDs = groups.flatMap(\.allTrackIDs)
    }

    private static let space = "artistTracks"

    private var allSynced: Bool { groups.allSatisfy(\.allSynced) }

    private func photoURL(_ g: ArtistGroup) -> URL? {
        photos.photoURL(for: g.name) ?? library.artworkURL(g.artworkKey)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                header
                ForEach(groups) { group in
                    if groups.count > 1 { artistHeading(group) }
                    ForEach(group.albums) { album in
                        albumSection(album)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 24)
            .coordinateSpace(.named(Self.space))
        }
        .background {
            // Clicking empty space clears the selection, like any macOS list.
            Color.clear.contentShape(Rectangle()).onTapGesture { selection.removeAll() }
        }
    }

    // MARK: Header

    private var header: some View {
        let albumCount = groups.reduce(0) { $0 + $1.albums.count }
        let trackCount = groups.reduce(0) { $0 + $1.trackCount }
        let duration = groups.reduce(0) { $0 + $1.totalDurationMs }
        return HStack(alignment: .center, spacing: 18) {
            if groups.count == 1, let g = groups.first {
                ArtworkThumb(url: photoURL(g), size: 96, cornerRadius: 48, placeholder: "music.mic")
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
            } else {
                // A small fan of the first few artists' photos.
                ZStack {
                    ForEach(Array(groups.prefix(3).enumerated().reversed()), id: \.element.id) { i, g in
                        ArtworkThumb(url: photoURL(g), size: 72, cornerRadius: 36, placeholder: "music.mic")
                            .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
                            .offset(x: CGFloat(i) * 26)
                    }
                }
                .frame(width: 72 + CGFloat(min(groups.count, 3) - 1) * 26, height: 96, alignment: .leading)
                .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(groups.count == 1 ? groups[0].name : "\(groups.count) Artists").font(.largeTitle.bold()).lineLimit(2)
                Text("\(albumCount) album\(albumCount == 1 ? "" : "s") · \(songsSummary(count: trackCount, durationMs: duration))")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(isOn: Binding(
                get: { allSynced },
                set: { v in library.setSync(v, forTracks: Set(orderedIDs)) }
            )) {
                Label(allSynced ? "Syncing All" : "Sync All", systemImage: allSynced ? "checkmark" : "arrow.triangle.2.circlepath")
            }
            .toggleStyle(.button)
            .controlSize(.large)
            .help(groups.count == 1 ? "Put every song by this artist on your iPod" : "Put every song by these artists on your iPod")
        }
        .padding(18)
        .background {
            ZStack {
                BlurredArtwork(url: groups.first.flatMap(photoURL)).opacity(0.4)
                LinearGradient(colors: [.clear, Color(nsColor: .windowBackgroundColor).opacity(0.6)], startPoint: .top, endPoint: .bottom)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .allowsHitTesting(false)
        }
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.separator.opacity(0.5), lineWidth: 0.5))
    }

    /// Divides artists when several are shown together; draggable like the artist list rows.
    private func artistHeading(_ g: ArtistGroup) -> some View {
        HStack(spacing: 10) {
            ArtworkThumb(url: photoURL(g), size: 28, cornerRadius: 14, placeholder: "music.mic")
            Text(g.name).font(.title3.bold())
            Text(songsSummary(count: g.trackCount, durationMs: g.totalDurationMs)).font(.callout).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.top, 6)
        .overlay(alignment: .bottom) { Divider().offset(y: 8) }
        .draggable(TrackIDsTransfer(ids: g.allTrackIDs)) {
            DragPreview(count: g.trackCount, artworkURL: photoURL(g), title: g.name)
        }
    }

    // MARK: Albums

    private func albumSection(_ album: AlbumGroup) -> some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                ArtworkThumb(url: library.artworkURL(album.artworkKey), size: 150, cornerRadius: 8)
                    .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
                    .draggable(TrackIDsTransfer(ids: album.tracks.map(\.id))) {
                        DragPreview(count: album.tracks.count, artworkURL: library.artworkURL(album.artworkKey), title: album.title)
                    }
                    .help("Drag onto an iPod in the sidebar to add this album")
                Toggle(isOn: Binding(get: { album.allSynced }, set: { v in library.setSync(v, forTracks: Set(album.tracks.map(\.id))) })) {
                    Text("Sync album")
                }
                .toggleStyle(.checkbox)
            }
            .frame(width: 150)

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(album.title).font(.title2.bold()).lineLimit(2)
                    Text([album.genre, album.year > 0 ? String(album.year) : nil, songsSummary(count: album.tracks.count, durationMs: album.totalDurationMs)]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.callout).foregroundStyle(.secondary)
                }
                VStack(spacing: 0) {
                    ForEach(Array(album.tracks.enumerated()), id: \.element.id) { index, t in
                        TrackRowView(track: t, library: library,
                                     isSelected: selection.contains(t.id),
                                     isSweeping: sweepBase != nil,
                                     isStriped: index.isMultiple(of: 2),
                                     dragPayload: dragPayload(for: t.id),
                                     dragTitle: selection.contains(t.id) && selection.count > 1 ? "\(selection.count) songs" : t.title,
                                     dragArtworkURL: library.artworkURL(album.artworkKey ?? t.artworkKey),
                                     onClick: { click(t.id) },
                                     sweep: sweepGesture(from: t.id),
                                     contextIDs: selection.contains(t.id) ? selection : [t.id],
                                     selection: $selection,
                                     onNewPlaylist: onNewPlaylist)
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { rowFrames.frames[t.id] = $0 }
                            .onDisappear { rowFrames.frames[t.id] = nil }
                    }
                }
                .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
            }
        }
    }

    // MARK: Selection

    private func dragPayload(for id: UUID) -> TrackIDsTransfer {
        guard selection.contains(id), selection.count > 1 else { return TrackIDsTransfer(ids: [id]) }
        return TrackIDsTransfer(ids: orderedIDs.filter(selection.contains))
    }

    private func click(_ id: UUID) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.shift), let anchorID, let range = range(from: anchorID, to: id) {
            selection = flags.contains(.command) ? selection.union(range) : Set(range)
            return
        }
        if flags.contains(.command) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        } else {
            selection = [id]
        }
        anchorID = id
    }

    private func range(from a: UUID, to b: UUID) -> [UUID]? {
        guard let i = orderedIDs.firstIndex(of: a), let j = orderedIDs.firstIndex(of: b) else { return nil }
        return Array(orderedIDs[min(i, j)...max(i, j)])
    }

    /// Click-and-drag starting on an unselected song selects every song between it and the pointer;
    /// with ⌘ held it adds that range to the existing selection instead of replacing it.
    private func sweepGesture(from id: UUID) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.space))
            .onChanged { value in
                if sweepBase == nil {
                    sweepBase = NSEvent.modifierFlags.contains(.command) ? selection : []
                    anchorID = id
                }
                guard let current = rowFrames.row(atY: value.location.y), let range = range(from: id, to: current) else { return }
                selection = (sweepBase ?? []).union(range)
            }
            .onEnded { _ in sweepBase = nil }
    }
}

/// One song in an album's tracklist. Its own view so hover state stays local to the row.
private struct TrackRowView<Sweep: Gesture>: View {
    let track: LibraryTrack
    let library: LibraryStore
    let isSelected: Bool
    /// True while a sweep is in progress anywhere in the list. Rows keep their sweep gesture until it
    /// ends: swapping the origin row to `.draggable` as soon as the sweep selects it would tear down
    /// the very gesture that's tracking the pointer.
    let isSweeping: Bool
    let isStriped: Bool
    let dragPayload: TrackIDsTransfer
    let dragTitle: String
    let dragArtworkURL: URL?
    let onClick: () -> Void
    let sweep: Sweep
    let contextIDs: Set<UUID>
    @Binding var selection: Set<UUID>
    let onNewPlaylist: () -> Void
    @State private var isHovered = false

    var body: some View {
        let row = content
            .contentShape(Rectangle())
            .onTapGesture(perform: onClick)
            .onHover { isHovered = $0 }
            .contextMenu {
                TrackContextMenu(ids: contextIDs, library: library, selection: $selection, onNewPlaylist: onNewPlaylist)
            }
        // A drag that starts on a selected song carries the selection out (to an iPod); one that starts
        // on an unselected song sweeps out a new selection instead.
        if isSelected && !isSweeping {
            row.draggable(dragPayload) {
                DragPreview(count: dragPayload.ids.count, artworkURL: dragArtworkURL, title: dragTitle)
            }
        } else {
            row.gesture(sweep)
        }
    }

    private var content: some View {
        HStack(spacing: 10) {
            Text(track.trackNumber > 0 ? "\(track.trackNumber)" : "–")
                .font(.callout).monospacedDigit()
                .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
                .frame(width: 22, alignment: .trailing)
            Text(track.title)
                .lineLimit(1)
                .foregroundStyle(isSelected ? Color.white : track.syncEnabled ? Color.primary : Color.secondary)
            if track.hasLyrics {
                Image(systemName: "quote.bubble").font(.caption2)
                    .foregroundStyle(isSelected ? Color.white.opacity(0.7) : Color.secondary.opacity(0.7))
                    .help("Has lyrics")
            }
            if library.missingPaths.contains(track.path) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help("File not found")
            }
            Spacer(minLength: 8)
            Text(Format.duration(ms: track.durationMs))
                .font(.callout).monospacedDigit()
                .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
            Toggle("", isOn: Binding(
                get: { track.syncEnabled },
                set: { v in library.setSync(v, forTracks: isSelected ? selection : [track.id]) }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
            .help(track.syncEnabled ? "Syncs to iPod" : "Doesn't sync to iPod")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 6).fill(Color.accentColor)
            } else if isHovered {
                RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06))
            } else if isStriped {
                RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.025))
            }
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 1)
    }
}
