import DefaultBackend
import DeviceKit
import Foundation
import SwiftCrossUI
import iPodKit
#if canImport(AppKitBackend)
    import AppKit
#endif
#if os(Windows)
    import WinSDK
#endif
#if canImport(WinUIBackend)
    import WinAppSDK
#endif

struct ContentView: View {
    @Environment(\.chooseFile) private var chooseFile
    @State var portableLibrary: LoadedPortableLibrary?
    @State var busyDevices: Set<String> = []
    @State var transferStatus = ""
    @State var scanning = false
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
    @State var library: Library?
    @State var ipods: [IPodDevice] = []
    /// The iPods' names, for the sidebar.
    @State var devices: [String] = []
    @State var ejectError: String?
    @State var selection: SidebarItem = .music
    /// Followed from the system on Linux (GTK doesn't tell SwiftCrossUI); AppKit handles macOS.
    @State var colorScheme: ColorScheme = .light

    var body: some View {
        ZStack(alignment: .topLeading) {
            NavigationSplitView {
                Sidebar(devices: $devices, library: $library, selection: $selection, busyDevices: $busyDevices, onEject: eject)
            } detail: {
                detail
            }
            if drawsWindowControls {
                WindowControls()
            }
        }
        .windowChrome(colorScheme: $colorScheme)
        .followingSystemColorScheme(colorScheme)
        .task {
            if ProcessInfo.processInfo.environment["IPPM_CHECK_INTERACTIONS"] != nil {
                #if canImport(AppKitBackend)
                await checkNativeMusicInteractions()
                exit(0)
                #endif
            }
            ApplicationLifecycle.shared.onError = { transferStatus = $0 }
            ApplicationLifecycle.shared.savePreferences = { try await flushPreferences() }
            ApplicationLifecycle.shared.beforeExit = {
                MusicTransfer.shared.acceptingDrops = false
                defer { MusicTransfer.shared.acceptingDrops = true }
                try await flushPreferences()
                await MusicTransfer.shared.finishActiveTransfers()
                try await flushPreferences()
            }
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
            if ProcessInfo.processInfo.environment["IPPM_BENCH_VIEWS"] != nil {
                await loadPortable(refresh: false)
                await benchLoadedViews()
            } else if ProcessInfo.processInfo.environment["IPPM_BENCH"] != nil {
                library = await Library.load(arguments: CommandLine.arguments)
                await benchSidebar()
            } else {
                await loadPortable(refresh: false)
                if ProcessInfo.processInfo.environment["IPPM_CHECK_PREF_EXIT"] != nil {
                    await checkPreferencesOnExit()
                    return
                }
                await loadPortable(refresh: true)
            }
        }
        .task {
            await watchIPods { found in
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
                if let added {
                    selection = .device(added.id)
                } else if case .device(let name) = selection, !names.contains(name) {
                    selection = .music
                }
            }
        }
        .task(id: deviceBenchmarkReady) {
            guard deviceBenchmarkReady, !didBenchDevices else { return }
            didBenchDevices = true
            await benchDevicePages()
        }
        .alert($ejectError) {}
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
        if settingsLoaded, let store = portableLibrary?.store, let mode {
            PortablePreferences.shared.stageMusicMode(mode.rawValue, store: store)
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

    private func loadPortable(folder: URL? = nil, audiobooksFolder: URL? = nil, refresh: Bool) async {
        guard !scanning else { return }
        scanning = true
        defer { scanning = false }
        do {
            var configuredFolder = folder
            if configuredFolder == nil, let i = CommandLine.arguments.firstIndex(of: "--music-folder"), i + 1 < CommandLine.arguments.count {
                configuredFolder = URL(fileURLWithPath: CommandLine.arguments[i + 1])
            }
            let loaded = try await PortableLoading.load(folder: configuredFolder, audiobooksFolder: audiobooksFolder, refresh: refresh)
            let indexed = await Task.detached(priority: .userInitiated) { Library.portable(loaded.cache, source: loaded.store.hostFolder.url.path, artworkFolder: loaded.store.artwork) }.value
            portableLibrary = loaded; library = indexed
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
            if !settingsLoaded {
                let settings = await Task.detached(priority: .utility) { loaded.store.data.read(PortableSettings.self, from: "settings.json") }.value
                mode = MusicMode(rawValue: settings?.musicViewMode ?? "") ?? .allSongs
                settingsLoaded = true
            }
            if !loaded.configured { transferStatus = "Choose your music folder with +." }
        } catch {
            if library == nil { library = Library.portable(PortableLibraryCache(), source: "") }
            transferStatus = error.localizedDescription
        }
    }

    /// One layout for every section, so switching never tears the track table down: detaching
    /// an NSTableView from the window is what made each sidebar click cost ~60 ms. Sections
    /// without a table draw over it instead.
    @ViewBuilder
    private var detail: some View {
        if let library {
            // Opaque: on Windows the window itself is translucent, for the sidebar.
            VStack(spacing: 0) {
                header(library)
                HStack(spacing: 0) {
                    if selection == .music && mode == .byArtist {
                        ArtistList(artists: library.artists, tracksByArtist: library.rowsByArtist, selection: $selectedArtists)
                            .frame(width: 250)
                        Divider()
                    }
                    if selection == .podcasts && !PodcastController.shared.shows.isEmpty {
                        PodcastShowList(revision: podcastRevision, selectedID: Binding(get: { currentShow?.id }, set: { selectedShowID = $0 }))
                            .frame(width: 260)
                        Divider()
                    }
                    VStack(spacing: 0) {
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
                    // The cover only hides the table: over the artist list, it would swallow the
                    // clicks that pick an artist.
                    ZStack {
                        TrackTable(rows: tableRows(library), isActive: trackTableActive(library))
                        ForEach(ipods, id: \.id) { device in
                            RetainedPage(active: selection == .device(device.id)) {
                            DeviceView(device: device, library: library, revision: contentRevision, isBusy: busyDevices.contains(device.id),
                                onEject: { eject(.device(device.id)) }, onRename: { name in
                                    ConnectedDeviceTitles.names[device.id] = name
                                    contentRevision += 1
                                })
                                .background(WindowBackground())
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
                                }, query: search.trimmingCharacters(in: .whitespaces), allowsPhotoSelection: group.photoArtist != nil)
                                .background(WindowBackground())
                        }
                        if selection == .photos {
                            PhotosView(store: portableLibrary?.store, devices: ipods.filter(\.generation.supportsPhotos).map(\.id),
                                isBusy: { busyDevices.contains($0) },
                                onSync: { name in
                                    guard let device = ipod(named: name), let loaded = portableLibrary else { return }
                                    MusicTransfer.shared.enqueuePhotos(device: device, loaded: loaded, selection: PhotoChoices.shared.selection)
                                })
                                .background(WindowBackground())
                        }
                        if selection == .podcasts && addingPodcast {
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
                HStack {
                    Text(scanning ? "Checking music folders…" : transferStatus).font(.system(size: 12))
                    Spacer()
                    if let device = ipods.first(where: { MusicTransfer.shared.isRunning($0) }) {
                        Button("Cancel Transfer") { MusicTransfer.shared.cancel(device) }
                    }
                }.padding(8)
            }
            .background(WindowBackground())
        } else {
            Text("Loading…").foregroundColor(.gray)
        }
    }

    /// Always the same view type, with only its strings and controls changing: swapping the
    /// whole header made SwiftCrossUI re-add every sibling, the table included.
    private func header(_ library: Library) -> some View {
        let title: String
        let subtitle: String
        switch selection {
        case .music:
            title = "Music"
            subtitle = songCount(library.allRows.count)
        case .playlist(let id):
            title = library.playlists.first { $0.id == id }?.name ?? "Playlist"
            subtitle = songCount(library.rowsByPlaylist[id]?.count ?? 0)
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
            if selection == .music {
                SegmentedControl(options: MusicMode.allCases, selection: Binding(get: { mode }, set: { value in
                    mode = value
                    if settingsLoaded, let store = portableLibrary?.store, let value {
                        PortablePreferences.shared.stageMusicMode(value.rawValue, store: store)
                    }
                }))
                ToolbarButton(icon: "plus") { Task { await configureMusic() } }
                ToolbarButton(icon: "arrow.clockwise") { Task { await loadPortable(refresh: true) } }
                SearchField(prompt: "Search songs", text: $search)
            } else if selection == .podcasts {
                ToolbarButton(icon: "plus") { addingPodcast.toggle() }
                ToolbarButton(icon: "arrow.clockwise") { Task { await PodcastController.shared.refreshAll() } }
                SearchField(prompt: "Search episodes", text: $search)
            } else if selection == .audiobooks {
                ToolbarButton(icon: "plus") { Task { await configureAudiobooks() } }
                ToolbarButton(icon: "arrow.clockwise") { Task { await loadPortable(refresh: true) } }
                SearchField(prompt: "Search audiobooks", text: $search)
            } else if case .device(let id) = selection, let device = ipod(named: id) {
                ToolbarButton(icon: "arrow.clockwise") {
                    DevicePageCache.shared.invalidate(device)
                    contentRevision += 1
                }
            }
        }
    }

    /// Keeping native rows for reuse must never keep an obscured table interactive.
    private func trackTableActive(_ library: Library) -> Bool {
        switch selection {
        case .music: return mode != .byArtist && !library.allRows.isEmpty
        case .podcasts: return !addingPodcast && !PodcastController.shared.shows.isEmpty
        case .audiobooks: return !audiobookRows.isEmpty
        case .playlist: return true
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
        case .playlist(let id):
            return library.rowsByPlaylist[id] ?? []
        case .podcasts where addingPodcast:
            return nil
        case .podcasts:
            return filtered(podcastRows.rows(for: currentShow, revision: PodcastController.shared.contentRevision))
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
        case .podcasts where PodcastController.shared.shows.isEmpty && !addingPodcast:
            return EmptyState(icon: "antenna.radiowaves.left.and.right", title: "No Podcasts Yet",
                              message: "Subscribe by searching Apple Podcasts or pasting a feed, OHdio or YouTube link with +. Episodes are downloaded here and copied to the iPod's Podcasts menu when you drag them onto it.")
        case .audiobooks where audiobookRows.isEmpty:
            return EmptyState(icon: "book", title: scanning ? "Scanning…" : "No Audiobooks Yet",
                              message: "Choose a folder with + . A subfolder with several files becomes a book with chapters, merged into a single file with chapter marks on the iPod; a single file becomes a one-part book. Drag chapters onto an iPod in the sidebar.")
        case .music, .playlist, .podcasts, .audiobooks, .photos:
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
final class SearchCache: SwiftCrossUI.ObservableObject {
    private var source: [TrackRow] = []
    private var query = ""
    private var result: [TrackRow] = []

    func filter(_ rows: [TrackRow], query: String) -> [TrackRow] {
        guard !query.isEmpty else { return rows }
        let sameRows = rows.withUnsafeBufferPointer { a in source.withUnsafeBufferPointer { a.baseAddress == $0.baseAddress } }
        if sameRows && rows.count == source.count && query == self.query { return result }
        source = rows
        self.query = query
        result = rows.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.artist.localizedCaseInsensitiveContains(query)
                || $0.album.localizedCaseInsensitiveContains(query)
        }
        return result
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
                    VStack(alignment: .leading, spacing: 1) {
                        // One line each, truncated when the window is narrow, as in a Mac toolbar.
                        Text(title).font(.system(size: 13, weight: .bold)).lineLimit(1)
                        if !subtitle.isEmpty {
                            Text(subtitle).font(.system(size: 11)).foregroundColor(.gray).lineLimit(1)
                        }
                    }
                    Spacer()
                    controls
                }
            }
            .padding(.horizontal, 10)
            .frame(height: titleBarHeight)
            Divider()
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
        Button(action: action) {
            Symbol(name: icon, size: 20, pointSize: 15, tint: .primary)
        }
        .buttonStyle(.borderless)
        .titleBarControl()
    }
}

struct SearchField: View {
    var prompt: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 4) {
            Symbol(name: "magnifyingglass", size: 16, pointSize: 12, tint: .secondary)
            TextField(prompt, text: $text)
        }
        .frame(width: 240)
        .titleBarControl()
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

@main
struct IPodProMaxApp: App {
    /// Declared rather than looked up: SwiftCrossUI otherwise scans the binary for Swift Bundler's
    /// metadata at launch (byte by byte), and GTK would run as `com.example.SwiftCrossUIApp`.
    static var metadata: AppMetadata? {
        AppMetadata(identifier: appIdentifier, version: "0.1", additionalMetadata: [:])
    }

    var body: some Scene {
        WindowGroup("iPod Pro Max") {
            ContentView()
        }
        .defaultSize(width: 1100, height: 700)
    }
}
