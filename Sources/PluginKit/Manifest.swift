import Foundation

public enum PluginContract {
    public static let supportedAPIVersion = 1
}

public enum PluginConsentType: String, Codable, Sendable, Equatable, Hashable {
    case p2p
    case scraping

    public func alertTitle(pluginName: String) -> String {
        switch self {
        case .p2p: "Enable peer-to-peer sharing?"
        case .scraping: "Enable \(pluginName)?"
        }
    }

    public func alertMessage(pluginName: String, serviceName: String?) -> String {
        switch self {
        case .p2p:
            return "\(pluginName) downloads from and shares with other users on a public network. You are responsible for what you download and share, and for following the laws where you live."
        case .scraping:
            let service = (serviceName?.isEmpty == false ? serviceName! : pluginName)
            return "\(pluginName) reads data from \(service) without an official API. It may stop working at any time, and may go against the service's terms of use."
        }
    }
}

public enum PluginSettingType: String, Codable, Sendable, Equatable {
    case bool
    case string
    case secret
    case int
    case `enum`
    case orderedList
    case folder
    case account
    case action
    case note
}

public struct PluginEnumOption: Codable, Sendable, Equatable, Hashable {
    public var value: String
    public var label: String

    public init(value: String, label: String) {
        self.value = value
        self.label = label
    }
}

public struct PluginVisibilityCondition: Codable, Sendable, Equatable {
    public var key: String
    public var equals: JSONValue

    public init(key: String, equals: JSONValue) {
        self.key = key
        self.equals = equals
    }
}

public struct PluginAccountField: Codable, Sendable, Equatable {
    public var key: String
    public var label: String
    public var type: String?
    public var placeholder: String?
    public var required: Bool?

    public init(
        key: String,
        label: String,
        type: String? = nil,
        placeholder: String? = nil,
        required: Bool? = nil
    ) {
        self.key = key
        self.label = label
        self.type = type
        self.placeholder = placeholder
        self.required = required
    }

    public var isSecret: Bool { type == "secret" }
    public var isRequired: Bool { required ?? true }
}

public struct PluginSettingDefinition: Codable, Sendable, Equatable {
    public var key: String
    public var type: PluginSettingType
    public var label: String?
    public var help: String?
    public var visibleIf: PluginVisibilityCondition?
    public var defaultValue: JSONValue?
    public var placeholder: String?
    public var min: Int?
    public var max: Int?
    public var unit: String?
    public var options: [PluginEnumOption]?
    public var fields: [PluginAccountField]?
    public var oauth: Bool?
    public var autoIdentity: Bool?
    public var text: String?

    enum CodingKeys: String, CodingKey {
        case key, type, label, help, visibleIf
        case defaultValue = "default"
        case placeholder, min, max, unit, options, fields, oauth, autoIdentity, text
    }

    public init(
        key: String,
        type: PluginSettingType,
        label: String? = nil,
        help: String? = nil,
        visibleIf: PluginVisibilityCondition? = nil,
        defaultValue: JSONValue? = nil,
        placeholder: String? = nil,
        min: Int? = nil,
        max: Int? = nil,
        unit: String? = nil,
        options: [PluginEnumOption]? = nil,
        fields: [PluginAccountField]? = nil,
        oauth: Bool? = nil,
        autoIdentity: Bool? = nil,
        text: String? = nil
    ) {
        self.key = key
        self.type = type
        self.label = label
        self.help = help
        self.visibleIf = visibleIf
        self.defaultValue = defaultValue
        self.placeholder = placeholder
        self.min = min
        self.max = max
        self.unit = unit
        self.options = options
        self.fields = fields
        self.oauth = oauth
        self.autoIdentity = autoIdentity
        self.text = text
    }

    public var isSecret: Bool { type == .secret }
    public var isFolder: Bool { type == .folder }
    public var isDisplayOnly: Bool { type == .note || type == .action || type == .account }
}

public struct PluginManifest: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var version: String
    public var apiVersion: Int
    public var description: String
    public var author: String?
    public var license: String?
    public var serviceName: String?
    public var roles: [String]
    public var executable: [String: String]
    public var urlPatterns: [String]?
    public var badge: String?
    public var requiresConsent: PluginConsentType?
    public var settings: [PluginSettingDefinition]?
    public var config: [String: JSONValue]?

    public init(
        id: String,
        name: String,
        version: String,
        apiVersion: Int = PluginContract.supportedAPIVersion,
        description: String,
        author: String? = nil,
        license: String? = nil,
        serviceName: String? = nil,
        roles: [String],
        executable: [String: String],
        urlPatterns: [String]? = nil,
        badge: String? = nil,
        requiresConsent: PluginConsentType? = nil,
        settings: [PluginSettingDefinition]? = nil,
        config: [String: JSONValue]? = nil
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.apiVersion = apiVersion
        self.description = description
        self.author = author
        self.license = license
        self.serviceName = serviceName
        self.roles = roles
        self.executable = executable
        self.urlPatterns = urlPatterns
        self.badge = badge
        self.requiresConsent = requiresConsent
        self.settings = settings
        self.config = config
    }

    /// Supported roles parsed from `roles` (unknown roles are ignored with warnings).
    public var knownRoles: [PluginRole] {
        var seen = Set<PluginRole>()
        var out: [PluginRole] = []
        for raw in roles {
            if let role = PluginRole(rawValue: raw), seen.insert(role).inserted {
                out.append(role)
            }
        }
        return out
    }

    public var unknownRoles: [String] {
        roles.filter { PluginRole(rawValue: $0) == nil }
    }

    /// Compiles `urlPatterns` into regular expressions.
    public func compiledURLPatterns() -> [NSRegularExpression] {
        (urlPatterns ?? []).compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
    }

    public func matchesURL(_ urlString: String) -> Bool {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        return compiledURLPatterns().contains { $0.firstMatch(in: trimmed, range: range) != nil }
    }
}

public enum PluginPlatform: String, Sendable {
    case macos
    case windowsX64 = "windows-x64"
    case windowsARM64 = "windows-arm64"
    case linuxX86_64 = "linux-x86_64"
    case linuxAarch64 = "linux-aarch64"

    public static var current: PluginPlatform {
        #if os(macOS)
        return .macos
        #elseif os(Windows)
        #if arch(arm64)
        return .windowsARM64
        #else
        return .windowsX64
        #endif
        #else
        #if arch(arm64)
        return .linuxAarch64
        #else
        return .linuxX86_64
        #endif
        #endif
    }

    public static var osDisplayName: String {
        #if os(macOS)
        return "macOS"
        #elseif os(Windows)
        return "Windows"
        #else
        return "Linux"
        #endif
    }

    /// Keys to look up in `manifest.executable` in preference order.
    public var executableKeys: [String] {
        switch self {
        case .macos: ["macos"]
        case .windowsX64: ["windows-x64"]
        case .windowsARM64: ["windows-arm64", "windows-x64"]
        case .linuxX86_64: ["linux-x86_64"]
        case .linuxAarch64: ["linux-aarch64"]
        }
    }
}

public enum ManifestValidationError: LocalizedError, Equatable {
    case unreadable(String)
    case missingField(String)
    case invalidField(String, String)
    case folderNameMismatch
    case unsupportedAPIVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let msg): "plugin.json: \(msg)"
        case .missingField(let field): "plugin.json: missing field '\(field)'"
        case .invalidField(let field, let reason): "plugin.json: invalid '\(field)' (\(reason))"
        case .folderNameMismatch: "Folder name doesn't match plug-in id"
        case .unsupportedAPIVersion(let v): "plugin.json: unsupported apiVersion \(v) (app supports \(PluginContract.supportedAPIVersion))"
        }
    }
}

public struct ValidatedManifest: Sendable, Equatable {
    public var manifest: PluginManifest
    public var warnings: [String]
    public var executableRelativePath: String?

    public init(manifest: PluginManifest, warnings: [String], executableRelativePath: String?) {
        self.manifest = manifest
        self.warnings = warnings
        self.executableRelativePath = executableRelativePath
    }
}

public enum ManifestValidator {
    private static let requiredFields = ["id", "name", "version", "apiVersion", "description", "roles", "executable"]

    public static func loadAndValidate(
        from manifestURL: URL,
        expectedFolderName: String? = nil,
        platform: PluginPlatform = .current
    ) throws -> ValidatedManifest {
        let data: Data
        do {
            data = try Data(contentsOf: manifestURL)
        } catch {
            throw ManifestValidationError.unreadable(error.localizedDescription)
        }
        return try validate(data: data, expectedFolderName: expectedFolderName, platform: platform)
    }

    public static func validate(
        data: Data,
        expectedFolderName: String? = nil,
        platform: PluginPlatform = .current
    ) throws -> ValidatedManifest {
        let rawObj: [String: Any]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ManifestValidationError.unreadable("root must be a JSON object")
            }
            rawObj = parsed
        } catch let e as ManifestValidationError {
            throw e
        } catch {
            throw ManifestValidationError.unreadable("invalid JSON (\(error.localizedDescription))")
        }

        for field in requiredFields where rawObj[field] == nil {
            throw ManifestValidationError.missingField(field)
        }

        let manifest: PluginManifest
        do {
            manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
        } catch let DecodingError.keyNotFound(key, _) {
            throw ManifestValidationError.missingField(key.stringValue)
        } catch let DecodingError.typeMismatch(_, ctx) {
            let field = ctx.codingPath.first?.stringValue ?? "manifest"
            throw ManifestValidationError.invalidField(field, ctx.debugDescription)
        } catch {
            throw ManifestValidationError.unreadable(error.localizedDescription)
        }

        guard isValidID(manifest.id) else {
            throw ManifestValidationError.invalidField("id", "must contain only lowercase letters, digits and hyphens")
        }
        if let expectedFolderName, manifest.id != expectedFolderName {
            throw ManifestValidationError.folderNameMismatch
        }
        guard !manifest.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ManifestValidationError.invalidField("name", "must not be empty")
        }
        guard !manifest.version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ManifestValidationError.invalidField("version", "must not be empty")
        }
        guard manifest.apiVersion >= 1, manifest.apiVersion <= PluginContract.supportedAPIVersion else {
            throw ManifestValidationError.unsupportedAPIVersion(manifest.apiVersion)
        }
        guard !manifest.roles.isEmpty else {
            throw ManifestValidationError.invalidField("roles", "must contain at least one role")
        }

        var warnings: [String] = []
        for unknown in manifest.unknownRoles {
            warnings.append("Unknown role '\(unknown)' ignored.")
        }

        // Validate urlPatterns compile cleanly if present
        for pattern in manifest.urlPatterns ?? [] {
            do {
                _ = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            } catch {
                throw ManifestValidationError.invalidField("urlPatterns", "invalid regex '\(pattern)'")
            }
        }

        // Validate settings keys are unique
        if let settings = manifest.settings {
            var seenKeys = Set<String>()
            for s in settings {
                guard !s.key.isEmpty else {
                    throw ManifestValidationError.invalidField("settings", "setting key must not be empty")
                }
                guard seenKeys.insert(s.key).inserted else {
                    throw ManifestValidationError.invalidField("settings", "duplicate setting key '\(s.key)'")
                }
            }
        }

        let executablePath = platform.executableKeys.compactMap { key -> String? in
            guard let path = manifest.executable[key], !path.isEmpty else { return nil }
            return path
        }.first

        return ValidatedManifest(
            manifest: manifest,
            warnings: warnings,
            executableRelativePath: executablePath
        )
    }

    public static func isValidID(_ id: String) -> Bool {
        guard !id.isEmpty else { return false }
        return id.unicodeScalars.allSatisfy { scalar in
            (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9") || scalar == "-"
        }
    }

    /// Compares semantic versions (`1.2.3`). Returns `.orderedAscending` when `lhs < rhs`.
    public static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let a = lhs.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        let b = rhs.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        let count = max(a.count, b.count)
        for i in 0..<count {
            let av = i < a.count ? a[i] : 0
            let bv = i < b.count ? b[i] : 0
            if av < bv { return .orderedAscending }
            if av > bv { return .orderedDescending }
        }
        return lhs.compare(rhs, options: .numeric)
    }
}
