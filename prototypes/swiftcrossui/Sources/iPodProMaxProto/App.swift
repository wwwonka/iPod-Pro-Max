import DefaultBackend
import Foundation
import SwiftCrossUI

struct ContentView: View {
    @State var library: Library?
    @State var devices: [String] = []
    @State var selection: SidebarItem = .music
    @State var sidebarVisible = true

    var body: some View {
        NavigationSplitView {
            Sidebar(devices: devices, playlists: library?.playlists ?? [], selection: $selection)
        } detail: {
            detail
        }
        .macWindowChrome(sidebarVisible: $sidebarVisible)
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
                Picker(of: MusicMode.allCases, selection: $mode)
                    .pickerStyle(.segmented)
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

enum MusicMode: String, CaseIterable, CustomStringConvertible {
    case byArtist = "By Artist"
    case allSongs = "All Songs"

    var description: String { rawValue }
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

/// Resumes once the main queue has drained the work queued before it (the view update).
@MainActor
func mainThreadIdle() async {
    for _ in 0..<3 {
        await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
    }
}

func songCount(_ n: Int) -> String {
    n == 1 ? "1 song" : "\(n) songs"
}

/// stderr is unbuffered, so timings show up even when stdout is piped.
func log(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
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
