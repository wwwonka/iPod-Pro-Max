import Foundation
import SwiftCrossUI

// The "By Artist" page, as it was in the SwiftUI app: the artist in a header card, then one
// section per album with its cover and its numbered songs. Songs use a virtualized native
// list so selection/dragging stay available and offscreen tracks create no widgets.

/// "12 songs, 48 min", or "1 hr 5 min".
private func songsSummary(count: Int, durationMs: Int) -> String {
    let minutes = durationMs / 60_000
    let time = minutes >= 60 ? "\(minutes / 60) hr \(minutes % 60) min" : "\(minutes) min"
    return "\(songCount(count)), \(time)"
}

struct ArtistDetail: View {
    var artist: NamedGroup
    var albums: [AlbumInfo]
    var artworkFolder: URL?
    /// Names of the connected iPods.
    var devices: [String]
    var isBusy: (String) -> Bool
    var onSend: ([String], String) -> Void
    var onChoosePhoto: () -> Void
    var query: String
    var allowsPhotoSelection = true

    @State private var rowsCache = ArtistRowsCache()

    private var allIDs: [String] { albums.flatMap { $0.rows.map(\.id) } }

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, 24).padding(.vertical, 16)
            Divider()
            #if canImport(AppKitBackend)
                ArtistTrackList(albums: albums, artworkFolder: artworkFolder, query: query,
                                devices: devices, busyDevices: Set(devices.filter(isBusy)), onSend: onSend)
            #else
                TrackTable(rows: rowsCache.rows(albums, query: query))
            #endif
        }
    }

    private var header: some View {
        let duration = albums.reduce(0) { $0 + $1.durationMs }
        let cover = artist.photo
        return HStack(spacing: 18) {
            ArtistPhoto(url: cover, size: 96)
            VStack(alignment: .leading, spacing: 4) {
                Text(artist.id).font(.system(size: 28, weight: .bold)).lineLimit(2)
                Text("\(albums.count) album\(albums.count == 1 ? "" : "s") · \(songsSummary(count: artist.count, durationMs: duration))")
                    .foregroundColor(MacColor.secondaryText)
            }
            Spacer()
            if allowsPhotoSelection { Button("Choose Photo…") { onChoosePhoto() } }
            SendButtons(devices: devices, isBusy: isBusy, onSend: { onSend(allIDs, $0) })
        }
        .padding(18)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 16).fill(MacColor.accent.opacity(0.08))
                RoundedRectangle(cornerRadius: 16).stroke(MacColor.groupBorder)
            }
        )
    }
}

/// The artist's round picture (their first cover), or a gray disc with a microphone.
private struct ArtistPhoto: View {
    var url: URL?
    var size: Double

    var body: some View {
        ZStack {
            Circle().fill(Color(white: 0.5, opacity: 0.18))
            if let url {
                Thumbnail(url: url, pixels: Int(size * 2)).frame(width: size, height: size)
            } else {
                Symbol(name: "music.mic", size: size / 2, pointSize: size / 3, tint: .secondary)
            }
        }
        .frame(width: size, height: size)
        .cornerRadius(Int(size / 2))
    }
}

/// One "Send to iPod" button per connected iPod.
private struct SendButtons: View {
    var devices: [String]
    var isBusy: (String) -> Bool
    var onSend: (String) -> Void

    var body: some View {
        ForEach(devices, id: \.self) { name in
            Button(devices.count > 1 ? "Send to \(name)" : "Send to iPod") { onSend(name) }
                .disabled(isBusy(name))
        }
    }
}

/// Reuse one flattened buffer so progress/photo updates preserve native table selection.
final class ArtistRowsCache: SwiftCrossUI.ObservableObject {
    private var albums: [AlbumInfo] = []
    private var cached: [TrackRow] = []
    private var query = ""
    func rows(_ albums: [AlbumInfo], query: String) -> [TrackRow] {
        guard !self.albums.sameStorage(as: albums) || self.query != query else { return cached }
        self.albums = albums
        self.query = query
        cached = albums.flatMap(\.rows).filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)
            || $0.artist.localizedCaseInsensitiveContains(query) || $0.album.localizedCaseInsensitiveContains(query) }
        return cached
    }
}
