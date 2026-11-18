import Foundation
import PluginKit

/// Exposes Soulseek as `Resolver`, `Downloader`, `ShareProvider`, `PluginConfigurable`,
/// and `PluginAccountHandling` (`SLSK-4`…`SLSK-14`).
public actor SoulseekHandler: Resolver, Downloader, ShareProvider, PluginConfigurable, PluginAccountHandling {
    private var context: (any PluginRuntimeContext)?
    private var identity: IdentityManager?
    private var client: SoulseekClient?

    private var shareEnabled: Bool = true
    private var listenPort: UInt16 = 2234
    private var searchWindowSeconds: Int = 8
    private var serverHost: String = "server.slsknet.org"
    private var serverPort: UInt16 = 2242
    private var onIPod = false

    public init() {}

    // MARK: - PluginConfigurable (`SLSK-14`)

    public func initialize(params: PluginInitializeParams, context: any PluginRuntimeContext) async throws {
        self.context = context
        self.onIPod = params.host.onIPod
        let idMgr = IdentityManager(dataDirectory: params.paths.data)
        self.identity = idMgr

        if let host = params.config["serverHost"]?.stringValue, !host.isEmpty {
            self.serverHost = host
        }
        if let port = params.config["serverPort"]?.intValue, port > 0 && port <= 65535 {
            self.serverPort = UInt16(port)
        }
        applySettingsMap(params.settings)

        let cli = SoulseekClient(transport: CSocketTransport.shared, identity: idMgr)
        var cfg = SoulseekClient.Config()
        cfg.serverHost = serverHost
        cfg.serverPort = serverPort
        cfg.listenPort = listenPort
        cfg.searchWindowSeconds = searchWindowSeconds
        cfg.onIPod = onIPod
        await cli.configure(context: context, config: cfg, shareEnabled: shareEnabled)
        self.client = cli

        await context.reportStatus(.ready, message: "Not connected")
    }

    public func settingsChanged(_ settings: [String: JSONValue]) async {
        applySettingsMap(settings)
        await client?.updateSettings(
            listenPort: listenPort,
            searchWindowSeconds: searchWindowSeconds,
            shareEnabled: shareEnabled
        )
        await client?.reportReadySummary()
    }

    private func applySettingsMap(_ settings: [String: JSONValue]) {
        if let s = settings["share"]?.boolValue {
            shareEnabled = s
        }
        if let p = settings["listenPort"]?.intValue, p >= 1024 && p <= 65535 {
            listenPort = UInt16(p)
        }
        if let w = settings["searchWindowSeconds"]?.intValue {
            searchWindowSeconds = max(3, min(20, w))
        }
    }

    // MARK: - PluginAccountHandling (`SLSK-4`, `SLSK-5`)

    public func login(key: String, fields: [String: String]) async throws -> PluginAccountStatus {
        guard let identity, let client else {
            throw PluginError(code: .internal, message: "Plug-in not initialized")
        }
        let user = (fields["username"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let pass = fields["password"] ?? ""
        guard !user.isEmpty, !pass.isEmpty else {
            throw PluginError(code: .unauthorized, message: "Username and password are required.")
        }
        let creds = await identity.setPersonalAccount(username: user, password: pass)
        let status = try await client.reconnectWithCredentials(creds)
        await context?.reportAccountStatus(status)
        return status
    }

    public func logout() async throws -> PluginAccountStatus {
        guard let identity, let client else {
            return PluginAccountStatus(status: "signedOut")
        }
        await identity.clearCacheForReset()
        _ = await identity.regenerateAutoIdentity()
        await client.disconnectServer()
        let out = PluginAccountStatus(status: "signedOut")
        await context?.reportStatus(.ready, message: "Not connected")
        return out
    }

    public func status() async throws -> PluginAccountStatus {
        guard let identity else {
            return PluginAccountStatus(status: "signedOut")
        }
        return await identity.currentStatus()
    }

    // MARK: - Resolver (`SLSK-6`, `SLSK-7`)

    public func search(
        track: TrackRef,
        policy: QualityPolicy,
        onPartialCandidates: @escaping @Sendable ([Candidate]) async -> Void
    ) async throws -> [Candidate] {
        try Task.checkCancellation()

        if ProcessInfo.processInfo.environment["IPPM_PLUGIN_TEST_CANCEL"] == "1" {
            try await Task.sleep(nanoseconds: 5_000_000_000)
        }

        if ProcessInfo.processInfo.environment["IPPM_PLUGIN_OFFLINE"] == "1",
           let offline = Self.loadOfflineCandidates() {
            await onPartialCandidates(offline)
            return offline
        }

        guard let client else {
            throw PluginError(code: .internal, message: "Soulseek client not initialized")
        }

        return try await client.searchTrack(
            track: track,
            policy: policy,
            searchWindowSeconds: searchWindowSeconds,
            onPartialCandidates: onPartialCandidates
        )
    }

    // MARK: - Downloader (`SLSK-8`..`SLSK-10`)

    public func download(
        candidate: Candidate,
        destinationDir: URL,
        onProgress: @escaping @Sendable (PluginProgress) async -> Void
    ) async throws -> URL {
        try Task.checkCancellation()

        if ProcessInfo.processInfo.environment["IPPM_PLUGIN_OFFLINE"] == "1" {
            let fm = FileManager.default
            try fm.createDirectory(at: destinationDir, withIntermediateDirectories: true)
            let part = destinationDir.appendingPathComponent("offline-soulseek.flac.part")
            try Data("offline-soulseek-fixture".utf8).write(to: part)
            await onProgress(PluginProgress(done: 100, total: 100, message: "Complete"))
            return part
        }

        guard let client else {
            throw PluginError(code: .internal, message: "Soulseek client not initialized")
        }

        return try await client.downloadCandidate(
            candidate: candidate,
            destinationDir: destinationDir,
            onProgress: onProgress
        )
    }

    // MARK: - ShareProvider (`SLSK-11`..`SLSK-13`)

    public func setIndex(entries: [ShareIndexEntry], uploadSlots: Int) async throws {
        try Task.checkCancellation()
        if ProcessInfo.processInfo.environment["IPPM_PLUGIN_TEST_CANCEL"] == "1" {
            try await Task.sleep(nanoseconds: 5_000_000_000)
        }
        guard let client else { return }
        if ProcessInfo.processInfo.environment["IPPM_PLUGIN_OFFLINE"] == "1" {
            // Skip live network socket connection in offline CLI verification.
            return
        }
        try await client.setShareIndex(entries: entries, uploadSlots: uploadSlots)
    }

    public func stop() async throws {
        await client?.stopAll()
    }

    private static func loadOfflineCandidates() -> [Candidate]? {
        guard let path = ProcessInfo.processInfo.environment["IPPM_PLUGIN_FIXTURES"],
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let fixtures = try? JSONDecoder().decode(PluginTestFixtures.self, from: data) else {
            return nil
        }
        return fixtures.resolver?.offlineResponse
    }
}
