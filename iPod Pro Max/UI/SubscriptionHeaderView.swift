import Foundation
import MediaKit
import PluginKit
import SwiftCrossUI

/// Header bar above the track list for a subscribed playlist (`SUB-5`).
struct SubscriptionHeaderView: View {
    var playlistID: String
    var revision: Int
    var onAddFromLibrary: (() -> Void)? = nil

    private var controller: SubscriptionController { .shared }
    private var sub: SubscriptionEntry? { controller.subscription(forPlaylistID: playlistID) }
    private var badgeData: ParsedSVGBadge? {
        guard let sub else { return nil }
        return PluginController.shared.plugins.first(where: { $0.id == sub.sourcePluginID })?.badgeSVG
    }

    var body: some View {
        let _ = revision
        if let sub {
            let syncing = controller.syncingSubIDs.contains(sub.id)
            let stats = controller.activeDownloadStats[sub.id]
            let availableCount = sub.tracks.filter { $0.libraryTrackID != nil }.count
            let totalCount = sub.tracks.count

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Cover(url: controller.artworkURL(for: sub), size: 56, symbol: "music.note")

                    VStack(alignment: .leading, spacing: 3) {
                        Text(sub.title)
                            .font(.system(size: 16, weight: .semibold))
                            .lineLimit(1)

                        HStack(spacing: 6) {
                            PluginBadgeView(badge: badgeData, size: 14)
                            Text(subtitleText(sub: sub, syncing: syncing, stats: stats, available: availableCount, total: totalCount))
                                .font(.system(size: 12))
                                .foregroundColor(MacColor.secondaryText)
                                .lineLimit(1)
                        }
                    }

                    Spacer()

                    if let onAddFromLibrary {
                        Button("Add Songs…") {
                            onAddFromLibrary()
                        }
                        .disabled(syncing)
                    }

                    if syncing {
                        ProgressView()
                        Button("Stop") {
                            controller.stop(playlistID: playlistID)
                        }
                    } else {
                        Button("Refresh") {
                            controller.refresh(playlistID: playlistID)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                if let errorText = sub.lastError, !errorText.isEmpty {
                    bannerBar(
                        message: errorText,
                        actionLabel: errorText.localizedCaseInsensitiveContains("sign in") ? "Plug-in Settings…" : nil,
                        onAction: { AppCommands.openSettings?() },
                        onDismiss: { controller.dismissError(for: sub.id) }
                    )
                } else if let fallback = controller.downloadFallbackBanner, !fallback.isEmpty {
                    bannerBar(
                        message: fallback,
                        actionLabel: nil,
                        onAction: nil,
                        onDismiss: nil
                    )
                }
            }
        }
    }

    private func subtitleText(
        sub: SubscriptionEntry,
        syncing: Bool,
        stats: (active: Int, total: Int)?,
        available: Int,
        total: Int
    ) -> String {
        let ownerName = sub.owner?.trimmingCharacters(in: .whitespacesAndNewlines)
        let ownerPart = (ownerName?.isEmpty == false) ? "by \(ownerName!)" : nil
        let prefix = (sub.lastError?.localizedCaseInsensitiveContains("offline") == true) ? "Offline" : sub.sourceName

        if syncing {
            if let stats, stats.total > 0 {
                let current = min(stats.active + 1, stats.total)
                return [prefix, ownerPart, "Downloading \(current) of \(stats.total)…"].compactMap { $0 }.joined(separator: " · ")
            }
            return [prefix, ownerPart, "Updating…"].compactMap { $0 }.joined(separator: " · ")
        }

        let updatedPart = sub.lastSyncedAt.map { "Updated \(relativeDateString($0))" } ?? "Not synced yet"
        let countPart = "\(available) of \(total) song\(total == 1 ? "" : "s") available"
        return [prefix, ownerPart, updatedPart, countPart].compactMap { $0 }.joined(separator: " · ")
    }

    private func relativeDateString(_ date: Date) -> String {
        let elapsed = max(0, Int(Date().timeIntervalSince(date)))
        if elapsed < 45 { return "just now" }
        if elapsed < 3600 {
            let mins = max(1, elapsed / 60)
            return "\(mins) min ago"
        }
        if elapsed < 86400 {
            let hrs = elapsed / 3600
            return "\(hrs) hr\(hrs == 1 ? "" : "s") ago"
        }
        let days = elapsed / 86400
        return "\(days) day\(days == 1 ? "" : "s") ago"
    }

    private func bannerBar(
        message: String,
        actionLabel: String?,
        onAction: (() -> Void)?,
        onDismiss: (() -> Void)?
    ) -> some View {
        HStack(spacing: 10) {
            Symbol(
                name: "exclamationmark.triangle.fill",
                size: 14,
                pointSize: 12,
                tint: .color(SystemColor(light: 0xB87300, dark: 0xF5B82E))
            )
            Text(message)
                .font(.system(size: 12))
                .foregroundColor(Color(red: 0.72, green: 0.45, blue: 0.0))
                .lineLimit(2)
            Spacer()
            if let actionLabel, let onAction {
                Button(actionLabel) { onAction() }
            }
            if let onDismiss {
                Button("Dismiss") { onDismiss() }
                    .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(Color(red: 0.96, green: 0.76, blue: 0.16, opacity: 0.16))
    }
}

/// Sheet letting the user search their personal music library and add tracks upstream to a subscribed playlist.
struct AddLibrarySongsSheet: View {
    var playlistTitle: String
    var sourceName: String
    var libraryRows: [TrackRow]
    var existingLibraryIDs: Set<String>
    var onAdd: ([String]) -> Void
    var onClose: () -> Void

    @State private var query = ""
    @State private var selectedIDs: Set<String> = []

    private var filteredRows: [TrackRow] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let available = libraryRows.filter { !existingLibraryIDs.contains($0.id) }
        guard !q.isEmpty else { return Array(available.prefix(120)) }
        let matched = available.filter { row in
            row.title.localizedCaseInsensitiveContains(q)
                || row.artist.localizedCaseInsensitiveContains(q)
                || row.album.localizedCaseInsensitiveContains(q)
        }
        return Array(matched.prefix(120))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Library Songs to \(playlistTitle)")
                .font(.system(size: 16, weight: .semibold))

            Text("Selected songs will be searched on \(sourceName) and added to this playlist (only playlists that you own can be modified on Spotify).")
                .font(.system(size: 12))
                .foregroundColor(MacColor.secondaryText)

            TextField("Filter your library by title, artist, or album…", text: $query)
                .frame(maxWidth: .infinity)

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if filteredRows.isEmpty {
                        Text(libraryRows.isEmpty ? "No songs in your library yet." : "No matching songs available to add.")
                            .font(.system(size: 12))
                            .foregroundColor(MacColor.secondaryText)
                            .padding(.vertical, 20)
                    } else {
                        ForEach(filteredRows, id: \.id) { row in
                            let chosen = selectedIDs.contains(row.id)
                            HStack(spacing: 10) {
                                Symbol(
                                    name: chosen ? "checkmark.circle.fill" : "plus",
                                    size: 14,
                                    pointSize: 13,
                                    tint: chosen ? .accent : .secondary
                                )
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(row.title)
                                        .font(.system(size: 12, weight: .medium))
                                        .lineLimit(1)
                                    let subtitle = [row.artist, row.album].filter { !$0.isEmpty }.joined(separator: " — ")
                                    if !subtitle.isEmpty {
                                        Text(subtitle)
                                            .font(.system(size: 11))
                                            .foregroundColor(MacColor.secondaryText)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer()
                                if !row.duration.isEmpty {
                                    Text(row.duration)
                                        .font(.system(size: 11))
                                        .foregroundColor(MacColor.secondaryText)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color(white: 1, opacity: chosen ? 0.12 : 0.03)))
                            .onTapGesture {
                                if chosen {
                                    selectedIDs.remove(row.id)
                                } else {
                                    selectedIDs.insert(row.id)
                                }
                            }
                        }
                    }
                }
            }
            .frame(minHeight: 240, maxHeight: 340)

            HStack {
                Text(selectedIDs.isEmpty ? "Click songs to select" : "\(selectedIDs.count) selected")
                    .font(.system(size: 11))
                    .foregroundColor(MacColor.secondaryText)
                Spacer()
                Button("Cancel") { onClose() }
                Button("Search & Add") {
                    let chosenOrder = libraryRows.map(\.id).filter { selectedIDs.contains($0) }
                    onAdd(chosenOrder)
                    onClose()
                }
                .disabled(selectedIDs.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
