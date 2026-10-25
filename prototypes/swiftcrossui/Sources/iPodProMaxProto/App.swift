import DefaultBackend
import Foundation
import SwiftCrossUI
#if os(Windows)
    import WinSDK
#endif

struct ContentView: View {
    @State var library: Library?
    @State var devices: [String] = []
    @State var selection: SidebarItem = .music
    @State var sidebarVisible = true
    /// Followed from the system on Linux (GTK doesn't tell SwiftCrossUI); AppKit handles macOS.
    @State var colorScheme: ColorScheme = .light

    var body: some View {
        ZStack(alignment: .topLeading) {
            NavigationSplitView {
                Sidebar(devices: $devices, library: $library, selection: $selection)
            } detail: {
                detail
            }
            if drawsWindowControls {
                WindowControls()
            }
        }
        .windowChrome(sidebarVisible: $sidebarVisible, colorScheme: $colorScheme)
        .followingSystemColorScheme(colorScheme)
        .task {
            let start = Date()
            async let found = Task.detached(priority: .utility) { connectedIPods() }.value
            let loaded = await Library.load(arguments: CommandLine.arguments)
            library = loaded
            devices = await found
            log("[proto] \(loaded.allRows.count) tracks from \(loaded.source)")
            log("[proto] decode \(loaded.loadMs) ms, index \(loaded.indexMs) ms, "
                + "ready \(Int(Date().timeIntervalSince(start) * 1000)) ms after first render")
            if ProcessInfo.processInfo.environment["IPPM_BENCH"] != nil { await benchSidebar() }
        }
    }

    /// `IPPM_BENCH=1`: switches sections like sidebar clicks and logs how long each update takes
    /// until the main thread is free again, then quits.
    private func benchSidebar() async {
        let rounds = Int(ProcessInfo.processInfo.environment["IPPM_BENCH"] ?? "") ?? 1
        let steps: [SidebarItem] = Array(repeating: [.podcasts, .music, .videos, .music, .audiobooks, .music], count: rounds).flatMap { $0 }
        for item in steps {
            let start = Date()
            selection = item
            await mainThreadIdle()
            log("[bench] \(item.title): \(Int(Date().timeIntervalSince(start) * 1000)) ms")
        }
        // The chrome logs how many frames each slide drew ([bench] sidebar ...).
        for _ in 0..<4 {
            toggleSidebar()
            try? await Task.sleep(for: .seconds(0.8))
        }
        exit(0)
    }

    @State var mode: MusicMode? = .allSongs
    @State var search = ""
    @State var selectedArtist: String?

    /// One layout for every section, so switching never tears the track table down: detaching
    /// an NSTableView from the window is what made each sidebar click cost ~60 ms. Sections
    /// without a table draw over it instead.
    @ViewBuilder
    private var detail: some View {
        if let library {
            VStack(spacing: 0) {
                header(library)
                ZStack {
                    HStack(spacing: 0) {
                        if selection == .music && mode == .byArtist {
                            List(library.artists, selection: $selectedArtist) { group in
                                HStack {
                                    Text(group.id)
                                    Spacer()
                                    Text("\(group.count)").foregroundColor(.gray)
                                }
                            }
                            .frame(width: 250)
                            Divider()
                        }
                        TrackTable(rows: tableRows(library))
                    }
                    if let cover = cover(library) {
                        cover.background(WindowBackground())
                    }
                }
            }
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
        default:
            title = selection.title
            subtitle = ""
        }
        return DetailHeader(title: title, subtitle: subtitle,
                            leadingInset: sidebarVisible ? 0 : collapsedHeaderInset) {
            if selection == .music {
                SegmentedControl(options: MusicMode.allCases, selection: $mode)
                ToolbarButton(icon: "plus")
                ToolbarButton(icon: "square.and.arrow.down")
                SearchField(prompt: "Search songs", text: $search)
            }
        }
    }

    /// The rows the table shows; nil for sections without a table, which keeps the last rows so
    /// the table underneath doesn't reload for nothing.
    private func tableRows(_ library: Library) -> [TrackRow]? {
        switch selection {
        case .music where mode == .byArtist:
            return filtered(selectedArtist.flatMap { library.rowsByArtist[$0] } ?? [])
        case .music:
            return filtered(library.allRows)
        case .playlist(let id):
            return library.rowsByPlaylist[id] ?? []
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
        case .music where mode == .byArtist && selectedArtist == nil:
            return EmptyState(icon: "music.mic", title: "Select an Artist",
                              message: "⌘-click or ⇧-click to see several artists at once.")
        case .music, .playlist:
            return nil
        case .device:
            return EmptyState(icon: "ipod", title: "Not in the Prototype",
                              message: "The iPod tab isn't in the prototype yet.")
        default:
            return EmptyState(icon: selection.icon, title: "Not in the Prototype",
                              message: "\(selection.title) isn't in the prototype yet.")
        }
    }

    /// Plain substring search over title, artist and album; a full pass over 5,000 rows takes
    /// about a millisecond, so it runs per keystroke.
    private func filtered(_ rows: [TrackRow]) -> [TrackRow] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return rows }
        return rows.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.artist.localizedCaseInsensitiveContains(query)
                || $0.album.localizedCaseInsensitiveContains(query)
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
        #endif
    }
}

enum MusicMode: String, CaseIterable, CustomStringConvertible {
    case byArtist = "By Artist"
    case allSongs = "All Songs"

    var description: String { rawValue }
}

/// Mac-style traffic lights and the sidebar toggle, for platforms without a Mac title bar. They sit
/// over the window's top-left corner, where macOS puts them.
struct WindowControls: View {
    var body: some View {
        HStack(spacing: 8) {
            light(Color(red: 1, green: 0.37, blue: 0.34), .close)
            light(Color(red: 1, green: 0.74, blue: 0.18), .minimize)
            light(Color(red: 0.16, green: 0.79, blue: 0.25), .zoom)
            Symbol(name: "sidebar.left", size: 28, pointSize: 16, tint: .secondary)
                .padding(.leading, 18)
                .onTapGesture { toggleSidebar() }
        }
        .padding(.leading, 20)
        .frame(height: 52)
    }

    private func light(_ color: Color, _ action: WindowAction) -> some View {
        color.frame(width: 12, height: 12).cornerRadius(6)
            .onTapGesture { performWindowAction(action) }
    }
}

/// The toolbar row at the top of the detail column, in the transparent title bar on macOS.
struct DetailHeader<Controls: View>: View {
    var title: String
    var subtitle: String
    /// Room for the traffic lights when the sidebar is hidden.
    var leadingInset = 0
    var controls: Controls

    init(title: String, subtitle: String, leadingInset: Int = 0, @ViewBuilder controls: () -> Controls) {
        self.title = title
        self.subtitle = subtitle
        self.leadingInset = leadingInset
        self.controls = controls()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .bold))
                    if !subtitle.isEmpty {
                        Text(subtitle).font(.system(size: 11)).foregroundColor(.gray)
                    }
                }
                Spacer()
                controls
            }
            .padding(.horizontal, 10)
            .padding(.leading, leadingInset)
            .frame(height: 52)
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

/// Resumes once the main thread has drained the work queued before it (the view update). On GTK
/// it waits for GLib's loop itself to go idle: dispatch's main queue is only drained by GLib now
/// and then, which would add a fixed delay unrelated to the app.
@MainActor
func mainThreadIdle() async {
    #if canImport(GtkBackend)
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let box = Unmanaged.passRetained(ContinuationBox(c)).toOpaque()
            g_idle_add_full(300, { data in  // G_PRIORITY_DEFAULT_IDLE + 100: after layout and drawing
                Unmanaged<ContinuationBox>.fromOpaque(data!).takeRetainedValue().continuation.resume()
                return 0
            }, box, nil)
        }
    #else
        for _ in 0..<3 {
            await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
        }
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

/// Windows apps started from Explorer have no console: they always log to %TEMP%\\ippm.log.
private let logFile: String? = {
    if let path = ProcessInfo.processInfo.environment["IPPM_LOG"] { return path }
    #if os(Windows)
        return (ProcessInfo.processInfo.environment["TEMP"] ?? "C:\\Windows\\Temp") + "\\ippm.log"
    #else
        return nil
    #endif
}()

/// stderr is unbuffered, so timings show up even when stdout is piped. `IPPM_LOG=<file>` also
/// appends to a file, for apps started from a desktop shell (no console to read).
func log(_ message: String) {
    if let path = logFile, let file = fopen(path, "a") {
        fputs(message + "\n", file)
        fclose(file)
    }
    // A Windows app started from Explorer has no console: writing to the missing handle traps in
    // Foundation (the launch crash) or stalls in the C runtime, so only write when there is one.
    #if os(Windows)
        guard GetFileType(GetStdHandle(STD_ERROR_HANDLE)) != DWORD(FILE_TYPE_UNKNOWN) else { return }
    #endif
    fputs(message + "\n", stderr)
}

@main
struct IPodProMaxProtoApp: App {
    var body: some Scene {
        WindowGroup("iPod Pro Max") {
            ContentView()
        }
        .defaultSize(width: 1100, height: 700)
    }
}
