import Foundation
import PluginKit

/// Manages persistent automatic (`ipod-xxxxxx`) and personal Soulseek credentials (`SLSK-4`, `SLSK-5`).
/// Stored atomically in `Persistent Data/Plug-ins/soulseek/secrets.json`.
public actor IdentityManager {
    public struct Credentials: Codable, Sendable, Equatable {
        public var mode: String // "auto" or "account"
        public var username: String
        public var password: String
    }

    private let secretsFileURL: URL
    private var cached: Credentials?

    public init(dataDirectory: String) {
        let dataURL = URL(fileURLWithPath: dataDirectory, isDirectory: true)
        let parent = dataURL.deletingLastPathComponent()
        self.secretsFileURL = parent.appendingPathComponent("secrets.json", isDirectory: false)
    }

    public func currentOrGenerate() -> Credentials {
        if let cached { return cached }
        if let loaded = loadFromDisk(), !loaded.username.isEmpty, !loaded.password.isEmpty {
            self.cached = loaded
            return loaded
        }
        let fresh = Credentials(
            mode: "auto",
            username: Self.generateUsername(),
            password: Self.generatePassword()
        )
        saveToDisk(fresh)
        self.cached = fresh
        return fresh
    }

    public func regenerateAutoIdentity() -> Credentials {
        let fresh = Credentials(
            mode: "auto",
            username: Self.generateUsername(),
            password: Self.generatePassword()
        )
        saveToDisk(fresh)
        self.cached = fresh
        return fresh
    }

    public func setPersonalAccount(username: String, password: String) -> Credentials {
        let creds = Credentials(mode: "account", username: username, password: password)
        saveToDisk(creds)
        self.cached = creds
        return creds
    }

    public func currentStatus() -> PluginAccountStatus {
        let creds = loadFromDisk() ?? cached
        guard let creds, !creds.username.isEmpty else {
            return PluginAccountStatus(status: "signedOut")
        }
        return PluginAccountStatus(status: "signedIn", displayName: creds.username)
    }

    public func clearCacheForReset() {
        cached = nil
    }

    // MARK: - Persistence & Generators

    private func loadFromDisk() -> Credentials? {
        guard let data = try? Data(contentsOf: secretsFileURL),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let mode = (raw["mode"] as? String) ?? "auto"
        let user = (raw["username"] as? String) ?? ""
        let pass = (raw["password"] as? String) ?? ""
        guard !user.isEmpty, !pass.isEmpty else { return nil }
        return Credentials(mode: mode, username: user, password: pass)
    }

    private func saveToDisk(_ creds: Credentials) {
        let dir = secretsFileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let payload: [String: Any] = [
            "mode": creds.mode,
            "username": creds.username,
            "password": creds.password,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        let tmp = dir.appendingPathComponent(".secrets.\(UUID().uuidString).tmp")
        try? data.write(to: tmp, options: .atomic)
        let fm = FileManager.default
        #if os(macOS)
        if fm.fileExists(atPath: secretsFileURL.path) {
            _ = try? fm.replaceItemAt(secretsFileURL, withItemAt: tmp)
        } else {
            try? fm.moveItem(at: tmp, to: secretsFileURL)
        }
        #else
        if fm.fileExists(atPath: secretsFileURL.path) {
            try? fm.removeItem(at: secretsFileURL)
        }
        try? fm.moveItem(at: tmp, to: secretsFileURL)
        #endif
    }

    public static func generateUsername() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        let suffix = (0..<6).map { _ in alphabet[Int.random(in: 0..<alphabet.count)] }
        return "ipod-" + String(suffix)
    }

    public static func generatePassword() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*-_")
        let chars = (0..<24).map { _ in alphabet[Int.random(in: 0..<alphabet.count)] }
        return String(chars)
    }
}
