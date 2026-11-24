import Foundation
import PluginKit
import SwiftCrossUI

/// Modal sheet for pasting a playlist URL and subscribing via an installed playlist plug-in (`SUB-1`).
struct NewSubscriptionSheet: View {
    private struct PendingConsent {
        let plugin: DiscoveredPlugin
        let consent: PluginConsentType?
        let title: String
        let message: String
    }

    @Binding var isPresented: Bool
    @Binding var urlText: String
    var pluginRevision: Int = 0
    var onNoDownloadSource: (() -> Void)? = nil

    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var pendingConsent: PendingConsent?

    private var match: (url: URL, plugin: DiscoveredPlugin?)? {
        let _ = pluginRevision
        return SubscriptionController.shared.matchSource(for: urlText)
    }

    private var activeConsent: PendingConsent? {
        guard let pendingConsent,
              pendingConsent.plugin.id == match?.plugin?.id else {
            return nil
        }
        return pendingConsent
    }

    var body: some View {
        let _ = pluginRevision
        VStack(alignment: .leading, spacing: 14) {
            Text("New Playlist Subscription")
                .font(.system(size: 16, weight: .semibold))

            Text("Paste a playlist URL from a supported source plug-in (for example Spotify).")
                .font(.system(size: 12))
                .foregroundColor(MacColor.secondaryText)

            TextField("https://open.spotify.com/playlist/…", text: $urlText)
                .frame(maxWidth: .infinity)

            statusRow

            if let activeConsent {
                VStack(alignment: .leading, spacing: 8) {
                    Text(activeConsent.title)
                        .font(.system(size: 13, weight: .semibold))
                    Text(activeConsent.message)
                        .font(.system(size: 12))
                        .foregroundColor(MacColor.secondaryText)
                    HStack(spacing: 10) {
                        Spacer()
                        Button("Back") {
                            pendingConsent = nil
                        }
                        .disabled(isSubmitting)
                        Button("Enable & Subscribe") {
                            let plugin = activeConsent.plugin
                            let consent = activeConsent.consent
                            PluginController.shared.enableWithConsent(pluginID: plugin.id, consent: consent)
                            pendingConsent = nil
                            Task { await runSubscribe(plugin: plugin) }
                        }
                        .disabled(isSubmitting)
                    }
                }
                .padding(10)
                .background(Color(red: 0.5, green: 0.5, blue: 0.5, opacity: 0.10))
                .cornerRadius(8)
            }

            if let errorMessage, !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundColor(Color(red: 0.85, green: 0.25, blue: 0.20))
            }

            HStack(spacing: 10) {
                Button("Plug-in Settings…") {
                    isPresented = false
                    AppCommands.openSettings?()
                }
                .disabled(isSubmitting)

                Spacer()

                Button("Cancel") {
                    pendingConsent = nil
                    errorMessage = nil
                    isPresented = false
                }
                .disabled(isSubmitting)

                if isSubmitting {
                    ProgressView()
                }

                Button("Subscribe") {
                    submit()
                }
                .disabled(isSubmitting || match?.plugin == nil || activeConsent != nil)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    @ViewBuilder
    private var statusRow: some View {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            Text("Waiting for a playlist URL…")
                .font(.system(size: 12))
                .foregroundColor(MacColor.secondaryText)
        } else if let m = match, let plugin = m.plugin {
            let enabled = PluginController.shared.isEnabled(plugin.id)
            HStack(spacing: 8) {
                PluginBadgeView(badge: plugin.badgeSVG, size: 18)
                Text(enabled
                    ? "Will subscribe using \(plugin.name)"
                    : "Will enable \(plugin.name) and subscribe")
                    .font(.system(size: 12))
                    .foregroundColor(MacColor.secondaryText)
            }
        } else {
            HStack(spacing: 8) {
                Text("No installed plug-in supports this URL.")
                    .font(.system(size: 12))
                    .foregroundColor(MacColor.secondaryText)
            }
        }
    }

    private func submit() {
        guard let m = match, let plugin = m.plugin else {
            errorMessage = "Enter a URL supported by an installed playlist plug-in."
            return
        }
        errorMessage = nil
        if !plugin.isEnabledEligible {
            errorMessage = "\(plugin.name) is unavailable on this platform."
            return
        }
        if !PluginController.shared.isEnabled(plugin.id) {
            let consent = PluginController.shared.needsConsent(for: plugin)
            let title = consent?.alertTitle(pluginName: plugin.name) ?? "Enable \(plugin.name)?"
            let detail = consent?.alertMessage(pluginName: plugin.name, serviceName: plugin.manifest?.serviceName)
                ?? "\(plugin.name) needs to be enabled to subscribe to playlists from this URL."
            pendingConsent = PendingConsent(
                plugin: plugin,
                consent: consent,
                title: title,
                message: detail
            )
            return
        }
        Task { await runSubscribe(plugin: plugin) }
    }

    private func runSubscribe(plugin: DiscoveredPlugin) async {
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            _ = try await SubscriptionController.shared.subscribe(urlString: urlText, plugin: plugin)
            let resolvers = PluginController.shared.enabledResolvers
            pendingConsent = nil
            errorMessage = nil
            isPresented = false
            if resolvers.isEmpty {
                onNoDownloadSource?()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Modal sheet to create a new playlist directly on Spotify and subscribe to it in the app.
struct NewSpotifyPlaylistSheet: View {
    @Binding var isPresented: Bool
    var pluginRevision: Int = 0

    @State private var nameText = ""
    @State private var descriptionText = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    private var spotifyPlugin: DiscoveredPlugin? {
        let _ = pluginRevision
        return PluginController.shared.plugins.first(where: { $0.id == "spotify" && !$0.overriddenByUnpacked })
    }

    private var isSignedIn: Bool {
        let _ = pluginRevision
        if case .signedIn = PluginController.shared.accountStates["spotify"]?.phase {
            return true
        }
        return false
    }

    var body: some View {
        let _ = pluginRevision
        VStack(alignment: .leading, spacing: 14) {
            Text("New Spotify Playlist")
                .font(.system(size: 16, weight: .semibold))

            Text("Creates a new playlist on your Spotify account and links it here.")
                .font(.system(size: 12))
                .foregroundColor(MacColor.secondaryText)

            TextField("Playlist name", text: $nameText)
                .frame(maxWidth: .infinity)

            TextField("Optional description", text: $descriptionText)
                .frame(maxWidth: .infinity)

            if !isSignedIn {
                HStack(spacing: 8) {
                    Symbol(
                        name: "exclamationmark.triangle.fill",
                        size: 14,
                        pointSize: 12,
                        tint: .color(SystemColor(light: 0xB87300, dark: 0xF5B82E))
                    )
                    Text("Sign in to your Spotify account in Plug-in Settings first.")
                        .font(.system(size: 12))
                        .foregroundColor(MacColor.secondaryText)
                }
            }

            if let errorMessage, !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundColor(Color(red: 0.85, green: 0.25, blue: 0.20))
            }

            HStack(spacing: 10) {
                Button("Plug-in Settings…") {
                    isPresented = false
                    AppCommands.openSettings?()
                }
                .disabled(isSubmitting)

                Spacer()

                Button("Cancel") {
                    errorMessage = nil
                    isPresented = false
                }
                .disabled(isSubmitting)

                if isSubmitting {
                    ProgressView()
                }

                Button("Create") {
                    submit()
                }
                .disabled(isSubmitting || spotifyPlugin == nil || nameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func submit() {
        let trimmed = nameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Enter a playlist name."
            return
        }
        guard let plugin = spotifyPlugin else {
            errorMessage = "Spotify plug-in is not installed."
            return
        }
        if !PluginController.shared.isEnabled(plugin.id) {
            PluginController.shared.enableWithConsent(
                pluginID: plugin.id,
                consent: PluginController.shared.needsConsent(for: plugin)
            )
        }
        errorMessage = nil
        isSubmitting = true
        let desc = descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            defer { isSubmitting = false }
            do {
                _ = try await SubscriptionController.shared.createUpstreamPlaylist(
                    name: trimmed,
                    description: desc.isEmpty ? nil : desc,
                    pluginID: "spotify"
                )
                isPresented = false
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
