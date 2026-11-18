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
