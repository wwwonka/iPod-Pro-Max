import Foundation
import PluginKit
import SwiftCrossUI

/// Preferences → Plug-ins (`PLG-8`, `PLG-9`, `PLG-10`, `PLG-11`, `PLG-13`, `PLG-14`).
/// Compiles identically on macOS, Linux (GTK), and Windows (WinUI).
struct PluginsSettingsTabView: View {
    @Environment(\.chooseFile) private var chooseFile
    @Environment(\.presentAlert) private var presentAlert
    @Environment(\.openWindow) private var openWindow

    @State private var revision = 0
    @State private var revealedSecrets: Set<String> = []
    @State private var intDrafts: [String: String] = [:]

    private var controller: PluginController { .shared }
    private var hasLibrary: Bool { SettingsController.shared.hasLibrary }

    var body: some View {
        let _ = revision
        VStack(alignment: .leading, spacing: 22) {
            if controller.plugins.isEmpty {
                emptyState
            } else {
                ForEach(controller.plugins, id: \.id) { plugin in
                    pluginCard(plugin)
                }

                if !controller.enabledResolvers.isEmpty {
                    downloadSourcesCard
                }
            }

            downloadsCard
            footerSection
        }
        .task {
            controller.settingsPluginsTabActive = true
            controller.observe("plugins-tab") { revision += 1 }
            SubscriptionController.shared.observe("plugins-tab") { revision += 1 }
            ShareController.shared.observe("plugins-tab") { revision += 1 }
            controller.onPluginsTabOpened()
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 14) {
            Text("No plug-ins installed.")
                .foregroundColor(MacColor.secondaryText)
            Button("Install Plug-in…") { pickAndInstallPackage() }
                .disabled(!hasLibrary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 44)
        .padding(.bottom, 12)
    }

    // MARK: - Plug-in Card

    private func pluginCard(_ plugin: DiscoveredPlugin) -> some View {
        let enabled = controller.isEnabled(plugin.id) && plugin.isEnabledEligible
        let procState = controller.runtimeStates[plugin.id] ?? .stopped
        let statusUpdate = controller.runtimeStatuses[plugin.id]
        let isRunning = procState == .starting || procState == .running
        let errorMessage = cardErrorMessage(plugin: plugin, procState: procState, status: statusUpdate)
        let isUnavailable: Bool = {
            if case .unavailable = plugin.availability { return true }
            return false
        }()

        return card {
            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack(alignment: .top, spacing: 10) {
                    PluginBadgeView(badge: plugin.badgeSVG, size: 24)
                        .padding(.top, 2)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(plugin.name)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(isUnavailable || (!enabled && !plugin.overriddenByUnpacked) ? MacColor.secondaryText : Color.adaptive(light: .black, dark: .white))
                                .lineLimit(1)
                            if !plugin.version.isEmpty {
                                Text(plugin.version)
                                    .font(.system(size: 11))
                                    .foregroundColor(MacColor.secondaryText)
                            }
                            if plugin.isUnpacked {
                                Text("Unpacked")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(RoundedRectangle(cornerRadius: 4).fill(AppAccent.color))
                            }
                            if isRunning {
                                ProgressView()
                            }
                            if errorMessage != nil {
                                Text("●")
                                    .font(.system(size: 10))
                                    .foregroundColor(MacColor.red)
                            }
                        }

                        if let desc = plugin.manifest?.description, !desc.isEmpty {
                            Text(desc)
                                .font(.system(size: 11))
                                .foregroundColor(MacColor.secondaryText)
                                .lineLimit(1)
                        }

                        if let roles = plugin.manifest?.knownRoles, !roles.isEmpty {
                            roleBadgesRow(roles)
                                .padding(.top, 2)
                        }
                    }

                    Spacer()

                    Toggle(
                        "",
                        isOn: Binding(
                            get: { enabled },
                            set: { newValue in handleToggle(plugin: plugin, enable: newValue) }
                        )
                    )
                    .toggleStyle(.switch)
                    .disabled(!plugin.isEnabledEligible || !hasLibrary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

                // Notices & Errors
                if plugin.overriddenByUnpacked {
                    Divider()
                    Text("Overridden by unpacked plug-in")
                        .font(.system(size: 11))
                        .foregroundColor(MacColor.secondaryText)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                } else if case .unavailable(let reason) = plugin.availability {
                    Divider()
                    Text(reason)
                        .font(.system(size: 11))
                        .foregroundColor(MacColor.secondaryText)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                }

                if let errorMessage {
                    Divider()
                    HStack(spacing: 8) {
                        Text(errorMessage)
                            .font(.system(size: 11))
                            .foregroundColor(MacColor.red)
                            .lineLimit(1)
                        Spacer()
                        if case .error = procState {
                            Button("Restart") {
                                Task { await controller.restartPlugin(plugin.id) }
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                }

                // Runtime status text for share/connection when present
                if enabled, let statusMsg = statusUpdate?.message, !statusMsg.isEmpty, statusUpdate?.state != .error {
                    Divider()
                    Text(statusMsg)
                        .font(.system(size: 11))
                        .foregroundColor(MacColor.secondaryText)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                }

                // Share index status summary (SUB-17)
                if enabled, plugin.manifest?.knownRoles.contains(.share) == true {
                    Divider()
                    Text(ShareController.shared.shareStatusSummary)
                        .font(.system(size: 11))
                        .foregroundColor(MacColor.secondaryText)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                }

                // Body (manifest settings)
                if enabled, let manifest = plugin.manifest, let defs = manifest.settings, !defs.isEmpty {
                    let values = controller.settingsValues[plugin.id] ?? [:]
                    let pStore = controller.registry?.settingsStore(for: plugin.id)
                    let visibleDefs = defs.filter { pStore?.isVisible($0, values: values) ?? true }
                    if !visibleDefs.isEmpty {
                        ForEach(Array(visibleDefs.enumerated()), id: \.offset) { _, def in
                            Divider()
                            settingRow(plugin: plugin, definition: def, values: values)
                        }
                    }
                }

                // Card management / developer actions
                if plugin.isUnpacked || controller.developerMode || !plugin.isUnpacked {
                    Divider()
                    HStack(spacing: 10) {
                        if plugin.isUnpacked {
                            Button("Reload") { controller.reloadUnpackedPlugin(plugin) }
                            Button("Show Log") {
                                controller.openLogWindow(for: plugin.id)
                                openWindow(id: "plugin-log")
                            }
                            Spacer()
                            Button("Remove") { controller.removeUnpackedPlugin(plugin) }
                                .buttonStyle(.borderless)
                                .foregroundColor(MacColor.secondaryText)
                        } else {
                            if controller.developerMode {
                                Button("Show Log") {
                                    controller.openLogWindow(for: plugin.id)
                                    openWindow(id: "plugin-log")
                                }
                            }
                            Spacer()
                            Button("Remove Plug-in…") { promptRemoveInstalled(plugin) }
                                .buttonStyle(.borderless)
                                .foregroundColor(MacColor.secondaryText)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
            }
        }
    }

    private func cardErrorMessage(
        plugin: DiscoveredPlugin,
        procState: ExternalPluginProcessState,
        status: PluginStatusUpdate?
    ) -> String? {
        if case .error(let msg) = plugin.availability { return msg }
        if case .error(let msg) = procState { return msg }
        if status?.state == .error, let msg = status?.message, !msg.isEmpty { return msg }
        return nil
    }

    private func roleBadgesRow(_ roles: [PluginRole]) -> some View {
        // Wrap cleanly in chunks of 4 on narrow windows
        let rows = stride(from: 0, to: roles.count, by: 4).map {
            Array(roles[$0..<min($0 + 4, roles.count)])
        }
        return VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, rowRoles in
                HStack(spacing: 4) {
                    ForEach(rowRoles, id: \.self) { role in
                        Text(role.badgeLabel)
                            .font(.system(size: 10))
                            .foregroundColor(MacColor.secondaryText)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color(white: 0.5, opacity: 0.14)))
                    }
                }
            }
        }
    }

    // MARK: - Enable / Disable / Remove Alerts

    private func handleToggle(plugin: DiscoveredPlugin, enable: Bool) {
        if enable {
            if let consent = controller.needsConsent(for: plugin) {
                let title = consent.alertTitle(pluginName: plugin.name)
                let body = consent.alertMessage(pluginName: plugin.name, serviceName: plugin.manifest?.serviceName)
                Task {
                    await presentAlert("\(title)\n\n\(body)") {
                        Button("Enable") {
                            controller.enableWithConsent(pluginID: plugin.id, consent: consent)
                        }
                        Button("Cancel") {}
                    }
                }
            } else {
                controller.enableWithConsent(pluginID: plugin.id, consent: nil)
            }
        } else {
            Task {
                if await controller.isPluginInUse(plugin.id) {
                    await presentAlert("\(plugin.name) is in use. Disable it anyway?") {
                        Button("Disable") {
                            Task { await controller.disablePlugin(plugin.id) }
                        }
                        Button("Cancel") {}
                    }
                } else {
                    await controller.disablePlugin(plugin.id)
                }
            }
        }
    }

    private func promptRemoveInstalled(_ plugin: DiscoveredPlugin) {
        Task {
            await presentAlert("Remove “\(plugin.name)”?\n\nDo you also want to delete its settings and account data from this iPod?") {
                Button("Keep Settings") {
                    controller.uninstallPlugin(pluginID: plugin.id, deleteSettings: false)
                }
                Button("Delete Settings Too") {
                    controller.uninstallPlugin(pluginID: plugin.id, deleteSettings: true)
                }
                Button("Cancel") {}
            }
        }
    }

    // MARK: - Generic Manifest Setting Renderer (PLG-8)

    @ViewBuilder
    private func settingRow(
        plugin: DiscoveredPlugin,
        definition def: PluginSettingDefinition,
        values: [String: JSONValue]
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            switch def.type {
            case .bool:
                let current = values[def.key]?.boolValue ?? def.defaultValue?.boolValue ?? false
                HStack {
                    Text(def.label ?? def.key)
                    Spacer()
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { current },
                            set: { controller.updateSetting(pluginID: plugin.id, definition: def, value: .bool($0), immediate: true) }
                        )
                    )
                    .toggleStyle(.switch)
                }

            case .string:
                let current = values[def.key]?.stringValue ?? def.defaultValue?.stringValue ?? ""
                HStack(spacing: 8) {
                    Text(def.label ?? def.key)
                    Spacer()
                    TextField(
                        def.placeholder ?? "",
                        text: Binding(
                            get: { current },
                            set: { controller.updateSetting(pluginID: plugin.id, definition: def, value: .string($0), immediate: false) }
                        )
                    )
                    .frame(width: 220)
                }

            case .secret:
                let secretKey = "\(plugin.id)::\(def.key)"
                let revealed = revealedSecrets.contains(secretKey)
                let current = values[def.key]?.stringValue ?? ""
                let binding = Binding<String>(
                    get: { current },
                    set: { controller.updateSetting(pluginID: plugin.id, definition: def, value: .string($0), immediate: false) }
                )
                HStack(spacing: 8) {
                    Text(def.label ?? def.key)
                    Spacer()
                    if revealed {
                        TextField(def.placeholder ?? "", text: binding).frame(width: 185)
                    } else {
                        SecureField(def.placeholder ?? "", text: binding).frame(width: 185)
                    }
                    Button(revealed ? "Hide" : "Show") {
                        if revealed { revealedSecrets.remove(secretKey) }
                        else { revealedSecrets.insert(secretKey) }
                    }
                }

            case .int:
                let lo = def.min ?? Int.min
                let hi = def.max ?? Int.max
                let current = values[def.key]?.intValue ?? def.defaultValue?.intValue ?? max(0, lo)
                let draftKey = "\(plugin.id)::\(def.key)"
                let textBinding = Binding<String>(
                    get: { intDrafts[draftKey] ?? "\(current)" },
                    set: { raw in
                        intDrafts[draftKey] = raw
                        if let parsed = Int(raw.trimmingCharacters(in: .whitespaces)) {
                            let clamped = min(max(parsed, lo), hi)
                            controller.updateSetting(pluginID: plugin.id, definition: def, value: .int(clamped), immediate: false)
                        }
                    }
                )
                HStack(spacing: 6) {
                    Text(def.label ?? def.key)
                    Spacer()
                    TextField("", text: textBinding)
                        .onSubmit {
                            let parsed = Int((intDrafts[draftKey] ?? "\(current)").trimmingCharacters(in: .whitespaces)) ?? current
                            let clamped = min(max(parsed, lo), hi)
                            intDrafts.removeValue(forKey: draftKey)
                            controller.updateSetting(pluginID: plugin.id, definition: def, value: .int(clamped), immediate: true)
                        }
                        .frame(width: 64)
                    if let unit = def.unit, !unit.isEmpty {
                        Text(unit).font(.system(size: 11)).foregroundColor(MacColor.secondaryText)
                    }
                    Button("−") {
                        let next = min(max(current - 1, lo), hi)
                        intDrafts.removeValue(forKey: draftKey)
                        controller.updateSetting(pluginID: plugin.id, definition: def, value: .int(next), immediate: true)
                    }
                    Button("+") {
                        let next = min(max(current + 1, lo), hi)
                        intDrafts.removeValue(forKey: draftKey)
                        controller.updateSetting(pluginID: plugin.id, definition: def, value: .int(next), immediate: true)
                    }
                }

            case .enum:
                let options = (def.options ?? []).map { EnumChoice(value: $0.value, label: $0.label) }
                let currentVal = values[def.key]?.stringValue ?? def.defaultValue?.stringValue ?? options.first?.value
                let selected = options.first { $0.value == currentVal } ?? options.first
                HStack {
                    Text(def.label ?? def.key)
                    Spacer()
                    if !options.isEmpty {
                        Picker(
                            of: options,
                            selection: Binding(
                                get: { selected },
                                set: { next in
                                    guard let next else { return }
                                    controller.updateSetting(pluginID: plugin.id, definition: def, value: .string(next.value), immediate: true)
                                }
                            )
                        )
                    }
                }

            case .orderedList:
                let optionMap = Dictionary(uniqueKeysWithValues: (def.options ?? []).map { ($0.value, $0.label) })
                let currentOrder = values[def.key]?.stringArrayValue
                    ?? (def.options ?? []).map(\.value)
                VStack(alignment: .leading, spacing: 6) {
                    if let label = def.label {
                        Text(label).font(.system(size: 12, weight: .medium))
                    }
                    ForEach(Array(currentOrder.enumerated()), id: \.offset) { idx, itemKey in
                        HStack(spacing: 8) {
                            Text(optionMap[itemKey] ?? itemKey).font(.system(size: 12))
                            Spacer()
                            Button("↑") {
                                guard idx > 0 else { return }
                                var copy = currentOrder
                                copy.swapAt(idx, idx - 1)
                                controller.updateSetting(pluginID: plugin.id, definition: def, value: .array(copy.map { .string($0) }), immediate: true)
                            }
                            .disabled(idx == 0)
                            Button("↓") {
                                guard idx + 1 < currentOrder.count else { return }
                                var copy = currentOrder
                                copy.swapAt(idx, idx + 1)
                                controller.updateSetting(pluginID: plugin.id, definition: def, value: .array(copy.map { .string($0) }), immediate: true)
                            }
                            .disabled(idx + 1 >= currentOrder.count)
                        }
                    }
                }

            case .folder:
                let path = values[def.key]?.stringValue ?? ""
                let missing = controller.missingFolderKeys[plugin.id]?.contains(def.key) ?? false
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(def.label ?? def.key)
                        Text(path.isEmpty ? "Not set" : path)
                            .font(.system(size: 11))
                            .foregroundColor(missing ? MacColor.red : MacColor.secondaryText)
                            .lineLimit(1)
                        if missing {
                            Text("Folder not found")
                                .font(.system(size: 11))
                                .foregroundColor(MacColor.red)
                        }
                    }
                    Spacer()
                    if def.defaultValue != nil {
                        Button("Reset") {
                            controller.resetFolderSetting(pluginID: plugin.id, definition: def)
                        }
                    }
                    Button("Choose…") {
                        Task {
                            guard let folder = await chooseFile(
                                title: "Choose \(def.label ?? "Folder")",
                                defaultButtonLabel: "Choose",
                                allowSelectingFiles: false,
                                allowSelectingDirectories: true
                            ) else { return }
                            controller.updateSetting(pluginID: plugin.id, definition: def, value: .string(folder.path), immediate: true)
                        }
                    }
                }

            case .account:
                accountBlock(plugin: plugin, setting: def)

            case .action:
                let state = controller.actionStates["\(plugin.id)::\(def.key)"] ?? .init()
                HStack(spacing: 10) {
                    Button(def.label ?? def.key) {
                        controller.performAction(pluginID: plugin.id, key: def.key)
                    }
                    .disabled(state.running)
                    if state.running { ProgressView() }
                    if let msg = state.message, !msg.isEmpty {
                        Text(msg)
                            .font(.system(size: 11))
                            .foregroundColor(state.isError ? MacColor.red : MacColor.secondaryText)
                            .lineLimit(1)
                    }
                    Spacer()
                }

            case .note:
                Text(def.text ?? def.label ?? "")
                    .font(.system(size: 11))
                    .foregroundColor(MacColor.secondaryText)
            }

            if let help = def.help, !help.isEmpty {
                Text(help)
                    .font(.system(size: 11))
                    .foregroundColor(MacColor.secondaryText)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Account Block (PLG-10)

    @ViewBuilder
    private func accountBlock(plugin: DiscoveredPlugin, setting: PluginSettingDefinition) -> some View {
        let state = controller.accountStates[plugin.id] ?? .init()
        VStack(alignment: .leading, spacing: 8) {
            if let label = setting.label {
                Text(label).font(.system(size: 12, weight: .medium))
            }

            if setting.autoIdentity == true {
                HStack(spacing: 8) {
                    ForEach(["auto", "account"], id: \.self) { mode in
                        let selected = state.mode == mode
                        Text(mode == "auto" ? "Automatic identity" : "My account")
                            .font(.system(size: 12))
                            .foregroundColor(selected ? AppAccent.color : MacColor.secondaryText)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color(white: 1, opacity: selected ? 0.11 : 0.03)))
                            .onTapGesture { controller.setAccountMode(pluginID: plugin.id, mode: mode) }
                    }
                }
            }

            if setting.autoIdentity == true && state.mode == "auto" {
                HStack {
                    if case .signedIn(let name) = state.phase {
                        Text("Signed in as \(name)").font(.system(size: 12))
                    } else {
                        Text("Automatic identity").font(.system(size: 12)).foregroundColor(MacColor.secondaryText)
                    }
                    Spacer()
                    Button("New Identity") {
                        Task {
                            await presentAlert("Generate a new automatic identity for \(plugin.name)?") {
                                Button("New Identity") { controller.signOut(pluginID: plugin.id) }
                                Button("Cancel") {}
                            }
                        }
                    }
                }
            } else {
                switch state.phase {
                case .signedIn(let name):
                    HStack {
                        Text("Signed in as \(name)")
                            .font(.system(size: 12))
                        Spacer()
                        Button("Sign Out") { controller.signOut(pluginID: plugin.id) }
                    }

                case .signingIn:
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Signing in…")
                            .font(.system(size: 12))
                            .foregroundColor(MacColor.secondaryText)
                        Spacer()
                        Button("Cancel") { controller.cancelSignIn(pluginID: plugin.id) }
                    }

                case .waitingForBrowser(let url, let openFailed):
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Waiting for the browser…")
                                .font(.system(size: 12))
                                .foregroundColor(MacColor.secondaryText)
                            Spacer()
                            Button("Cancel") { controller.cancelSignIn(pluginID: plugin.id) }
                        }
                        if openFailed {
                            HStack(spacing: 8) {
                                Text(url.absoluteString)
                                    .font(.system(size: 11))
                                    .foregroundColor(MacColor.secondaryText)
                                    .lineLimit(1)
                                Button("Copy Link") { copyToClipboard(url.absoluteString) }
                            }
                        }
                    }

                case .signedOut:
                    let fields = setting.fields ?? []
                    let missingRequired = fields.contains { f in
                        f.isRequired && (state.fields[f.key] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(fields, id: \.key) { field in
                            let binding = Binding<String>(
                                get: { state.fields[field.key] ?? "" },
                                set: { controller.updateAccountField(pluginID: plugin.id, key: field.key, value: $0) }
                            )
                            HStack(spacing: 8) {
                                Text(field.label).frame(width: 110, alignment: .leading)
                                if field.isSecret {
                                    SecureField(field.placeholder ?? "", text: binding)
                                } else {
                                    TextField(field.placeholder ?? "", text: binding)
                                }
                            }
                        }
                        HStack {
                            if (plugin.id == "spotify" || plugin.id == "youtube-music") && BrowserCookieImporter.isSupportedOnPlatform {
                                Button("Import from Browser…") {
                                    controller.importAccountFromBrowser(pluginID: plugin.id, setting: setting)
                                }
                            }
                            Spacer()
                            Button(setting.oauth == true ? "Sign In…" : "Sign In") {
                                controller.signIn(pluginID: plugin.id, setting: setting)
                            }
                            .disabled(missingRequired)
                        }
                        if controller.browserImportPluginID == plugin.id && !controller.browserImportChoices.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("\(plugin.name) session found in multiple browsers — choose one:")
                                    .font(.system(size: 11))
                                    .foregroundColor(MacColor.secondaryText)
                                ForEach(controller.browserImportChoices) { candidate in
                                    HStack {
                                        Text(candidate.displayTitle)
                                            .font(.system(size: 12))
                                        Spacer()
                                        Button("Import") {
                                            controller.selectBrowserImportCandidate(candidate)
                                        }
                                    }
                                }
                                HStack {
                                    Spacer()
                                    Button("Cancel") {
                                        controller.cancelBrowserImportChoices()
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                            .padding(.top, 2)
                        }
                    }
                }
            }

            if let err = state.errorMessage, !err.isEmpty {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundColor(MacColor.red)
            }
        }
    }

    // MARK: - Download Sources & Downloads Cards (PLG-9)

    private var downloadSourcesCard: some View {
        let resolvers = controller.enabledResolvers
        return group("Download Sources") {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(resolvers.enumerated()), id: \.offset) { idx, resolver in
                    if idx > 0 { Divider() }
                    HStack(spacing: 10) {
                        PluginBadgeView(badge: resolver.badgeSVG, size: 18)
                        Text(resolver.name)
                        Spacer()
                        Button("↑") { controller.moveResolver(from: idx, to: idx - 1) }
                            .disabled(idx == 0)
                        Button("↓") { controller.moveResolver(from: idx, to: idx + 1) }
                            .disabled(idx + 1 >= resolvers.count)
                        Text("≡")
                            .foregroundColor(MacColor.secondaryText)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }
        }
    }

    private var downloadsCard: some View {
        let formats = controller.preferredFormats
        let ytdlpEnabled = controller.isEnabled("yt-dlp")
            && controller.plugins.contains { $0.id == "yt-dlp" && !$0.overriddenByUnpacked && $0.isEnabledEligible }

        return group("Downloads") {
            VStack(alignment: .leading, spacing: 0) {
                // Preferred formats
                VStack(alignment: .leading, spacing: 6) {
                    Text("Preferred formats")
                        .font(.system(size: 12, weight: .medium))
                    ForEach(Array(formats.enumerated()), id: \.offset) { idx, fmt in
                        HStack(spacing: 8) {
                            Text(PluginController.formatDisplayName(fmt))
                                .font(.system(size: 12))
                            Spacer()
                            Button("↑") { controller.movePreferredFormat(from: idx, to: idx - 1) }
                                .disabled(idx == 0)
                            Button("↓") { controller.movePreferredFormat(from: idx, to: idx + 1) }
                                .disabled(idx + 1 >= formats.count)
                            Text("≡")
                                .foregroundColor(MacColor.secondaryText)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)

                Divider()

                // Minimum bitrate
                HStack(spacing: 6) {
                    Text("Minimum bitrate")
                    Spacer()
                    TextField(
                        "192",
                        text: Binding(
                            get: { "\(controller.minimumBitrateKbps)" },
                            set: { raw in
                                if let val = Int(raw.trimmingCharacters(in: .whitespaces)) {
                                    controller.setMinimumBitrate(val)
                                }
                            }
                        )
                    )
                    .frame(width: 64)
                    Text("kbps")
                        .font(.system(size: 11))
                        .foregroundColor(MacColor.secondaryText)
                    Button("−") { controller.setMinimumBitrate(controller.minimumBitrateKbps - 32) }
                    Button("+") { controller.setMinimumBitrate(controller.minimumBitrateKbps + 32) }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                if ytdlpEnabled {
                    Divider()
                    HStack {
                        Text("Accept YouTube when nothing else is found")
                        Spacer()
                        Toggle(
                            "",
                            isOn: Binding(
                                get: { controller.acceptYouTubeFallback },
                                set: { controller.setAcceptYouTubeFallback($0) }
                            )
                        )
                        .toggleStyle(.switch)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }

                Divider()

                // Download folder
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Download folder")
                        Text(controller.effectiveDownloadFolderDisplay)
                            .font(.system(size: 11))
                            .foregroundColor(controller.downloadFolderMissing ? MacColor.red : MacColor.secondaryText)
                            .lineLimit(1)
                        if controller.downloadFolderMissing {
                            Text("Folder not found")
                                .font(.system(size: 11))
                                .foregroundColor(MacColor.red)
                        }
                    }
                    Spacer()
                    if controller.downloadFolderOverride != nil {
                        Button("Reset") { controller.resetDownloadFolder() }
                    }
                    Button("Choose…") {
                        Task {
                            guard let folder = await chooseFile(
                                title: "Choose Download Folder",
                                defaultButtonLabel: "Choose",
                                allowSelectingFiles: false,
                                allowSelectingDirectories: true
                            ) else { return }
                            controller.setDownloadFolder(folder)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                // Active subscription downloads status (SUB-13)
                if let active = SubscriptionController.shared.downloadsCardStatus {
                    Divider()
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(active.text)
                            .font(.system(size: 11))
                            .foregroundColor(MacColor.secondaryText)
                            .lineLimit(1)
                        Spacer()
                        if let pid = active.activePlaylistID {
                            Button("Show") {
                                AppCommands.openPlaylistByID?(pid)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }
        }
    }

    // MARK: - Footer & Developer Mode (PLG-14)

    private var footerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if !controller.plugins.isEmpty {
                    Button("Install Plug-in…") { pickAndInstallPackage() }
                        .disabled(!hasLibrary)
                }
                if controller.developerMode {
                    Button("Load Unpacked…") { pickAndLoadUnpacked() }
                        .disabled(!hasLibrary)
                }
                Spacer()
                HStack(spacing: 6) {
                    Text("Developer Mode")
                        .font(.system(size: 12))
                        .foregroundColor(MacColor.secondaryText)
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { controller.developerMode },
                            set: { controller.setDeveloperMode($0) }
                        )
                    )
                    .toggleStyle(.switch)
                    .disabled(!hasLibrary)
                }
            }

            Caption("Plug-in passwords and tokens are stored on this iPod, unencrypted.")
        }
    }

    private func pickAndInstallPackage() {
        Task {
            guard let file = await chooseFile(
                title: "Choose a Plug-in Package (.ippmplugin)",
                defaultButtonLabel: "Install",
                allowSelectingFiles: true,
                allowSelectingDirectories: false
            ) else { return }
            controller.inspectPackageForInstall(at: file)
        }
    }

    private func pickAndLoadUnpacked() {
        Task {
            guard let folder = await chooseFile(
                title: "Choose an Unpacked Plug-in Folder",
                defaultButtonLabel: "Load",
                allowSelectingFiles: false,
                allowSelectingDirectories: true
            ) else { return }
            controller.loadUnpackedPlugin(folderURL: folder)
        }
    }

    // MARK: - Helpers

    private func group<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 14, weight: .semibold)).padding(.leading, 2)
            card(content)
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ZStack {
                RoundedRectangle(cornerRadius: 8).fill(MacColor.groupFill)
                RoundedRectangle(cornerRadius: 8).stroke(MacColor.groupBorder)
            })
    }
}

private struct EnumChoice: Equatable, CustomStringConvertible {
    var value: String
    var label: String
    var description: String { label }
}

// MARK: - Package Install Confirmation Sheet (PLG-13)

struct PluginInstallSheet: View {
    @State private var revision = 0
    private var controller: PluginController { .shared }

    var body: some View {
        let _ = revision
        let pending = controller.pendingInstall
        VStack(alignment: .leading, spacing: 14) {
            if let error = controller.installErrorMessage ?? pending?.verificationError {
                Text("Couldn't Install Plug-in")
                    .font(.system(size: 16, weight: .semibold))
                Text(error)
                    .font(.system(size: 12))
                    .foregroundColor(MacColor.red)
                HStack {
                    Spacer()
                    Button("OK") { controller.cancelInstall() }
                }
            } else if let pending, let verified = pending.verified {
                let m = verified.manifest
                Text(sheetTitle(manifest: m, pending: pending))
                    .font(.system(size: 16, weight: .semibold))

                VStack(alignment: .leading, spacing: 6) {
                    Text(m.description).font(.system(size: 12))
                    if let author = m.author, !author.isEmpty {
                        Text("Author: \(author)")
                            .font(.system(size: 11))
                            .foregroundColor(MacColor.secondaryText)
                    }
                    Text("Roles: \(m.knownRoles.map(\.badgeLabel).joined(separator: ", "))")
                        .font(.system(size: 11))
                        .foregroundColor(MacColor.secondaryText)
                    if let consent = m.requiresConsent {
                        Text("Risk: \(consent.rawValue)")
                            .font(.system(size: 11))
                            .foregroundColor(MacColor.secondaryText)
                    }
                    if pending.isOverriddenByUnpacked {
                        Text("An unpacked plug-in with id '\(m.id)' is currently loaded and will remain prioritized.")
                            .font(.system(size: 11))
                            .foregroundColor(MacColor.secondaryText)
                    }
                    if pending.isInUse {
                        Text("\(m.name) is currently running; installing will stop it first.")
                            .font(.system(size: 11))
                            .foregroundColor(MacColor.secondaryText)
                    }
                }

                if controller.isInstalling {
                    ProgressView(value: Double?.none)
                }

                HStack {
                    Button("Cancel") { controller.cancelInstall() }
                        .disabled(controller.isInstalling)
                    Spacer()
                    Button("Install") { controller.confirmInstall() }
                        .disabled(controller.isInstalling)
                }
            }
        }
        .padding(22)
        .frame(width: 400)
        .task { controller.observe("install-sheet") { revision += 1 } }
    }

    private func sheetTitle(manifest: PluginManifest, pending: PluginController.PendingPackageInstall) -> String {
        if let existing = pending.existingInstalled {
            let verb = pending.isDowngrade ? "Downgrade" : "Update"
            return "\(verb) \(manifest.name) \(existing.version) → \(manifest.version)"
        }
        return "Install \(manifest.name) \(manifest.version)?"
    }
}

// MARK: - Developer Mode Live Log Window (PLG-14)

struct PluginLogWindowView: View {
    @State private var revision = 0
    private var controller: PluginController { .shared }

    var body: some View {
        let _ = revision
        let pluginID = controller.activeLogPluginID ?? ""
        let entries = controller.logsByPlugin[pluginID] ?? []
        let pluginName = controller.plugins.first { $0.id == pluginID }?.name ?? (pluginID.isEmpty ? "Plug-in" : pluginID)

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(pluginName) — Live Log")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("Clear") {
                    if !pluginID.isEmpty { controller.clearLogs(for: pluginID) }
                }
                Button("Copy") {
                    if !pluginID.isEmpty { copyToClipboard(controller.formattedLogText(for: pluginID)) }
                }
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    if entries.isEmpty {
                        Text("No log output yet.")
                            .font(.system(size: 11))
                            .foregroundColor(MacColor.secondaryText)
                    } else {
                        ForEach(entries) { entry in
                            Text(entry.text)
                                .font(.system(size: 11))
                                .foregroundColor(entryColor(entry.kind))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .frame(width: 680, height: 420)
        .task { controller.observe("log-window") { revision += 1 } }
    }

    private func entryColor(_ kind: PluginLogEntry.Kind) -> Color {
        switch kind {
        case .error: MacColor.red
        case .rpc: MacColor.secondaryText
        case .stderr, .log: Color.adaptive(light: .black, dark: .white)
        }
    }
}
