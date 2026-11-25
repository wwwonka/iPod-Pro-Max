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

            Text("Paste a playlist URL from a supported source plug-in (for example Spotify or YouTube Music).")
                .font(.system(size: 12))
                .foregroundColor(MacColor.secondaryText)

            TextField("https://open.spotify.com/playlist/… or music.youtube.com/…", text: $urlText)
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
                Button("Browse My Playlists…") {
                    pendingConsent = nil
                    errorMessage = nil
                    isPresented = false
                    AppCommands.importRemotePlaylists?()
                }
                .disabled(isSubmitting)

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

/// Modal sheet to create a new playlist directly on a supported remote service (`spotify` / `youtube-music`)
/// and subscribe to it in the app.
struct NewRemotePlaylistSheet: View {
    @Binding var isPresented: Bool
    var pluginID: String
    var serviceName: String
    var pluginRevision: Int = 0

    @State private var nameText = ""
    @State private var descriptionText = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    private var targetPlugin: DiscoveredPlugin? {
        let _ = pluginRevision
        return PluginController.shared.plugins.first(where: { $0.id == pluginID && !$0.overriddenByUnpacked })
    }

    private var isSignedIn: Bool {
        let _ = pluginRevision
        if case .signedIn = PluginController.shared.accountStates[pluginID]?.phase {
            return true
        }
        return false
    }

    var body: some View {
        let _ = pluginRevision
        VStack(alignment: .leading, spacing: 14) {
            Text("New \(serviceName) Playlist")
                .font(.system(size: 16, weight: .semibold))

            Text("Creates a new playlist on your \(serviceName) account and links it here.")
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
                    Text("Sign in to your \(serviceName) account in Plug-in Settings first.")
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
                .disabled(isSubmitting || targetPlugin == nil || nameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
        guard let plugin = targetPlugin else {
            errorMessage = "\(serviceName) plug-in is not installed."
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
                    pluginID: pluginID
                )
                isPresented = false
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// Modal sheet to browse and multi-import existing playlists from signed-in music plug-ins without copying URLs.
struct ImportRemotePlaylistsSheet: View {
    @Binding var isPresented: Bool
    var pluginRevision: Int = 0
    var subscriptionRevision: Int = 0
    var onNoDownloadSource: (() -> Void)? = nil

    @State private var selectedPluginID = ""
    @State private var playlistsByPlugin: [String: [RemotePlaylistSummary]] = SubscriptionController.shared.cachedUserPlaylistsByPlugin
    @State private var selectedIDs: Set<String> = []
    @State private var searchQuery = ""
    @State private var markLikedAsFavorites = true
    @State private var loadingPluginIDs: Set<String> = []
    @State private var lastLoadedTokenByPlugin: [String: Int] = [:]
    @State private var isImporting = false
    @State private var needsAuthByPlugin: Set<String> = []
    @State private var errorMessage: String?
    @State private var reloadToken = 0

    private var availablePlugins: [DiscoveredPlugin] {
        let _ = pluginRevision
        return PluginController.shared.plugins.filter { plugin in
            !plugin.overriddenByUnpacked
                && plugin.isEnabledEligible
                && (plugin.manifest?.knownRoles.contains(.playlistSource) ?? false)
                && (plugin.manifest?.settings?.contains(where: { $0.type == .account }) ?? false)
        }
    }

    private var activePlugin: DiscoveredPlugin? {
        if let match = availablePlugins.first(where: { $0.id == selectedPluginID }) {
            return match
        }
        // Prefer an enabled + signed-in service when opening the sheet for the first time.
        if let signedIn = availablePlugins.first(where: { plugin in
            PluginController.shared.isEnabled(plugin.id) && isSignedIn(pluginID: plugin.id)
        }) {
            return signedIn
        }
        return availablePlugins.first
    }

    private var activeServiceName: String {
        activePlugin?.manifest?.serviceName ?? activePlugin?.name ?? "Account"
    }

    private var isActiveEnabled: Bool {
        guard let plugin = activePlugin else { return false }
        let _ = pluginRevision
        return PluginController.shared.isEnabled(plugin.id)
    }

    private var isActiveSignedIn: Bool {
        guard let plugin = activePlugin else { return false }
        let _ = pluginRevision
        return isSignedIn(pluginID: plugin.id)
    }

    private var subscribedIDs: Set<String> {
        let _ = subscriptionRevision
        guard let plugin = activePlugin else { return [] }
        return SubscriptionController.shared.subscribedSourcePlaylistIDs(for: plugin.id)
    }

    private var playlists: [RemotePlaylistSummary] {
        guard let pid = activePlugin?.id else { return [] }
        return playlistsByPlugin[pid] ?? SubscriptionController.shared.cachedUserPlaylistsByPlugin[pid] ?? []
    }

    private var hasCachedPlaylistsForActive: Bool {
        guard let pid = activePlugin?.id else { return false }
        return playlistsByPlugin[pid] != nil || SubscriptionController.shared.cachedUserPlaylistsByPlugin[pid] != nil
    }

    private var isLoading: Bool {
        guard let pid = activePlugin?.id else { return false }
        return loadingPluginIDs.contains(pid)
    }

    private var needsAuth: Bool {
        guard let pid = activePlugin?.id else { return false }
        return needsAuthByPlugin.contains(pid)
    }

    private var hasLikedSongsVisibleOrSelected: Bool {
        filteredPlaylists.contains(where: \.isLikedSongs)
            || playlists.contains(where: { $0.isLikedSongs && selectedIDs.contains($0.id) })
    }

    private var filteredPlaylists: [RemotePlaylistSummary] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return playlists }
        return playlists.filter { item in
            item.title.localizedCaseInsensitiveContains(query)
                || (item.owner?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private var importableFilteredIDs: [String] {
        let existing = subscribedIDs
        return filteredPlaylists.map(\.id).filter { !existing.contains($0) }
    }

    private var allFilteredSelected: Bool {
        let candidates = importableFilteredIDs
        return !candidates.isEmpty && candidates.allSatisfy { selectedIDs.contains($0) }
    }

    private var importableSelectionCount: Int {
        let existing = subscribedIDs
        return playlists.filter { selectedIDs.contains($0.id) && !existing.contains($0.id) }.count
    }

    private var accountPhaseState: String {
        guard let plugin = activePlugin else { return "signedOut" }
        let _ = pluginRevision
        switch PluginController.shared.accountStates[plugin.id]?.phase {
        case .signedIn: return "signedIn"
        case .signingIn, .waitingForBrowser: return "signingIn"
        case .signedOut, nil: return "signedOut"
        }
    }

    private var taskKey: String {
        "\(activePlugin?.id ?? "none")-\(isActiveEnabled)-\(accountPhaseState)-\(reloadToken)"
    }

    var body: some View {
        let _ = pluginRevision
        let _ = subscriptionRevision
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Import Playlists from Account")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Choose playlists from your signed-in music accounts to subscribe without copying URLs.")
                        .font(.system(size: 12))
                        .foregroundColor(MacColor.secondaryText)
                }
                Spacer()
                if isLoading && !playlists.isEmpty {
                    ProgressView()
                }
                Button("Refresh") {
                    reloadToken += 1
                }
                .disabled(isLoading || isImporting || activePlugin == nil || !isActiveEnabled)
            }

            if !availablePlugins.isEmpty {
                HStack(spacing: 8) {
                    ForEach(availablePlugins, id: \.id) { plugin in
                        let selected = plugin.id == activePlugin?.id
                        Button {
                            guard selectedPluginID != plugin.id else { return }
                            selectedPluginID = plugin.id
                            errorMessage = nil
                        } label: {
                            HStack(spacing: 6) {
                                PluginBadgeView(badge: plugin.badgeSVG, size: 15)
                                Text(plugin.manifest?.serviceName ?? plugin.name)
                                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(selected
                                ? Color(red: 0.25, green: 0.50, blue: 0.95, opacity: 0.18)
                                : Color(red: 0.5, green: 0.5, blue: 0.5, opacity: 0.10))
                            .cornerRadius(6)
                        }
                        .buttonStyle(.borderless)
                        .disabled(isImporting)
                    }
                    Spacer()
                }
            }

            TextField("Filter playlists…", text: $searchQuery)
                .frame(maxWidth: .infinity)
                .disabled(isImporting)

            contentArea
                .frame(height: 290)
                .frame(maxWidth: .infinity)
                .background(Color(red: 0.5, green: 0.5, blue: 0.5, opacity: 0.08))
                .cornerRadius(8)

            if hasLikedSongsVisibleOrSelected {
                HStack(spacing: 8) {
                    Toggle("Also add Liked Songs tracks to Favorites", isOn: $markLikedAsFavorites)
                        .disabled(isImporting)
                    Spacer()
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
                .disabled(isImporting)

                if !importableFilteredIDs.isEmpty {
                    Button(allFilteredSelected ? "Clear Selection" : "Select All") {
                        toggleSelectAll()
                    }
                    .disabled(isImporting || isLoading)
                }

                Spacer()

                Button("Cancel") {
                    isPresented = false
                }
                .disabled(isImporting)

                if isImporting {
                    ProgressView()
                }

                let count = importableSelectionCount
                Button(count > 0 ? "Import (\(count))" : "Import") {
                    Task { await runImport() }
                }
                .disabled(isImporting || isLoading || count == 0 || activePlugin == nil)
            }
        }
        .padding(20)
        .frame(width: 520)
        .task(id: taskKey) {
            await loadPlaylists()
        }
    }

    @ViewBuilder
    private var contentArea: some View {
        if availablePlugins.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Text("No account-capable playlist plug-ins are installed.")
                    .font(.system(size: 13, weight: .medium))
                Text("Install a playlist plug-in (such as Spotify or YouTube Music) in Settings › Plug-ins.")
                    .font(.system(size: 12))
                    .foregroundColor(MacColor.secondaryText)
                Spacer()
            }
            .padding(16)
        } else if let plugin = activePlugin, !isActiveEnabled {
            VStack(spacing: 10) {
                Spacer()
                Text("\(plugin.name) plug-in is currently disabled.")
                    .font(.system(size: 13, weight: .medium))
                if let msg = PluginController.shared.needsConsent(for: plugin)?.alertMessage(pluginName: plugin.name, serviceName: activeServiceName) {
                    Text(msg)
                        .font(.system(size: 12))
                        .foregroundColor(MacColor.secondaryText)
                }
                Button("Enable \(plugin.name)") {
                    PluginController.shared.enableWithConsent(
                        pluginID: plugin.id,
                        consent: PluginController.shared.needsConsent(for: plugin)
                    )
                    reloadToken += 1
                }
                Spacer()
            }
            .padding(16)
        } else if isLoading && playlists.isEmpty {
            VStack(spacing: 10) {
                Spacer()
                ProgressView()
                Text("Loading your \(activeServiceName) playlists…")
                    .font(.system(size: 12))
                    .foregroundColor(MacColor.secondaryText)
                Spacer()
            }
            .padding(16)
        } else if needsAuth, let plugin = activePlugin {
            let accState = PluginController.shared.accountStates[plugin.id]
            let authInFlight: Bool = {
                switch accState?.phase {
                case .signingIn, .waitingForBrowser: return true
                default: return false
                }
            }()
            VStack(spacing: 10) {
                Spacer()
                if authInFlight {
                    ProgressView()
                    Text("Complete sign in to \(activeServiceName) in the login window…")
                        .font(.system(size: 13, weight: .medium))
                    Button("Cancel Sign In") {
                        PluginController.shared.cancelSignIn(pluginID: plugin.id)
                    }
                } else {
                    Symbol(
                        name: "person.crop.circle.badge.exclamationmark",
                        size: 24,
                        pointSize: 20,
                        tint: .color(SystemColor(light: 0xB87300, dark: 0xF5B82E))
                    )
                    Text("Sign in to \(activeServiceName) to list your playlists.")
                        .font(.system(size: 13, weight: .medium))
                    Text("After signing in, your playlists will appear here automatically.")
                        .font(.system(size: 12))
                        .foregroundColor(MacColor.secondaryText)
                    if let signInErr = accState?.errorMessage, !signInErr.isEmpty {
                        Text(signInErr)
                            .font(.system(size: 11))
                            .foregroundColor(Color(red: 0.85, green: 0.25, blue: 0.20))
                    }
                    HStack(spacing: 10) {
                        if let accountSetting = plugin.manifest?.settings?.first(where: { $0.type == .account }) {
                            Button("Sign In to \(activeServiceName)…") {
                                PluginController.shared.signIn(pluginID: plugin.id, setting: accountSetting)
                            }
                            if (plugin.id == "spotify" || plugin.id == "youtube-music") && BrowserCookieImporter.isSupportedOnPlatform {
                                Button("Import from Browser…") {
                                    PluginController.shared.importAccountFromBrowser(pluginID: plugin.id, setting: accountSetting)
                                }
                            }
                        }
                        Button("Plug-in Settings…") {
                            isPresented = false
                            AppCommands.openSettings?()
                        }
                    }
                    if PluginController.shared.browserImportPluginID == plugin.id && !PluginController.shared.browserImportChoices.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Multiple browser sessions found — choose one:")
                                .font(.system(size: 11))
                                .foregroundColor(MacColor.secondaryText)
                            ForEach(PluginController.shared.browserImportChoices) { candidate in
                                HStack(spacing: 8) {
                                    Text(candidate.displayTitle)
                                        .font(.system(size: 12))
                                    Button("Use") {
                                        PluginController.shared.selectBrowserImportCandidate(candidate)
                                    }
                                }
                            }
                        }
                        .padding(.top, 4)
                    }
                }
                Spacer()
            }
            .padding(16)
        } else if filteredPlaylists.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Text(playlists.isEmpty
                    ? "No playlists found in your \(activeServiceName) account."
                    : "No playlists match your filter.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(MacColor.secondaryText)
                Spacer()
            }
            .padding(16)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(filteredPlaylists, id: \.id) { item in
                        playlistRow(item)
                    }
                }
                .padding(8)
            }
        }
    }

    @ViewBuilder
    private func playlistRow(_ item: RemotePlaylistSummary) -> some View {
        let alreadySubscribed = subscribedIDs.contains(item.id)
        let isSelected = selectedIDs.contains(item.id)
        HStack(spacing: 10) {
            if alreadySubscribed {
                Symbol(
                    name: "checkmark.circle.fill",
                    size: 16,
                    pointSize: 13,
                    tint: .color(SystemColor(light: 0x1D8348, dark: 0x58D68D))
                )
            } else {
                Toggle(
                    "",
                    isOn: Binding(
                        get: { isSelected },
                        set: { checked in
                            if checked {
                                selectedIDs.insert(item.id)
                            } else {
                                selectedIDs.remove(item.id)
                            }
                        }
                    )
                )
                .disabled(isImporting)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 13, weight: .medium))
                if let subtitle = subtitleText(for: item, alreadySubscribed: alreadySubscribed) {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(MacColor.secondaryText)
                }
            }

            Spacer()

            if !alreadySubscribed {
                Button(isSelected ? "Selected" : "Select") {
                    if isSelected {
                        selectedIDs.remove(item.id)
                    } else {
                        selectedIDs.insert(item.id)
                    }
                }
                .buttonStyle(.borderless)
                .disabled(isImporting)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isSelected && !alreadySubscribed
            ? Color(red: 0.25, green: 0.50, blue: 0.95, opacity: 0.12)
            : Color.clear)
        .cornerRadius(6)
    }

    private func subtitleText(for item: RemotePlaylistSummary, alreadySubscribed: Bool) -> String? {
        var parts: [String] = []
        if item.isLikedSongs {
            parts.append("Liked Songs")
        } else if item.isOwned == true {
            parts.append("By you")
        } else if let owner = item.owner?.trimmingCharacters(in: .whitespacesAndNewlines), !owner.isEmpty {
            parts.append(owner)
        }
        if let count = item.trackCount {
            parts.append(count == 1 ? "1 song" : "\(count) songs")
        }
        if alreadySubscribed {
            parts.append("Already in library")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }

    private func isSignedIn(pluginID: String) -> Bool {
        if case .signedIn = PluginController.shared.accountStates[pluginID]?.phase {
            return true
        }
        return false
    }

    private func toggleSelectAll() {
        let candidates = importableFilteredIDs
        if allFilteredSelected {
            for id in candidates { selectedIDs.remove(id) }
        } else {
            for id in candidates { selectedIDs.insert(id) }
        }
    }

    private func loadPlaylists() async {
        guard let plugin = activePlugin else { return }
        if selectedPluginID != plugin.id {
            selectedPluginID = plugin.id
        }
        guard PluginController.shared.isEnabled(plugin.id) else {
            needsAuthByPlugin.remove(plugin.id)
            return
        }
        // Do not start or interrupt playlist fetching while an interactive sign-in flow is active.
        if accountPhaseState == "signingIn" {
            loadingPluginIDs.remove(plugin.id)
            needsAuthByPlugin.insert(plugin.id)
            return
        }

        let explicitRefresh = (reloadToken > 0 && lastLoadedTokenByPlugin[plugin.id] != reloadToken)
        // Skip network fetch when switching back to a tab that is already cached unless Refresh was requested
        // or the account just completed sign-in cleanly.
        if hasCachedPlaylistsForActive && !explicitRefresh && !needsAuthByPlugin.contains(plugin.id) {
            return
        }

        loadingPluginIDs.insert(plugin.id)
        needsAuthByPlugin.remove(plugin.id)
        errorMessage = nil
        defer { loadingPluginIDs.remove(plugin.id) }

        do {
            let fetched = try await SubscriptionController.shared.fetchUserPlaylists(pluginID: plugin.id)
            guard !Task.isCancelled else { return }
            // In-place update preserves already-rendered rows & selections cleanly during refresh.
            if playlistsByPlugin[plugin.id] != fetched {
                playlistsByPlugin[plugin.id] = fetched
            }
            lastLoadedTokenByPlugin[plugin.id] = reloadToken
        } catch is CancellationError {
            return
        } catch let subErr as SubscriptionController.SubscribeError {
            guard !Task.isCancelled else { return }
            if case .unauthorized = subErr {
                needsAuthByPlugin.insert(plugin.id)
                playlistsByPlugin.removeValue(forKey: plugin.id)
            } else {
                errorMessage = subErr.localizedDescription
            }
        } catch {
            guard !Task.isCancelled else { return }
            if let pErr = error as? PluginError, pErr.code == .cancelled { return }
            errorMessage = error.localizedDescription
        }
    }

    private func runImport() async {
        guard let plugin = activePlugin else { return }
        let existing = subscribedIDs
        let chosen = playlists.filter { selectedIDs.contains($0.id) && !existing.contains($0.id) }
        guard !chosen.isEmpty else { return }

        isImporting = true
        errorMessage = nil
        defer { isImporting = false }

        do {
            let summary = try await SubscriptionController.shared.importUserPlaylists(
                chosen,
                plugin: plugin,
                markLikedAsFavorites: markLikedAsFavorites
            )
            selectedIDs.subtract(chosen.map(\.id))
            if summary.failed.isEmpty {
                let resolvers = PluginController.shared.enabledResolvers
                isPresented = false
                if summary.importedCount > 0 && resolvers.isEmpty {
                    onNoDownloadSource?()
                }
            } else if summary.importedCount > 0 {
                let failedNames = summary.failed.map(\.title).joined(separator: ", ")
                errorMessage = "Imported \(summary.importedCount) playlist(s). Could not import: \(failedNames) (\(summary.failed.first?.error ?? ""))."
            } else {
                errorMessage = summary.failed.first?.error ?? "Failed to import selected playlists."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
