import Foundation
import SwiftCrossUI
import iPodKit
#if canImport(AppKit)
    import AppKit
#endif

/// The iPod page, copied from the SwiftUI app's `DeviceView`: header, support banner, capacity bar,
/// sync panel, sync options and actions. Read from the iPod itself with iPodKit (name, contents,
/// space); the sync options live in the view only, and Sync, Import and Forget are shown but not
/// wired up: the prototype has no sync records or sync engine behind it. Eject and Show in Finder work.
struct DeviceView: View {
    var device: IPodDevice
    var library: Library
    var onEject: () -> Void

    @State var contents: DeviceContents?
    @State var isRenaming = false
    @State var newName = ""
    @State var renamed: String?

    // Sync options, as in the app's DeviceSyncRecord (defaults included).
    @State var musicChoice: MusicChoice? = .entireLibrary
    @State var selectedPlaylists: Set<String> = []
    @State var syncPodcasts = true
    @State var syncVideos = true
    @State var syncAudiobooks = true
    @State var syncPhotos = true
    @State var removeUnknownTracks = false
    @State var albumArtistGrouping = true

    struct DeviceContents {
        var songs = 0
        var podcasts = 0
        var videos = 0
        var audiobooks = 0
        var musicBytes: Int64 = 0
        var podcastBytes: Int64 = 0
        var videoBytes: Int64 = 0
        var audiobookBytes: Int64 = 0
        var photoBytes: Int64 = 0
        var photos = 0
        var name = ""
        var readError: String?
        var stats = IPodDevice.VolumeStats(total: 0, free: 0)
    }

    enum MusicChoice: String, CaseIterable, CustomStringConvertible {
        case entireLibrary = "Entire library"
        case selectedPlaylists = "Selected playlists"
        var description: String { rawValue }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if device.supportLevel == .unsupported {
                    unsupportedBanner
                } else if device.supportLevel == .experimental {
                    experimentalBanner
                }
                capacity
                syncPanel
                optionsPanel
                actionsPanel
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: device.id) { await loadContents() }
    }

    private var displayName: String {
        if let renamed { return renamed }
        if let n = contents?.name, !n.isEmpty { return n }
        return device.displayName
    }

    // MARK: Sections

    private var header: some View {
        HStack(alignment: .center, spacing: 18) {
            Symbol(name: "ipod", size: 80, pointSize: 56, tint: .accent)
                .background(RoundedRectangle(cornerRadius: 16).fill(MacColor.accent.opacity(0.1)))
            VStack(alignment: .leading, spacing: 4) {
                if isRenaming {
                    HStack(spacing: 8) {
                        TextField("Name", text: $newName)
                            .frame(width: 260)
                            .onSubmit { rename() }
                        Button("Rename") { rename() }
                        Button("Cancel") { isRenaming = false }
                    }
                } else {
                    HStack(spacing: 8) {
                        Text(displayName).font(.system(size: 26, weight: .bold))
                        Button {
                            newName = displayName
                            isRenaming = true
                        } label: {
                            Symbol(name: "pencil", size: 16, pointSize: 13, tint: .secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Rename")
                    }
                }
                Text([device.displayModelName, device.capacityLabel].compactMap { $0 }.joined(separator: " · "))
                    .foregroundColor(MacColor.secondaryText)
                HStack(spacing: 12) {
                    if let s = device.serialNumber { Text("Serial \(s)") }
                    if device.isSimulated {
                        HStack(spacing: 4) {
                            Symbol(name: "folder", size: 12, pointSize: 10, tint: .tertiary)
                            Text("Simulated iPod folder")
                        }
                    }
                    Text("Never synced with iPod Pro Max")
                }
                .font(.system(size: 10))
                .foregroundColor(MacColor.tertiaryText)
            }
            Spacer()
        }
    }

    private var unsupportedBanner: some View {
        banner(color: MacColor.redTint, icon: "xmark.octagon.fill", title: "This iPod isn't supported yet",
               text: "\(device.displayModelName) needs a database signature that iPod Pro Max 1.0 can't produce. iPod Video, iPod nano (1st & 2nd gen), iPod photo, iPod mini, iPod classic and the original click-wheel iPods are fully supported.")
    }

    private var experimentalBanner: some View {
        banner(color: MacColor.orangeTint, icon: "flask.fill", title: "Experimental support",
               text: device.generation == .unknown
                   ? "iPod Pro Max couldn't identify this model from its SysInfo file. Syncing should work for classic click-wheel iPods, but album art may not display."
                   : "\(device.displayModelName) uses a signed database. iPod Pro Max signs it, but this model hasn't been verified yet. Keep a backup of anything important on the iPod.")
    }

    private func banner(color: SystemColor, icon: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Symbol(name: icon, size: 20, pointSize: 15, tint: .color(color))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .bold))
                Text(text).font(.system(size: 12)).foregroundColor(MacColor.secondaryText)
            }
            Spacer()
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(color.color.opacity(0.08)))
    }

    private var capacity: some View {
        let stats = contents?.stats ?? IPodDevice.VolumeStats(total: 0, free: 0)
        let music = contents?.musicBytes ?? 0
        let podcasts = contents?.podcastBytes ?? 0
        let videos = contents?.videoBytes ?? 0
        let audiobooks = contents?.audiobookBytes ?? 0
        let photos = contents?.photoBytes ?? 0
        let used = max(stats.used, music + podcasts + videos + audiobooks + photos)
        let other = max(used - music - podcasts - videos - audiobooks - photos, 0)
        let segments: [(Color, Int64)] = [
            (MacColor.blue, music), (MacColor.purple, podcasts), (MacColor.orange, videos),
            (MacColor.pink, audiobooks), (MacColor.green, photos), (MacColor.gray.opacity(0.6), other),
        ]
        return VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                HStack(spacing: 1) {
                    if stats.total > 0 {
                        ForEach(segments.indices, id: \.self) { i in
                            segments[i].0.frame(width: geo.size.width * Double(segments[i].1) / Double(stats.total), height: 18)
                        }
                    }
                    MacColor.secondaryText.opacity(0.12).frame(height: 18)
                }
            }
            .frame(height: 18)
            .cornerRadius(6)
            HStack(spacing: 18) {
                legend(MacColor.blue, "Music", bytes(music), detail: contents.map { "\($0.songs) songs" })
                legend(MacColor.purple, "Podcasts", bytes(podcasts), detail: contents.map { "\($0.podcasts) episodes" })
                if videos > 0 { legend(MacColor.orange, "Videos", bytes(videos), detail: contents.map { "\($0.videos)" }) }
                if audiobooks > 0 { legend(MacColor.pink, "Audiobooks", bytes(audiobooks), detail: contents.map { "\($0.audiobooks)" }) }
                if photos > 0 { legend(MacColor.green, "Photos", bytes(photos), detail: contents.map { "\($0.photos)" }) }
                legend(MacColor.gray, "Other", bytes(other))
                legend(MacColor.secondaryText.opacity(0.3), "Free", bytes(stats.free))
                if stats.total > 0 { Text("\(bytes(stats.total)) total").foregroundColor(MacColor.secondaryText).legendFixedSize() }
            }
            .font(.system(size: 10))
            if let e = contents?.readError {
                HStack(spacing: 4) {
                    Symbol(name: "exclamationmark.triangle", size: 12, pointSize: 10, tint: .color(MacColor.orangeTint))
                    Text(e).foregroundColor(MacColor.orange)
                }
                .font(.system(size: 10))
            }
        }
    }

    private func legend(_ color: Color, _ name: String, _ value: String, detail: String? = nil) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(name).bold()
            Text(value)
            if let detail { Text("(\(detail))").foregroundColor(MacColor.secondaryText) }
        }
        .legendFixedSize()
    }

    private var syncPanel: some View {
        GroupBox {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Ready to sync").font(.system(size: 13, weight: .bold))
                    Text(planSummary).foregroundColor(MacColor.secondaryText).font(.system(size: 12)).lineLimit(2)
                }
                Spacer()
                ProminentButton(title: "Sync", icon: "arrow.triangle.2.circlepath", enabled: false) {}
                    .help("Syncing isn't in the prototype yet")
            }
        }
    }

    private var planSummary: String {
        let songs = library.allRows.count
        var parts = ["\(songs) song\(songs == 1 ? "" : "s")"]
        if syncPhotos && device.generation.supportsPhotos { parts.append("photos from your whole library") }
        let playlists = musicChoice == .selectedPlaylists ? selectedPlaylists.count : library.playlists.count
        if playlists > 0 { parts.append("\(playlists) playlist\(playlists == 1 ? "" : "s")") }
        return parts.joined(separator: ", ")
    }

    private var optionsPanel: some View {
        GroupBox(title: "Sync Options") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 8) {
                    Text("Music:")
                    RadioGroup(options: MusicChoice.allCases, selection: $musicChoice)
                }
                if musicChoice == .selectedPlaylists {
                    if library.playlists.isEmpty {
                        Caption("No playlists yet. Create one from the Music view.").padding(.leading, 20)
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(library.playlists, id: \.id) { pl in
                                CheckboxRow(title: pl.name, isOn: Binding(
                                    get: { selectedPlaylists.contains(pl.id) },
                                    set: { on in
                                        if on { selectedPlaylists.insert(pl.id) } else { selectedPlaylists.remove(pl.id) }
                                    }))
                            }
                        }
                        .padding(.leading, 20)
                    }
                }
                Divider()
                CheckboxRow(title: "Sync podcasts", isOn: $syncPodcasts).disabled(!device.supportsPodcasts)
                if !device.supportsPodcasts {
                    Caption("This iPod's firmware has no Podcasts menu.")
                }
                CheckboxRow(title: "Sync videos", isOn: $syncVideos)
                CheckboxRow(title: "Sync audiobooks", isOn: $syncAudiobooks)
                CheckboxRow(title: "Sync photos", isOn: $syncPhotos).disabled(!device.generation.supportsPhotos)
                if !device.generation.supportsPhotos {
                    Caption("This iPod has no color screen for photos.")
                }
                CheckboxRow(title: "Remove songs that aren't in this library", isOn: $removeUnknownTracks)
                Caption("When on, songs that were put on the iPod by iTunes or another Mac are deleted during sync so the iPod mirrors this library. Turn it off to keep them.")
                Divider()
                CheckboxRow(title: "Use Album Artist for Grouping", isOn: $albumArtistGrouping)
                Caption("Replaces the Artist tag with Album Artist on this iPod so albums stay grouped in the Artists view. Your library files are not modified.")
            }
        }
    }

    private var actionsPanel: some View {
        HStack(spacing: 12) {
            LabelButton(title: device.isSimulated ? "Detach Folder" : "Eject", icon: "eject") { onEject() }
            LabelButton(title: "Import Songs from iPod…", icon: "square.and.arrow.down") {}
                .disabled(true)
                .help("Importing isn't in the prototype yet")
            LabelButton(title: "Show in \(fileManagerName)", icon: "folder") { showInFileManager(device.mountPoint) }
            Spacer()
            Button("Forget iPod") {}
                .disabled(true)
        }
    }

    // MARK: Actions

    private func loadContents() async {
        let dev = device
        contents = await Task.detached(priority: .utility) { Self.readContents(of: dev) }.value
    }

    /// The same reading as the app's `DeviceView.loadContents`, plus the volume's space.
    private nonisolated static func readContents(of dev: IPodDevice) -> DeviceContents {
        var c = DeviceContents()
        c.stats = dev.volumeStats()
        do {
            let db = try dev.readDatabase()
            c.name = db.name
            for t in db.tracks {
                if t.isPodcast { c.podcasts += 1; c.podcastBytes += Int64(t.fileSize) }
                else if t.mediaType & IPodMediaType.movie != 0 || t.mediaType & IPodMediaType.musicVideo != 0 || t.mediaType & IPodMediaType.tvShow != 0 { c.videos += 1; c.videoBytes += Int64(t.fileSize) }
                else if t.mediaType & IPodMediaType.audiobook != 0 { c.audiobooks += 1; c.audiobookBytes += Int64(t.fileSize) }
                else { c.songs += 1; c.musicBytes += Int64(t.fileSize) }
            }
            let photosDir = dev.mountPoint.appendingPathComponent("Photos")
            if let e = FileManager.default.enumerator(at: photosDir, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) {
                while let f = e.nextObject() as? URL {
                    c.photoBytes += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                }
            }
            if let data = try? Data(contentsOf: photosDir.appendingPathComponent("Photo Database")), data.count > 0x84 {
                let r = ByteReader(data)
                // mhfd → first mhsd (type 1) → mhli holds the photo count.
                let mhsd = Int(r.u32(4))
                if r.hasHeader("mhsd", at: mhsd), r.hasHeader("mhli", at: mhsd + 0x60) { c.photos = Int(r.u32(mhsd + 0x60 + 8)) }
            }
        } catch {
            c.readError = "The iPod's database couldn't be read (\(error.localizedDescription)). Syncing will rebuild it."
        }
        return c
    }

    /// Written to the iPod at once, as the app does, so the new name shows even without a sync.
    private func rename() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        isRenaming = false
        guard !name.isEmpty else { return }
        renamed = name
        let dev = device
        Task.detached(priority: .utility) {
            guard var db = try? dev.readDatabase() else { return }
            db.name = name
            guard let out = try? ITunesDBWriter(database: db, checksum: dev.checksumType, firewireID: dev.firewireIDBytes).write() else { return }
            try? FileManager.default.createDirectory(at: dev.iTunesDir, withIntermediateDirectories: true)
            try? out.data.write(to: dev.iTunesDBURL, options: .atomic)
        }
    }
}

// MARK: Pieces of the page

/// The Mac's system colors, which the app's page uses, for every platform.
enum MacColor {
    static let accentTint = SystemColor(light: 0x007AFF, dark: 0x0A84FF)
    static let purpleTint = SystemColor(light: 0xAF52DE, dark: 0xBF5AF2)
    static let orangeTint = SystemColor(light: 0xFF9500, dark: 0xFF9F0A)
    static let pinkTint = SystemColor(light: 0xFF2D55, dark: 0xFF375F)
    static let greenTint = SystemColor(light: 0x28CD41, dark: 0x32D74B)
    static let redTint = SystemColor(light: 0xFF3B30, dark: 0xFF453A)
    static let whiteTint = SystemColor(0xFFFFFF)

    static let accent = accentTint.color
    static let blue = accentTint.color
    static let purple = purpleTint.color
    static let orange = orangeTint.color
    static let pink = pinkTint.color
    static let green = greenTint.color
    static let red = redTint.color
    static let gray = SystemColor(0x8E8E93).color
    /// `secondaryLabelColor` and `tertiaryLabelColor`.
    static let secondaryText = Color.adaptive(light: Color(white: 0, opacity: 0.5), dark: Color(white: 1, opacity: 0.55))
    static let tertiaryText = Color.adaptive(light: Color(white: 0, opacity: 0.26), dark: Color(white: 1, opacity: 0.25))
    /// A GroupBox's fill and border.
    static let groupFill = Color.adaptive(light: Color(white: 0, opacity: 0.03), dark: Color(white: 1, opacity: 0.04))
    static let groupBorder = Color.adaptive(light: Color(white: 0, opacity: 0.08), dark: Color(white: 1, opacity: 0.08))
}

/// SwiftUI's GroupBox on macOS: an optional title above a rounded, lightly filled box.
struct GroupBox<Content: View>: View {
    var title: String?
    var content: Content

    init(title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title { Text(title).font(.system(size: 13, weight: .bold)).padding(.leading, 2) }
            content
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    ZStack {
                        RoundedRectangle(cornerRadius: 6).fill(MacColor.groupFill)
                        RoundedRectangle(cornerRadius: 6).stroke(MacColor.groupBorder)
                    }
                )
        }
    }
}

struct Caption: View {
    var text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.system(size: 10)).foregroundColor(MacColor.secondaryText)
    }
}

/// A Mac checkbox: the box, then its title (SwiftCrossUI's Toggle puts the title first, so its
/// own title stays empty).
struct CheckboxRow: View {
    var title: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 2) {
            Toggle("", isOn: $isOn).toggleStyle(.checkbox)
            Text(title).onTapGesture { isOn.toggle() }
        }
    }
}

/// Radio buttons: native on macOS and Windows; drawn on GTK, whose backend has none.
struct RadioGroup<Value: Equatable & CustomStringConvertible>: View {
    var options: [Value]
    @Binding var selection: Value?

    var body: some View {
        #if canImport(GtkBackend)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(0..<options.count), id: \.self) { (i: Int) in
                    HStack(spacing: 6) {
                        ZStack {
                            Circle().stroke(MacColor.secondaryText).frame(width: 14, height: 14)
                            if selection == options[i] { Circle().fill(MacColor.accent).frame(width: 8, height: 8) }
                        }
                        Text(options[i].description)
                    }
                    .onTapGesture { selection = options[i] }
                }
            }
        #else
            Picker(of: options, selection: $selection).pickerStyle(.radioGroup)
        #endif
    }
}

/// A bordered button with a symbol before its title, like SwiftUI's `Label` in a Button.
struct LabelButton: View {
    var title: String
    var icon: String
    var action: @MainActor @Sendable () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Symbol(name: icon, size: 14, pointSize: 12, tint: .primary)
                Text(title)
            }
        }
    }
}

/// `.borderedProminent` at `.large` size: accent fill, white title and symbol.
struct ProminentButton: View {
    var title: String
    var icon: String
    var enabled = true
    var action: @MainActor @Sendable () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Symbol(name: icon, size: 16, pointSize: 13, tint: .color(MacColor.whiteTint))
            Text(title).font(.system(size: 13)).foregroundColor(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(minWidth: 80)
        .background(RoundedRectangle(cornerRadius: 7).fill(enabled ? MacColor.accent : MacColor.accent.opacity(0.45)))
        .onTapGesture { if enabled { action() } }
    }
}

extension View {
    /// The legend's items keep their width instead of truncating, as in the app. Not on WinUI:
    /// there `fixedSize` inside the page overflows the stack (layout recursion) when it appears.
    @ViewBuilder
    func legendFixedSize() -> some View {
        #if os(Windows)
            self
        #else
            fixedSize()
        #endif
    }
}

func bytes(_ b: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
}

var fileManagerName: String {
    #if os(macOS)
        "Finder"
    #elseif os(Windows)
        "Explorer"
    #else
        "Files"
    #endif
}

/// Opens the iPod in the system's file manager.
func showInFileManager(_ url: URL) {
    #if os(macOS)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    #else
        let process = Process()
        #if os(Windows)
            process.executableURL = URL(fileURLWithPath: "C:\\Windows\\explorer.exe")
            process.arguments = [FileOps.nativePath(url)]
        #else
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xdg-open")
            process.arguments = [url.path]
        #endif
        try? process.run()
    #endif
}
