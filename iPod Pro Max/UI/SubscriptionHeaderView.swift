import Foundation
import MediaKit
import PluginKit
import SwiftCrossUI

/// Header bar above the track list for a subscribed playlist (`SUB-5`).
struct SubscriptionHeaderView: View {
    var playlistID: String
    var revision: Int
    var onChangeCover: (() -> Void)? = nil

    @State private var coverHovered = false

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
                    ZStack(alignment: .bottomTrailing) {
                        Cover(url: controller.artworkURL(for: sub), size: 56, symbol: "music.note")
                        if coverHovered, !syncing, onChangeCover != nil {
                            RoundedRectangle(cornerRadius: 7)
                                .fill(Color(white: 0, opacity: 0.45))
                                .frame(width: 56, height: 56)
                            Symbol(name: "photo.badge.plus", size: 18, pointSize: 13, tint: .color(SystemColor(light: 0xFFFFFF, dark: 0xFFFFFF)))
                                .padding(5)
                        }
                    }
                    .onHover { inside in coverHovered = inside }
                    .onTapGesture {
                        if !syncing { onChangeCover?() }
                    }
                    .help(syncing ? "Sync in progress" : "Click to change cover (1:1 JPEG, min 300×300 px)")

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

                    if syncing {
                        ProgressView()
                        Button("Stop") {
                            controller.stop(playlistID: playlistID)
                        }
                    } else {
                        Button(action: { controller.refresh(playlistID: playlistID) }) {
                            Symbol(name: "arrow.clockwise", size: 22, pointSize: 14, tint: .secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Refresh Playlist")
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
