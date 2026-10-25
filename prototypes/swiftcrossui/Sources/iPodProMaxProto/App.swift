import DefaultBackend
import Foundation
import SwiftCrossUI

struct ContentView: View {
    @State var library: Library?
    @State var devices: [String] = []
    @State var selection: SidebarItem = .music

    var body: some View {
        NavigationSplitView {
            Sidebar(devices: devices, playlists: library?.playlists ?? [], selection: $selection)
        } detail: {
            detail
        }
        .hiddenTitleBar()
        .task {
            let start = Date()
            async let found = Task.detached(priority: .utility) { connectedIPods() }.value
            let loaded = await Library.load(arguments: CommandLine.arguments)
            library = loaded
            devices = await found
            log("[proto] \(loaded.allRows.count) tracks from \(loaded.source)")
            log("[proto] decode \(loaded.loadMs) ms, index \(loaded.indexMs) ms, "
                + "ready \(Int(Date().timeIntervalSince(start) * 1000)) ms after first render")
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let library {
            switch selection {
            case .music:
                MusicView(library: library)
            case .playlist(let id):
                let rows = library.rowsByPlaylist[id] ?? []
                VStack(spacing: 0) {
                    DetailHeader(title: library.playlists.first { $0.id == id }?.name ?? "Playlist",
                                 subtitle: songCount(rows.count))
                    TrackTable(rows: rows)
                }
            case .device(let name):
                placeholder(title: name, icon: "ipod", message: "The iPod tab isn't in the prototype yet.")
            default:
                placeholder(title: selection.title, icon: selection.icon,
                            message: "\(selection.title) isn't in the prototype yet.")
            }
        } else {
            Text("Loading…").foregroundColor(.gray)
        }
    }

    private func placeholder(title: String, icon: String, message: String) -> some View {
        VStack(spacing: 0) {
            DetailHeader(title: title, subtitle: "")
            EmptyState(icon: icon, title: "Not in the Prototype", message: message)
        }
    }
}

/// The SwiftUI app's Music view: a toolbar with title, subtitle, view picker, buttons and search,
/// above either the artists split view or the table of all songs.
struct MusicView: View {
    enum Mode: String, CaseIterable, CustomStringConvertible {
        case byArtist = "By Artist"
        case allSongs = "All Songs"

        var description: String { rawValue }
    }

    var library: Library
    @State var mode: Mode? = .allSongs
    @State var search = ""
    @State var selectedArtist: String?

    var body: some View {
        VStack(spacing: 0) {
            DetailHeader(title: "Music", subtitle: songCount(library.allRows.count)) {
                Picker(of: Mode.allCases, selection: $mode)
                    .pickerStyle(.segmented)
                ToolbarButton(icon: "plus")
                ToolbarButton(icon: "square.and.arrow.down")
                SearchField(prompt: "Search songs", text: $search)
            }
            if library.allRows.isEmpty {
                EmptyState(icon: "music.note", title: "No Music Yet",
                           message: "Add MP3, AAC, Apple Lossless, WAV or AIFF files, or import your Music app library. FLAC and other formats are converted to AAC when syncing.")
            } else if mode == .byArtist {
                HStack(spacing: 0) {
                    List(library.artists, selection: $selectedArtist) { group in
                        HStack {
                            Text(group.id)
                            Spacer()
                            Text("\(group.count)").foregroundColor(.gray)
                        }
                    }
                    .frame(width: 250)
                    Divider()
                    if let artist = selectedArtist, let rows = library.rowsByArtist[artist] {
                        TrackTable(rows: filtered(rows))
                    } else {
                        EmptyState(icon: "music.mic", title: "Select an Artist",
                                   message: "⌘-click or ⇧-click to see several artists at once.")
                    }
                }
            } else {
                TrackTable(rows: filtered(library.allRows))
            }
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

struct TrackTable: View {
    var rows: [TrackRow]

    var body: some View {
        Table(rows) {
            TableColumn("#", value: \TrackRow.number)
            TableColumn("Title", value: \TrackRow.title)
            TableColumn("Artist", value: \TrackRow.artist)
            TableColumn("Album", value: \TrackRow.album)
            TableColumn("Year", value: \TrackRow.year)
            TableColumn("Time", value: \TrackRow.duration)
        }
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
