import DefaultBackend
import DeviceKit
import Foundation
import SwiftCrossUI
import iPodKit
import MediaKit
#if canImport(AppKitBackend)
    import AppKit
    import UniformTypeIdentifiers
#endif
#if os(Windows)
    import WinSDK
#endif
#if canImport(WinUIBackend)
    import WinAppSDK
#endif

#if canImport(AppKitBackend)
    private let nativeSplitProbe = ProcessInfo.processInfo.environment["IPPM_LEGACY_SPLIT"] == nil
#endif

private final class AppearanceObserverToken {}

struct ContentView: View {
    @Environment(\.chooseFile) private var chooseFile
    @Environment(\.openWindow) private var openWindow
    @Environment(\.presentAlert) private var presentAlert
    /// The library and its edits (see `LibrarySession`); the view only reads and forwards.
    @State var session = LibrarySession()
    var portableLibrary: LoadedPortableLibrary? { session.loaded }
    var library: Library? {
        get { session.library }
        nonmutating set { session.library = newValue }
    }
    var playlistSaving: Bool { session.saving }
    @State var busyDevices: Set<String> = []
    @State var transferStatus = ""
    @State var scanning = false
    @State var selectedSongIDs: [String] = []
    @State var settingsLoaded = false
    @State var didBenchDevices = false
    @State var contentRevision = 0
    @State var podcastRevision = 0
    @State var podcastsLoaded = false
    @State var audiobooks: [AudiobookEntry] = []
    @State var audiobookRows: [TrackRow] = []
    @State var selectedShowID: Foundation.UUID?
    @State var addingPodcast = false
    @State var podcastRows = PodcastRowsCache()
    @State var ipods: [IPodDevice] = []
    /// The iPods' names, for the sidebar.
    @State var devices: [String] = []
    @State var ejectError: String?
    @State var selection: SidebarItem = .music
    /// Followed from the system on Linux (GTK doesn't tell SwiftCrossUI); AppKit handles macOS.
    @State var colorScheme: ColorScheme = .light
    @State var playerVisible = false
    /// macOS: the sidebar card is open, so the content leaves it room.
    @State var sidebarOpen = true
    /// Cover width of each grid page, by `GridSection.key`.
    @State var gridArtworkSizes: [String: Double] = [:]
    @State var sidebarPoints = Int(sidebarWidth)
    /// Widths of the list columns beside the content (artists, podcast shows), resized by their edge.
    @State var artistListWidth = 250.0
    @State var showListWidth = 260.0
    @State var sectionTabs: [String: String] = [:]
    @State var sidebarOrder: [String: [String]] = [:]
    @State var editingPlaylistID: String? = nil
    @State private var appearanceRevision = 0
    @State private var pluginSheetRevision = 0
    @State private var subscriptionRevision = 0
    @State private var subscriptionsLoaded = false
    private struct RemotePlaylistTarget: Equatable {
        var pluginID: String
        var serviceName: String
    }

    @State private var newSubscriptionVisible = false
    @State private var importRemotePlaylistsVisible = false
    @State private var newRemotePlaylistTarget: RemotePlaylistTarget? = nil
    @State private var newSubscriptionInitialURL = ""
    @State private var subscriptionNotice: String?
    private let appearanceToken = AppearanceObserverToken()
    @State var selectedAlbumID: String?
    @State var playlistEditorVisible = false
    @State var playlistEditorName = ""
    @State var didReceiveInitialDevices = false
    /// The launch found an iPod, whose page opens first (the last page shown is not restored over it).
    @State var launchedOnDevice = false

    private var floatingPlayerBottomPadding: Int {
        #if canImport(AppKitBackend)
        return 0
        #else
        return playerVisible ? 124 : 0
        #endif
    }

    var body: some View {
        let _ = appearanceRevision
        let _ = subscriptionRevision
        let currentTableRows = library.flatMap { tableRows($0) }
        #if canImport(AppKitBackend)
        // Before the layout of this pass, so the sidebar and the page change in the same frame.
        let _: Void = MacChrome.shared.setSidebarAvailable(!isDevicePage)
        let _: Void = PlayerDisplayController.shared.setIdleDevices(ipods, selectedID: { if case .device(let id) = selection { return id }; return nil }())
        let _: Void = MacChrome.shared.setPlaybackSelection(rows: currentTableRows ?? [], selectedIDs: selectedSongIDs, onStart: { row, rows in if let library { startPlayback(row, displayed: rows, library: library) } })
        #endif
        ZStack(alignment: .topLeading) {
            ZStack(alignment: .bottom) {
                HStack(spacing: 0) {
                    MediaRail(selection: railSelection, devices: devices,
                              animateDeviceChanges: didReceiveInitialDevices)
                    #if canImport(AppKitBackend)
                    if nativeSplitProbe {
                        // SwiftCrossUI's own NSSplitView, as on Linux and Windows (IPPM_LEGACY_SPLIT=1: the old overlay).
                        NavigationSplitView {
                            sidebarColumn
                        } detail: {
                            // Always fills its pane (SwiftCrossUI centres a smaller one), and bounds the sidebar's width.
                            detailView(tableRows: currentTableRows).frame(minWidth: 760, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        }
                    } else {
                        // The main view keeps its place; the sidebar floats over its left side.
                        ZStack(alignment: .topLeading) {
                            detailView(tableRows: currentTableRows)
                            sidebarColumn.frame(width: sidebarPoints)
                        }
                    }
                    #else
                    NavigationSplitView {
                        sidebarColumn
                    } detail: {
                        detailView(tableRows: currentTableRows)
                    }
                    #endif
                }.padding(.bottom, floatingPlayerBottomPadding)
                #if !canImport(AppKitBackend)
                if playerVisible { PlayerDock() }
                #endif
            }
            if drawsWindowControls {
                WindowControls()
            }
        }
        .windowChrome(colorScheme: $colorScheme)
        .followingSystemColorScheme(colorScheme)
        .pluginPackageDropTarget()

        .task {
            PluginController.shared.observe("main-window") { pluginSheetRevision += 1 }
            ListAppearance.shared.observe(appearanceToken) { appearanceRevision += 1 }
            // With a library open the menu adds a folder (as Settings does); the first one sets it up.
            AppCommands.addMusicFolder = { Task {
                if portableLibrary == nil { await configureMusic() }
                else { await chooseAndAdd(.music, title: "Choose Music Folder") }
            } }
            AppCommands.addAudiobooksFolder = { Task {
                if portableLibrary == nil { await configureAudiobooks() }
                else { await chooseAndAdd(.audiobooks, title: "Choose Audiobooks Folder") }
            } }
            AppCommands.addPhotosFolder = { Task { await addPhotosFolder() } }
            PlaybackController.shared.onQueueReset = { PlayerDisplayController.shared.clearSources() }
            PlaybackController.shared.onEnqueue = { rows in recordPlaybackSource(rows) }
            PlaybackController.shared.startSelection = { row, rows in if let library { startPlayback(row, displayed: rows, library: library) } }
            PlayerDisplayController.shared.canReveal = { id in
                library?.trackIDs.contains(id) == true || audiobookRows.contains(where: { $0.id == id }) || PodcastController.shared.episodeIDs.contains(UUID(uuidString: id) ?? UUID())
            }
            PlayerDisplayController.shared.favoriteValue = { id in library?.allRows.first { $0.id == id }?.isFavorite }
            PlayerDisplayController.shared.onFavorite = { id, favorite in setFavorite(favorite, ids: [id]) }
            PlaybackController.shared.libraryRowsProvider = { ids in
                let wanted = Set(ids)
                let candidates = (library?.allRows ?? []) + audiobookRows + PodcastController.shared.shows.flatMap { show in
                    show.episodes.compactMap { episode -> TrackRow? in
                        guard let path = episode.localPath else { return nil }
                        return TrackRow(id: episode.id.uuidString, title: episode.title, artist: show.author ?? show.title, album: show.title, number: "", year: "", duration: "", path: path, playbackKind: .podcast, artworkKey: show.artworkKey)
                    }
                }
                let byID = Dictionary(candidates.filter { wanted.contains($0.id) }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                return ids.compactMap { byID[$0] }
            }
            AppCommands.openSettings = { openWindow(id: "settings") }
            AppCommands.createPlaylist = { isFolder in createNewPlaylist(isFolder: isFolder) }
            AppCommands.newSubscription = {
                newSubscriptionInitialURL = ""
                newSubscriptionVisible = true
            }
            AppCommands.importRemotePlaylists = {
                importRemotePlaylistsVisible = true
            }
            AppCommands.newSpotifyPlaylist = {
                newRemotePlaylistTarget = RemotePlaylistTarget(pluginID: "spotify", serviceName: "Spotify")
            }
            AppCommands.newYouTubeMusicPlaylist = {
                newRemotePlaylistTarget = RemotePlaylistTarget(pluginID: "youtube-music", serviceName: "YouTube Music")
            }
            AppCommands.newSubscriptionWithURL = { url in
                newSubscriptionInitialURL = url
                newSubscriptionVisible = true
            }
            AppCommands.openPlaylistByID = { id in
                navigationSelection.wrappedValue = .playlist(id)
            }
            AppCommands.addSource = { kind, folder in Task { await addSource(kind: kind, folder: folder) } }
            AppCommands.removeSource = { id in Task { await removeSource(id: id) } }
            #if canImport(AppKitBackend)
            MacChrome.shared.installContainerMask()
            MacChrome.shared.onSidebarChange = { open in
                sidebarOpen = open
                if settingsLoaded, let store = portableLibrary?.store { PortablePreferences.shared.stageSidebarOpen(open, store: store) }
            }
            MacChrome.shared.onSidebarWidth = { points in
                sidebarPoints = points
                if settingsLoaded, let store = portableLibrary?.store { PortablePreferences.shared.stageSidebarWidth(Double(points), store: store) }
            }
            #endif
            if let path = ProcessInfo.processInfo.environment["IPPM_CHECK_ANALYSIS"] {
                let passed = await checkDerivedAudio(path); flushLog(); exit(passed ? 0 : 1)
            }
            if let path = ProcessInfo.processInfo.environment["IPPM_CHECK_AUDIO"] {
                let passed = await checkPlatformAudio(path)
                logQueue.sync {}
                exit(passed ? 0 : 1)
            }
            #if canImport(AppKitBackend)
            // The sidebar's state machine alone (open, close, drag, restore), against the real split view.
            if ProcessInfo.processInfo.environment["IPPM_CHECK_SIDEBAR"] != nil {
                await checkNativeSidebarPersistence()
                exit(0)
            }
            #endif
            if ProcessInfo.processInfo.environment["IPPM_SETTINGS_SNAPSHOT"] != nil { AppCommands.openSettings?() }
            if let mode = ProcessInfo.processInfo.environment["IPPM_PLAYER_PREVIEW"], let path = ProcessInfo.processInfo.environment["IPPM_PLAYER_FIXTURE"] {
                library = Library.portable(PortableLibraryCache(tracks: []), source: "Player preview")
                settingsLoaded = true
                #if canImport(AppKitBackend)
                _ = MacChrome.shared.restoreSidebar(open: true, width: 210, onChange: { _ in })
                #endif
                await previewPlayerLCD(mode, path: path)
                return
            }
            if ProcessInfo.processInfo.environment["IPPM_CHECK_PLAYER"] != nil {
                checkPlaybackController()
                #if canImport(AppKitBackend)
                MacChrome.shared.checkPlayerToolbarLayout()
                await checkPlayerDisplayOwnership()
                guard await ToolbarPlaybackButton.checkHoverFeedback() else { flushLog(); exit(2) }
                checkMacMediaSession()
                #endif
                await checkPlayerActivityDeadlines()
                flushLog()
                exit(0)
            }
            if ProcessInfo.processInfo.environment["IPPM_CHECK_INTERACTIONS"] != nil {
                #if canImport(AppKitBackend)
                await checkNativeMusicInteractions()
                exit(0)
                #elseif canImport(GtkBackend)
                checkGtkAlbumGrid()
                exit(0)
                #endif
            }
            #if !canImport(AppKitBackend)
            PlaybackController.shared.onPresenceChanged = { visible in
                if visible { playerVisible = true }
                else {
                    Task {
                        try? await Task.sleep(nanoseconds: 180_000_000)
                        if PlaybackController.shared.track == nil { playerVisible = false }
                    }
                }
            }
            #endif
            await TemporaryCacheController.shared.startup()
            ApplicationLifecycle.shared.onError = { transferStatus = $0 }
            session.onError = { transferStatus = $0 }
            session.onReindexed = {
                applyArtistPhotos()
                ShareController.shared.update(tracks: portableLibrary?.cache.tracks ?? [], connectedDevice: ipods.first)
                #if canImport(AppKitBackend)
                configureMetadataEditor()
                #endif
            }
            ApplicationLifecycle.shared.savePreferences = { try await flushPreferences() }
            ApplicationLifecycle.shared.beforeExit = {
                MusicTransfer.shared.acceptingDrops = false
                defer { MusicTransfer.shared.acceptingDrops = true }
                try await flushPreferences()
                await SubscriptionController.shared.finishAndCheckpointBeforeQuit()
                await ShareController.shared.shutdown()
                await MusicTransfer.shared.finishActiveTransfers()
                await PluginController.shared.registry?.shutdownAll(timeoutSeconds: 2.0)
                try await flushPreferences()
                await PlaybackController.shared.prepareForExit()
                await TemporaryCacheController.shared.exitCleanup()
            }
            SubscriptionController.shared.observe("main") {
                subscriptionRevision += 1
                if let msg = SubscriptionController.shared.corruptSubscriptionsNotice {
                    SubscriptionController.shared.dismissCorruptNotice()
                    ejectError = msg
                }
            }
            #if canImport(AppKitBackend)
            installSubscriptionPasteMonitor()
            #endif
            MusicTransfer.shared.beforeTransfer = { _ in try await flushPreferences() }
            MusicTransfer.shared.onPodcastResult = { PodcastController.shared.apply($0) }
            PodcastController.shared.onChange = { podcastRevision += 1 }
            ArtistPhotoController.shared.onChange = { applyArtistPhotos() }
            PodcastController.shared.onError = { transferStatus = $0 }
            PodcastController.shared.onStatus = { transferStatus = $0 }
            MusicTransfer.shared.onActivityChanged = { busyDevices = $0 }
            MusicTransfer.shared.onStatus = { transferStatus = $0 }
            MusicTransfer.shared.onDeviceFinished = { device in
                DevicePageCache.shared.invalidate(device)
                contentRevision += 1
            }
            MusicTransfer.shared.onDrop = { ids, name in
                guard let device = ipod(named: name), let loaded = portableLibrary else { return false }
                // What is dragged is songs, audiobook chapters or podcast episodes: all rows of the same table.
                let dropped = ids.compactMap(UUID.init(uuidString:))
                let episodes = Set(dropped).intersection(PodcastController.shared.episodeIDs)
                let tracks = dropped.filter { !episodes.contains($0) }
                if !tracks.isEmpty { MusicTransfer.shared.enqueue(ids: tracks, device: device, loaded: loaded) }
                if !episodes.isEmpty {
                    Task {
                        let shows = await PodcastController.shared.shows(forDropped: episodes)
                        if shows.isEmpty { transferStatus = "None of those episodes could be downloaded." }
                        else { MusicTransfer.shared.enqueuePodcasts(shows: shows, device: device, loaded: loaded) }
                    }
                }
                return true
            }
            if ProcessInfo.processInfo.environment["IPPM_PREVIEW_LIBRARY"] != nil {
                var preview = await Library.load(arguments: CommandLine.arguments)
                if let path = ProcessInfo.processInfo.environment["IPPM_PREVIEW_ARTWORK"] {
                    preview.artworkFolder = URL(fileURLWithPath: path)
                }
                library = preview
                LaunchReadiness.shared.mark(.library)
                return
            }
            if ProcessInfo.processInfo.environment["IPPM_BENCH_VIEWS"] != nil {
                await loadPortable(refresh: false)
                LaunchReadiness.shared.mark(.library)
                await benchLoadedViews()
            } else if ProcessInfo.processInfo.environment["IPPM_BENCH"] != nil {
                library = await Library.load(arguments: CommandLine.arguments)
                LaunchReadiness.shared.mark(.library)
                await benchSidebar()
            } else {
                await loadPortable(refresh: false)
                LaunchReadiness.shared.mark(.library)
                if ProcessInfo.processInfo.environment["IPPM_CHECK_PREF_EXIT"] != nil {
                    await checkPreferencesOnExit()
                    return
                }
                await loadPortable(refresh: true)
            }
        }
        .task {
            await watchIPods { found in
                let isInitialDiscovery = !didReceiveInitialDevices
                let names = found.map(\.id)
                ConnectedDeviceTitles.names = Dictionary(found.map { ($0.id, $0.displayName) }, uniquingKeysWith: { a, _ in a })
                if names != devices { log("[app] iPods: \(names.isEmpty ? "none" : names.joined(separator: ", "))") }
                // As in the app: show an iPod as it's plugged in; back to Music when the shown one leaves.
                let additions = found.filter { d in !ipods.contains { $0.id == d.id && $0.mountPoint == d.mountPoint } }
                let added = additions.first
                if !additions.isEmpty { Task { await DevicePageCache.shared.prefetch(additions) } }
                for removed in ipods where !found.contains(where: { $0.id == removed.id && $0.mountPoint == removed.mountPoint }) {
                    MusicTransfer.shared.cancel(removed)
                    DevicePageCache.shared.forget(removed)
                }
                ipods = found
                devices = names
                if let tracks = portableLibrary?.cache.tracks {
                    ShareController.shared.update(tracks: tracks, connectedDevice: found.first)
                }
                if let added {
                    // `IPPM_SELECT_MUSIC=1`: stays on Music, to look at its page and sidebar.
                    selection = ProcessInfo.processInfo.environment["IPPM_SELECT_MUSIC"] != nil ? .music : .device(added.id)
                } else if case .device(let name) = selection, !names.contains(name) {
                    selection = .music
                }
                if isInitialDiscovery {
                    // The iPod the app was launched from, else the one the first page shows: the
                    // page opens on it, with its snapshot and icon ready before anything appears.
                    let launchRoot = PortableRoot.url.map(FileOps.canonicalPath)
                    let launchDevice = found.first { launchRoot == FileOps.canonicalPath($0.mountPoint) } ?? added
                    // `IPPM_SELECT_MUSIC=1` keeps Music, to look at its page.
                    let opensOnDevice = launchDevice != nil && ProcessInfo.processInfo.environment["IPPM_SELECT_MUSIC"] == nil
                    launchedOnDevice = opensOnDevice
                    if opensOnDevice, let launchDevice { selection = .device(launchDevice.id) }
                    Task {
                        #if canImport(AppKitBackend)
                        if let launchDevice {
                            let icon = await MacVolumeIconLoader.shared.image(for: launchDevice.mountPoint)
                            MacLaunchTransition.shared.setIcon(icon)
                        } else {
                            MacLaunchTransition.shared.setIcon(nil)
                        }
                        #endif
                        if let launchDevice { _ = await DevicePageCache.shared.load(launchDevice) }
                        LaunchReadiness.shared.mark(.device)
                    }
                    // Let the first device list commit without motion. Later mount notifications animate.
                    DispatchQueue.main.async { didReceiveInitialDevices = true }
                }
            }
        }
        .task(id: deviceBenchmarkReady) {
            guard deviceBenchmarkReady, !didBenchDevices else { return }
            didBenchDevices = true
            await benchDevicePages()
        }
        .sheet(isPresented: $playlistEditorVisible) {
            VStack(alignment: .leading, spacing: 16) {
                Text("New Playlist").font(.system(size: 18, weight: .semibold))
                TextField("Playlist name", text: $playlistEditorName)
                HStack {
                    Button("Cancel") { playlistEditorVisible = false }
                    Spacer()
                    Button("Create") {
                        let name = playlistEditorName.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !name.isEmpty {
                            session.createPlaylist(base: name, uniqueName: false)
                            playlistEditorVisible = false
                        }
                    }
                }
            }.padding(24).frame(width: 340)
        }
        .alert($ejectError) {}
        .alert($subscriptionNotice) {}
        .alert(
            Binding(
                get: {
                    let _ = subscriptionRevision
                    return SubscriptionController.shared.pendingCoverVerificationMessage
                },
                set: { newValue in
                    if newValue == nil {
                        SubscriptionController.shared.dismissCoverVerificationAlert()
                    }
                }
            )
        ) {
            Button("Verify on YouTube…") {
                if let url = SubscriptionController.shared.pendingCoverVerificationURL {
                    _ = SafeStorage.openURL(url)
                }
                SubscriptionController.shared.dismissCoverVerificationAlert()
            }
            Button("OK") {
                SubscriptionController.shared.dismissCoverVerificationAlert()
            }
        }
        .sheet(
            isPresented: Binding(
                get: {
                    let _ = pluginSheetRevision
                    return PluginController.shared.pendingInstall != nil && !PluginController.shared.settingsPluginsTabActive
                },
                set: { if !$0 { PluginController.shared.cancelInstall() } }
            )
        ) {
            PluginInstallSheet()
        }
        .sheet(isPresented: $newSubscriptionVisible) {
            NewSubscriptionSheet(
                isPresented: $newSubscriptionVisible,
                urlText: $newSubscriptionInitialURL,
                pluginRevision: pluginSheetRevision,
                onNoDownloadSource: {
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 350_000_000)
                        subscriptionNotice = "Playlist Subscribed\n\nNo download source plug-in is currently enabled. Missing tracks will remain as unavailable placeholders until you enable a download source plug-in in Settings › Plug-ins."
                    }
                }
            )
        }
        .sheet(isPresented: $importRemotePlaylistsVisible) {
            ImportRemotePlaylistsSheet(
                isPresented: $importRemotePlaylistsVisible,
                pluginRevision: pluginSheetRevision,
                subscriptionRevision: subscriptionRevision,
                onNoDownloadSource: {
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 350_000_000)
                        subscriptionNotice = "Playlists Imported\n\nNo download source plug-in is currently enabled. Missing tracks will remain as unavailable placeholders until you enable a download source plug-in in Settings › Plug-ins."
                    }
                }
            )
        }
        .sheet(
            isPresented: Binding(
                get: { newRemotePlaylistTarget != nil },
                set: { if !$0 { newRemotePlaylistTarget = nil } }
            )
        ) {
            if let target = newRemotePlaylistTarget {
                NewRemotePlaylistSheet(
                    isPresented: Binding(
                        get: { newRemotePlaylistTarget != nil },
                        set: { if !$0 { newRemotePlaylistTarget = nil } }
                    ),
                    pluginID: target.pluginID,
                    serviceName: target.serviceName,
                    pluginRevision: pluginSheetRevision
                )
            }
        }
    }

    private var isDevicePage: Bool {
        if case .device = selection { return true }
        return false
    }

    private func validPage(_ item: SidebarItem) -> SidebarItem {
        if case .playlist(let id) = item, !(library?.playlists.contains { $0.id == id } ?? false) { return .music }
        if case .videoPlaylist(let id) = item, !(library?.videoPlaylists.contains { $0.id == id } ?? false) { return .videos }
        return item
    }

    private var railSelection: Binding<SidebarItem> {
        Binding(get: { navigationSelection.wrappedValue }, set: { item in
            guard let section = item.media, let key = section.persistentName else {
                navigationSelection.wrappedValue = item; return
            }
            let saved = sectionTabs[key].flatMap { SidebarItem(persistentName: $0) }
            let page = saved?.media == section ? validPage(saved!) : section
            navigationSelection.wrappedValue = page
        })
    }

    private var navigationSelection: Binding<SidebarItem> {
        Binding(get: { selection == .music && mode == .byArtist ? .artists : selection }, set: { item in
            selectedAlbumID = nil
            selectedSongIDs = []
            if item == .artists { selection = .music; mode = .byArtist }
            else { selection = item; if item == .music { mode = .allSongs } }
            if case .playlist(let id) = item {
                SubscriptionController.shared.onPlaylistSelected(id)
            }
            if settingsLoaded, let store = portableLibrary?.store, let mode {
                PortablePreferences.shared.stageMusicMode(mode.rawValue, store: store)
                if let tab = item.persistentName, let section = item.media?.persistentName {
                    sectionTabs[section] = tab
                    PortablePreferences.shared.stageLastTab(tab, store: store)
                    PortablePreferences.shared.stageSectionTab(tab, section: section, store: store)
                }
            }
        })
    }

    private func startPlayback(_ row: TrackRow, displayed: [TrackRow], library: Library) {
        PlayerArtwork.folder = library.artworkFolder
        PlaybackController.shared.start(row, in: displayed)
    }

    private func recordPlaybackSource(_ rows: [TrackRow]) {
        #if canImport(AppKitBackend)
        let origin = selection, originMode = mode, album = selectedAlbumID, artists = selectedArtists, show = selectedShowID
        PlayerDisplayController.shared.registerSource(rows.map(\.id)) { id in
            guard PlayerDisplayController.shared.canReveal(id) else { return }
            selection = origin; mode = originMode; selectedAlbumID = album; selectedArtists = artists
            if origin == .podcasts || origin == .recentPodcasts { selectedShowID = show; addingPodcast = false }
            search = ""; selectedSongIDs = [id]
            NativePlaybackReveal.request(id, kind: origin.isAlbumGrid ? .album : origin == .music && originMode == .byArtist ? .artist : .table)
        }
        #endif
    }

    /// Opt-in integration check: stage changes and close in the same event turn, before debounce.
    private func checkPreferencesOnExit() async {
        guard let loaded = portableLibrary,
              let device = await Task.detached(priority: .utility, operation: { PortableRoot.simulatedIPod(besides: []) }).value,
              device.sysInfo["pszSerialNumber"] == "TEST0000000" else { log("FAIL: exit check requires a simulated iPod"); return }
        mode = .byArtist
        PortablePreferences.shared.stageMusicMode(MusicMode.byArtist.rawValue, store: loaded.store)
        var options = DeviceOptions()
        options.syncPodcasts = false; options.useAlbumArtistForGrouping = false
        DevicePageCache.shared.stage(options, for: device)
        log("[check] preferences staged; closing before debounce")
        #if canImport(AppKitBackend)
            NSApplication.shared.terminate(nil)
        #else
            performWindowAction(.close)
        #endif
    }

    private func flushPreferences() async throws {
        try await session.flush()
        if settingsLoaded, let store = portableLibrary?.store, let mode {
            PortablePreferences.shared.stageMusicMode(mode.rawValue, store: store)
            if let tab = navigationSelection.wrappedValue.persistentName, let section = navigationSelection.wrappedValue.media?.persistentName {
                PortablePreferences.shared.stageLastTab(tab, store: store)
                PortablePreferences.shared.stageSectionTab(tab, section: section, store: store)
            }
        }
        try await PortablePreferences.shared.flush()
        try await PodcastController.shared.flush()
        await PhotoChoices.shared.flush()
        try await DevicePageCache.shared.flushAll()
    }

    /// Puts the Deezer photos on the artists: a new array, so the artist list reloads.
    private func applyArtistPhotos() {
        guard var current = library else { return }
        current.artists = current.artists.map { artist in
            var artist = artist
            artist.photo = ArtistPhotoController.shared.url(for: artist.id) ?? artist.cover
            return artist
        }
        library = current
    }

    private func ipod(named name: String) -> IPodDevice? {
        ipods.first { $0.id == name }
    }

    /// The sidebar's eject buttons and the iPod page's Eject. The volume watcher then removes the
    /// iPod from the sidebar.
    private func eject(_ item: SidebarItem) {
        guard case .device(let name) = item, let device = ipod(named: name) else { return }
        guard MusicTransfer.shared.beginEject(device) else {
            transferStatus = "Cancel or finish the transfer before ejecting."
            return
        }
        log("[app] ejecting \(name)")
        Task {
            defer { MusicTransfer.shared.endEject(device) }
            do {
                try await flushPreferences()
                try await Ejector.eject(device)
            } catch {
                ejectError = "Couldn't eject \(name): \(error.localizedDescription)"
            }
        }
    }

    /// `IPPM_BENCH=1`: switches sections like sidebar clicks and logs how long each update takes
    /// until the main thread is free again, then quits.
    private func benchSidebar() async {
        let rounds = Int(ProcessInfo.processInfo.environment["IPPM_BENCH"] ?? "") ?? 1
        let steps: [SidebarItem] = Array(repeating: [.podcasts, .music, .videos, .music, .audiobooks, .music, .photos, .music], count: rounds).flatMap { $0 }
        for item in steps {
            let start = Date()
            selection = item
            let idle = await mainThreadIdle()
            log("[bench] \(item.title): \(Int(idle.timeIntervalSince(start) * 1000)) ms")
        }
        mode = .byArtist
        selection = .music
        for artist in library?.artists.prefix(8) ?? [] {
            let start = Date()
            selectedArtists = [artist.id]
            let idle = await mainThreadIdle()
            log("[bench] artist \(artist.id): \(Int(idle.timeIntervalSince(start) * 1000)) ms")
        }
        if let ids = library?.artists.prefix(3).map(\.id), !ids.isEmpty {
            let start = Date()
            selectedArtists = Set(ids)
            let idle = await mainThreadIdle()
            log("[bench] 3 artists: \(Int(idle.timeIntervalSince(start) * 1000)) ms")
        }
        for playlist in library?.playlists.prefix(3) ?? [] {
            let start = Date()
            selection = .playlist(playlist.id)
            let idle = await mainThreadIdle()
            log("[bench] playlist \(playlist.name): \(Int(idle.timeIntervalSince(start) * 1000)) ms")
        }
        if ProcessInfo.processInfo.environment["IPPM_BENCH_DEVICE_SIDEBAR"] != nil,
           let device = ipods.first {
            selection = .device(device.id)
        } else {
            selection = .music
        }
        _ = await mainThreadIdle()
        // The chrome logs how many frames each slide drew ([bench] sidebar ...).
        for _ in 0..<4 {
            toggleSidebar()
            try? await Task.sleep(nanoseconds: UInt64((SidebarSlide.duration + 0.55) * 1e9))
        }
        exit(0)
    }

    /// Populated-view benchmark against the launching simulated iPod, without scanning music,
    /// fetching artwork or transferring media. Includes repeat-visit cache evidence.
    private func benchLoadedViews() async {
        guard let library, let loaded = portableLibrary else { log("FAIL: views benchmark needs a portable root"); exit(1) }
        mode = .allSongs
        if !ipods.isEmpty { await DevicePageCache.shared.prefetch(ipods) }
        let reads = DevicePageCache.shared.readCount
        let photoStart = Date()
        _ = await PhotoInventory.shared.load(loaded.store)
        log("[bench] photos inventory first load: \(Int(Date().timeIntervalSince(photoStart) * 1000)) ms")
        let scans = PhotoInventory.shared.scanCount
        var steps: [SidebarItem] = [.music, .podcasts, .audiobooks, .photos, .videos]
        steps += library.playlists.prefix(3).map { .playlist($0.id) }
        steps += ipods.map { .device($0.id) }
        for round in 1...3 {
            for item in steps {
                let start = Date()
                selection = item
                let idle = await mainThreadIdle()
                log("[bench] views round \(round) \(item.title): \(Int(idle.timeIntervalSince(start) * 1000)) ms")
            }
        }
        log("[bench] repeat navigation: additional device reads \(DevicePageCache.shared.readCount - reads), photo scans \(PhotoInventory.shared.scanCount - scans)")
        log("[bench] populated library: \(library.allRows.count) songs, \(PodcastController.shared.shows.count) podcast shows, \(audiobookRows.count) audiobook chapters")
        await benchSidebar()
    }

    private var deviceBenchmarkReady: Bool {
        ProcessInfo.processInfo.environment["IPPM_BENCH_DEVICES"] != nil && library != nil && !scanning && ipods.count >= 2
    }

    /// Development-only benchmark: real native page layout, after connection data is ready.
    private func benchDevicePages() async {
        let targets = ipods
        await DevicePageCache.shared.prefetch(targets)
        let reads = DevicePageCache.shared.readCount
        var times: [Double] = []
        for _ in 0..<10 {
            for device in targets {
                let start = Date()
                selection = .device(device.id)
                let idle = await mainThreadIdle()
                times.append(idle.timeIntervalSince(start) * 1000)
            }
        }
        let sorted = times.sorted()
        log("[bench] device pages: \(times.count) switches, median \(sorted[sorted.count / 2]) ms, max \(sorted.last ?? 0) ms; additional reads \(DevicePageCache.shared.readCount - reads)")
        exit(0)
    }

    @State var mode: MusicMode? = .allSongs
    @State var search = ""
    @State var selectedArtists: Set<String> = []
    @State var artistSelection = ArtistSelectionCache()

    #if canImport(AppKitBackend)
    private func createPlaylist() {
        guard !scanning, !playlistSaving, portableLibrary != nil else { return }
        let alert = NSAlert()
        alert.messageText = "New Playlist"
        alert.informativeText = "Choose a name for your playlist."
        let field = NSTextField(string: "")
        field.placeholderString = "Playlist name"
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        session.createPlaylist(base: name, uniqueName: false)
    }

    private func createVideoPlaylist() {
        guard !scanning, !playlistSaving, portableLibrary != nil else { return }
        let alert = NSAlert()
        alert.messageText = "New Video Playlist"
        alert.informativeText = "Choose a name for your video playlist."
        let field = NSTextField(string: "")
        field.placeholderString = "Video playlist name"
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        session.createVideoPlaylist(named: field.stringValue)
    }

    #endif

    private func addTracksToPlaylist(_ ids: [String], _ playlistID: String) {
        session.addTracks(ids, toPlaylist: playlistID)
    }

    private func removeTracksFromPlaylist(_ ids: [String], _ playlistID: String) {
        session.removeTracks(ids, fromPlaylist: playlistID)
    }

    private func pickCoverImage(forPlaylistID id: String) {
        #if canImport(AppKitBackend)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if #available(macOS 11.0, *) {
            panel.allowedContentTypes = [.image]
        } else {
            panel.allowedFileTypes = ["jpg", "jpeg", "png", "heic", "tiff", "webp", "bmp", "gif"]
        }
        panel.prompt = "Choose Cover"
        panel.message = "Choose an image (converted to 1:1 sRGB JPEG, 300–640 px, ≤ 256 KB)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        SubscriptionController.shared.setPlaylistArtwork(playlistID: id, imageURL: url)
        #endif
    }

    private func createNewPlaylist(isFolder: Bool) {
        let id = session.createPlaylist(base: isFolder ? "New Folder" : "New Playlist", isFolder: isFolder)
        selection = .playlist(id)
        editingPlaylistID = id
    }

    private func renamePlaylist(_ id: String, to name: String) {
        session.renamePlaylist(id, to: name)
    }

    private func sendPlaylist(_ id: String, toDevice device: String) {
        let trackIDs = session.trackIDs(forPlaylist: id)
        guard !trackIDs.isEmpty else { return }
        _ = MusicTransfer.shared.onDrop(trackIDs, device)
    }

    private func movePlaylist(_ id: String, toFolder folderID: String?, atIndex insertIndex: Int? = nil) {
        session.movePlaylist(id, toFolder: folderID, atIndex: insertIndex)
    }

    private func reorderPlaylistTracks(_ ids: [String], to targetRow: Int) {
        guard let playlistID = selectedPlaylistID else { return }
        session.reorderTracks(ids, to: targetRow, inPlaylist: playlistID)
    }

    private var selectedPlaylistID: String? {
        if case .playlist(let id) = selection { return id }
        return nil
    }

    private func addVideosToPlaylist(_ ids: [String], _ playlistID: String) {
        session.addVideos(ids, toPlaylist: playlistID)
    }

    private func removeVideosFromPlaylist(_ ids: [String], _ playlistID: String) {
        session.removeVideos(ids, fromPlaylist: playlistID)
    }

    private var selectedVideoPlaylistID: String? {
        if case .videoPlaylist(let id) = selection { return id }
        return nil
    }

    private func unsubscribePlaylist(_ id: String) {
        guard let playlist = library?.playlists.first(where: { $0.id == id }),
              playlist.subscriptionID != nil else { return }
        Task {
            await presentAlert(
                "Unsubscribe from “\(playlist.name)”?\n\nYou can keep this playlist and its downloaded music in your library, or remove the playlist and move its downloaded files to the Trash."
            ) {
                Button("Unsubscribe and Keep Music") {
                    SubscriptionController.shared.unsubscribeKeepMusic(playlistID: id)
                }
                Button("Unsubscribe and Remove Everything") {
                    SubscriptionController.shared.unsubscribeRemoveEverything(playlistID: id)
                    if selectedPlaylistID == id {
                        navigationSelection.wrappedValue = .music
                    }
                }
                Button("Cancel") {}
            }
        }
    }

    #if canImport(AppKitBackend)
    private func installSubscriptionPasteMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags == .command,
                  event.charactersIgnoringModifiers?.lowercased() == "v" else {
                return event
            }
            let responder = NSApp.keyWindow?.firstResponder
            if responder is NSText || responder is NSTextView {
                return event
            }
            guard let clip = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !clip.isEmpty,
                  let matched = SubscriptionController.shared.matchSource(for: clip),
                  matched.plugin != nil else {
                return event
            }
            Task { @MainActor in
                AppCommands.newSubscriptionWithURL?(matched.url.absoluteString)
            }
            return nil
        }
    }

    private func renamePlaylist(_ id: String) {
        guard let playlist = library?.playlists.first(where: { $0.id == id }) else { return }
        let alert = NSAlert(); alert.messageText = "Rename Playlist"
        let field = NSTextField(string: playlist.name); field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field; alert.addButton(withTitle: "Rename"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        renamePlaylist(id, to: field.stringValue)
    }

    private func deletePlaylist(_ id: String) {
        guard let playlist = library?.playlists.first(where: { $0.id == id }) else { return }
        if playlist.subscriptionID != nil {
            unsubscribePlaylist(id)
            return
        }
        let alert = NSAlert(); alert.messageText = "Delete Playlist?"
        alert.informativeText = "Delete “\(playlist.name)”? Your music files won't be deleted."
        alert.addButton(withTitle: "Delete"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        session.deletePlaylist(id)
        navigationSelection.wrappedValue = .music
    }

    private func renameVideoPlaylist(_ id: String) {
        guard let playlist = library?.videoPlaylists.first(where: { $0.id == id }) else { return }
        let alert = NSAlert(); alert.messageText = "Rename Video Playlist"
        let field = NSTextField(string: playlist.name); field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field; alert.addButton(withTitle: "Rename"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        session.renameVideoPlaylist(id, to: field.stringValue)
    }

    private func deleteVideoPlaylist(_ id: String) {
        guard let playlist = library?.videoPlaylists.first(where: { $0.id == id }) else { return }
        let alert = NSAlert(); alert.messageText = "Delete Video Playlist?"
        alert.informativeText = "Delete “\(playlist.name)”? Your video files won't be deleted."
        alert.addButton(withTitle: "Delete"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        session.deleteVideoPlaylist(id)
        navigationSelection.wrappedValue = .videos
    }

    #endif

    #if canImport(AppKitBackend)
    private func configureMetadataEditor() {
        MetadataEditorController.shared.configure(
            artworkFolder: portableLibrary?.store.artwork,
            trackLookup: { [self] id in
                portableLibrary?.cache.tracks.first { $0.id == id }
            },
            genreProvider: { [self] in
                guard let tracks = portableLibrary?.cache.tracks else { return [] }
                return Array(Set(tracks.compactMap { $0.genre?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
            },
            onSaveTracks: { [self] updatedTracks, customArtworkData, completion in
                saveTracksMetadata(updatedTracks, customArtworkData: customArtworkData, completion: completion)
            }
        )
    }

    private func saveTracksMetadata(
        _ updatedTracks: [LibraryTrack],
        customArtworkData: Data?,
        completion: @escaping @MainActor (Result<Void, Error>) -> Void
    ) {
        Task { @MainActor [self] in
            do {
                // Write audio file tags + artwork off the main thread via MediaKit.TagWriter.
                try await Task.detached(priority: .utility) {
                    for track in updatedTracks where track.source == .file && FileManager.default.fileExists(atPath: track.path) {
                        try await TagWriter.writeTags(for: track, customArtworkData: customArtworkData)
                    }
                }.value

                session.write("metadata", completion: completion) { cache, artworkFolder in
                    let savedArtworkKey = customArtworkData.flatMap {
                        MetadataArtworkSaver.saveCustomArtwork($0, into: artworkFolder)
                    }
                    let byID = Dictionary(uniqueKeysWithValues: updatedTracks.map { ($0.id, $0) })
                    for idx in cache.tracks.indices {
                        if var updated = byID[cache.tracks[idx].id] {
                            if let savedArtworkKey {
                                updated.artworkKey = savedArtworkKey
                            }
                            cache.tracks[idx] = updated
                        }
                    }
                }
            } catch {
                completion(.failure(error))
            }
        }
    }
    #endif

    private func reorderSidebarSection(_ section: String, items: [SidebarItem]) {
        if section == "Playlists" {
            session.reorderPlaylists(items.compactMap { item -> String? in
                if case .playlist(let id) = item { return id }
                return nil
            })
        } else if section == "Video Playlists" {
            session.reorderVideoPlaylists(items.compactMap { item -> String? in
                if case .videoPlaylist(let id) = item { return id }
                return nil
            })
        } else {
            sidebarOrder[section] = items.compactMap(\.persistentName)
            if let store = portableLibrary?.store {
                PortablePreferences.shared.stageSidebarOrder(sidebarOrder, store: store)
            }
        }
    }

    /// The edge of a list column: on the Mac a 1 pt black line that resizes the column when dragged.
    @ViewBuilder
    private func columnEdge(width: Double, onResize: @escaping (Double) -> Void) -> some View {
        #if canImport(AppKitBackend)
        ColumnResizeHandle(width: width, range: 160...480, onResize: onResize, onResizeEnd: onResize)
        #else
        Divider()
        #endif
    }

    /// The albums of the current cover-grid page: all of them, or one shelf's.
    private func gridAlbums(_ library: Library) -> [AlbumInfo] {
        selection.albumShelf.map { library.shelfAlbums[$0] ?? [] } ?? library.albums
    }

    /// The lists whose rows are songs: only those show the favorite icon.
    private var showsFavoriteIcon: Bool {
        switch selection {
        case .music, .favorites, .recentMusic, .albums, .soundtracks, .classical, .playlist: return true
        default: return false
        }
    }

    /// The icon changes at once (`ListAppearance`); the library is saved and reindexed behind it.
    /// The selection is left as it is.
    private func setFavorite(_ favorite: Bool, ids: [String]? = nil) {
        session.setFavorite(favorite, ids: ids ?? selectedSongIDs)
    }


    private func configureMusic() async {
        guard !scanning else { return }
        guard let folder = await chooseFile(title: "Choose Music Folder", defaultButtonLabel: "Use Folder",
            allowSelectingFiles: false, allowSelectingDirectories: true) else { return }
        await loadPortable(folder: folder, refresh: true)
    }

    /// The show picked in the list, or the first one.
    private var currentShow: PodcastShow? {
        let controller = PodcastController.shared
        return selectedShowID.flatMap { controller.show(id: $0) } ?? controller.shows.first
    }

    private func configureAudiobooks() async {
        guard let folder = await chooseFile(title: "Choose Audiobooks Folder", defaultButtonLabel: "Use Folder",
            allowSelectingFiles: false, allowSelectingDirectories: true) else { return }
        await loadPortable(audiobooksFolder: folder, refresh: true)
    }

    private func chooseAndAdd(_ kind: SourceKind, title: String) async {
        guard let folder = await chooseFile(title: title, defaultButtonLabel: "Add Folder",
            allowSelectingFiles: false, allowSelectingDirectories: true) else { return }
        await addSource(kind: kind.rawValue, folder: folder)
    }

    /// A folder picked in Settings: kept with this computer's sources, then the library is rescanned
    /// for the kinds that feed it (music, audiobooks) or the photo list refreshed.
    @discardableResult private func addSource(kind: String, folder: URL) async -> Bool {
        guard let kind = SourceKind(rawValue: kind) else { return false }
        var success = false
        do { try await session.exclusive {
            guard let store = portableLibrary?.store else { throw PortableLoading.LoadingError.noRoot }
            try await Task.detached(priority: .utility) { _ = try store.addSource(kind: kind, path: folder.path) }.value
            try await refreshAfterSourceChange(kind, store: store)
            success = true
        } } catch { transferStatus = "Couldn't add folder: \(error.localizedDescription)" }
        return success
    }

    @discardableResult private func removeSource(id: Foundation.UUID) async -> Bool {
        var success = false
        do { try await session.exclusive {
            guard let store = portableLibrary?.store else { throw PortableLoading.LoadingError.noRoot }
            let source = try await Task.detached(priority: .utility) { () throws -> KnownSource? in
                let source = try store.data.readChecked(KnownHosts.self, from: "known_hosts.json")?.hosts.first { $0.id == store.hostID }?.sources.first { $0.id == id }
                guard source != nil else { return nil }
                try store.removeSource(id: id)
                return source
            }.value
            if let source { try await refreshAfterSourceChange(source.kind, store: store, removedPath: source.path); success = true }
        } } catch { transferStatus = "Couldn't remove folder: \(error.localizedDescription)" }
        return success
    }

    private func refreshAfterSourceChange(_ kind: SourceKind, store: PortableLibraryStore, removedPath: String? = nil) async throws {
        switch kind {
        case .music, .audiobooks:
            try await loadPortableLocked(refresh: true, removedKind: removedPath == nil ? nil : kind, removedSourcePath: removedPath)
        case .photos: _ = await PhotoInventory.shared.load(store, refresh: true)
        case .games: _ = await GameCatalog.shared.load(store, refresh: true)
        default: break
        }
        SettingsController.shared.attach(store)
    }

    private func addPhotosFolder() async {
        guard let url = await chooseFile(title: "Choose a Folder of Pictures", defaultButtonLabel: "Add Folder",
                allowSelectingFiles: false, allowSelectingDirectories: true) else { return }
        await addSource(kind: SourceKind.photos.rawValue, folder: url)
    }

    private func loadPortable(folder: URL? = nil, audiobooksFolder: URL? = nil, refresh: Bool, removedKind: SourceKind? = nil) async {
        do { try await session.exclusive {
            try await loadPortableLocked(folder: folder, audiobooksFolder: audiobooksFolder, refresh: refresh, removedKind: removedKind)
        } } catch { transferStatus = "Couldn't load library: \(error.localizedDescription)" }
    }

    private func loadPortableLocked(folder: URL? = nil, audiobooksFolder: URL? = nil, refresh: Bool, removedKind: SourceKind? = nil, removedSourcePath: String? = nil) async throws {
        scanning = true
        defer { scanning = false }
        do {
            var configuredFolder = folder
            if configuredFolder == nil, let i = CommandLine.arguments.firstIndex(of: "--music-folder"), i + 1 < CommandLine.arguments.count {
                configuredFolder = URL(fileURLWithPath: CommandLine.arguments[i + 1])
            }
            let loaded = try await PortableLoading.load(folder: configuredFolder, audiobooksFolder: audiobooksFolder, refresh: refresh, removedKind: removedKind, removedSourcePath: removedSourcePath)
            let indexed = await Task.detached(priority: .userInitiated) { Library.portable(loaded.cache, source: loaded.store.hostFolder.url.path, artworkFolder: loaded.store.artwork) }.value
            session.install(loaded, indexed: indexed)
            SettingsController.shared.attach(loaded.store)
            #if canImport(AppKitBackend)
            configureMetadataEditor()
            #endif
            await ArtistPhotoController.shared.load(store: loaded.store)
            applyArtistPhotos()
            if ProcessInfo.processInfo.environment["IPPM_BENCH_VIEWS"] == nil {
                ArtistPhotoController.shared.fetchMissing(indexed.artists.map(\.id))
            }
            let books = await Task.detached(priority: .userInitiated) {
                AudiobookEntry.books(from: loaded.cache.tracks.filter(\.isAudiobook))
            }.value
            audiobooks = books
            audiobookRows = AudiobookEntry.rows(books)
            if !podcastsLoaded {
                podcastsLoaded = true
                await PhotoChoices.shared.load(store: loaded.store)
                PhotoChoices.shared.onError = { transferStatus = $0 }
                await PodcastController.shared.load(store: loaded.store)
            }
            if !subscriptionsLoaded {
                subscriptionsLoaded = true
                SubscriptionController.shared.attach(
                    store: loaded.store,
                    tracksProvider: { [self] in portableLibrary?.cache.tracks ?? [] },
                    playlistsProvider: { [self] in portableLibrary?.cache.playlists ?? [] },
                    libraryMutator: { [self] mutation in
                        session.write("subscription", apply: mutation)
                    },
                    onSelectPlaylist: { [self] pid in
                        navigationSelection.wrappedValue = .playlist(pid)
                    }
                )
            }
            ShareController.shared.attach(
                store: loaded.store,
                tracks: loaded.cache.tracks,
                connectedDevice: ipods.first
            )
            if !settingsLoaded {
                let settings = await Task.detached(priority: .utility) { loaded.store.data.read(PortableSettings.self, from: "settings.json") }.value
                gridArtworkSizes = settings?.gridArtworkSizes ?? [:]
                mode = MusicMode(rawValue: settings?.musicViewMode ?? "") ?? .allSongs
                sectionTabs = settings?.sectionTabs ?? [:]
                sidebarOrder = settings?.sidebarOrder ?? [:]
                if let name = settings?.lastTab, let item = SidebarItem(persistentName: name), let key = item.media?.persistentName, sectionTabs[key] == nil {
                    sectionTabs[key] = name
                    PortablePreferences.shared.stageSectionTab(name, section: key, store: loaded.store)
                }
                // The page shown last time (a deleted playlist falls back to Music).
                // A launch with an iPod opens on its page, not on the page shown last time.
                if !launchedOnDevice, let name = settings?.lastTab, let item = SidebarItem(persistentName: name) {
                    if case .playlist(let id) = item, !(library?.playlists.contains { $0.id == id } ?? false) {
                        selection = .music
                    } else if case .videoPlaylist(let id) = item, !(library?.videoPlaylists.contains { $0.id == id } ?? false) {
                        selection = .videos
                    } else if item == .artists {
                        selection = .music; mode = .byArtist
                    } else {
                        selection = item
                        if item == .music { mode = .allSongs }
                    }
                }
                let store = loaded.store
                let width = settings?.sidebarWidth ?? sidebarWidth
                let open = settings?.sidebarOpen ?? true
                sidebarOpen = open
                #if canImport(AppKitBackend)
                let actualOpen = MacChrome.shared.restoreSidebar(open: open, width: width) { width in
                    PortablePreferences.shared.stageSidebarWidth(width, store: store)
                }
                if actualOpen != open { PortablePreferences.shared.stageSidebarOpen(actualOpen, store: store) }
                #elseif canImport(GtkBackend)
                GtkChrome.shared.restoreSidebar(open: open, width: width,
                    onOpen: { PortablePreferences.shared.stageSidebarOpen($0, store: store) },
                    onWidth: { PortablePreferences.shared.stageSidebarWidth($0, store: store) })
                #elseif canImport(WinUIBackend)
                WinUIChrome.shared.restoreSidebar(open: open, width: width,
                    onOpen: { PortablePreferences.shared.stageSidebarOpen($0, store: store) },
                    onWidth: { PortablePreferences.shared.stageSidebarWidth($0, store: store) })
                #endif
                settingsLoaded = true
            }
            if !loaded.configured { transferStatus = "Choose your music folder with +." }
        } catch {
            if library == nil { library = Library.portable(PortableLibraryCache(), source: "") }
            transferStatus = error.localizedDescription
            throw error
        }
    }

    private var sidebarColumn: some View {
        VStack(spacing: 0) {
            #if canImport(AppKitBackend)
            Sidebar(devices: $devices, library: Binding(get: { session.library }, set: { session.library = $0 }), selection: navigationSelection, busyDevices: $busyDevices, sidebarOrder: sidebarOrder, editingPlaylistID: editingPlaylistID, subscriptionRevision: subscriptionRevision, onEject: eject,
                onAdd: { media in
                    switch media {
                    case .music: Task { await configureMusic() }
                    case .podcasts: addingPodcast.toggle()
                    case .audiobooks: Task { await configureAudiobooks() }
                    case .videos:
                        createVideoPlaylist()
                    default: break
                    }
                },
                onReorder: { section, items in
                    reorderSidebarSection(section, items: items)
                },
                onAddMusicFolder: { AppCommands.addMusicFolder?() },
                onCreatePlaylist: { isFolder in createNewPlaylist(isFolder: isFolder) },
                onNewSubscription: { AppCommands.newSubscription?() },
                onImportRemotePlaylists: { AppCommands.importRemotePlaylists?() },
                onNewSpotifyPlaylist: { AppCommands.newSpotifyPlaylist?() },
                onNewYouTubeMusicPlaylist: { AppCommands.newYouTubeMusicPlaylist?() },
                onRenamePlaylist: { id, name in renamePlaylist(id, to: name) },
                onDeletePlaylist: { id in deletePlaylist(id) },
                onRefreshSubscription: { id in SubscriptionController.shared.refresh(playlistID: id) },
                onStopSubscription: { id in SubscriptionController.shared.stop(playlistID: id) },
                onAddTracksToPlaylist: { ids, playlistID in addTracksToPlaylist(ids, playlistID) },
                onUnsubscribePlaylist: { id in unsubscribePlaylist(id) },
                onMovePlaylistToFolder: { id, folderID, index in movePlaylist(id, toFolder: folderID, atIndex: index) },
                onSendPlaylistToDevice: { id, device in sendPlaylist(id, toDevice: device) },
                onClearEditing: { editingPlaylistID = nil })
            #else
            Sidebar(devices: $devices, library: Binding(get: { session.library }, set: { session.library = $0 }), selection: navigationSelection, busyDevices: $busyDevices, onEject: eject,
                onAdd: { media in
                    switch media {
                    case .music: Task { await configureMusic() }
                    case .podcasts: addingPodcast.toggle()
                    case .audiobooks: Task { await configureAudiobooks() }
                    case .videos: break
                    default: break
                    }
                })
            #endif
        }
        #if canImport(AppKitBackend)
        // Dark glass in the main view's shape: below the top band, flush with the window's bottom.
        .background(SidebarGlass())
        .padding(.top, Int(titleBarHeight))
        .padding(.bottom, floatingPanelMargin)
        #else
        .background(GlassSurface())
        #endif
    }

    /// One layout for every section, so switching never tears the track table down: detaching
    /// an NSTableView from the window is what made each sidebar click cost ~60 ms. Sections
    /// without a table draw over it instead.
    @ViewBuilder
    private func detailView(tableRows cachedTableRows: [TrackRow]?) -> some View {
        if let library {
            // Opaque: on Windows the window itself is translucent, for the sidebar.
            VStack(spacing: 0) {
                // The iPod scroll view reaches behind the unified toolbar. Its native content inset
                // keeps the resting content below it, while rubber-band overscroll can fill it.
                if !isDevicePage {
                    header(library)
                } else {
                    #if canImport(AppKitBackend)
                    SearchAnchor(prompt: "Search", text: $search).frame(width: 1, height: 0)
                    #endif
                }
                // On macOS the content is a panel floating over the window's glass.
                VStack(spacing: 0) {
                #if canImport(AppKitBackend)
                PanelAnchor().frame(width: 0, height: 0)
                #endif
                HStack(spacing: 0) {
                    if selection == .music && mode == .byArtist && !library.artists.isEmpty {
                        ArtistList(artists: library.artists, tracksByArtist: library.rowsByArtist, selection: $selectedArtists)
                            .frame(width: Int(artistListWidth))
                        columnEdge(width: artistListWidth) { artistListWidth = $0 }
                    }
                    if selection == .podcasts && !PodcastController.shared.shows.isEmpty {
                        PodcastShowList(revision: podcastRevision, selectedID: Binding(get: { currentShow?.id }, set: { selectedShowID = $0 }))
                            .frame(width: Int(showListWidth))
                        columnEdge(width: showListWidth) { showListWidth = $0 }
                    }
                    VStack(spacing: 0) {
                    if selection.isAlbumGrid, let id = selectedAlbumID,
                       let album = gridAlbums(library).first(where: { $0.id == id }) {
                        MusicAlbumHeader(album: album, artworkFolder: library.artworkFolder,
                            onPlay: { if let first = album.rows.first(where: { $0.path != nil }) {
                                startPlayback(first, displayed: album.rows, library: library)
                            } })
                        Divider()
                    }
                    if selection == .podcasts, !addingPodcast, let show = currentShow {
                        PodcastShowHeader(show: show, revision: podcastRevision, devices: ipods.filter(\.supportsPodcasts).map(\.id),
                            isBusy: { busyDevices.contains($0) },
                            onSync: { name in
                                guard let device = ipod(named: name), let loaded = portableLibrary else { return }
                                MusicTransfer.shared.enqueuePodcasts(shows: PodcastController.shared.shows, device: device, loaded: loaded)
                            },
                            onUnsubscribe: { PodcastController.shared.unsubscribe(showID: show.id); selectedShowID = nil })
                        Divider()
                    }
                    if let subPlaylistID = selectedPlaylistID,
                       SubscriptionController.shared.subscription(forPlaylistID: subPlaylistID) != nil {
                        SubscriptionHeaderView(
                            playlistID: subPlaylistID,
                            revision: subscriptionRevision,
                            onChangeCover: { pickCoverImage(forPlaylistID: subPlaylistID) }
                        )
                        Divider()
                    }
                    // The cover only hides the table: over the artist list, it would swallow the
                    // clicks that pick an artist.
                    ZStack {
                        TrackTable(rows: cachedTableRows, isActive: trackTableActive(library),
                                   onPlay: { row, displayed in startPlayback(row, displayed: displayed, library: library) },
                                   artworkFolder: library.artworkFolder,
                                   playlists: selection.media == .videos ? library.videoPlaylists : library.playlists,
                                   onAddToPlaylist: selection.media == .videos ? addVideosToPlaylist : addTracksToPlaylist,
                                   currentPlaylistID: selection.media == .videos ? selectedVideoPlaylistID : selectedPlaylistID,
                                   onRemoveFromPlaylist: selection.media == .videos ? removeVideosFromPlaylist : removeTracksFromPlaylist,
                                   onReorderPlaylist: selection.media == .videos ? nil : { ids, row in reorderPlaylistTracks(ids, to: row) },
                                   onSelectionChange: { ids in
                                       guard selection == .favorites || selection == .music || selection == .recentMusic || selectedPlaylistID != nil else { return }
                                       if ids != selectedSongIDs { selectedSongIDs = ids }
                                   },
                                   viewKey: "\(selection)", sortScope: selection == .recentMusic ? "recent" : "",
                                   onToggleFavorite: showsFavoriteIcon ? { ids, favorite in setFavorite(favorite, ids: ids) } : nil,
                                   subscriptionPlaylistID: selectedPlaylistID.flatMap { SubscriptionController.shared.subscription(forPlaylistID: $0) != nil ? $0 : nil },
                                   subscriptionStates: selectedPlaylistID.map { SubscriptionController.shared.statusStates(forPlaylistID: $0) } ?? [:],
                                   subscriptionRevision: subscriptionRevision,
                                   onRetrySubscribedTrack: { playlistID, trackKey in
                                       SubscriptionController.shared.retryTrack(playlistID: playlistID, trackKey: trackKey)
                                   })
                        if selection.isAlbumGrid && selectedAlbumID == nil {
                            GridPage(section: .albums, items: gridAlbums(library), artworkFolder: library.artworkFolder, query: search,
                                     artworkSizes: gridArtworkSizes, store: portableLibrary?.store,
                                     action: .expand(onSelect: { selectedAlbumID = $0 },
                                                     onPlay: { row, rows in startPlayback(row, displayed: rows, library: library) }),
                                     onArtworkSizesChange: { gridArtworkSizes = $0 })
                                .background(WindowBackground())
                        }
                        ForEach(ipods, id: \.id) { device in
                            RetainedPage(active: selection == .device(device.id)) {
                            DeviceView(device: device, library: library, revision: contentRevision, isBusy: busyDevices.contains(device.id),
                                onEject: { eject(.device(device.id)) }, onRename: { name in
                                    ConnectedDeviceTitles.names[device.id] = name
                                    contentRevision += 1
                                })
                                #if canImport(AppKitBackend)
                                .background(DevicePageBackground())
                                #else
                                .background(WindowBackground())
                                #endif
                            }
                        }
                        if selection == .music && mode == .byArtist,
                           let group = artistSelection.group(library, selected: selectedArtists) {
                            ArtistDetail(artist: group.artist, albums: group.albums, artworkFolder: library.artworkFolder,
                                devices: ipods.map(\.id), isBusy: { busyDevices.contains($0) },
                                onSend: { ids, device in _ = MusicTransfer.shared.onDrop(ids, device) },
                                onChoosePhoto: {
                                    Task {
                                        guard let name = group.photoArtist else { return }
                                        guard let file = await chooseFile(title: "Choose a Photo of \(name)", defaultButtonLabel: "Use Photo",
                                            allowSelectingFiles: true, allowSelectingDirectories: false) else { return }
                                        if !(await ArtistPhotoController.shared.setCustomPhoto(file, for: name)) {
                                            transferStatus = "That picture couldn't be used."
                                        }
                                    }
                                }, query: search.trimmingCharacters(in: .whitespaces), allowsPhotoSelection: group.photoArtist != nil,
                                onPlay: { row, displayed in
                                    startPlayback(row, displayed: displayed, library: library)
                                }, onToggleFavorite: { ids, favorite in setFavorite(favorite, ids: ids) })
                                .background(WindowBackground())
                        }
                        if selection == .photos {
                            PhotosView(store: portableLibrary?.store, devices: ipods.filter(\.generation.supportsPhotos).map(\.id),
                                isBusy: { busyDevices.contains($0) },
                                onSync: { name in
                                    guard let device = ipod(named: name), let loaded = portableLibrary else { return }
                                    MusicTransfer.shared.enqueuePhotos(device: device, loaded: loaded, selection: PhotoChoices.shared.selection)
                                },
                                onAddFolder: { await addSource(kind: SourceKind.photos.rawValue, folder: $0) },
                                onRemoveFolder: { await removeSource(id: $0) })
                                .background(WindowBackground())
                        }
                        if selection == .games {
                            GamesView(store: portableLibrary?.store, query: search, artworkSizes: gridArtworkSizes,
                                onArtworkSizesChange: { gridArtworkSizes = $0 },
                                onAddFolder: { await addSource(kind: SourceKind.games.rawValue, folder: $0) },
                                onRemoveFolder: { await removeSource(id: $0) })
                                .background(WindowBackground())
                        }
                        if selection.media == .podcasts && addingPodcast {
                            PodcastAddPanel(onSubscribed: { selectedShowID = $0; addingPodcast = false }, onClose: { addingPodcast = false })
                                .background(WindowBackground())
                        }
                        if case .device = selection {
                            if case .device(let id) = selection, ipod(named: id) == nil, let cover = cover(library) {
                                cover.background(WindowBackground())
                            }
                        } else if let cover = cover(library) {
                            cover.background(WindowBackground())
                        }
                    }
                    }
                }
                #if canImport(AppKitBackend)
                // No status bar on the Mac: messages go to the player LCD, which also shows transfer
                // progress and its cancel button.
                Color.clear.frame(width: 0, height: 0)
                    .onChange(of: transferStatus) {
                        guard !ipods.contains(where: { MusicTransfer.shared.isRunning($0) }) else { return }
                        PlayerActivityController.shared.notice(transferStatus)
                    }
                #else
                HStack {
                    Text(scanning ? "Checking music folders…" : transferStatus).font(.system(size: 12))
                    Spacer()
                    if let device = ipods.first(where: { MusicTransfer.shared.isRunning($0) }) {
                        Button("Cancel Transfer") { MusicTransfer.shared.cancel(device) }
                    }
                }.padding(8)
                #endif
                }
                #if canImport(AppKitBackend)
                // The content makes room for the sidebar, which fills the panel's left side.
                .padding(.leading, !nativeSplitProbe && sidebarOpen && !isDevicePage ? sidebarPoints : 0)
                .background(isDevicePage ? AnyView(DevicePageBackground()) : AnyView(WindowBackground()))
                // The split view's container mask rounds the corners in native mode.
                .cornerRadius(nativeSplitProbe ? 0 : floatingPanelRadius)
                .padding(.trailing, floatingPanelMargin)
                .padding(.bottom, floatingPanelMargin)
                #endif
            }
            #if !canImport(AppKitBackend)
            .background(WindowBackground())
            #endif
        } else {
            WindowBackground()
        }
    }

    /// Always the same view type, with only its strings and controls changing: swapping the
    /// whole header made SwiftCrossUI re-add every sibling, the table included.
    private func header(_ library: Library) -> some View {
        let title: String
        let subtitle: String
        switch selection {
        case .music:
            title = mode == .byArtist ? "Artists" : "Songs"
            subtitle = mode == .byArtist ? "\(library.artists.count) artists" : songCount(library.allRows.count)
        case .favorites:
            title = "Favorites"
            subtitle = songCount(library.favoriteRows.count)
        case .recentMusic:
            title = "Recently Added"
            subtitle = songCount(library.recentRows.count)
        case .albums, .soundtracks, .classical:
            let albums = gridAlbums(library)
            let album = albums.first { $0.id == selectedAlbumID }
            title = album?.title ?? selection.title
            subtitle = album.map { "\($0.artist) · \(songCount($0.rows.count))" } ?? "\(albums.count) albums"
        case .playlist(let id):
            title = library.playlists.first { $0.id == id }?.name ?? "Playlist"
            if let sub = SubscriptionController.shared.subscription(forPlaylistID: id) {
                let owner = sub.owner?.trimmingCharacters(in: .whitespacesAndNewlines)
                let ownerPart = (owner?.isEmpty == false) ? "by \(owner!)" : nil
                subtitle = [ownerPart, songCount(sub.tracks.count)].compactMap { $0 }.joined(separator: " · ")
            } else {
                subtitle = songCount(library.rowsByPlaylist[id]?.count ?? 0)
            }
        case .videos:
            title = "Videos"
            subtitle = videoCount(library.videoRows.count)
        case .movies:
            title = "Movies"
            subtitle = videoCount(library.videoRowsByCategory[.movie]?.count ?? 0)
        case .tvShows:
            title = "TV Shows"
            subtitle = videoCount(library.videoRowsByCategory[.tvShow]?.count ?? 0)
        case .webVideos:
            title = "Web Videos"
            subtitle = videoCount(library.videoRowsByCategory[.webVideo]?.count ?? 0)
        case .musicVideos:
            title = "Music Videos"
            subtitle = videoCount(library.videoRowsByCategory[.musicVideo]?.count ?? 0)
        case .videoPlaylist(let id):
            title = library.videoPlaylists.first { $0.id == id }?.name ?? "Video Playlist"
            subtitle = videoCount(library.rowsByVideoPlaylist[id]?.count ?? 0)
        case .audiobooks:
            title = "Audiobooks"
            let count = audiobooks.count
            subtitle = count == 0 ? "" : "\(count) book\(count == 1 ? "" : "s")"
        case .podcasts:
            title = "Podcasts"
            let count = PodcastController.shared.shows.count
            subtitle = count == 0 ? "" : "\(count) podcast\(count == 1 ? "" : "s")"
        default:
            title = selection.title
            subtitle = ""
        }
        return DetailHeader(title: title, subtitle: subtitle) {
            if selection == .music || selection == .recentMusic || selection.isAlbumGrid || selection == .favorites {
                ToolbarButton(icon: "plus") { Task { await configureMusic() } }
                ToolbarButton(icon: "arrow.clockwise") { Task { await loadPortable(refresh: true) } }
                if selection.isAlbumGrid && selectedAlbumID != nil {
                    Button("All \(selection.title)") { selectedAlbumID = nil }.titleBarControl()
                }
            } else if selection.media == .podcasts {
                ToolbarButton(icon: "plus") { addingPodcast.toggle() }
                ToolbarButton(icon: "arrow.clockwise") { Task { await PodcastController.shared.refreshAll() } }
            } else if case .videoPlaylist(let id) = selection {
                #if canImport(AppKitBackend)
                Button("Rename…") { renameVideoPlaylist(id) }.titleBarControl()
                Button("Delete…") { deleteVideoPlaylist(id) }.titleBarControl()
                #endif
            } else if selection == .audiobooks {
                ToolbarButton(icon: "plus") { Task { await configureAudiobooks() } }
                ToolbarButton(icon: "arrow.clockwise") { Task { await loadPortable(refresh: true) } }
            } else if case .device(let id) = selection, let device = ipod(named: id) {
                ToolbarButton(icon: "arrow.clockwise") {
                    DevicePageCache.shared.invalidate(device)
                    contentRevision += 1
                }
            }
            SearchField(prompt: "Search", text: $search)
        }
    }

    /// Keeping native rows for reuse must never keep an obscured table interactive.
    private func trackTableActive(_ library: Library) -> Bool {
        switch selection {
        case .music: return mode != .byArtist && !library.allRows.isEmpty
        case .favorites: return !library.favoriteRows.isEmpty
        case .podcasts, .recentPodcasts: return !addingPodcast && !PodcastController.shared.shows.isEmpty
        case .audiobooks: return !audiobookRows.isEmpty
        case .recentMusic: return !library.recentRows.isEmpty
        case .albums, .soundtracks, .classical: return selectedAlbumID != nil
        case .playlist: return true
        case .videos, .movies, .tvShows, .webVideos, .musicVideos, .videoPlaylist: return true
        default: return false
        }
    }

    /// The rows the table shows; nil for sections without a table, which keeps the last rows so
    /// the table underneath doesn't reload for nothing.
    private func tableRows(_ library: Library) -> [TrackRow]? {
        switch selection {
        case .music where mode == .byArtist:
            return nil
        case .music:
            return filtered(library.allRows)
        case .favorites:
            return filtered(library.favoriteRows)
        case .recentMusic:
            // Newest first, as indexed; the table keeps that order until a header is clicked.
            return filtered(library.recentRows)
        case .albums, .soundtracks, .classical:
            return selectedAlbumID.flatMap { id in gridAlbums(library).first { $0.id == id } }.map { filtered($0.rows) }
        case .playlist(let id):
            if let playlist = library.playlists.first(where: { $0.id == id }) {
                if playlist.isFolder {
                    var rows = library.playlists
                        .filter { $0.parentID == id }
                        .flatMap { p in
                            p.subscriptionID != nil
                                ? SubscriptionController.shared.rows(for: p, library: library)
                                : (library.rowsByPlaylist[p.id] ?? [])
                        }
                    for i in rows.indices { rows[i].number = "\(i + 1)" }
                    return filtered(rows)
                }
                if playlist.subscriptionID != nil {
                    return filtered(SubscriptionController.shared.rows(for: playlist, library: library))
                }
            }
            return filtered(library.rowsByPlaylist[id] ?? [])
        case .videos:
            return filtered(library.videoRows)
        case .movies:
            return filtered(library.videoRowsByCategory[.movie] ?? [])
        case .tvShows:
            return filtered(library.videoRowsByCategory[.tvShow] ?? [])
        case .webVideos:
            return filtered(library.videoRowsByCategory[.webVideo] ?? [])
        case .musicVideos:
            return filtered(library.videoRowsByCategory[.musicVideo] ?? [])
        case .videoPlaylist(let id):
            return filtered(library.rowsByVideoPlaylist[id] ?? [])
        case .podcasts where addingPodcast, .recentPodcasts where addingPodcast:
            return nil
        case .podcasts:
            return filtered(podcastRows.rows(for: currentShow, revision: PodcastController.shared.contentRevision))
        case .recentPodcasts:
            return filtered(podcastRows.recentRows(shows: PodcastController.shared.shows, revision: PodcastController.shared.contentRevision))
        case .audiobooks:
            return filtered(audiobookRows)
        default:
            return nil
        }
    }

    /// What hides the table: empty states and the sections the prototype doesn't have yet.
    private func cover(_ library: Library) -> EmptyState? {
        switch selection {
        case .music where library.allRows.isEmpty:
            return EmptyState(icon: "music.note", title: "No Music Yet",
                              message: "Add MP3, AAC, Apple Lossless, WAV or AIFF files, or import your Music app library. FLAC and other formats are converted to AAC when syncing.")
        case .music where mode == .byArtist && artistSelection.group(library, selected: selectedArtists) == nil:
            return EmptyState(icon: "music.mic", title: "Select an Artist",
                              message: "Pick an artist in the list to see their songs.")
        case .podcasts where PodcastController.shared.shows.isEmpty && !addingPodcast,
             .recentPodcasts where PodcastController.shared.shows.isEmpty && !addingPodcast:
            return EmptyState(icon: "antenna.radiowaves.left.and.right", title: "No Podcasts Yet",
                              message: "Subscribe by searching Apple Podcasts or pasting a feed, OHdio or YouTube link with +. Episodes are downloaded here and copied to the iPod's Podcasts menu when you drag them onto it.")
        case .audiobooks where audiobookRows.isEmpty:
            return EmptyState(icon: "book", title: scanning ? "Scanning…" : "No Audiobooks Yet",
                              message: "Choose a folder with + . A subfolder with several files becomes a book with chapters, merged into a single file with chapter marks on the iPod; a single file becomes a one-part book. Drag chapters onto an iPod in the sidebar.")
        case .videos where library.videoRows.isEmpty,
             .movies where library.videoRowsByCategory[.movie, default: []].isEmpty,
             .tvShows where library.videoRowsByCategory[.tvShow, default: []].isEmpty,
             .webVideos where library.videoRowsByCategory[.webVideo, default: []].isEmpty,
             .musicVideos where library.videoRowsByCategory[.musicVideo, default: []].isEmpty:
            return EmptyState(icon: selection.icon, title: "No \(selection.title) Yet",
                              message: "Videos added to the library will appear here according to their category.")
        case .videoPlaylist(let id) where library.rowsByVideoPlaylist[id, default: []].isEmpty:
            return EmptyState(icon: "film.stack", title: "Empty Video Playlist",
                              message: "Add videos from Movies, TV Shows, Web Videos or Music Videos.")
        case .playlist(let id) where library.playlists.first(where: { $0.id == id })?.isFolder == true && !library.playlists.contains(where: { $0.parentID == id }):
            return EmptyState(icon: "folder", title: "Empty Playlist Folder",
                              message: "Drag playlists onto this folder in the sidebar to organize them.")
        case .playlist(let id) where library.playlists.first(where: { $0.id == id })?.isFolder != true && SubscriptionController.shared.subscription(forPlaylistID: id) == nil && library.rowsByPlaylist[id, default: []].isEmpty:
            return EmptyState(icon: "music.note.list", title: "Empty Playlist",
                              message: "Drag songs onto this playlist or use Add to Playlist to add music.")
        case .playlist(let id) where SubscriptionController.shared.subscription(forPlaylistID: id)?.tracks.isEmpty == true:
            return EmptyState(icon: "music.note.list", title: "Empty Subscribed Playlist",
                              message: "This subscribed playlist currently has no tracks.")
        case .favorites where library.favoriteRows.isEmpty:
            return EmptyState(icon: ListAppearance.shared.favoriteIcon.rawValue, title: "No Favorites Yet",
                              message: "Click the \(ListAppearance.shared.favoriteIcon.rawValue) next to a song to keep it here.")
        case .recentMusic where library.recentRows.isEmpty:
            return EmptyState(icon: "clock", title: "Nothing Added Recently",
                              message: "Songs you add to your library will appear here, newest first.")
        case .albums where library.albums.isEmpty:
            return EmptyState(icon: "square.stack", title: "No Albums Yet",
                              message: "Music you add to your library will appear here.")
        case .soundtracks where gridAlbums(library).isEmpty:
            return EmptyState(icon: "film.music", title: "No Soundtracks",
                              message: "Albums whose genre is Soundtrack appear here.")
        case .classical where gridAlbums(library).isEmpty:
            return EmptyState(icon: "music.quarternote.3", title: "No Classical Music",
                              message: "Albums whose genre is Classical appear here.")
        case .recentMusic, .albums, .soundtracks, .classical, .favorites:
            return nil
        case .music, .playlist, .podcasts, .recentPodcasts, .audiobooks, .photos, .games, .videos, .movies, .tvShows, .webVideos, .musicVideos, .videoPlaylist:
            return nil
        case .device:
            // The iPod is gone (its page is drawn before the cover).
            return EmptyState(icon: "ipod", title: "No iPod", message: "This iPod is no longer connected.")
        default:
            return EmptyState(icon: selection.icon, title: "Coming Soon",
                              message: "\(selection.title) isn't available yet.")
        }
    }

    @State private var searchCache = SearchCache()

    private func filtered(_ rows: [TrackRow]) -> [TrackRow] {
        searchCache.filter(rows, query: search.trimmingCharacters(in: .whitespaces))
    }
}

/// Plain substring search over title, artist and album, recomputed only when the rows or the
/// query change: the same array comes back otherwise, so the table doesn't reload on unrelated
/// redraws (sidebar slide, color scheme).
@MainActor
final class SearchCache: SwiftCrossUI.ObservableObject {
    private var source: [TrackRow] = []
    private var query = ""
    private var foldedQuery = ""
    private var result: [TrackRow] = []
    private var resultIndices: [Int] = []
    private var keysSource: [TrackRow] = []
    private var foldedKeys: [String] = []
    private var prewarmTask: Task<Void, Never>?
    private var prewarmToken = 0

    func filter(_ rows: [TrackRow], query: String) -> [TrackRow] {
        let sameRows = rows.sameStorage(as: source)
        if !sameRows {
            source = rows
            self.query = ""
            self.foldedQuery = ""
            self.result = []
            self.resultIndices = []
            if !rows.sameStorage(as: keysSource) {
                foldedKeys = []
                keysSource = []
                schedulePrewarm(for: rows)
            }
        }
        guard !query.isEmpty else {
            self.query = ""
            self.foldedQuery = ""
            self.result = []
            self.resultIndices = []
            return rows
        }
        if sameRows && query == self.query { return result }

        let needle = FastSearch.fold(query)
        if !rows.sameStorage(as: keysSource) {
            foldedKeys = rows.map(FastSearch.rowKey)
            keysSource = rows
        }

        let narrowing = sameRows && !self.foldedQuery.isEmpty && needle.hasPrefix(self.foldedQuery)
        var nextIndices: [Int] = []
        var nextRows: [TrackRow] = []
        if narrowing {
            nextIndices.reserveCapacity(resultIndices.count)
            nextRows.reserveCapacity(resultIndices.count)
            for i in resultIndices where FastSearch.containsUTF8(foldedKeys[i], needle: needle) {
                nextIndices.append(i)
                nextRows.append(rows[i])
            }
        } else {
            for i in rows.indices where FastSearch.containsUTF8(foldedKeys[i], needle: needle) {
                nextIndices.append(i)
                nextRows.append(rows[i])
            }
        }
        self.query = query
        self.foldedQuery = needle
        self.resultIndices = nextIndices
        self.result = nextRows
        return nextRows
    }

    private func schedulePrewarm(for rows: [TrackRow]) {
        guard rows.count >= 256 else { return }
        prewarmToken &+= 1
        let token = prewarmToken
        prewarmTask?.cancel()
        prewarmTask = Task.detached(priority: .utility) { [weak self] in
            let keys = rows.map(FastSearch.rowKey)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled, self.prewarmToken == token else { return }
                if self.source.sameStorage(as: rows) && self.foldedKeys.isEmpty {
                    self.foldedKeys = keys
                    self.keysSource = rows
                }
            }
        }
    }
}

/// The native segmented control on macOS. GTK and WinUI have none in SwiftCrossUI, so they get
/// one drawn here, which also looks the same on both.
struct SegmentedControl<Value: Equatable & CustomStringConvertible>: View {
    var options: [Value]
    @Binding var selection: Value?

    var body: some View {
        #if canImport(AppKitBackend)
            Picker(of: options, selection: $selection).pickerStyle(.segmented)
        #else
            HStack(spacing: 0) {
                ForEach(options.indices, id: \.self) { i in
                    Text(options[i].description)
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(selection == options[i] ? sidebarSelection : Color(white: 0.5, opacity: 0.001))
                        .cornerRadius(5)
                        .onTapGesture { selection = options[i] }
                }
            }
            .padding(2)
            .background(Color(white: 0.5, opacity: 0.12))
            .cornerRadius(7)
            .titleBarControl()
        #endif
    }
}

enum MusicMode: String, CaseIterable, CustomStringConvertible {
    case byArtist = "By Artist"
    case allSongs = "All Songs"

    var description: String { rawValue }
}

/// The toolbar row at the top of the detail column, in the transparent title bar on macOS.
struct DetailHeader<Controls: View>: View {
    var title: String
    var subtitle: String
    var controls: Controls

    init(title: String, subtitle: String, @ViewBuilder controls: () -> Controls) {
        self.title = title
        self.subtitle = subtitle
        self.controls = controls()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                // Room for the traffic lights and the toggle where the sidebar no longer covers
                // them: the title follows the sidebar's edge as it slides.
                TitleClearance()
                HStack(spacing: 12) {
                    #if !canImport(AppKitBackend)
                    VStack(alignment: .leading, spacing: 1) {
                        // One line each, truncated when the window is narrow, as in a Mac toolbar.
                        Text(title).font(.system(size: subtitle.isEmpty ? 15 : 13, weight: .bold)).lineLimit(1)
                        if !subtitle.isEmpty {
                            Text(subtitle).font(.system(size: 11)).foregroundColor(.gray).lineLimit(1)
                        }
                    }
                    #endif
                    Spacer()
                    controls
                }
            }
            .padding(.horizontal, 10)
            .frame(height: titleBarHeight)
            #if !canImport(AppKitBackend)
            Divider()
            #endif
        }
    }
}

extension DetailHeader where Controls == EmptyView {
    init(title: String, subtitle: String) {
        self.title = title
        self.subtitle = subtitle
        controls = EmptyView()
    }
}

struct ToolbarButton: View {
    var icon: String
    var action: @MainActor @Sendable () -> Void = {}

    var body: some View {
        #if canImport(AppKitBackend)
        // The Mac toolbar keeps only the sidebar toggle and the search: no loose buttons.
        EmptyView()
        #else
        Button(action: action) {
            Symbol(name: icon, size: 20, pointSize: 15, tint: .primary)
        }
        .buttonStyle(.borderless)
        .titleBarControl()
        #endif
    }
}

struct SearchField: View {
    var prompt: String
    @Binding var text: String

    var body: some View {
        #if canImport(AppKitBackend)
        SearchAnchor(prompt: prompt, text: $text)
            .frame(width: 240)
        #else
        HStack(spacing: 4) {
            Symbol(name: "magnifyingglass", size: 16, pointSize: 12, tint: .secondary)
            TextField(prompt, text: $text)
        }
        .frame(width: 240)
        .titleBarControl()
        #endif
    }
}

struct EmptyState: View {
    var icon: String
    var title: String
    var message: String

    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            Symbol(name: icon, size: 56, pointSize: 44, tint: .secondary)
            Text(title).font(.system(size: 17, weight: .bold))
            Text(message)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
                .padding(.bottom, 66)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

/// Returns when the main thread had drained the work queued before it (the view update). On GTK
/// it waits for GLib's loop itself to go idle: dispatch's main queue is only drained by GLib now
/// and then, which would add a fixed delay unrelated to the app. On WinUI the time is taken in the
/// XAML dispatcher, at low priority, for the same reason: resuming the task adds its own delay.
@MainActor
func mainThreadIdle() async -> Date {
    #if canImport(GtkBackend)
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let box = Unmanaged.passRetained(ContinuationBox(c)).toOpaque()
            g_idle_add_full(300, { data in  // G_PRIORITY_DEFAULT_IDLE + 100: after layout and drawing
                Unmanaged<ContinuationBox>.fromOpaque(data!).takeRetainedValue().continuation.resume()
                return 0
            }, box, nil)
        }
        return Date()
    #elseif canImport(WinUIBackend)
        // Twice: the first pass may run before XAML's layout of the update.
        let queue = WinAppSDK.DispatcherQueue.getForCurrentThread()!
        return await withCheckedContinuation { (c: CheckedContinuation<Date, Never>) in
            _ = try? queue.tryEnqueue(.low) {
                _ = try? queue.tryEnqueue(.low) { c.resume(returning: Date()) }
            }
        }
    #else
        for _ in 0..<3 {
            await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
        }
        return Date()
    #endif
}

#if canImport(GtkBackend)
    import CGtk

    private final class ContinuationBox {
        let continuation: CheckedContinuation<Void, Never>
        init(_ c: CheckedContinuation<Void, Never>) { continuation = c }
    }
#endif

func songCount(_ n: Int) -> String {
    n == 1 ? "1 song" : "\(n) songs"
}

func videoCount(_ n: Int) -> String {
    n == 1 ? "1 video" : "\(n) videos"
}

/// Optional diagnostic output; the default Windows log also stays on the portable volume.
private let logFile: String? = {
    if let path = ProcessInfo.processInfo.environment["IPPM_LOG"] { return path }
    #if os(Windows)
        return PortableRoot.url?.appendingPathComponent("iPod Pro Max/Persistent Data/Logs/app.log").path
    #else
        return nil
    #endif
}()
private let logQueue = DispatchQueue(label: "ipodpromax.log", qos: .utility)

/// stderr is unbuffered, so timings show up even when stdout is piped. `IPPM_LOG=<file>` also
/// appends to a file, for apps started from a desktop shell (no console to read).
func flushLog() { logQueue.sync {} }
func audioTrace(_ message: String) {
    guard ProcessInfo.processInfo.environment["IPPM_CHECK_AUDIO"] != nil else { return }
    log("[audio check] " + message); flushLog()
}

func log(_ message: String) {
    if let path = logFile {
        logQueue.async {
            let url = URL(fileURLWithPath: path)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber, size.intValue > 1_000_000 {
                try? FileManager.default.removeItem(at: url)
            }
            if let file = fopen(path, "a") { fputs(message + "\n", file); fclose(file) }
        }
    }
    // A Windows app started from Explorer has no console: writing to the missing handle traps in
    // Foundation (the launch crash) or stalls in the C runtime, so only write when there is one.
    #if os(Windows)
        guard GetFileType(GetStdHandle(STD_ERROR_HANDLE)) != DWORD(FILE_TYPE_UNKNOWN) else { return }
    #endif
    fputs(message + "\n", stderr)
}

struct AudioCheckView: View {
    var path: String
    var body: some View {
        Text("Checking audio…").task {
            let passed = await checkPlatformAudio(path)
            flushLog()
            exit(passed ? 0 : 1)
        }
    }
}

@main
struct IPodProMaxApp: App {
    /// Declared rather than looked up: SwiftCrossUI otherwise scans the binary for Swift Bundler's
    /// metadata at launch (byte by byte), and GTK would run as `com.example.SwiftCrossUIApp`.
    static var metadata: AppMetadata? {
        AppMetadata(identifier: appIdentifier, version: "0.1", additionalMetadata: [:])
    }

    init() {
        #if canImport(AppKitBackend)
        // First thing: the launch panel is up before anything loads.
        MainActor.assumeIsolated { MacChrome.shared.beginLaunch(); AppMenuMac.shared.install() }
        #endif
    }

    private var initialWindowWidth: Int {
        #if canImport(AppKitBackend)
        return 1240
        #else
        return 1100
        #endif
    }

    var body: some Scene {
        WindowGroup("iPod Pro Max") {
            if let path = ProcessInfo.processInfo.environment["IPPM_CHECK_AUDIO"] {
                AudioCheckView(path: path)
            } else {
                ContentView()
            }
        }
        .defaultSize(width: initialWindowWidth, height: 700)
        .commands {
            // Merged into the system File menu by the backend.
            CommandMenu("File") {
                #if !canImport(AppKitBackend)
                // macOS has "Settings… ⌘," in the application menu (AppMenuMac) and "New Subscription… ⌥⌘N" in File menu.
                Button("Settings…") { AppCommands.openSettings?() }
                Button("New Subscription…") { AppCommands.newSubscription?() }
                #endif
                Menu("Add to Library") {
                    Button("Local Music Folder…") { AppCommands.addMusicFolder?() }
                    Button("Local Audiobooks Folder…") { AppCommands.addAudiobooksFolder?() }
                    Menu("Local Videos Folder") {
                        // Video folders can't be imported yet.
                        Button("Movies…") {}.disabled(true)
                        Button("TV Shows…") {}.disabled(true)
                        Button("Music Videos…") {}.disabled(true)
                        Button("Web Videos…") {}.disabled(true)
                    }
                    Button("Local Photos Folder…") { AppCommands.addPhotosFolder?() }
                }
            }
        }

        // Opened on demand (⌘, / Settings…), never at launch.
        Window("Settings", id: "settings") {
            SettingsView()
        }
        .defaultSize(width: 520, height: 420)
        .windowResizability(.contentSize)

        Window("Plug-in Log", id: "plugin-log") {
            PluginLogWindowView()
        }
        .defaultSize(width: 680, height: 420)
    }
}
