import Foundation
import SwiftCrossUI
import iPodKit
import MediaKit

/// The Podcasts section, ported from the SwiftUI app's `PodcastsView`: the subscriptions on the left,
/// the selected show and its episodes on the right, and an add panel (search or paste a feed link).
/// The controller is not observable: `revision` changes whenever it publishes, which redraws this view.
struct PodcastsView: View {
    var revision: Int
    /// Names of the connected iPods that can receive podcasts, for the Sync buttons.
    var devices: [String]
    var onSync: (String) -> Void
    var isBusy: (String) -> Bool

    @State private var selectedID: UUID?
    @State private var adding = false
    @State private var query = ""
    @State private var results: [PodcastSearchResult] = []
    @State private var working = false
    @State private var message = ""
    @State private var showAll = false

    private var controller: PodcastController { .shared }
    private let episodeLimit = 100

    var body: some View {
        VStack(spacing: 0) {
            actionBar
            Divider()
            if adding { addPanel; Divider() }
            if controller.shows.isEmpty && !adding {
                EmptyState(icon: "antenna.radiowaves.left.and.right", title: "No Podcasts Yet",
                           message: "Subscribe by searching Apple Podcasts or pasting a feed, OHdio or YouTube link. New episodes download here and are copied to the iPod's Podcasts menu, with unplayed dots and resume positions.")
            } else {
                HStack(spacing: 0) {
                    showList.frame(width: 260)
                    Divider()
                    detail
                }
            }
        }
    }

    // MARK: Pieces

    private var actionBar: some View {
        HStack(spacing: 10) {
            Button(adding ? "Done" : "Add Podcast…") { adding.toggle(); message = "" }
            Button("Refresh All") { Task { await controller.refreshAll() } }
                .disabled(controller.shows.isEmpty || !controller.refreshing.isEmpty)
            let pending = controller.pendingDownloads.count
            Button(pending > 0 ? "Download \(pending) New" : "Download New") { Task { await controller.downloadPending() } }
                .disabled(pending == 0)
            Spacer()
            ForEach(devices, id: \.self) { name in
                Button(devices.count > 1 ? "Sync to \(name)" : "Sync to iPod") { onSync(name) }
                    .disabled(isBusy(name) || controller.shows.isEmpty)
            }
        }
        .padding(8)
    }

    private var addPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Search podcasts or paste a feed link", text: $query)
                    .onSubmit { Task { await go() } }
                Button(PodcastSources.normalizedFeedURL(query) != nil ? "Subscribe" : "Search") { Task { await go() } }
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || working)
            }
            if working { Text("Working…").font(.system(size: 11)).foregroundColor(.gray) }
            if !message.isEmpty { Text(message).font(.system(size: 11)).foregroundColor(MacColor.red) }
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
        }
        .padding(10)
    }

    private var showList: some View {
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
                    .onTapGesture { selectedID = show.id; showAll = false }
                }
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let id = selectedID ?? controller.shows.first?.id, let show = controller.show(id: id) {
            let sync = Set(show.episodesToSync().map(\.id))
            let episodes = show.sortedEpisodes
            let visible = showAll ? episodes : Array(episodes.prefix(episodeLimit))
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    header(show)
                    Divider()
                    ForEach(visible) { episode in
                        EpisodeRow(show: show, episode: episode, willSync: sync.contains(episode.id),
                                   progress: controller.progress[episode.id], downloading: controller.isDownloading(episode.id))
                    }
                    if visible.count < episodes.count {
                        Button("Show all \(episodes.count) episodes") { showAll = true }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text("Select a podcast").foregroundColor(.gray).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func header(_ show: PodcastShow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 14) {
                Cover(url: controller.artworkURL(for: show), size: 88)
                VStack(alignment: .leading, spacing: 4) {
                    Text(show.title).font(.system(size: 20, weight: .bold)).lineLimit(2)
                    if let author = show.author { Text(author).foregroundColor(.gray) }
                    if let summary = show.summary, !summary.isEmpty {
                        Text(summary).font(.system(size: 12)).foregroundColor(.gray).lineLimit(3)
                    }
                }
            }
            HStack(spacing: 14) {
                CheckboxRow(title: "Sync to iPod", isOn: Binding(get: { show.syncEnabled }, set: { value in
                    var copy = show; copy.syncEnabled = value; controller.update(copy)
                }))
                HStack(spacing: 6) {
                    Text("Keep")
                    Picker(of: KeepRule.allCases, selection: Binding(get: { KeepRule(rawValue: show.keepLatest) ?? .latest5 }, set: { value in
                        guard let value else { return }
                        var copy = show; copy.keepLatest = value.rawValue; controller.update(copy)
                    }))
                }
                Spacer()
                Button("Refresh") { Task { await controller.refresh(showID: show.id) } }
                    .disabled(controller.refreshing.contains(show.id))
                Button("Unsubscribe") { controller.unsubscribe(showID: show.id); selectedID = nil }
            }
        }
    }

    // MARK: Actions

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
            selectedID = show.id
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

struct EpisodeRow: View {
    var show: PodcastShow
    var episode: PodcastEpisode
    var willSync: Bool
    var progress: Double?
    var downloading: Bool
    @State private var expanded = false

    private var controller: PodcastController { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 10) {
                Circle().fill(episode.played ? Color(white: 0.5, opacity: 0.001) : MacColor.accent).frame(width: 8, height: 8).padding(.top, 5)
                VStack(alignment: .leading, spacing: 2) {
                    Text(episode.title).lineLimit(expanded ? nil : 1)
                    Text(details).font(.system(size: 11)).foregroundColor(.gray).lineLimit(1)
                }
                .onTapGesture { expanded.toggle() }
                Spacer()
                trailing
            }
            if expanded {
                if let summary = episode.summary, !summary.isEmpty {
                    Text(summary).font(.system(size: 12)).foregroundColor(.gray).padding(.leading, 18)
                }
                HStack(spacing: 8) {
                    Button(episode.played ? "Mark as Unplayed" : "Mark as Played") {
                        controller.setPlayed(showID: show.id, episodeID: episode.id, played: !episode.played)
                    }
                    Button(syncLabel) {
                        let next: Bool? = episode.syncOverride == nil ? true : (episode.syncOverride == true ? false : nil)
                        controller.setEpisodeSync(showID: show.id, episodeID: episode.id, override: next)
                    }
                }
                .padding(.leading, 18)
            }
        }
    }

    private var syncLabel: String {
        switch episode.syncOverride {
        case nil: "Follows the show's rule"
        case true?: "Always sync"
        case false?: "Never sync"
        }
    }

    private var details: String {
        var parts: [String] = []
        if let date = episode.publishedAt { parts.append(Self.dateFormatter.string(from: date)) }
        if let ms = episode.durationMs, ms > 0 { parts.append(Self.duration(ms)) }
        if let size = episode.fileSize ?? episode.enclosureLength, size > 0 { parts.append(bytes(size)) }
        if episode.isDownloaded { parts.append("Downloaded") }
        if willSync { parts.append("Syncs") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var trailing: some View {
        if downloading {
            HStack(spacing: 6) {
                ProgressView(value: progress ?? 0).frame(width: 80)
                Button("Cancel") { controller.cancelDownload(episodeID: episode.id) }
            }
        } else if episode.isDownloaded {
            Button("Delete") { controller.deleteDownload(showID: show.id, episodeID: episode.id) }
        } else {
            Button("Download") { Task { await controller.download(showID: show.id, episodeID: episode.id) } }
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    private static func duration(_ ms: Int) -> String {
        let s = ms / 1000
        return s >= 3600 ? "\(s / 3600):" + (s % 3600 / 60 < 10 ? "0" : "") + "\(s % 3600 / 60):" + (s % 60 < 10 ? "0" : "") + "\(s % 60)"
            : "\(s / 60):" + (s % 60 < 10 ? "0" : "") + "\(s % 60)"
    }
}

/// A square cover, or a gray tile with the podcast symbol while there is none.
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
