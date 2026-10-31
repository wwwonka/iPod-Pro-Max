import Foundation
import SwiftCrossUI

// The "By Artist" page, as it was in the SwiftUI app: the artist in a header card, then one
// section per album with its cover and its numbered songs. Drawn with SwiftCrossUI itself, so it
// is the same on every platform. (No gradients: the GTK and WinUI backends have none.)

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

    private func coverURL(_ key: String?) -> URL? {
        guard let key, let artworkFolder else { return nil }
        let url = artworkFolder.appendingPathComponent("\(key).jpg")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private var allIDs: [String] { albums.flatMap { $0.rows.map(\.id) } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                ForEach(albums) { album in
                    AlbumSection(album: album, cover: coverURL(album.artworkKey), devices: devices, isBusy: isBusy,
                                 onSend: { name in onSend(album.rows.map(\.id), name) })
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 24)
        }
    }

    private var header: some View {
        let duration = albums.reduce(0) { $0 + $1.durationMs }
        let cover = coverURL(artist.artworkKey)
        return HStack(spacing: 18) {
            ArtistPhoto(url: cover, size: 96)
            VStack(alignment: .leading, spacing: 4) {
                Text(artist.id).font(.system(size: 28, weight: .bold)).lineLimit(2)
                Text("\(albums.count) album\(albums.count == 1 ? "" : "s") · \(songsSummary(count: artist.count, durationMs: duration))")
                    .foregroundColor(MacColor.secondaryText)
            }
            Spacer()
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
                Image(url).resizable().frame(width: size, height: size)
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

/// An album: its cover and Send button at the left; title, details and the numbered songs at the right.
private struct AlbumSection: View {
    var album: AlbumInfo
    var cover: URL?
    var devices: [String]
    var isBusy: (String) -> Bool
    var onSend: (String) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Cover(url: cover, size: 150, symbol: "music.note")
                SendButtons(devices: devices, isBusy: isBusy, onSend: onSend)
            }
            .frame(width: 150)
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(album.title).font(.system(size: 20, weight: .bold)).lineLimit(2)
                    Text([album.genre, album.year.isEmpty ? nil : album.year,
                          songsSummary(count: album.rows.count, durationMs: album.durationMs)]
                        .compactMap { $0 }.joined(separator: " · "))
                        .foregroundColor(MacColor.secondaryText)
                }
                VStack(spacing: 0) {
                    ForEach(Array(album.rows.enumerated()), id: \.offset) { index, row in
                        HStack(spacing: 10) {
                            Text(row.number.isEmpty ? "–" : row.number)
                                .foregroundColor(MacColor.secondaryText)
                                .frame(width: 22, alignment: .trailing)
                            Text(row.title).lineLimit(1)
                            Spacer(minLength: 8)
                            Text(row.duration).foregroundColor(MacColor.secondaryText)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(index.isMultiple(of: 2) ? MacColor.groupFill : Color(white: 0.5, opacity: 0.001))
                    }
                }
                .cornerRadius(8)
                .background(
                    ZStack {
                        RoundedRectangle(cornerRadius: 8).fill(MacColor.groupFill)
                        RoundedRectangle(cornerRadius: 8).stroke(MacColor.groupBorder)
                    }
                )
            }
        }
    }
}
