import Foundation
import SwiftCrossUI
import iPodKit
import MediaKit

// The Podcasts section is three pieces around the app's one native track table, which gives the
// episodes multi-selection, virtualization and the platform's own drag onto an iPod in the sidebar:
//   PodcastShowList    the subscriptions, at the left of the table
//   PodcastShowHeader  the selected show's settings, above the table
//   PodcastAddPanel    search or paste a link, drawn over the table
// The controller is not observable: the app bumps a revision whenever it publishes.

/// The subscriptions, with their covers.
struct PodcastShowList: View {
    var revision: Int
    @Binding var selectedID: UUID?

    private var controller: PodcastController { .shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(controller.shows) { show in
                    let downloaded = show.episodes.filter(\.isDownloaded).count
                    HStack(spacing: 8) {
                        Cover(url: controller.artworkURL(for: show), size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(show.title).lineLimit(1)
                            Text("\(show.episodes.count) episodes · \(downloaded) downloaded")
                                .font(.system(size: 11)).foregroundColor(.gray).lineLimit(1)
                        }
                        Spacer()
                        if controller.refreshing.contains(show.id) { Text("…").foregroundColor(.gray) }
                        else if !show.syncEnabled { Text("paused").font(.system(size: 11)).foregroundColor(.gray) }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(selectedID == show.id ? sidebarSelection : Color(white: 0.5, opacity: 0.001))
                    .onTapGesture { selectedID = show.id }
                }
            }
        }
    }
}

/// The selected show: cover, description, and what the sync does with it.
struct PodcastShowHeader: View {
    var show: PodcastShow
    var revision: Int
    /// Names of the connected iPods that can receive podcasts.
    var devices: [String]
    var isBusy: (String) -> Bool
    var onSync: (String) -> Void
    var onUnsubscribe: () -> Void

    private var controller: PodcastController { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 14) {
                Cover(url: controller.artworkURL(for: show), size: 72)
                VStack(alignment: .leading, spacing: 4) {
                    Text(show.title).font(.system(size: 18, weight: .bold)).lineLimit(1)
                    if let author = show.author { Text(author).foregroundColor(.gray).lineLimit(1) }
                    if let summary = show.summary, !summary.isEmpty {
                        Text(summary).font(.system(size: 12)).foregroundColor(.gray).lineLimit(2)
                    }
                }
            }
            HStack(spacing: 12) {
                CheckboxRow(title: "Sync to iPod", isOn: Binding(get: { show.syncEnabled }, set: { value in
                    var copy = show; copy.syncEnabled = value; controller.update(copy)
                }))
                Text("Keep")
                Picker(of: KeepRule.allCases, selection: Binding(get: { KeepRule(rawValue: show.keepLatest) ?? .latest5 }, set: { value in
                    guard let value else { return }
                    var copy = show; copy.keepLatest = value.rawValue; controller.update(copy)
                }))
                Spacer()
                Button("Refresh") { Task { await controller.refresh(showID: show.id) } }
                    .disabled(controller.refreshing.contains(show.id))
                let pending = controller.pendingDownloads.filter { $0.show.id == show.id }.count
                Button(pending > 0 ? "Download \(pending) New" : "Download New") {
                    Task { await controller.downloadPending(showID: show.id) }
                }
                .disabled(pending == 0)
                ForEach(devices, id: \.self) { name in
                    Button(devices.count > 1 ? "Sync to \(name)" : "Sync to iPod") { onSync(name) }
                        .disabled(isBusy(name))
                }
                Button("Unsubscribe") { onUnsubscribe() }
            }
            Text("Select episodes in the list and drag them onto an iPod in the sidebar. Episodes that aren't downloaded yet are downloaded first.")
                .font(.system(size: 11)).foregroundColor(.gray)
        }
        .padding(10)
    }
}

/// Search Apple Podcasts or paste a feed, OHdio or YouTube link.
struct PodcastAddPanel: View {
    var onSubscribed: (UUID) -> Void
    var onClose: () -> Void

    @State private var query = ""
    @State private var results: [PodcastSearchResult] = []
    @State private var working = false
    @State private var message = ""

    private var controller: PodcastController { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField("Search podcasts or paste a feed link", text: $query)
                    .onSubmit { Task { await go() } }
                Button(PodcastSources.normalizedFeedURL(query) != nil ? "Subscribe" : "Search") { Task { await go() } }
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || working)
                Button("Done") { onClose() }
            }
            if working { Text("Working…").font(.system(size: 11)).foregroundColor(.gray) }
            if !message.isEmpty { Text(message).font(.system(size: 11)).foregroundColor(MacColor.red) }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(results) { result in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(result.name).lineLimit(1)
                                Text(result.artist).font(.system(size: 11)).foregroundColor(.gray).lineLimit(1)
                            }
                            Spacer()
                            if let url = result.feedURL {
                                if controller.shows.contains(where: { $0.feedURL == url }) {
                                    Text("Subscribed").font(.system(size: 11)).foregroundColor(.gray)
                                } else {
                                    Button("Subscribe") { Task { await subscribe(url) } }.disabled(working)
                                }
                            }
                        }
                    }
                    if results.isEmpty && !working {
                        Text("Search Apple Podcasts, or paste the link of a feed, an OHdio show or a YouTube channel.")
                            .foregroundColor(.gray)
                    }
                }
            }
            Spacer()
        }
        .padding(12)
    }

    private func go() async {
        message = ""
        if let url = PodcastSources.normalizedFeedURL(query) {
            await subscribe(url)
            return
        }
        working = true
        defer { working = false }
        do { results = try await PodcastSearch.search(query) }
        catch { message = "Search failed: \(error.localizedDescription)" }
    }

    private func subscribe(_ url: URL) async {
        working = true
        defer { working = false }
        do {
            let show = try await controller.subscribe(feedURL: url)
            onSubscribed(show.id)
            query = ""
            results = []
        } catch { message = "Couldn't subscribe: \(error.localizedDescription)" }
    }
}

/// How many of a show's latest episodes are downloaded and sent to the iPod.
enum KeepRule: Int, CaseIterable, CustomStringConvertible {
    case latest1 = 1, latest3 = 3, latest5 = 5, latest10 = 10, latest25 = 25, all = 0

    var description: String {
        switch self {
        case .latest1: "latest episode"
        case .all: "all episodes"
        default: "latest \(rawValue)"
        }
    }
}

// MARK: Table rows

/// The episodes of one show as rows of the track table. The same array comes back while nothing visible
/// changed (download progress, for one, doesn't), so the table doesn't reload and lose its selection.
final class PodcastRowsCache {
    private var showID: UUID?
    private var revision = -1
    private var rows: [TrackRow] = []

    /// Rebuilt only when the show or the content revision changes (not on download progress ticks).
    @MainActor
    func rows(for show: PodcastShow?, revision: Int) -> [TrackRow] {
        guard let show else { showID = nil; rows = []; return rows }
        if showID == show.id, self.revision == revision { return rows }
        self.revision = revision
        let fresh = show.sortedEpisodes.map { episode -> TrackRow in
            var year = ""
            if let date = episode.publishedAt {
                year = String(Calendar(identifier: .gregorian).component(.year, from: date))
            }
            return TrackRow(id: episode.id.uuidString,
                            title: (episode.played ? "" : "● ") + episode.title + (episode.isDownloaded ? "" : "  (not downloaded)"),
                            artist: show.author ?? show.title, album: show.title,
                            number: (episode.episodeNumber ?? 0) > 0 ? "\(episode.episodeNumber!)" : "",
                            year: year, duration: Self.duration(episode.durationMs ?? 0))
        }
        if showID == show.id, fresh == rows { return rows }
        showID = show.id
        rows = fresh
        return rows
    }

    private static func duration(_ ms: Int) -> String {
        let s = ms / 1000
        let two = { (n: Int) in n < 10 ? "0\(n)" : "\(n)" }
        return s >= 3600 ? "\(s / 3600):\(two(s % 3600 / 60)):\(two(s % 60))" : "\(s / 60):\(two(s % 60))"
    }
}

/// A square cover, or a gray tile with a symbol while there is none.
struct Cover: View {
    var url: URL?
    var size: Double
    var symbol = "antenna.radiowaves.left.and.right"

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size / 8).fill(Color(white: 0.5, opacity: 0.15))
            if let url {
                Image(url).resizable().frame(width: size, height: size)
            } else {
                Symbol(name: symbol, size: size / 2, pointSize: size / 3, tint: .secondary)
            }
        }
        .frame(width: size, height: size)
        .cornerRadius(Int(size / 8))
    }
}
