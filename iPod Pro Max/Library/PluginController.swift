import Foundation
import iPodKit
import MediaKit
import PluginKit

/// Coordinates plug-in discovery, per-plug-in settings/secrets/accounts, quality policy,
/// consent, `.ippmplugin` installation, and Developer Mode live logs (`PLG-5`, `PLG-7`,
/// `PLG-9`, `PLG-10`, `PLG-11`, `PLG-13`, `PLG-14`).
///
/// Event-driven only: zero timers or polling loops. Heavy I/O runs off the main actor.
@MainActor
final class PluginController {
    static let shared = PluginController()

    struct AccountUIState: Equatable {
        enum Phase: Equatable {
            case signedOut
            case signingIn
            case waitingForBrowser(URL, openFailed: Bool)
            case signedIn(String)
        }

        var phase: Phase = .signedOut
        var mode: String = "auto" // "auto" or "account" (for autoIdentity plug-ins)
        var fields: [String: String] = [:]
        var errorMessage: String?
    }

    struct ActionUIState: Equatable {
        var running = false
        var message: String?
        var isError = false
    }

    struct PendingPackageInstall {
        var fileURL: URL
        var verified: VerifiedPluginPackage?
        var verificationError: String?
        var existingInstalled: DiscoveredPlugin?
        var isDowngrade: Bool = false
        var isOverriddenByUnpacked: Bool = false
        var isInUse: Bool = false
    }

    private(set) var store: PortableLibraryStore?
    private(set) var registry: PluginRegistry?
    private(set) var plugins: [DiscoveredPlugin] = []
    private(set) var enabledIDs: Set<String> = []
    private(set) var resolverOrder: [String] = ["soulseek", "yt-dlp"]
    private(set) var developerMode = false
    private(set) var runtimeStates: [String: ExternalPluginProcessState] = [:]
    private(set) var runtimeStatuses: [String: PluginStatusUpdate] = [:]
    private(set) var settingsValues: [String: [String: JSONValue]] = [:]
    private(set) var folderOverrides: [String: [String: String]] = [:]
    private(set) var missingFolderKeys: [String: Set<String>] = [:]
    private(set) var accountStates: [String: AccountUIState] = [:]
    private(set) var actionStates: [String: ActionUIState] = [:]
    private(set) var logsByPlugin: [String: [PluginLogEntry]] = [:]
    private(set) var activeLogPluginID: String?

    // PLG-9 Downloads card state
    private(set) var preferredFormats: [String] = QualityPolicy.defaultPreferredFormats
    private(set) var minimumBitrateKbps: Int = 192
    private(set) var acceptYouTubeFallback: Bool = true
    private(set) var downloadFolderOverride: String?
    private(set) var downloadFolderMissing: Bool = false

    // PLG-13 Install / Drag-and-drop state
    var pendingInstall: PendingPackageInstall?
    var isInstalling = false
    var installErrorMessage: String?
    var dragHoveringPackage = false
    var settingsPluginsTabActive = false

    // On-demand browser cookie import choices (macOS Spotify)
    private(set) var browserImportChoices: [BrowserCookieCandidate] = []
    private(set) var browserImportPluginID: String?
    private var browserImportSetting: PluginSettingDefinition?

    private var observers: [String: @MainActor () -> Void] = [:]

    func observe(_ key: String, _ handler: @escaping @MainActor () -> Void) {
        observers[key] = handler
    }

    func refreshObservers() {
        notifyObservers()
    }

    private func notifyObservers() {
        for handler in observers.values {
            handler()
        }
    }

    private var discoverTask: Task<Void, Never>?
    private var debounceTasks: [String: Task<Void, Never>] = [:]
    private var accountTasks: [String: Task<Void, Never>] = [:]
    private var oauthContinuations: [String: CheckedContinuation<PluginAccountStatus, Error>] = [:]
    private var activeOperationsByPlugin: [String: Int] = [:]

    private init() {}

    // MARK: - Attachment & Discovery

    func attach(_ store: PortableLibraryStore?) {
        self.store = store
        discoverTask?.cancel()

        guard let store else {
            registry = nil
            plugins = []
            enabledIDs = []
            runtimeStates = [:]
            runtimeStatuses = [:]
            settingsValues = [:]
            folderOverrides = [:]
            missingFolderKeys = [:]
            accountStates = [:]
            actionStates = [:]
            notifyObservers()
            return
        }

        let iPodRoot = store.data.url.deletingLastPathComponent().deletingLastPathComponent()
        let ffmpeg = FFmpeg.binaryPath()
        let reg = PluginRegistry(iPodRoot: iPodRoot, appVersion: "0.1", onIPod: true, ffmpegPath: ffmpeg)
        reg.onLogEntry = { [weak self] pluginID, entry in
            Task { @MainActor in
                self?.appendLog(pluginID: pluginID, entry: entry)
            }
        }
        reg.onRuntimeStateChanged = { [weak self] pluginID, procState, status in
            Task { @MainActor in
                self?.runtimeStates[pluginID] = procState
                if let status {
                    self?.runtimeStatuses[pluginID] = status
                } else if case .stopped = procState {
                    self?.runtimeStatuses.removeValue(forKey: pluginID)
                }
                self?.notifyObservers()
            }
        }
        reg.onAccountStatusChanged = { [weak self] pluginID, status in
            Task { @MainActor in
                self?.handleAccountStatusUpdate(pluginID: pluginID, status: status)
            }
        }
        self.registry = reg

        discoverTask = Task {
            let result = await Task.detached(priority: .utility) {
                let settings = store.data.read(PortableSettings.self, from: "settings.json")
                let host = store.currentHost()
                reg.setHostConfiguration(
                    unpackedFolders: host?.unpackedPlugins ?? [],
                    folderOverrides: host?.pluginFolders ?? [:]
                )
                let discovered = reg.discover()
                let regState = reg.currentState()
                let snapshot = Self.buildSettingsSnapshot(
                    discovered: discovered,
                    registry: reg,
                    host: host
                )
                return (settings, host, discovered, regState, snapshot)
            }.value
            guard !Task.isCancelled else { return }

            let (settings, host, discovered, regState, snapshot) = result
            self.preferredFormats = Self.normalizedFormats(settings?.preferredFormats)
            self.minimumBitrateKbps = max(0, settings?.minimumBitrateKbps ?? 192)
            self.acceptYouTubeFallback = settings?.acceptYouTubeFallback ?? true
            self.downloadFolderOverride = host?.downloadFolder
            self.downloadFolderMissing = Self.isCustomFolderMissing(host?.downloadFolder)

            self.applyDiscovery(discovered: discovered, regState: regState, snapshot: snapshot)
            self.launchEnabledSharePlugins()
        }
    }

    func refreshDiscovery() {
        guard let store, let reg = registry else { return }
        discoverTask?.cancel()
        discoverTask = Task {
            let result = await Task.detached(priority: .utility) {
                let host = store.currentHost()
                reg.setHostConfiguration(
                    unpackedFolders: host?.unpackedPlugins ?? [],
                    folderOverrides: host?.pluginFolders ?? [:]
                )
                let discovered = reg.discover()
                let regState = reg.currentState()
                let snapshot = Self.buildSettingsSnapshot(discovered: discovered, registry: reg, host: host)
                return (host, discovered, regState, snapshot)
            }.value
            guard !Task.isCancelled else { return }
            self.downloadFolderOverride = result.0?.downloadFolder
            self.downloadFolderMissing = Self.isCustomFolderMissing(result.0?.downloadFolder)
            self.applyDiscovery(discovered: result.1, regState: result.2, snapshot: result.3)
        }
    }

    private struct SettingsSnapshot: Sendable {
        var values: [String: [String: JSONValue]]
        var folderOverrides: [String: [String: String]]
        var missingFolders: [String: Set<String>]
        var cachedAccountNames: [String: String]
        var hasAccountSecrets: [String: Bool]
        var warnings: [(String, String)]
    }

    private nonisolated static func buildSettingsSnapshot(
        discovered: [DiscoveredPlugin],
        registry: PluginRegistry,
        host: KnownHost?
    ) -> SettingsSnapshot {
        var values: [String: [String: JSONValue]] = [:]
        var overrides: [String: [String: String]] = [:]
        var missing: [String: Set<String>] = [:]
        var cachedNames: [String: String] = [:]
        var hasSecrets: [String: Bool] = [:]
        var warnings: [(String, String)] = []

        let hostFolders = host?.pluginFolders ?? [:]
        for plugin in discovered where !plugin.overriddenByUnpacked {
            guard let manifest = plugin.manifest else { continue }
            let pStore = registry.settingsStore(for: plugin.id)
            let pOverrides = hostFolders[plugin.id] ?? [:]
            overrides[plugin.id] = pOverrides

            let storedSettings = pStore.loadSettingsDict()
            let storedSecrets = pStore.loadSecretsDict()
            var uiVals: [String: JSONValue] = [:]
            var missingKeys = Set<String>()

            for def in manifest.settings ?? [] {
                if def.isFolder {
                    if let custom = pOverrides[def.key], !custom.isEmpty {
                        uiVals[def.key] = .string(custom)
                        var isDir: ObjCBool = false
                        if !FileManager.default.fileExists(atPath: custom, isDirectory: &isDir) || !isDir.boolValue {
                            missingKeys.insert(def.key)
                        }
                    } else if let defVal = pStore.resolveFolderValue(def: def, override: nil) {
                        uiVals[def.key] = .string(defVal)
                    }
                    continue
                }
                guard !def.isDisplayOnly else { continue }
                let raw = def.isSecret ? storedSecrets[def.key] : storedSettings[def.key]
                if let raw {
                    if let valid = pStore.validateValue(raw, for: def) {
                        uiVals[def.key] = valid
                    } else {
                        warnings.append((plugin.id, "Setting '\(def.key)' has unexpected type; using default."))
                        if let defVal = pStore.defaultValue(for: def) { uiVals[def.key] = defVal }
                    }
                } else if let defVal = pStore.defaultValue(for: def) {
                    uiVals[def.key] = defVal
                }
            }

            values[plugin.id] = uiVals
            if !missingKeys.isEmpty { missing[plugin.id] = missingKeys }
            if let cached = storedSettings["_accountDisplayName"]?.stringValue, !cached.isEmpty {
                cachedNames[plugin.id] = cached
            }
            hasSecrets[plugin.id] = pStore.hasAccountSecrets
        }
        return SettingsSnapshot(
            values: values,
            folderOverrides: overrides,
            missingFolders: missing,
            cachedAccountNames: cachedNames,
            hasAccountSecrets: hasSecrets,
            warnings: warnings
        )
    }

    private func applyDiscovery(
        discovered: [DiscoveredPlugin],
        regState: PluginsStateFile,
        snapshot: SettingsSnapshot
    ) {
        self.plugins = discovered
        self.enabledIDs = Set(regState.enabledIDs)
        self.resolverOrder = regState.resolverOrder
        self.developerMode = regState.developerMode
        self.settingsValues = snapshot.values
        self.folderOverrides = snapshot.folderOverrides
        self.missingFolderKeys = snapshot.missingFolders

        for (pluginID, msg) in snapshot.warnings {
            appendLog(pluginID: pluginID, entry: PluginLogEntry(kind: .log, text: "[warning] \(msg)"))
        }

        for plugin in discovered where !plugin.overriddenByUnpacked {
            if runtimeStates[plugin.id] == nil {
                runtimeStates[plugin.id] = .stopped
            }
            var acc = accountStates[plugin.id] ?? AccountUIState()
            if case .signedOut = acc.phase, let cached = snapshot.cachedAccountNames[plugin.id] {
                acc.phase = .signedIn(cached)
            }
            accountStates[plugin.id] = acc
        }
        notifyObservers()
    }

    private func launchEnabledSharePlugins() {
        guard let registry else { return }
        for plugin in plugins where !plugin.overriddenByUnpacked && plugin.isEnabledEligible {
            guard enabledIDs.contains(plugin.id),
                  let roles = plugin.manifest?.knownRoles,
                  roles.contains(.share),
                  let runtime = registry.runtime(for: plugin.id) else { continue }
            let shareEnabled = settingsValues[plugin.id]?["share"]?.boolValue ?? true
            if shareEnabled {
                Task {
                    await runtime.setShareLease(true)
                    _ = try? await runtime.initializeOnly()
                }
            }
        }
    }

    // MARK: - Preferences Tab Open

    /// Refreshes account status ONLY for plug-ins already running or with saved account secrets,
    /// without launching any dormant process just to render Preferences (PLG-10).
    func onPluginsTabOpened() {
        guard let registry else { return }
        for plugin in plugins where !plugin.overriddenByUnpacked && enabledIDs.contains(plugin.id) {
            guard let manifest = plugin.manifest,
                  (manifest.settings ?? []).contains(where: { $0.type == .account }),
                  let runtime = registry.runtime(for: plugin.id) else { continue }
            let hasSecrets = registry.settingsStore(for: plugin.id).hasAccountSecrets
            let hasCachedAccount: Bool = {
                if case .signedIn = accountStates[plugin.id]?.phase { return true }
                return false
            }()
            Task {
                let running = await runtime.isRunning()
                guard running || hasSecrets || hasCachedAccount else { return }
                if let status = try? await runtime.accountStatus() {
                    handleAccountStatusUpdate(pluginID: plugin.id, status: status)
                    if plugin.id == "spotify",
                       status.status == "signedIn",
                       Self.needsSpotifyNameResolution(status.displayName) {
                        _ = await self.refreshSpotifyWebSessionIfPossible(preferredPlaylistID: nil)
                    }
                }
            }
        }
    }

    // MARK: - Enable / Disable / Consent / Restart

    func isEnabled(_ pluginID: String) -> Bool {
        enabledIDs.contains(pluginID)
    }

    func needsConsent(for plugin: DiscoveredPlugin) -> PluginConsentType? {
        registry?.needsConsent(for: plugin)
    }

    func enableWithConsent(pluginID: String, consent: PluginConsentType?) {
        guard let registry else { return }
        do {
            if let consent {
                try registry.grantConsentAndEnable(pluginID: pluginID, type: consent)
            } else {
                try registry.setEnabled(true, pluginID: pluginID)
            }
            enabledIDs.insert(pluginID)
            if let plugin = plugins.first(where: { $0.id == pluginID && !$0.overriddenByUnpacked }),
               plugin.manifest?.knownRoles.contains(.share) == true,
               settingsValues[pluginID]?["share"]?.boolValue ?? true,
               let runtime = registry.runtime(for: pluginID) {
                Task {
                    await runtime.setShareLease(true)
                    _ = try? await runtime.initializeOnly()
                    ShareController.shared.refreshIfShareEnabled()
                }
            }
            notifyObservers()
        } catch {
            appendLog(pluginID: pluginID, entry: PluginLogEntry(kind: .error, text: error.localizedDescription))
        }
    }

    func isPluginInUse(_ pluginID: String) async -> Bool {
        if (activeOperationsByPlugin[pluginID] ?? 0) > 0 { return true }
        guard let runtime = registry?.runtime(for: pluginID) else { return false }
        return await runtime.isRunning()
    }

    func disablePlugin(_ pluginID: String) async {
        guard let registry else { return }
        if let runtime = registry.runtime(for: pluginID) {
            await runtime.setShareLease(false)
            await runtime.shutdown(timeoutSeconds: 2.0)
        }
        do {
            try registry.setEnabled(false, pluginID: pluginID)
            enabledIDs.remove(pluginID)
            notifyObservers()
            ShareController.shared.refreshIfShareEnabled()
        } catch {
            appendLog(pluginID: pluginID, entry: PluginLogEntry(kind: .error, text: error.localizedDescription))
        }
    }

    func restartPlugin(_ pluginID: String) async {
        guard let runtime = registry?.runtime(for: pluginID) else { return }
        await runtime.restart()
        runtimeStates[pluginID] = .stopped
        runtimeStatuses.removeValue(forKey: pluginID)
        notifyObservers()
    }

    // MARK: - Settings & Secrets Mutation (PLG-7)

    func updateSetting(
        pluginID: String,
        definition: PluginSettingDefinition,
        value: JSONValue,
        immediate: Bool
    ) {
        var map = settingsValues[pluginID] ?? [:]
        map[definition.key] = value
        settingsValues[pluginID] = map
        notifyObservers()
        if definition.key == "share" {
            ShareController.shared.refreshIfShareEnabled()
        }

        let taskKey = "\(pluginID)::\(definition.key)"
        debounceTasks[taskKey]?.cancel()

        let persist: @MainActor () -> Void = { [weak self] in
            self?.commitSettingToDiskAndPlugin(pluginID: pluginID, definition: definition, value: value)
        }

        if immediate {
            persist()
        } else {
            debounceTasks[taskKey] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { return }
                self?.debounceTasks.removeValue(forKey: taskKey)
                persist()
            }
        }
    }

    private func commitSettingToDiskAndPlugin(
        pluginID: String,
        definition: PluginSettingDefinition,
        value: JSONValue
    ) {
        guard let registry, let store else { return }
        let pStore = registry.settingsStore(for: pluginID)

        if definition.isFolder, let path = value.stringValue {
            var overrides = folderOverrides[pluginID] ?? [:]
            overrides[definition.key] = path
            folderOverrides[pluginID] = overrides
            var missing = missingFolderKeys[pluginID] ?? []
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                missing.remove(definition.key)
            } else {
                missing.insert(definition.key)
            }
            missingFolderKeys[pluginID] = missing
            Task.detached(priority: .utility) {
                try? store.updateCurrentHost { host in
                    var folders = host.pluginFolders ?? [:]
                    var p = folders[pluginID] ?? [:]
                    p[definition.key] = path
                    folders[pluginID] = p
                    host.pluginFolders = folders
                }
            }
        } else {
            Task.detached(priority: .utility) {
                if definition.isSecret {
                    var dict = pStore.loadSecretsDict()
                    dict[definition.key] = value
                    try? pStore.saveSecretsDict(dict)
                } else {
                    var dict = pStore.loadSettingsDict()
                    dict[definition.key] = value
                    try? pStore.saveSettingsDict(dict)
                }
            }
        }

        pushSettingsChangedToRunningPlugin(pluginID: pluginID)
    }

    func resetFolderSetting(pluginID: String, definition: PluginSettingDefinition) {
        guard let registry, let store else { return }
        let pStore = registry.settingsStore(for: pluginID)
        var overrides = folderOverrides[pluginID] ?? [:]
        overrides.removeValue(forKey: definition.key)
        folderOverrides[pluginID] = overrides
        missingFolderKeys[pluginID]?.remove(definition.key)

        if let defaultPath = pStore.resolveFolderValue(def: definition, override: nil) {
            var map = settingsValues[pluginID] ?? [:]
            map[definition.key] = .string(defaultPath)
            settingsValues[pluginID] = map
        } else {
            settingsValues[pluginID]?.removeValue(forKey: definition.key)
        }
        notifyObservers()

        Task.detached(priority: .utility) {
            try? store.updateCurrentHost { host in
                var folders = host.pluginFolders ?? [:]
                folders[pluginID]?.removeValue(forKey: definition.key)
                if folders[pluginID]?.isEmpty == true { folders.removeValue(forKey: pluginID) }
                host.pluginFolders = folders.isEmpty ? nil : folders
            }
        }
        pushSettingsChangedToRunningPlugin(pluginID: pluginID)
    }

    private func pushSettingsChangedToRunningPlugin(pluginID: String) {
        guard let registry,
              let plugin = plugins.first(where: { $0.id == pluginID && !$0.overriddenByUnpacked }),
              let manifest = plugin.manifest,
              let runtime = registry.runtime(for: pluginID) else { return }
        let overrides = folderOverrides[pluginID] ?? [:]
        registry.setHostConfiguration(
            unpackedFolders: plugins.filter(\.isUnpacked).map { $0.rootURL.path },
            folderOverrides: folderOverrides
        )
        let pStore = registry.settingsStore(for: pluginID)
        let resolved = pStore.resolvedSettings(for: manifest, folderOverrides: overrides)
        Task {
            await runtime.notifySettingsChanged(resolved)
        }
    }

    // MARK: - Accounts & OAuth (PLG-10)

    func updateAccountField(pluginID: String, key: String, value: String) {
        var acc = accountStates[pluginID] ?? AccountUIState()
        acc.fields[key] = value
        accountStates[pluginID] = acc
        notifyObservers()
    }

    func setAccountMode(pluginID: String, mode: String) {
        var acc = accountStates[pluginID] ?? AccountUIState()
        acc.mode = mode
        acc.errorMessage = nil
        accountStates[pluginID] = acc
        notifyObservers()
    }

    func signIn(pluginID: String, setting: PluginSettingDefinition) {
        guard let runtime = registry?.runtime(for: pluginID),
              let registry else { return }
        accountTasks[pluginID]?.cancel()
        browserImportChoices = []
        browserImportPluginID = nil
        browserImportSetting = nil

        var acc = accountStates[pluginID] ?? AccountUIState()
        acc.phase = .signingIn
        acc.errorMessage = nil
        let submittedFields = acc.fields
        accountStates[pluginID] = acc
        notifyObservers()

        let pStore = registry.settingsStore(for: pluginID)

        accountTasks[pluginID] = Task {
            do {
                let res = try await runtime.login(key: setting.key, fields: submittedFields)
                guard !Task.isCancelled else { return }

                if let openURLStr = res.openURL, let url = URL(string: openURLStr) {
                    if pluginID == "spotify" && SpotifyWebBridge.shared.isSupportedOnPlatform {
                        var state = self.accountStates[pluginID] ?? AccountUIState()
                        state.phase = .waitingForBrowser(url, openFailed: false)
                        self.accountStates[pluginID] = state
                        self.notifyObservers()

                        let webSession = try await SpotifyWebBridge.shared.signInInteractively()
                        guard !Task.isCancelled else { return }
                        let fields = Self.loginFields(from: webSession)
                        let finalStatus = try await runtime.login(key: setting.key, fields: fields)
                        guard !Task.isCancelled else { return }
                        self.applyAccountResult(pluginID: pluginID, status: finalStatus, setting: setting, pStore: pStore)
                    } else {
                        let opened = SafeStorage.openURL(url)
                        var state = self.accountStates[pluginID] ?? AccountUIState()
                        state.phase = .waitingForBrowser(url, openFailed: !opened)
                        self.accountStates[pluginID] = state
                        self.notifyObservers()

                        let finalStatus = try await self.waitForOAuthCompletion(pluginID: pluginID, timeoutSeconds: 300)
                        guard !Task.isCancelled else { return }
                        self.applyAccountResult(pluginID: pluginID, status: finalStatus, setting: setting, pStore: pStore)
                    }
                } else {
                    if pluginID == "spotify",
                       let spDC = submittedFields["sp_dc"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !spDC.isEmpty,
                       SpotifyWebBridge.shared.isSupportedOnPlatform {
                        await SpotifyWebBridge.shared.seedSpDCCookie(spDC)
                        if await self.refreshSpotifyWebSessionIfPossible(preferredPlaylistID: nil) {
                            return
                        }
                    }
                    self.applyAccountResult(pluginID: pluginID, status: res, setting: setting, pStore: pStore)
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.failAccountSignIn(pluginID: pluginID, message: error.localizedDescription, setting: setting)
            }
        }
    }

    private func waitForOAuthCompletion(pluginID: String, timeoutSeconds: Double) async throws -> PluginAccountStatus {
        try await withThrowingTaskGroup(of: PluginAccountStatus.self) { group in
            group.addTask { @MainActor in
                try await withCheckedThrowingContinuation { cont in
                    self.oauthContinuations[pluginID]?.resume(throwing: PluginError(code: .cancelled, message: "Cancelled"))
                    self.oauthContinuations[pluginID] = cont
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw PluginError(code: .startTimeout, message: "Sign in timed out after 5 minutes.")
            }
            guard let first = try await group.next() else {
                throw PluginError(code: .cancelled, message: "Cancelled")
            }
            group.cancelAll()
            return first
        }
    }

    private func handleAccountStatusUpdate(pluginID: String, status: PluginAccountStatus) {
        if let cont = oauthContinuations.removeValue(forKey: pluginID) {
            cont.resume(returning: status)
            return
        }
        guard let plugin = plugins.first(where: { $0.id == pluginID && !$0.overriddenByUnpacked }),
              let setting = plugin.manifest?.settings?.first(where: { $0.type == .account }),
              let pStore = registry?.settingsStore(for: pluginID) else {
            return
        }
        applyAccountResult(pluginID: pluginID, status: status, setting: setting, pStore: pStore)
    }

    private func applyAccountResult(
        pluginID: String,
        status: PluginAccountStatus,
        setting: PluginSettingDefinition,
        pStore: PluginSettingsStore
    ) {
        var acc = accountStates[pluginID] ?? AccountUIState()
        switch status.status {
        case "signedIn":
            let name = status.displayName ?? "Account"
            acc.phase = .signedIn(name)
            acc.errorMessage = nil
            // Clear password fields from temporary input memory
            for field in setting.fields ?? [] where field.isSecret {
                acc.fields.removeValue(forKey: field.key)
            }
            accountStates[pluginID] = acc
            Task.detached(priority: .utility) { try? pStore.setCachedAccountDisplayName(name) }
        case "error":
            failAccountSignIn(pluginID: pluginID, message: status.message ?? "Sign in failed.", setting: setting)
            return
        default:
            acc.phase = .signedOut
            acc.errorMessage = status.message
            accountStates[pluginID] = acc
            Task.detached(priority: .utility) { try? pStore.setCachedAccountDisplayName(nil) }
        }
        notifyObservers()
    }

    private func failAccountSignIn(pluginID: String, message: String, setting: PluginSettingDefinition) {
        var acc = accountStates[pluginID] ?? AccountUIState()
        acc.phase = .signedOut
        acc.errorMessage = message
        // Spec: keep filled fields EXCEPT password/secret fields!
        for field in setting.fields ?? [] where field.isSecret {
            acc.fields.removeValue(forKey: field.key)
        }
        accountStates[pluginID] = acc
        notifyObservers()
    }

    func cancelSignIn(pluginID: String) {
        cancelBrowserImportChoices()
        if pluginID == "spotify" {
            SpotifyWebBridge.shared.cancelInteractiveSignIn()
        }
        accountTasks[pluginID]?.cancel()
        accountTasks.removeValue(forKey: pluginID)
        if let cont = oauthContinuations.removeValue(forKey: pluginID) {
            cont.resume(throwing: PluginError(code: .cancelled, message: "Cancelled"))
        }
        var acc = accountStates[pluginID] ?? AccountUIState()
        acc.phase = .signedOut
        accountStates[pluginID] = acc
        notifyObservers()
    }

    func signOut(pluginID: String) {
        guard let registry else { return }
        cancelBrowserImportChoices()
        let pStore = registry.settingsStore(for: pluginID)
        let runtime = registry.runtime(for: pluginID)
        Task {
            if pluginID == "spotify" {
                await SpotifyWebBridge.shared.signOut()
            }
            _ = try? await runtime?.logout()
            try? pStore.clearAccountSecrets()
            var acc = accountStates[pluginID] ?? AccountUIState()
            acc.phase = .signedOut
            acc.errorMessage = nil
            accountStates[pluginID] = acc
            notifyObservers()
        }
    }

    func importAccountFromBrowser(pluginID: String, setting: PluginSettingDefinition) {
        guard pluginID == "spotify", BrowserCookieImporter.isSupportedOnPlatform else { return }
        accountTasks[pluginID]?.cancel()
        browserImportChoices = []
        browserImportPluginID = nil
        browserImportSetting = nil

        var acc = accountStates[pluginID] ?? AccountUIState()
        acc.phase = .signingIn
        acc.errorMessage = nil
        accountStates[pluginID] = acc
        notifyObservers()

        accountTasks[pluginID] = Task {
            let scanResult = await Task.detached(priority: .userInitiated) {
                (
                    candidates: BrowserCookieImporter.discoverSpotifyCookieBrowsers(),
                    safariBlocked: BrowserCookieImporter.safariBlockedByPermissions()
                )
            }.value
            guard !Task.isCancelled else { return }

            if scanResult.candidates.isEmpty {
                let err: BrowserCookieImportError = scanResult.safariBlocked
                    ? .safariPermissionDenied
                    : .noCookiesFound
                self.failAccountSignIn(
                    pluginID: pluginID,
                    message: err.localizedDescription,
                    setting: setting
                )
                return
            }

            if scanResult.candidates.count == 1, let only = scanResult.candidates.first {
                self.browserImportSetting = setting
                self.browserImportPluginID = pluginID
                self.selectBrowserImportCandidate(only)
                return
            }

            var signedOutAcc = self.accountStates[pluginID] ?? AccountUIState()
            signedOutAcc.phase = .signedOut
            signedOutAcc.errorMessage = nil
            self.accountStates[pluginID] = signedOutAcc
            self.browserImportChoices = scanResult.candidates
            self.browserImportPluginID = pluginID
            self.browserImportSetting = setting
            self.notifyObservers()
        }
    }

    func selectBrowserImportCandidate(_ candidate: BrowserCookieCandidate) {
        guard let pluginID = browserImportPluginID ?? "spotify" as String?,
              let setting = browserImportSetting,
              let runtime = registry?.runtime(for: pluginID),
              let registry else { return }

        browserImportChoices = []
        browserImportPluginID = nil
        browserImportSetting = nil

        var acc = accountStates[pluginID] ?? AccountUIState()
        acc.phase = .signingIn
        acc.errorMessage = nil
        accountStates[pluginID] = acc
        notifyObservers()

        let pStore = registry.settingsStore(for: pluginID)
        accountTasks[pluginID]?.cancel()
        accountTasks[pluginID] = Task {
            do {
                let spDC = try await Task.detached(priority: .userInitiated) {
                    try BrowserCookieImporter.readSpotifyCookie(from: candidate)
                }.value
                guard !Task.isCancelled else { return }

                if SpotifyWebBridge.shared.isSupportedOnPlatform {
                    await SpotifyWebBridge.shared.seedSpDCCookie(spDC)
                    if await self.refreshSpotifyWebSessionIfPossible(preferredPlaylistID: nil) {
                        return
                    }
                }

                let finalStatus = try await runtime.login(key: setting.key, fields: ["sp_dc": spDC])
                guard !Task.isCancelled else { return }
                self.applyAccountResult(pluginID: pluginID, status: finalStatus, setting: setting, pStore: pStore)
            } catch {
                guard !Task.isCancelled else { return }
                self.failAccountSignIn(pluginID: pluginID, message: error.localizedDescription, setting: setting)
            }
        }
    }

    func cancelBrowserImportChoices() {
        guard !browserImportChoices.isEmpty || browserImportPluginID != nil else { return }
        browserImportChoices = []
        browserImportPluginID = nil
        browserImportSetting = nil
        notifyObservers()
    }

    /// Silently boots an off-screen OS WebView to renew an expired Spotify Web token on demand.
    func refreshSpotifyWebSessionIfPossible(preferredPlaylistID: String?) async -> Bool {
        guard let runtime = registry?.runtime(for: "spotify"),
              let registry,
              SpotifyWebBridge.shared.isSupportedOnPlatform,
              let webSession = await SpotifyWebBridge.shared.refreshSilently(preferredPlaylistID: preferredPlaylistID) else {
            return false
        }
        let fields = Self.loginFields(from: webSession)
        guard let status = try? await runtime.login(key: "account", fields: fields) else {
            return false
        }
        if let plugin = plugins.first(where: { $0.id == "spotify" && !$0.overriddenByUnpacked }),
           let setting = plugin.manifest?.settings?.first(where: { $0.type == .account }) {
            let pStore = registry.settingsStore(for: "spotify")
            applyAccountResult(pluginID: "spotify", status: status, setting: setting, pStore: pStore)
        }
        return status.status == "signedIn"
    }

    private static func needsSpotifyNameResolution(_ raw: String?) -> Bool {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty || trimmed == "Spotify Web" || trimmed == "Account" { return true }
        if trimmed.count >= 20, trimmed.allSatisfy({ ($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9") }) {
            return true
        }
        return false
    }

    private static func loginFields(from webSession: SpotifyWebAuthSession) -> [String: String] {
        var fields: [String: String] = [
            "accessToken": webSession.accessToken,
            "expiresAtMs": String(webSession.expiresAtMs),
        ]
        if let spDC = webSession.spDC, !spDC.isEmpty {
            fields["sp_dc"] = spDC
        }
        if let clientToken = webSession.clientToken, !clientToken.isEmpty {
            fields["clientToken"] = clientToken
        }
        if let displayName = webSession.displayName, !displayName.isEmpty {
            fields["displayName"] = displayName
        }
        return fields
    }

    // MARK: - Actions (action/<key>)

    func performAction(pluginID: String, key: String) {
        guard let runtime = registry?.runtime(for: pluginID) else { return }
        actionStates["\(pluginID)::\(key)"] = ActionUIState(running: true, message: nil, isError: false)
        notifyObservers()
        Task {
            do {
                let res = try await runtime.performAction(key: key)
                actionStates["\(pluginID)::\(key)"] = ActionUIState(running: false, message: res.message, isError: false)
            } catch {
                actionStates["\(pluginID)::\(key)"] = ActionUIState(running: false, message: error.localizedDescription, isError: true)
            }
            notifyObservers()
        }
    }

    // MARK: - PLG-9 Download Sources & Downloads Card

    var enabledResolvers: [DiscoveredPlugin] {
        registry?.orderedEnabledResolvers() ?? []
    }

    func moveResolver(from index: Int, to destination: Int) {
        var current = enabledResolvers.map(\.id)
        guard index >= 0, index < current.count, destination >= 0, destination < current.count, index != destination else { return }
        let item = current.remove(at: index)
        current.insert(item, at: destination)
        do {
            try registry?.reorderEnabledResolvers(current)
            if let state = registry?.currentState() {
                resolverOrder = state.resolverOrder
            }
            notifyObservers()
        } catch {
            // keep existing order on write failure
        }
    }

    func movePreferredFormat(from index: Int, to destination: Int) {
        guard index >= 0, index < preferredFormats.count, destination >= 0, destination < preferredFormats.count, index != destination else { return }
        let item = preferredFormats.remove(at: index)
        preferredFormats.insert(item, at: destination)
        persistQualityPolicy()
        notifyObservers()
    }

    func setMinimumBitrate(_ value: Int) {
        let clamped = min(max(value, 64), 320)
        guard clamped != minimumBitrateKbps else { return }
        minimumBitrateKbps = clamped
        persistQualityPolicy()
        notifyObservers()
    }

    func setAcceptYouTubeFallback(_ value: Bool) {
        guard value != acceptYouTubeFallback else { return }
        acceptYouTubeFallback = value
        persistQualityPolicy()
        notifyObservers()
    }

    private func persistQualityPolicy() {
        guard let store else { return }
        PortablePreferences.shared.stageQualityPolicy(
            preferredFormats: preferredFormats,
            minimumBitrateKbps: minimumBitrateKbps,
            acceptYouTubeFallback: acceptYouTubeFallback,
            store: store
        )
    }

    var effectiveDownloadFolderDisplay: String {
        if let custom = downloadFolderOverride, !custom.isEmpty {
            return custom
        }
        return "Downloads › iPod Pro Max (default)"
    }

    func setDownloadFolder(_ folder: URL) {
        guard let store else { return }
        let path = folder.path
        downloadFolderOverride = path
        downloadFolderMissing = Self.isCustomFolderMissing(path)
        notifyObservers()
        Task.detached(priority: .utility) {
            try? store.updateCurrentHost { host in
                host.downloadFolder = path
            }
        }
    }

    func resetDownloadFolder() {
        guard let store else { return }
        downloadFolderOverride = nil
        downloadFolderMissing = false
        notifyObservers()
        Task.detached(priority: .utility) {
            try? store.updateCurrentHost { host in
                host.downloadFolder = nil
            }
        }
    }

    private nonisolated static func normalizedFormats(_ raw: [String]?) -> [String] {
        let defaults = QualityPolicy.defaultPreferredFormats
        guard let raw, !raw.isEmpty else { return defaults }
        let validSet = Set(defaults)
        var filtered = raw.filter { validSet.contains($0) }
        for item in defaults where !filtered.contains(item) && item != "other" {
            filtered.append(item)
        }
        return filtered.isEmpty ? defaults : filtered
    }

    private nonisolated static func isCustomFolderMissing(_ path: String?) -> Bool {
        guard let path, !path.isEmpty else { return false }
        var isDir: ObjCBool = false
        return !FileManager.default.fileExists(atPath: path, isDirectory: &isDir) || !isDir.boolValue
    }

    static func formatDisplayName(_ key: String) -> String {
        switch key {
        case "flac": "FLAC"
        case "alac": "ALAC"
        case "mp3-320": "MP3 320"
        case "aac-256": "AAC 256+"
        case "mp3-v0": "MP3 V0"
        case "other": "Any other format"
        default: key
        }
    }

    // MARK: - PLG-13 Install / Uninstall Packages

    func inspectPackageForInstall(at fileURL: URL) {
        let currentPlugins = self.plugins
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<VerifiedPluginPackage, Error> in
                do { return .success(try PluginPackage.verify(packageURL: fileURL)) }
                catch { return .failure(error) }
            }.value

            switch result {
            case .success(let verified):
                let id = verified.manifest.id
                let existing = currentPlugins.first { $0.id == id && !$0.isUnpacked }
                let unpacked = currentPlugins.contains { $0.id == id && $0.isUnpacked }
                let isDowngrade = existing.map {
                    ManifestValidator.compareVersions(verified.manifest.version, $0.version) == .orderedAscending
                } ?? false
                let inUse = await isPluginInUse(id)
                pendingInstall = PendingPackageInstall(
                    fileURL: fileURL,
                    verified: verified,
                    verificationError: nil,
                    existingInstalled: existing,
                    isDowngrade: isDowngrade,
                    isOverriddenByUnpacked: unpacked,
                    isInUse: inUse
                )
            case .failure(let error):
                pendingInstall = PendingPackageInstall(
                    fileURL: fileURL,
                    verified: nil,
                    verificationError: error.localizedDescription
                )
            }
            notifyObservers()
        }
    }

    func confirmInstall() {
        guard let pending = pendingInstall, let verified = pending.verified, let registry else {
            pendingInstall = nil
            notifyObservers()
            return
        }
        isInstalling = true
        installErrorMessage = nil
        notifyObservers()

        Task {
            do {
                _ = try await registry.install(package: verified)
                isInstalling = false
                pendingInstall = nil
                refreshDiscovery()
            } catch {
                isInstalling = false
                installErrorMessage = error.localizedDescription
                notifyObservers()
            }
        }
    }

    func cancelInstall() {
        guard !isInstalling else { return }
        pendingInstall = nil
        installErrorMessage = nil
        notifyObservers()
    }

    func uninstallPlugin(pluginID: String, deleteSettings: Bool) {
        guard let registry else { return }
        Task {
            try? await registry.uninstall(pluginID: pluginID, deleteSettings: deleteSettings)
            refreshDiscovery()
        }
    }

    // MARK: - PLG-14 Developer Mode & Live Logs

    func setDeveloperMode(_ enabled: Bool) {
        guard let registry else { return }
        do {
            try registry.setDeveloperMode(enabled)
            developerMode = enabled
            notifyObservers()
        } catch {}
    }

    func loadUnpackedPlugin(folderURL: URL) {
        guard let store else { return }
        let path = folderURL.path
        Task {
            await Task.detached(priority: .utility) {
                try? store.updateCurrentHost { host in
                    var list = host.unpackedPlugins ?? []
                    if !list.contains(path) { list.append(path) }
                    host.unpackedPlugins = list
                }
            }.value
            refreshDiscovery()
        }
    }

    func reloadUnpackedPlugin(_ plugin: DiscoveredPlugin) {
        guard let registry else { return }
        Task {
            if let runtime = registry.runtime(for: plugin.id) {
                await runtime.shutdown(timeoutSeconds: 2.0)
            }
            refreshDiscovery()
        }
    }

    func removeUnpackedPlugin(_ plugin: DiscoveredPlugin) {
        guard let store, let registry else { return }
        let path = plugin.rootURL.path
        Task {
            if let runtime = registry.runtime(for: plugin.id) {
                await runtime.shutdown(timeoutSeconds: 2.0)
            }
            await Task.detached(priority: .utility) {
                try? store.updateCurrentHost { host in
                    var list = host.unpackedPlugins ?? []
                    list.removeAll { $0 == path }
                    host.unpackedPlugins = list.isEmpty ? nil : list
                }
            }.value
            refreshDiscovery()
        }
    }

    func openLogWindow(for pluginID: String) {
        if let prev = activeLogPluginID, prev != pluginID, let prevRuntime = registry?.runtime(for: prev) {
            Task { await prevRuntime.setRPCLoggingEnabled(false) }
        }
        activeLogPluginID = pluginID
        if let runtime = registry?.runtime(for: pluginID) {
            Task { await runtime.setRPCLoggingEnabled(true) }
        }
        notifyObservers()
    }

    func closeLogWindow() {
        if let prev = activeLogPluginID, let prevRuntime = registry?.runtime(for: prev) {
            Task { await prevRuntime.setRPCLoggingEnabled(false) }
        }
        activeLogPluginID = nil
        notifyObservers()
    }

    func clearLogs(for pluginID: String) {
        logsByPlugin[pluginID] = []
        notifyObservers()
    }

    func formattedLogText(for pluginID: String) -> String {
        let entries = logsByPlugin[pluginID] ?? []
        let formatter = ISO8601DateFormatter()
        return entries.map { entry in
            "[\(formatter.string(from: entry.timestamp))] [\(entry.kind.rawValue)] \(entry.text)"
        }.joined(separator: "\n")
    }

    private func appendLog(pluginID: String, entry: PluginLogEntry) {
        var list = logsByPlugin[pluginID] ?? []
        list.append(entry)
        if list.count > 2000 {
            list.removeFirst(list.count - 2000)
        }
        logsByPlugin[pluginID] = list
        if activeLogPluginID == pluginID {
            notifyObservers()
        }
    }
}
