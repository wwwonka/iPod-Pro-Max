//
//  ContentView.swift
//  iPod Pro Max
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(LibraryStore.self) private var envLibrary: LibraryStore?
    private var library: LibraryStore { envLibrary ?? AppServices.shared.library }
    @Environment(DeviceMonitor.self) private var envDevices: DeviceMonitor?
    private var devices: DeviceMonitor { envDevices ?? AppServices.shared.devices }
    @Environment(SyncCoordinator.self) private var envSync: SyncCoordinator?
    private var sync: SyncCoordinator { envSync ?? AppServices.shared.sync }
    @Environment(AppState.self) private var envAppState: AppState?
    private var appState: AppState { envAppState ?? AppServices.shared.appState }

    var body: some View {
        @Bindable var appState = appState
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        } detail: {
            detail
        }
        .sheet(isPresented: $appState.showNewPlaylist) {
            NewPlaylistSheet()
        }
        .sheet(isPresented: $appState.showAddPodcast) {
            AddPodcastSheet()
        }
        .sheet(isPresented: $appState.showMusicImport) {
            MusicImportSheet()
        }
        .alert(item: $appState.alert) { a in
            Alert(title: Text(a.title), message: Text(a.message))
        }
        .modifier(MenuRequestHandler(currentDevice: currentDevice))
        .onAppear {
            if appState.selection == nil, let d = devices.devices.first { appState.selection = .device(d.id) }
            // Development aid: `-importFolder /path` imports a folder shortly after launch.
            if let folder = UserDefaults.standard.string(forKey: "importFolder"), !folder.isEmpty {
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    await library.importFiles([URL(fileURLWithPath: folder)])
                }
            }
        }
        .onChange(of: devices.devices) { old, new in
            handleDeviceChange(old: old, new: new)
        }
        .onChange(of: library.lastError) { _, e in
            if let e {
                appState.alert = AlertMessage(title: "Something Went Wrong", message: e)
                library.lastError = nil
            }
        }
    }

    private func handleDeviceChange(old: [IPodDevice], new: [IPodDevice]) {
        // Jump to a newly connected iPod; fall back to Music when the selected one disappears.
        let initial = UserDefaults.standard.string(forKey: "initialSelection")
        let pinned = initial != nil && initial != "device" && old.isEmpty
        if pinned { return }
        if let added = new.first(where: { d in !old.contains(where: { $0.id == d.id }) }) {
            appState.selection = .device(added.id)
        } else if case .device(let id) = appState.selection, !new.contains(where: { $0.id == id }) {
            appState.selection = .music
        }
    }

    private var currentDevice: IPodDevice? {
        if case .device(let id) = appState.selection { return devices.device(id: id) }
        return nil
    }

    @ViewBuilder
    private var detail: some View {
        switch appState.selection {
        case .device(let id):
            if let d = devices.device(id: id) {
                DeviceView(device: d)
            } else {
                WelcomeView()
            }
        case .music:
            MusicView()
        case .videos:
            VideosView()
        case .podcasts:
            PodcastsView()
        case .audiobooks:
            AudiobooksView()
        case .photos:
            PhotosView()
        case .playlist(let id):
            if let pl = library.playlists.first(where: { $0.id == id }) {
                PlaylistView(playlistID: pl.id)
            } else {
                MusicView()
            }
        case nil:
            WelcomeView()
        }
    }
}

/// Turns menu-bar requests (flags on AppState) into actions.
struct MenuRequestHandler: ViewModifier {
    let currentDevice: IPodDevice?
    @Environment(LibraryStore.self) private var envLibrary: LibraryStore?
    private var library: LibraryStore { envLibrary ?? AppServices.shared.library }
    @Environment(DeviceMonitor.self) private var envDevices: DeviceMonitor?
    private var devices: DeviceMonitor { envDevices ?? AppServices.shared.devices }
    @Environment(SyncCoordinator.self) private var envSync: SyncCoordinator?
    private var sync: SyncCoordinator { envSync ?? AppServices.shared.sync }
    @Environment(AppState.self) private var envAppState: AppState?
    private var appState: AppState { envAppState ?? AppServices.shared.appState }
    @State private var confirmRemoveMissing = false

    func body(content: Content) -> some View {
        content
            .onChange(of: appState.requestScanLibrary) { _, v in
                guard v else { return }
                appState.requestScanLibrary = false
                Task { await scanLibrary() }
            }
            .onChange(of: appState.requestChooseLibraryFolder) { _, v in
                guard v else { return }
                appState.requestChooseLibraryFolder = false
                Task { await FileImportActions.chooseMusicFolder(library: library) }
            }
            .onChange(of: appState.requestRemoveMissing) { _, v in
                guard v else { return }
                appState.requestRemoveMissing = false
                confirmRemoveMissing = true
            }
            .confirmationDialog("Remove \(library.missingPaths.count) missing file\(library.missingPaths.count == 1 ? "" : "s") from your library?", isPresented: $confirmRemoveMissing) {
                Button("Remove", role: .destructive) { library.removeMissingTracks() }
            } message: {
                Text("Copies already on an iPod stay there — turn on “Remove songs that aren't in this library” in that iPod's sync options to clear them too.")
            }
            .onChange(of: appState.requestAddFiles) { _, v in
                guard v else { return }
                appState.requestAddFiles = false
                Task { await FileImportActions.addFiles(library: library) }
            }
            .onChange(of: appState.requestMusicImport) { _, v in
                guard v else { return }
                appState.requestMusicImport = false
                appState.showMusicImport = true
            }
            .onChange(of: appState.requestRefreshPodcasts) { _, v in
                guard v else { return }
                appState.requestRefreshPodcasts = false
                Task { await library.refreshAllShows() }
            }
            .onChange(of: appState.requestSync) { _, v in
                guard v else { return }
                appState.requestSync = false
                startSync()
            }
            .onChange(of: appState.requestEject) { _, v in
                guard v else { return }
                appState.requestEject = false
                eject()
            }
    }

    /// Menu-initiated scan: unlike the silent one at launch, this reports what it found.
    private func scanLibrary() async {
        guard library.musicFolderPath != nil else {
            await FileImportActions.chooseMusicFolder(library: library)
            return
        }
        guard let added = await library.scanLibraryFolders() else {
            appState.alert = AlertMessage(title: "Library Folder Not Found",
                                          message: "\(library.musicFolderPath ?? "The folder") isn't available. If it's on an external drive, connect it and try again.")
            return
        }
        var message = added == 0 ? "No new files were found." : "Added \(added) new file\(added == 1 ? "" : "s")."
        let missing = library.missingPaths.count
        if missing > 0 {
            message += " \(missing) song\(missing == 1 ? " is" : "s are") missing from disk — use Library ▸ Remove Missing Files to clean them up."
        }
        appState.alert = AlertMessage(title: "Library Scanned", message: message)
    }

    private func startSync() {
        if let d = currentDevice {
            sync.startSync(d)
        } else if let d = devices.devices.first {
            appState.selection = .device(d.id)
            sync.startSync(d)
        } else {
            appState.alert = AlertMessage(title: "No iPod Connected", message: "Plug in an iPod to sync.")
        }
    }

    private func eject() {
        guard let d = currentDevice ?? devices.devices.first else { return }
        Task {
            do { try await devices.eject(d) } catch { appState.alert = AlertMessage(title: "Couldn't Eject", message: error.localizedDescription) }
        }
    }
}

/// The fixed library sections, in a user-customizable order persisted across launches.
enum LibraryItemKind: String, CaseIterable, Codable {
    case music, videos, podcasts, audiobooks, photos

    var title: String {
        switch self {
        case .music: return "Music"
        case .videos: return "Videos"
        case .podcasts: return "Podcasts"
        case .audiobooks: return "Audiobooks"
        case .photos: return "Photos"
        }
    }

    var icon: String {
        switch self {
        case .music: return "music.note"
        case .videos: return "film"
        case .podcasts: return "antenna.radiowaves.left.and.right"
        case .audiobooks: return "book.closed"
        case .photos: return "photo.on.rectangle.angled"
        }
    }

    var sidebarItem: SidebarItem {
        switch self {
        case .music: return .music
        case .videos: return .videos
        case .podcasts: return .podcasts
        case .audiobooks: return .audiobooks
        case .photos: return .photos
        }
    }
}

struct SidebarView: View {
    @Environment(LibraryStore.self) private var envLibrary: LibraryStore?
    private var library: LibraryStore { envLibrary ?? AppServices.shared.library }
    @Environment(DeviceMonitor.self) private var envDevices: DeviceMonitor?
    private var devices: DeviceMonitor { envDevices ?? AppServices.shared.devices }
    @Environment(SyncCoordinator.self) private var envSync: SyncCoordinator?
    private var sync: SyncCoordinator { envSync ?? AppServices.shared.sync }
    @Environment(AppState.self) private var envAppState: AppState?
    private var appState: AppState { envAppState ?? AppServices.shared.appState }
    @State private var libraryOrder: [LibraryItemKind] = SidebarView.loadLibraryOrder()

    private static let orderKey = "sidebarLibraryOrder"

    private static func loadLibraryOrder() -> [LibraryItemKind] {
        guard let saved = UserDefaults.standard.array(forKey: orderKey) as? [String] else { return LibraryItemKind.allCases }
        let known = saved.compactMap { LibraryItemKind(rawValue: $0) }
        let missing = LibraryItemKind.allCases.filter { !known.contains($0) }
        return known + missing
    }

    private func saveLibraryOrder() {
        UserDefaults.standard.set(libraryOrder.map(\.rawValue), forKey: Self.orderKey)
    }

    var body: some View {
        @Bindable var appState = appState
        List(selection: $appState.selection) {
            Section("iPods") {
                if devices.devices.isEmpty {
                    Label("No iPod connected", systemImage: "ipod")
                        .foregroundStyle(.secondary)
                        .selectionDisabled()
                } else {
                    ForEach(devices.devices) { d in
                        DeviceSidebarRow(device: d, name: deviceName(d), isSyncing: sync.isSyncing(d))
                            .tag(SidebarItem.device(d.id))
                            .contextMenu {
                                Button("Sync") { sync.startSync(d) }.disabled(sync.isSyncing(d))
                                Button("Eject") { Task { try? await devices.eject(d) } }
                            }
                    }
                }
            }
            Section("Library") {
                ForEach(libraryOrder, id: \.self) { kind in
                    Label(kind.title, systemImage: kind.icon).tag(kind.sidebarItem)
                }
                .onMove { from, to in
                    libraryOrder.move(fromOffsets: from, toOffset: to)
                    saveLibraryOrder()
                }
            }
            Section("Playlists") {
                ForEach(library.playlists) { pl in
                    Label(pl.name, systemImage: "music.note.list")
                        .tag(SidebarItem.playlist(pl.id))
                        .contextMenu {
                            Button("Delete Playlist", role: .destructive) {
                                library.deletePlaylist(id: pl.id)
                                if appState.selection == .playlist(pl.id) { appState.selection = .music }
                            }
                        }
                }
                Button {
                    appState.showNewPlaylist = true
                } label: {
                    Label("New Playlist…", systemImage: "plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .listStyle(.sidebar)
    }

    private func deviceName(_ d: IPodDevice) -> String {
        library.deviceRecords[d.id]?.deviceName ?? d.displayName
    }
}

/// A sidebar iPod row that also accepts drag-and-drop from the library (songs, albums, artists,
/// audiobooks): dropped items are set to sync and a sync starts shortly after, so they land on the iPod.
private struct DeviceSidebarRow: View {
    let device: IPodDevice
    let name: String
    let isSyncing: Bool
    @Environment(LibraryStore.self) private var envLibrary: LibraryStore?
    private var library: LibraryStore { envLibrary ?? AppServices.shared.library }
    @Environment(SyncCoordinator.self) private var envSync: SyncCoordinator?
    private var sync: SyncCoordinator { envSync ?? AppServices.shared.sync }
    @State private var isDropTargeted = false
    @State private var justAdded: Int?

    var body: some View {
        HStack {
            Label(name, systemImage: "ipod")
            Spacer()
            if let justAdded {
                Text("+\(justAdded)")
                    .font(.caption2.weight(.semibold)).monospacedDigit()
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Color.accentColor, in: Capsule())
                    .foregroundStyle(.white)
                    .transition(.scale.combined(with: .opacity))
            }
            if isSyncing {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.vertical, 2)
        .background {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(0.18))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 1.5))
                    .padding(.horizontal, -6)
            }
        }
        .animation(.snappy(duration: 0.2), value: isDropTargeted)
        .help("Drag songs, albums or artists here to put them on this iPod")
        .dropDestination(for: TrackIDsTransfer.self, action: { items, _ in
            let ids = Set(items.flatMap(\.ids)).filter { library.track(id: $0) != nil }
            guard !ids.isEmpty else { return false }
            library.setSync(true, forTracks: ids)
            var r = library.record(for: device)
            var recordChanged = false
            if ids.contains(where: { library.track(id: $0)?.isAudiobook == true }), !r.audiobooksEnabled {
                r.syncAudiobooks = true
                recordChanged = true
            }
            if ids.contains(where: { library.track(id: $0)?.isVideo == true }), !r.videosEnabled {
                r.syncVideos = true
                recordChanged = true
            }
            if recordChanged { library.updateRecord(r) }
            withAnimation(.snappy) { justAdded = (justAdded ?? 0) + ids.count }
            Task {
                try? await Task.sleep(for: .seconds(2.5))
                withAnimation(.snappy) { justAdded = nil }
            }
            sync.scheduleSync(device)
            return true
        }, isTargeted: { isDropTargeted = $0 })
    }
}

struct WelcomeView: View {
    @Environment(LibraryStore.self) private var envLibrary: LibraryStore?
    private var library: LibraryStore { envLibrary ?? AppServices.shared.library }
    @Environment(AppState.self) private var envAppState: AppState?
    private var appState: AppState { envAppState ?? AppServices.shared.appState }

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "ipod")
                .font(.system(size: 72, weight: .thin))
                .foregroundStyle(.secondary)
            Text("Connect an iPod")
                .font(.title.bold())
            Text("Plug in an iPod Video, nano, mini or photo with its USB cable. It will show up in the sidebar, and you can sync music, videos, podcasts and photos from your library.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 440)
            HStack {
                Button("Add Music…") { appState.requestAddFiles = true }
                Button("Import from Music App") { appState.requestMusicImport = true }
                Button("Add Podcast…") { appState.showAddPodcast = true }
            }
            .padding(.top, 8)
            if library.tracks.isEmpty && library.shows.isEmpty {
                Text("Your library is empty. Add some songs or podcasts to get started.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

enum FileImportActions {
    @MainActor
    static func addFiles(library: LibraryStore) async {
        let panel = NSOpenPanel()
        panel.title = "Add to Library"
        panel.message = "Choose music or video files (or folders) to add to your iPod Pro Max library."
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.audio, .movie, .video, .folder, .mp3, .mpeg4Audio, .wav, .aiff, .mpeg4Movie, .quickTimeMovie, .appleProtectedMPEG4Video]
        guard await panel.begin() == .OK else { return }
        await library.importFiles(panel.urls)
    }

    @MainActor
    static func chooseMusicFolder(library: LibraryStore) async {
        let panel = NSOpenPanel()
        panel.title = "Choose Library Folder"
        panel.message = "Choose the folder your music is stored in. iPod Pro Max checks it for new files every time it opens."
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if let path = library.musicFolderPath { panel.directoryURL = URL(fileURLWithPath: path, isDirectory: true) }
        guard await panel.begin() == .OK, let url = panel.url else { return }
        await library.setMusicFolder(url)
    }
}

struct NewPlaylistSheet: View {
    @Environment(LibraryStore.self) private var envLibrary: LibraryStore?
    private var library: LibraryStore { envLibrary ?? AppServices.shared.library }
    @Environment(AppState.self) private var envAppState: AppState?
    private var appState: AppState { envAppState ?? AppServices.shared.appState }
    @Environment(\.dismiss) private var dismiss
    @State private var name = "New Playlist"
    var initialTrackIDs: [UUID] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Playlist").font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(create)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create", action: create).keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func create() {
        let pl = library.addPlaylist(name: name.trimmingCharacters(in: .whitespaces), trackIDs: initialTrackIDs)
        appState.selection = .playlist(pl.id)
        dismiss()
    }
}
