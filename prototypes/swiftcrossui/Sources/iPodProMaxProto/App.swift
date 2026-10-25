import DefaultBackend
import Foundation
import SwiftCrossUI

enum Section: String, CaseIterable, Identifiable {
    case artists = "Artistes"
    case albums = "Albums"
    case songs = "Morceaux"

    var id: Self { self }
}

struct ContentView: View {
    @State var library: Library?
    @State var section: Section? = .artists
    @State var selectedArtist: String?
    @State var selectedAlbum: String?

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading) {
                Text("Bibliothèque").font(.headline)
                List(Section.allCases, selection: $section) { s in
                    Text(s.rawValue)
                }
                Spacer()
                Text(status).font(.caption).foregroundColor(.gray)
            }
            .padding(10)
            .padding(.top, titleBarInset)
            .frame(minWidth: 180)
        } content: {
            groupList
                .padding(10)
                .padding(.top, titleBarInset)
                .frame(minWidth: 220)
        } detail: {
            detail
                .padding(10)
                .padding(.top, titleBarInset)
        }
        .hiddenTitleBar()
        .task {
            let start = Date()
            let loaded = await Library.load(arguments: CommandLine.arguments)
            library = loaded
            log("[proto] \(loaded.allRows.count) tracks from \(loaded.source)")
            log("[proto] decode \(loaded.loadMs) ms, index \(loaded.indexMs) ms, "
                + "ready \(Int(Date().timeIntervalSince(start) * 1000)) ms after first render")
        }
    }

    private var status: String {
        guard let library else { return "Chargement…" }
        return "\(library.allRows.count) pistes\nlecture \(library.loadMs) ms · index \(library.indexMs) ms"
    }

    @ViewBuilder
    private var groupList: some View {
        if let library {
            switch section {
            case .artists:
                List(library.artists, selection: $selectedArtist) { g in
                    groupRow(g)
                }
            case .albums:
                List(library.albums, selection: $selectedAlbum) { g in
                    groupRow(g)
                }
            case .songs, nil:
                Text("Toutes les pistes à droite →").foregroundColor(.gray)
            }
        } else {
            Text("Chargement…")
        }
    }

    private func groupRow(_ g: NamedGroup) -> some View {
        HStack {
            Text(g.id)
            Spacer()
            Text("\(g.count)").foregroundColor(.gray)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let library {
            switch section {
            case .artists:
                trackTable(title: selectedArtist, rows: selectedArtist.flatMap { library.rowsByArtist[$0] })
            case .albums:
                trackTable(title: selectedAlbum, rows: selectedAlbum.flatMap { library.rowsByAlbum[$0] })
            case .songs, nil:
                trackTable(title: "Tous les morceaux", rows: library.allRows)
            }
        } else {
            Text("Chargement…")
        }
    }

    @ViewBuilder
    private func trackTable(title: String?, rows: [TrackRow]?) -> some View {
        if let title, let rows {
            VStack(alignment: .leading) {
                Text(title).font(.title2)
                Text("\(rows.count) pistes").foregroundColor(.gray)
                Table(rows) {
                    TableColumn("#", value: \TrackRow.number)
                    TableColumn("Titre", value: \TrackRow.title)
                    TableColumn("Artiste", value: \TrackRow.artist)
                    TableColumn("Album", value: \TrackRow.album)
                    TableColumn("Année", value: \TrackRow.year)
                    TableColumn("Durée", value: \TrackRow.duration)
                }
            }
        } else {
            Text("Choisis un élément dans la liste").foregroundColor(.gray)
        }
    }
}

/// stderr is unbuffered, so timings show up even when stdout is piped.
func log(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

@main
struct IPodProMaxProtoApp: App {
    var body: some Scene {
        WindowGroup("iPod Pro Max — prototype SwiftCrossUI") {
            ContentView()
        }
        .defaultSize(width: 1100, height: 700)
    }
}
