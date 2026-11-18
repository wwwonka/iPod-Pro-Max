import Foundation

public enum PluginPackageError: LocalizedError, Equatable {
    case unreadable(String)
    case damaged(String)
    case validation(ManifestValidationError)
    case missingExecutableForOS(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable: "This plug-in is damaged and can't be installed."
        case .damaged: "This plug-in is damaged and can't be installed."
        case .validation(let err): err.errorDescription
        case .missingExecutableForOS(let os): "Not available on \(os)"
        }
    }

    public var detailedReason: String {
        switch self {
        case .unreadable(let msg): msg
        case .damaged(let msg): msg
        case .validation(let err): err.localizedDescription
        case .missingExecutableForOS(let os): "Not available on \(os)"
        }
    }
}

public struct VerifiedPluginPackage: Sendable {
    public var validatedManifest: ValidatedManifest
    public var entries: [ZipEntry]
    public var totalUncompressedSize: Int64

    public var manifest: PluginManifest { validatedManifest.manifest }
}

/// Verification and packaging of `.ippmplugin` archives (`PLG-12`).
public enum PluginPackage {
    /// Verifies a `.ippmplugin` archive in the spec's exact order:
    /// 1. zip readable
    /// 2. `plugin.json` valid
    /// 3. `apiVersion` supported
    /// 4. executable present for current OS
    /// 5. `SHA256SUMS` matches every other file.
    public static func verify(
        packageURL: URL,
        platform: PluginPlatform = .current
    ) throws -> VerifiedPluginPackage {
        let entries: [ZipEntry]
        do {
            entries = try ZipArchive.read(from: packageURL)
        } catch {
            throw PluginPackageError.unreadable(error.localizedDescription)
        }

        var byPath: [String: ZipEntry] = [:]
        var totalSize: Int64 = 0
        for entry in entries {
            guard byPath[entry.path] == nil else {
                throw PluginPackageError.damaged("Duplicate entry '\(entry.path)'")
            }
            byPath[entry.path] = entry
            totalSize += Int64(entry.data.count)
        }

        // 2 & 3. plugin.json valid and apiVersion supported
        guard let manifestEntry = byPath["plugin.json"] else {
            throw PluginPackageError.validation(.missingField("plugin.json"))
        }
        let validated: ValidatedManifest
        do {
            validated = try ManifestValidator.validate(
                data: manifestEntry.data,
                expectedFolderName: nil,
                platform: platform
            )
        } catch let err as ManifestValidationError {
            throw PluginPackageError.validation(err)
        } catch {
            throw PluginPackageError.unreadable(error.localizedDescription)
        }

        // 4. Executable present for current OS
        guard let execRel = validated.executableRelativePath,
              let cleanExec = try? ZipArchive.sanitizeRelativePath(execRel),
              byPath[cleanExec] != nil else {
            throw PluginPackageError.missingExecutableForOS(PluginPlatform.osDisplayName)
        }

        // 5. SHA256SUMS covers all other files
        guard let sumsEntry = byPath["SHA256SUMS"],
              let sumsText = String(data: sumsEntry.data, encoding: .utf8) else {
            throw PluginPackageError.damaged("Missing SHA256SUMS")
        }

        let expectedSums = try parseSHA256Sums(sumsText)
        let otherPaths = Set(byPath.keys.filter { $0 != "SHA256SUMS" })
        guard Set(expectedSums.keys) == otherPaths else {
            throw PluginPackageError.damaged("SHA256SUMS file list mismatch")
        }
        for (path, expectedDigest) in expectedSums {
            guard let entry = byPath[path] else {
                throw PluginPackageError.damaged("Missing file '\(path)'")
            }
            let actual = SHA256.hex(entry.data)
            if actual != expectedDigest {
                throw PluginPackageError.damaged("SHA-256 mismatch for '\(path)'")
            }
        }

        return VerifiedPluginPackage(
            validatedManifest: validated,
            entries: entries,
            totalUncompressedSize: totalSize
        )
    }

    /// Packs a plug-in folder (containing `plugin.json`, `bin/`, optional `vendor/`, `badge.svg`,
    /// `LICENSE`, `README.md`) into a `.ippmplugin` archive with `SHA256SUMS`.
    public static func pack(
        folderURL: URL,
        outputURL: URL,
        platform: PluginPlatform = .current
    ) throws -> ValidatedManifest {
        let manifestURL = folderURL.appendingPathComponent("plugin.json")
        let validated = try ManifestValidator.loadAndValidate(from: manifestURL, platform: platform)

        let allowedTopLevel: Set<String> = [
            "plugin.json", "bin", "vendor", "badge.svg", "LICENSE", "README.md"
        ]
        var declaredExecutables = Set<String>()
        for (_, rel) in validated.manifest.executable {
            if let clean = try? ZipArchive.sanitizeRelativePath(rel) {
                declaredExecutables.insert(clean)
            }
        }

        let fm = FileManager.default
        var collected: [ZipEntry] = []

        func collectItem(at url: URL, relativePath: String) throws {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return }
            if isDir.boolValue {
                let children = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey], options: [.skipsHiddenFiles])
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
                for child in children {
                    try collectItem(at: child, relativePath: "\(relativePath)/\(child.lastPathComponent)")
                }
            } else {
                let data = try Data(contentsOf: url)
                let attrs = try? fm.attributesOfItem(atPath: url.path)
                let posix = (attrs?[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o644
                let isExec = declaredExecutables.contains(relativePath)
                    || relativePath.hasPrefix("bin/")
                    || relativePath.hasPrefix("vendor/")
                let mode: UInt16 = isExec ? (posix | 0o111) : (posix & 0o666)
                collected.append(ZipEntry(path: relativePath, data: data, unixPermissions: mode))
            }
        }

        for name in allowedTopLevel.sorted() {
            let itemURL = folderURL.appendingPathComponent(name)
            try collectItem(at: itemURL, relativePath: name)
        }
        if let badge = validated.manifest.badge,
           let cleanBadge = try? ZipArchive.sanitizeRelativePath(badge),
           !collected.contains(where: { $0.path == cleanBadge }) {
            let badgeURL = folderURL.appendingPathComponent(cleanBadge)
            if fm.fileExists(atPath: badgeURL.path) {
                try collectItem(at: badgeURL, relativePath: cleanBadge)
            }
        }

        collected.sort { $0.path < $1.path }
        var sumsLines: [String] = []
        for entry in collected {
            sumsLines.append("\(SHA256.hex(entry.data))  \(entry.path)")
        }
        let sumsData = Data((sumsLines.joined(separator: "\n") + "\n").utf8)
        collected.append(ZipEntry(path: "SHA256SUMS", data: sumsData, unixPermissions: 0o644))

        try ZipArchive.write(entries: collected, to: outputURL)
        return validated
    }

    public static func parseSHA256Sums(_ text: String) throws -> [String: String] {
        var result: [String: String] = [:]
        let lines = text.split(whereSeparator: \.isNewline)
        for rawLine in lines {
            let line = String(rawLine)
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            // Format: "<64-hex>  <path>" (or single space)
            guard line.count >= 66 else {
                throw PluginPackageError.damaged("Malformed SHA256SUMS line")
            }
            let hash = String(line.prefix(64)).lowercased()
            guard hash.unicodeScalars.allSatisfy({ ($0 >= "0" && $0 <= "9") || ($0 >= "a" && $0 <= "f") }) else {
                throw PluginPackageError.damaged("Invalid digest in SHA256SUMS")
            }
            var rest = line.dropFirst(64)
            while rest.first == " " || rest.first == "*" {
                rest = rest.dropFirst()
            }
            let path = try ZipArchive.sanitizeRelativePath(String(rest))
            result[path] = hash
        }
        return result
    }
}
