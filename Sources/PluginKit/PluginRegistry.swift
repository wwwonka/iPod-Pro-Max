import Foundation

// MARK: - Persistent Registry State (Persistent Data/plugins.json)

public struct PluginsStateFile: Codable, Sendable, Equatable {
    public var version: Int = 1
    public var enabledIDs: [String] = []
    public var resolverOrder: [String] = ["soulseek", "yt-dlp"]
    public var consents: [String: [String]] = [:]
    public var developerMode: Bool = false

    public init(
        version: Int = 1,
        enabledIDs: [String] = [],
        resolverOrder: [String] = ["soulseek", "yt-dlp"],
        consents: [String: [String]] = [:],
        developerMode: Bool = false
    ) {
        self.version = version
        self.enabledIDs = enabledIDs
        self.resolverOrder = resolverOrder
        self.consents = consents
        self.developerMode = developerMode
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        enabledIDs = try c.decodeIfPresent([String].self, forKey: .enabledIDs) ?? []
        resolverOrder = try c.decodeIfPresent([String].self, forKey: .resolverOrder) ?? ["soulseek", "yt-dlp"]
        consents = try c.decodeIfPresent([String: [String]].self, forKey: .consents) ?? [:]
        developerMode = try c.decodeIfPresent(Bool.self, forKey: .developerMode) ?? false
    }

    public func hasConsent(pluginID: String, type: PluginConsentType) -> Bool {
        consents[pluginID]?.contains(type.rawValue) ?? false
    }

    public mutating func grantConsent(pluginID: String, type: PluginConsentType) {
        var list = consents[pluginID] ?? []
        if !list.contains(type.rawValue) {
            list.append(type.rawValue)
            consents[pluginID] = list
        }
    }
}

// MARK: - Discovered Plug-in Record

public struct DiscoveredPlugin: Sendable, Identifiable {
    public enum AvailabilityState: Sendable, Equatable {
        case available
        case unavailable(String) // e.g. "Not available on Windows"
        case error(String)       // e.g. "plugin.json: missing field 'roles'" or "Folder not found"
    }

    public var id: String
    public var name: String
    public var version: String
    public var isUnpacked: Bool
    public var rootURL: URL
    public var manifest: PluginManifest?
    public var executableURL: URL?
    public var badgeSVG: ParsedSVGBadge?
    public var badgeError: String?
    public var warnings: [String]
    public var availability: AvailabilityState
    public var overriddenByUnpacked: Bool = false

    public var isEnabledEligible: Bool {
        if case .available = availability { return !overriddenByUnpacked }
        return false
    }
}

// MARK: - Per-Plugin Settings & Secrets Store

public struct PluginSettingsStore: Sendable {
    public let pluginID: String
    public let settingsURL: URL
    public let secretsURL: URL
    public let dataDirURL: URL

    public init(persistentDataDir: URL, pluginID: String) {
        self.pluginID = pluginID
        let pluginDataRoot = persistentDataDir
            .appendingPathComponent("Plug-ins", isDirectory: true)
            .appendingPathComponent(pluginID, isDirectory: true)
        self.settingsURL = pluginDataRoot.appendingPathComponent("settings.json")
        self.secretsURL = pluginDataRoot.appendingPathComponent("secrets.json")
        self.dataDirURL = pluginDataRoot.appendingPathComponent("Data", isDirectory: true)
    }

    public func loadSettingsDict() -> [String: JSONValue] {
        SafeStorage.readWithBackup([String: JSONValue].self, from: settingsURL) ?? [:]
    }

    public func saveSettingsDict(_ dict: [String: JSONValue]) throws {
        try SafeStorage.writeWithBackup(dict, to: settingsURL)
    }

    public func loadSecretsDict() -> [String: JSONValue] {
        SafeStorage.readWithBackup([String: JSONValue].self, from: secretsURL) ?? [:]
    }

    public func saveSecretsDict(_ dict: [String: JSONValue]) throws {
        try SafeStorage.writeWithBackup(dict, to: secretsURL)
    }

    public var hasAccountSecrets: Bool {
        let secrets = loadSecretsDict()
        return secrets.keys.contains { $0.hasPrefix("_account") || $0 == "token" || $0 == "password" || $0 == "username" }
    }

    public func cachedAccountDisplayName() -> String? {
        loadSettingsDict()["_accountDisplayName"]?.stringValue
    }

    public func setCachedAccountDisplayName(_ name: String?) throws {
        var dict = loadSettingsDict()
        if let name, !name.isEmpty {
            dict["_accountDisplayName"] = .string(name)
        } else {
            dict.removeValue(forKey: "_accountDisplayName")
        }
        try saveSettingsDict(dict)
    }

    public func clearAccountSecrets() throws {
        var secrets = loadSecretsDict()
        for key in secrets.keys where key.hasPrefix("_account") || key == "password" || key == "token" || key == "username" {
            secrets.removeValue(forKey: key)
        }
        try saveSecretsDict(secrets)
        try setCachedAccountDisplayName(nil)
    }

    /// Resolves effective settings to send to the plug-in (matching manifest types, falling back
    /// to defaults on type mismatch or missing folder, and omitting keys removed from the manifest).
    public func resolvedSettings(
        for manifest: PluginManifest,
        folderOverrides: [String: String],
        onWarning: ((String) -> Void)? = nil
    ) -> [String: JSONValue] {
        let storedSettings = loadSettingsDict()
        let storedSecrets = loadSecretsDict()
        var resolved: [String: JSONValue] = [:]

        for def in manifest.settings ?? [] {
            guard !def.isDisplayOnly else { continue }
            if def.isFolder {
                let path = resolveFolderValue(def: def, override: folderOverrides[def.key])
                if let path { resolved[def.key] = .string(path) }
                continue
            }
            let raw = def.isSecret ? storedSecrets[def.key] : storedSettings[def.key]
            if let raw {
                if let coerced = validateValue(raw, for: def) {
                    resolved[def.key] = coerced
                } else {
                    onWarning?("Setting '\(def.key)' in \(def.isSecret ? "secrets.json" : "settings.json") has unexpected type; using default.")
                    if let fallback = defaultValue(for: def) {
                        resolved[def.key] = fallback
                    }
                }
            } else if let fallback = defaultValue(for: def) {
                resolved[def.key] = fallback
            }
        }
        return resolved
    }

    public func resolveFolderValue(def: PluginSettingDefinition, override: String?) -> String? {
        if let override, !override.isEmpty {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: override, isDirectory: &isDir), isDir.boolValue {
                return override
            }
            // Missing folder on this host -> fall back to default
        }
        if let defStr = def.defaultValue?.stringValue {
            if defStr == "downloads" {
                return SafeStorage.defaultDownloadsFolder().path
            }
            return defStr
        }
        return nil
    }

    public func defaultValue(for def: PluginSettingDefinition) -> JSONValue? {
        if let defVal = def.defaultValue {
            return validateValue(defVal, for: def) ?? defVal
        }
        switch def.type {
        case .bool: return .bool(false)
        case .string, .secret: return .string("")
        case .int: return .int(def.min ?? 0)
        case .enum: return def.options?.first.map { .string($0.value) }
        case .orderedList: return .array((def.options ?? []).map { .string($0.value) })
        case .folder: return def.defaultValue
        case .account, .action, .note: return nil
        }
    }

    public func validateValue(_ value: JSONValue, for def: PluginSettingDefinition) -> JSONValue? {
        switch def.type {
        case .bool:
            return value.boolValue.map { .bool($0) }
        case .string, .secret:
            return value.stringValue.map { .string($0) }
        case .int:
            guard let i = value.intValue else { return nil }
            let lo = def.min ?? Int.min
            let hi = def.max ?? Int.max
            return .int(min(max(i, lo), hi))
        case .enum:
            guard let s = value.stringValue else { return nil }
            if let options = def.options, !options.isEmpty, !options.contains(where: { $0.value == s }) {
                return nil
            }
            return .string(s)
        case .orderedList:
            guard let arr = value.stringArrayValue else { return nil }
            if let options = def.options, !options.isEmpty {
                let allowed = Set(options.map(\.value))
                var merged = arr.filter { allowed.contains($0) }
                for opt in options where !merged.contains(opt.value) {
                    merged.append(opt.value)
                }
                return .array(merged.map { .string($0) })
            }
            return .array(arr.map { .string($0) })
        case .folder:
            return value.stringValue.map { .string($0) }
        case .account, .action, .note:
            return nil
        }
    }

    public func isVisible(_ def: PluginSettingDefinition, values: [String: JSONValue]) -> Bool {
        guard let cond = def.visibleIf else { return true }
        return values[cond.key] == cond.equals
    }
}

// MARK: - Registry Manager (PLG-5, PLG-11, PLG-13)

public enum PluginInstallError: LocalizedError, Equatable {
    case noRoot
    case insufficientSpace
    case activeOperation(String)
    case packageError(PluginPackageError)
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .noRoot: "Launch the app from the iPod to manage plug-ins."
        case .insufficientSpace: "Not enough space on the iPod."
        case .activeOperation(let name): "\(name) is currently in use."
        case .packageError(let err): err.errorDescription
        case .io(let msg): msg
        }
    }
}

public final class PluginRegistry: @unchecked Sendable {
    public let iPodRoot: URL
    public let pluginsDir: URL
    public let persistentDataDir: URL
    public let pluginsStateURL: URL
    public let appVersion: String
    public let onIPod: Bool
    public let ffmpegPath: String?

    private let lock = NSLock()
    private var state = PluginsStateFile()
    private var discovered: [DiscoveredPlugin] = []
    private var runtimes: [String: ExternalPlugin] = [:]
    private var unpackedFolders: [String] = []
    private var folderOverridesByPlugin: [String: [String: String]] = [:]

    public var onLogEntry: (@Sendable (String, PluginLogEntry) -> Void)?
    public var onRuntimeStateChanged: (@Sendable (String, ExternalPluginProcessState, PluginStatusUpdate?) -> Void)?
    public var onAccountStatusChanged: (@Sendable (String, PluginAccountStatus) -> Void)?

    public init(
        iPodRoot: URL,
        appVersion: String = "0.1",
        onIPod: Bool = true,
        ffmpegPath: String? = nil
    ) {
        self.iPodRoot = iPodRoot
        let appDir = iPodRoot.appendingPathComponent("iPod Pro Max", isDirectory: true)
        self.pluginsDir = appDir.appendingPathComponent("Plug-ins", isDirectory: true)
        self.persistentDataDir = appDir.appendingPathComponent("Persistent Data", isDirectory: true)
        self.pluginsStateURL = persistentDataDir.appendingPathComponent("plugins.json")
        self.appVersion = appVersion
        self.onIPod = onIPod
        self.ffmpegPath = ffmpegPath
    }

    public func currentState() -> PluginsStateFile {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    public func allPlugins() -> [DiscoveredPlugin] {
        lock.lock(); defer { lock.unlock() }
        return discovered
    }

    public func activePlugin(id: String) -> DiscoveredPlugin? {
        lock.lock(); defer { lock.unlock() }
        return discovered.first { $0.id == id && !$0.overriddenByUnpacked }
    }

    public func runtime(for pluginID: String) -> ExternalPlugin? {
        lock.lock(); defer { lock.unlock() }
        return runtimes[pluginID]
    }

    public func settingsStore(for pluginID: String) -> PluginSettingsStore {
        PluginSettingsStore(persistentDataDir: persistentDataDir, pluginID: pluginID)
    }

    public func setHostConfiguration(
        unpackedFolders: [String],
        folderOverrides: [String: [String: String]]
    ) {
        lock.lock()
        self.unpackedFolders = unpackedFolders
        self.folderOverridesByPlugin = folderOverrides
        lock.unlock()
    }

    public func folderOverrides(for pluginID: String) -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        return folderOverridesByPlugin[pluginID] ?? [:]
    }

    /// Reads `plugins.json` (with `.bak` fallback; resets to all-disabled on double corruption)
    /// and scans `Plug-ins/` + unpacked folders on disk. Call off the main actor.
    @discardableResult
    public func discover(platform: PluginPlatform = .current) -> [DiscoveredPlugin] {
        let loadedState = SafeStorage.readWithBackup(PluginsStateFile.self, from: pluginsStateURL) ?? PluginsStateFile()
        let fm = FileManager.default

        lock.lock()
        let unpacked = self.unpackedFolders
        lock.unlock()

        var unpackedResults: [DiscoveredPlugin] = []
        var activeUnpackedIDs = Set<String>()

        for rawPath in unpacked {
            let folderURL = URL(fileURLWithPath: rawPath, isDirectory: true)
            let plugin = Self.inspectPluginFolder(
                folderURL,
                isUnpacked: true,
                platform: platform
            )
            unpackedResults.append(plugin)
            if !plugin.id.isEmpty, case .available = plugin.availability {
                activeUnpackedIDs.insert(plugin.id)
            } else if !plugin.id.isEmpty {
                activeUnpackedIDs.insert(plugin.id)
            }
        }

        var installedResults: [DiscoveredPlugin] = []
        if let children = try? fm.contentsOfDirectory(
            at: pluginsDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for child in children {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: child.path, isDirectory: &isDir), isDir.boolValue else { continue }
                var plugin = Self.inspectPluginFolder(
                    child,
                    isUnpacked: false,
                    platform: platform
                )
                if activeUnpackedIDs.contains(plugin.id) {
                    plugin.overriddenByUnpacked = true
                }
                installedResults.append(plugin)
            }
        }

        let all = (unpackedResults + installedResults).sorted {
            if $0.name.localizedCaseInsensitiveCompare($1.name) != .orderedSame {
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            return $0.isUnpacked && !$1.isUnpacked
        }

        var newRuntimes: [String: ExternalPlugin] = [:]
        for plugin in all where !plugin.overriddenByUnpacked {
            guard let manifest = plugin.manifest, case .available = plugin.availability else { continue }
            if let existing = runtimes[plugin.id],
               existing.rootURL == plugin.rootURL,
               existing.manifest == manifest,
               existing.executableURL == plugin.executableURL {
                newRuntimes[plugin.id] = existing
            } else {
                newRuntimes[plugin.id] = makeRuntime(for: plugin, manifest: manifest)
            }
        }

        // Keep resolverOrder synced with available resolver plug-ins while preserving disabled spots
        var updatedState = loadedState
        for plugin in all where !plugin.overriddenByUnpacked {
            if let roles = plugin.manifest?.knownRoles, roles.contains(.resolver),
               !updatedState.resolverOrder.contains(plugin.id) {
                updatedState.resolverOrder.append(plugin.id)
            }
        }

        lock.lock()
        self.state = updatedState
        self.discovered = all
        self.runtimes = newRuntimes
        lock.unlock()

        for plugin in all {
            for w in plugin.warnings {
                onLogEntry?(plugin.id, PluginLogEntry(kind: .log, text: "[warning] \(w)"))
            }
            if let badgeErr = plugin.badgeError {
                onLogEntry?(plugin.id, PluginLogEntry(kind: .error, text: "Invalid badge SVG: \(badgeErr)"))
            }
        }
        return all
    }

    private func makeRuntime(for plugin: DiscoveredPlugin, manifest: PluginManifest) -> ExternalPlugin {
        let store = settingsStore(for: plugin.id)
        let hostCaches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let cacheDir = hostCaches.appendingPathComponent("iPodProMax/Plug-ins/\(plugin.id)", isDirectory: true)
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("iPodProMax/Plug-ins/\(plugin.id)", isDirectory: true)
        let paths = PluginPaths(
            data: store.dataDirURL.path,
            cache: cacheDir.path,
            temp: tempDir.path,
            ffmpeg: ffmpegPath
        )

        return ExternalPlugin(
            manifest: manifest,
            rootURL: plugin.rootURL,
            executableURL: plugin.executableURL,
            hostInfo: .current(appVersion: appVersion, onIPod: onIPod),
            paths: paths,
            settingsProvider: { [weak self] in
                guard let self else { return [:] }
                let overrides = self.folderOverrides(for: plugin.id)
                return store.resolvedSettings(for: manifest, folderOverrides: overrides) { [weak self] warn in
                    self?.onLogEntry?(plugin.id, PluginLogEntry(kind: .log, text: "[warning] \(warn)"))
                }
            },
            onStateChanged: { [weak self] procState, status in
                self?.onRuntimeStateChanged?(plugin.id, procState, status)
            },
            onLogLine: { [weak self] entry in
                self?.onLogEntry?(plugin.id, entry)
            },
            onAccountStatus: { [weak self] accStatus in
                if let name = accStatus.displayName {
                    try? store.setCachedAccountDisplayName(name)
                } else if accStatus.status == "signedOut" {
                    try? store.setCachedAccountDisplayName(nil)
                }
                self?.onAccountStatusChanged?(plugin.id, accStatus)
            }
        )
    }

    public static func inspectPluginFolder(
        _ folderURL: URL,
        isUnpacked: Bool,
        platform: PluginPlatform = .current
    ) -> DiscoveredPlugin {
        let fm = FileManager.default
        let fallbackName = folderURL.lastPathComponent

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: folderURL.path, isDirectory: &isDir), isDir.boolValue else {
            return DiscoveredPlugin(
                id: fallbackName,
                name: fallbackName,
                version: "",
                isUnpacked: isUnpacked,
                rootURL: folderURL,
                manifest: nil,
                executableURL: nil,
                badgeSVG: nil,
                badgeError: nil,
                warnings: [],
                availability: .error("Folder not found")
            )
        }

        let manifestURL = folderURL.appendingPathComponent("plugin.json")
        let validated: ValidatedManifest
        do {
            validated = try ManifestValidator.loadAndValidate(
                from: manifestURL,
                expectedFolderName: isUnpacked ? nil : folderURL.lastPathComponent,
                platform: platform
            )
        } catch {
            return DiscoveredPlugin(
                id: fallbackName,
                name: fallbackName,
                version: "",
                isUnpacked: isUnpacked,
                rootURL: folderURL,
                manifest: nil,
                executableURL: nil,
                badgeSVG: nil,
                badgeError: nil,
                warnings: [],
                availability: .error(error.localizedDescription)
            )
        }

        let manifest = validated.manifest
        var badgeSVG: ParsedSVGBadge?
        var badgeError: String?
        if let badgeRel = manifest.badge, !badgeRel.isEmpty {
            let badgeURL = folderURL.appendingPathComponent(badgeRel)
            if let data = try? Data(contentsOf: badgeURL) {
                do {
                    badgeSVG = try SVGBadgeParser.parse(data: data)
                } catch {
                    badgeError = error.localizedDescription
                }
            } else {
                badgeError = "Badge file '\(badgeRel)' could not be read"
            }
        }

        guard let execRel = validated.executableRelativePath else {
            return DiscoveredPlugin(
                id: manifest.id,
                name: manifest.name,
                version: manifest.version,
                isUnpacked: isUnpacked,
                rootURL: folderURL,
                manifest: manifest,
                executableURL: nil,
                badgeSVG: badgeSVG,
                badgeError: badgeError,
                warnings: validated.warnings,
                availability: .unavailable("Not available on \(PluginPlatform.osDisplayName)")
            )
        }

        let execURL = folderURL.appendingPathComponent(execRel)
        return DiscoveredPlugin(
            id: manifest.id,
            name: manifest.name,
            version: manifest.version,
            isUnpacked: isUnpacked,
            rootURL: folderURL,
            manifest: manifest,
            executableURL: execURL,
            badgeSVG: badgeSVG,
            badgeError: badgeError,
            warnings: validated.warnings,
            availability: .available
        )
    }

    // MARK: - Enable / Consent / Resolver Order

    public func isEnabled(_ pluginID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return state.enabledIDs.contains(pluginID)
    }

    public func needsConsent(for plugin: DiscoveredPlugin) -> PluginConsentType? {
        guard let consent = plugin.manifest?.requiresConsent else { return nil }
        lock.lock(); defer { lock.unlock() }
        return state.hasConsent(pluginID: plugin.id, type: consent) ? nil : consent
    }

    public func grantConsentAndEnable(pluginID: String, type: PluginConsentType) throws {
        try mutateState { s in
            s.grantConsent(pluginID: pluginID, type: type)
            if !s.enabledIDs.contains(pluginID) {
                s.enabledIDs.append(pluginID)
            }
        }
    }

    public func setEnabled(_ enabled: Bool, pluginID: String) throws {
        try mutateState { s in
            if enabled {
                if !s.enabledIDs.contains(pluginID) {
                    s.enabledIDs.append(pluginID)
                }
            } else {
                s.enabledIDs.removeAll { $0 == pluginID }
            }
        }
    }

    public func setDeveloperMode(_ enabled: Bool) throws {
        try mutateState { s in
            s.developerMode = enabled
        }
    }

    /// Enabled plug-ins that implement `resolver`, sorted according to `resolverOrder`.
    public func orderedEnabledResolvers() -> [DiscoveredPlugin] {
        lock.lock()
        let currentState = self.state
        let currentPlugins = self.discovered
        lock.unlock()

        let activeResolvers = currentPlugins.filter { plugin in
            !plugin.overriddenByUnpacked
                && plugin.isEnabledEligible
                && currentState.enabledIDs.contains(plugin.id)
                && (plugin.manifest?.knownRoles.contains(.resolver) ?? false)
        }
        var byID = Dictionary(uniqueKeysWithValues: activeResolvers.map { ($0.id, $0) })
        var ordered: [DiscoveredPlugin] = []
        for id in currentState.resolverOrder {
            if let match = byID.removeValue(forKey: id) {
                ordered.append(match)
            }
        }
        for plugin in activeResolvers where byID[plugin.id] != nil {
            ordered.append(plugin)
        }
        return ordered
    }

    /// Updates the order of currently enabled resolvers while keeping disabled resolvers' slots intact.
    public func reorderEnabledResolvers(_ newEnabledOrder: [String]) throws {
        try mutateState { s in
            let enabledSet = Set(newEnabledOrder)
            var result: [String] = []
            var queue = newEnabledOrder
            for existing in s.resolverOrder {
                if enabledSet.contains(existing) {
                    if !queue.isEmpty {
                        result.append(queue.removeFirst())
                    }
                } else {
                    result.append(existing)
                }
            }
            for remaining in queue where !result.contains(remaining) {
                result.append(remaining)
            }
            s.resolverOrder = result
        }
    }

    /// Matches a pasted URL against `urlPatterns` of `playlistSource` plug-ins (without launching processes).
    /// Returns the first match in alphabetical order of `id` (logging a warning if multiple match).
    public func matchPlaylistSource(for urlString: String, includeDisabled: Bool = false) -> DiscoveredPlugin? {
        lock.lock()
        let enabledSet = Set(state.enabledIDs)
        let candidates = discovered.filter { plugin in
            guard !plugin.overriddenByUnpacked,
                  let manifest = plugin.manifest,
                  manifest.knownRoles.contains(.playlistSource) else { return false }
            if !includeDisabled && !enabledSet.contains(plugin.id) { return false }
            return manifest.matchesURL(urlString)
        }.sorted { $0.id < $1.id }
        lock.unlock()

        if candidates.count > 1 {
            onLogEntry?(candidates[0].id, PluginLogEntry(
                kind: .log,
                text: "[warning] Multiple playlistSource plug-ins match URL; using '\(candidates[0].id)'."
            ))
        }
        return candidates.first
    }

    public func mutateState(_ block: (inout PluginsStateFile) -> Void) throws {
        lock.lock()
        var copy = state
        block(&copy)
        lock.unlock()

        try SafeStorage.writeWithBackup(copy, to: pluginsStateURL)

        lock.lock()
        state = copy
        lock.unlock()
    }

    // MARK: - Package Installation & Removal (PLG-13)

    /// Installs or updates a verified `.ippmplugin` package atomically into `Plug-ins/<id>/`.
    public func install(
        package: VerifiedPluginPackage,
        platform: PluginPlatform = .current
    ) async throws -> DiscoveredPlugin {
        let id = package.manifest.id
        let fm = FileManager.default
        try fm.createDirectory(at: pluginsDir, withIntermediateDirectories: true)

        if let free = SafeStorage.availableBytes(at: pluginsDir),
           free < package.totalUncompressedSize + 1_048_576 {
            throw PluginInstallError.insufficientSpace
        }

        if let running = runtime(for: id) {
            await running.shutdown(timeoutSeconds: 5.0)
        }

        let staging = pluginsDir.appendingPathComponent(".\(id).installing", isDirectory: true)
        let dest = pluginsDir.appendingPathComponent(id, isDirectory: true)
        let oldBackup = pluginsDir.appendingPathComponent(".\(id).old", isDirectory: true)

        if fm.fileExists(atPath: staging.path) { try? fm.removeItem(at: staging) }
        if fm.fileExists(atPath: oldBackup.path) { try? fm.removeItem(at: oldBackup) }

        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            for entry in package.entries {
                let target = staging.appendingPathComponent(entry.path)
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try entry.data.write(to: target, options: .atomic)
                #if !os(Windows)
                try? fm.setAttributes([.posixPermissions: NSNumber(value: entry.unixPermissions)], ofItemAtPath: target.path)
                #endif
            }

            SafeStorage.prepareInstalledExecutables(in: staging, manifest: package.manifest)

            if fm.fileExists(atPath: dest.path) {
                try fm.moveItem(at: dest, to: oldBackup)
            }
            do {
                try fm.moveItem(at: staging, to: dest)
            } catch {
                if fm.fileExists(atPath: oldBackup.path), !fm.fileExists(atPath: dest.path) {
                    try? fm.moveItem(at: oldBackup, to: dest)
                }
                throw error
            }
            if fm.fileExists(atPath: oldBackup.path) {
                try? fm.removeItem(at: oldBackup)
            }
        } catch {
            try? fm.removeItem(at: staging)
            throw PluginInstallError.io(error.localizedDescription)
        }

        let all = discover(platform: platform)
        guard let installed = all.first(where: { $0.id == id && !$0.isUnpacked }) else {
            throw PluginInstallError.io("Installed plug-in could not be loaded.")
        }
        return installed
    }

    public func uninstall(pluginID: String, deleteSettings: Bool, platform: PluginPlatform = .current) async throws {
        if let running = runtime(for: pluginID) {
            await running.shutdown(timeoutSeconds: 5.0)
        }
        let fm = FileManager.default
        let dest = pluginsDir.appendingPathComponent(pluginID, isDirectory: true)
        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }
        try mutateState { s in
            s.enabledIDs.removeAll { $0 == pluginID }
            if deleteSettings {
                s.consents.removeValue(forKey: pluginID)
                s.resolverOrder.removeAll { $0 == pluginID }
            }
        }
        if deleteSettings {
            let dataFolder = persistentDataDir
                .appendingPathComponent("Plug-ins", isDirectory: true)
                .appendingPathComponent(pluginID, isDirectory: true)
            if fm.fileExists(atPath: dataFolder.path) {
                try? fm.removeItem(at: dataFolder)
            }
        }
        _ = discover(platform: platform)
    }

    private func allRuntimes() -> [ExternalPlugin] {
        lock.lock(); defer { lock.unlock() }
        return Array(runtimes.values)
    }

    public func shutdownAll(timeoutSeconds: Double = 2.0) async {
        let all = allRuntimes()
        await withTaskGroup(of: Void.self) { group in
            for rt in all {
                group.addTask {
                    await rt.shutdown(timeoutSeconds: timeoutSeconds)
                }
            }
        }
    }
}
