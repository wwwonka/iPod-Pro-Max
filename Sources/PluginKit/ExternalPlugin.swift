import Foundation

/// Live runtime status of an external plug-in managed by `ExternalPlugin`.
public enum ExternalPluginProcessState: Sendable, Equatable {
    case stopped
    case starting
    case running
    case error(String)
}

/// One line emitted in the Developer Mode live log window.
public struct PluginLogEntry: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable {
        case stderr
        case log
        case error
        case rpc
    }

    public let id: UUID
    public let timestamp: Date
    public let kind: Kind
    public let text: String

    public init(id: UUID = UUID(), timestamp: Date = Date(), kind: Kind, text: String) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.text = text
    }
}

/// App-side adapter for an out-of-process plug-in executable (`PLG-4`).
///
/// Conforms to all plug-in role protocols so the core engine can drive internal and external
/// implementations interchangeably. Concurrent operations share one running process; when the
/// last active operation finishes (and no persistent share lease is held), `shutdown` is sent.
public final class ExternalPlugin: @unchecked Sendable, PlaylistSource, Resolver, Downloader, ShareProvider, MetadataLookupProvider, LyricsLookupProvider {
    public let id: String
    public let name: String
    public let manifest: PluginManifest
    public let rootURL: URL
    public let executableURL: URL?

    private let session: SessionActor

    public init(
        manifest: PluginManifest,
        rootURL: URL,
        executableURL: URL?,
        hostInfo: PluginHostInfo = .current(),
        paths: PluginPaths,
        settingsProvider: @escaping @Sendable () async -> [String: JSONValue],
        onStateChanged: (@Sendable (ExternalPluginProcessState, PluginStatusUpdate?) -> Void)? = nil,
        onLogLine: (@Sendable (PluginLogEntry) -> Void)? = nil,
        onAccountStatus: (@Sendable (PluginAccountStatus) -> Void)? = nil
    ) {
        self.id = manifest.id
        self.name = manifest.name
        self.manifest = manifest
        self.rootURL = rootURL
        self.executableURL = executableURL
        self.session = SessionActor(
            id: manifest.id,
            manifest: manifest,
            rootURL: rootURL,
            executableURL: executableURL,
            hostInfo: hostInfo,
            paths: paths,
            settingsProvider: settingsProvider,
            onStateChanged: onStateChanged,
            onLogLine: onLogLine,
            onAccountStatus: onAccountStatus
        )
    }

    // MARK: - Lifecycle & Control

    public func currentState() async -> ExternalPluginProcessState {
        await session.processState
    }

    public func isRunning() async -> Bool {
        await session.isProcessRunning
    }

    public func setShareLease(_ active: Bool) async {
        await session.setShareLease(active)
    }

    public func setRPCLoggingEnabled(_ enabled: Bool) async {
        await session.setRPCLoggingEnabled(enabled)
    }

    public func notifySettingsChanged(_ settings: [String: JSONValue]) async {
        await session.sendSettingsChanged(settings)
    }

    public func restart() async {
        await session.restart()
    }

    public func shutdown(timeoutSeconds: Double = 5.0) async {
        await session.shutdown(timeoutSeconds: timeoutSeconds)
    }

    public func initializeOnly() async throws -> PluginInitializeResult {
        try await session.withLease {
            try await session.getInitializeResult()
        }
    }

    // MARK: - Accounts & Actions

    public func login(key: String, fields: [String: String]) async throws -> PluginAccountStatus {
        try await session.withLease {
            let params = try JsonRpcCodec.encodeValue(AccountLoginParams(key: key, fields: fields))
            let result = try await session.call(method: "account/login", params: params)
            return try JsonRpcCodec.decodeValue(PluginAccountStatus.self, from: result)
        }
    }

    public func logout() async throws -> PluginAccountStatus {
        try await session.withLease {
            let result = try await session.call(method: "account/logout", params: .object([:]))
            return try JsonRpcCodec.decodeValue(PluginAccountStatus.self, from: result)
        }
    }

    public func accountStatus() async throws -> PluginAccountStatus {
        try await session.withLease {
            let result = try await session.call(method: "account/status", params: .object([:]))
            return try JsonRpcCodec.decodeValue(PluginAccountStatus.self, from: result)
        }
    }

    public func performAction(key: String) async throws -> PluginActionResult {
        try await session.withLease {
            let result = try await session.call(method: "action/\(key)", params: .object([:]))
            return try JsonRpcCodec.decodeValue(PluginActionResult.self, from: result)
        }
    }

    // MARK: - Role Protocols

    public func fetch(url: URL) async throws -> PlaylistFetchResult {
        try await session.withLease {
            let params = try JsonRpcCodec.encodeValue(SourceFetchParams(url: url.absoluteString))
            let result = try await session.call(method: "source/fetch", params: params)
            return try JsonRpcCodec.decodeValue(PlaylistFetchResult.self, from: result)
        }
    }

    public func reorderPlaylist(request: PlaylistReorderRequest) async throws {
        try await session.withLease {
            let params = try JsonRpcCodec.encodeValue(request)
            _ = try await session.call(method: "source/reorder", params: params)
        }
    }

    public func addTracksToPlaylist(request: PlaylistAddTracksRequest) async throws -> PlaylistAddTracksResult {
        try await session.withLease {
            let params = try JsonRpcCodec.encodeValue(request)
            let result = try await session.call(method: "source/addTracks", params: params)
            return try JsonRpcCodec.decodeValue(PlaylistAddTracksResult.self, from: result)
        }
    }

    public func renamePlaylist(request: PlaylistRenameRequest) async throws {
        try await session.withLease {
            let params = try JsonRpcCodec.encodeValue(request)
            _ = try await session.call(method: "source/rename", params: params)
        }
    }

    public func removeTracksFromPlaylist(request: PlaylistRemoveTracksRequest) async throws {
        try await session.withLease {
            let params = try JsonRpcCodec.encodeValue(request)
            _ = try await session.call(method: "source/removeTracks", params: params)
        }
    }

    public func createPlaylist(request: PlaylistCreateRequest) async throws -> PlaylistCreateResult {
        try await session.withLease {
            let params = try JsonRpcCodec.encodeValue(request)
            let result = try await session.call(method: "source/createPlaylist", params: params)
            return try JsonRpcCodec.decodeValue(PlaylistCreateResult.self, from: result)
        }
    }

    public func setPlaylistArtwork(request: PlaylistArtworkRequest) async throws {
        try await session.withLease {
            let params = try JsonRpcCodec.encodeValue(request)
            _ = try await session.call(method: "source/setArtwork", params: params)
        }
    }

    public func listUserPlaylists() async throws -> [RemotePlaylistSummary] {
        try await session.withLease {
            let result = try await session.call(method: "source/listUserPlaylists", params: .object([:]))
            return try JsonRpcCodec.decodeValue(SourceListPlaylistsResult.self, from: result).playlists
        }
    }

    public func search(
        track: TrackRef,
        policy: QualityPolicy,
        onPartialCandidates: @escaping @Sendable ([Candidate]) async -> Void
    ) async throws -> [Candidate] {
        try await session.withLease {
            let params = try JsonRpcCodec.encodeValue(ResolverSearchParams(track: track, policy: policy))
            let result = try await session.call(
                method: "resolver/search",
                params: params,
                onPartialCandidates: onPartialCandidates
            )
            let decoded = try JsonRpcCodec.decodeValue(ResolverSearchResult.self, from: result)
            return decoded.candidates
        }
    }

    public func download(
        candidate: Candidate,
        destinationDir: URL,
        onProgress: @escaping @Sendable (PluginProgress) async -> Void
    ) async throws -> URL {
        guard candidate.resolver == id else {
            throw PluginError(
                code: .wrongResolver,
                message: "Candidate resolver '\(candidate.resolver)' does not match '\(id)'."
            )
        }
        return try await session.withLease {
            let params = try JsonRpcCodec.encodeValue(
                DownloaderDownloadParams(candidate: candidate, destinationDir: destinationDir.path)
            )
            let result = try await session.call(
                method: "downloader/download",
                params: params,
                onProgress: onProgress
            )
            let decoded = try JsonRpcCodec.decodeValue(DownloaderDownloadResult.self, from: result)
            return URL(fileURLWithPath: decoded.path)
        }
    }

    public func setIndex(entries: [ShareIndexEntry], uploadSlots: Int) async throws {
        await session.setShareLease(true)
        try await session.withLease {
            let chunkSize = 5000
            if entries.isEmpty {
                let params = try JsonRpcCodec.encodeValue(
                    ShareSetIndexParams(part: 0, lastPart: true, entries: [], uploadSlots: uploadSlots)
                )
                _ = try await session.call(method: "share/setIndex", params: params)
                return
            }
            var index = 0
            var part = 0
            while index < entries.count {
                let end = min(index + chunkSize, entries.count)
                let slice = Array(entries[index..<end])
                let last = end >= entries.count
                let params = try JsonRpcCodec.encodeValue(
                    ShareSetIndexParams(part: part, lastPart: last, entries: slice, uploadSlots: uploadSlots)
                )
                _ = try await session.call(method: "share/setIndex", params: params)
                index = end
                part += 1
            }
        }
    }

    public func stop() async throws {
        await session.setShareLease(false)
        if await session.isProcessRunning {
            _ = try? await session.call(method: "share/stop", params: .object([:]))
        }
        await session.shutdownIfIdle()
    }

    public func search(query: MetadataQuery) async throws -> [MetadataMatch] {
        try await session.withLease {
            let params = try JsonRpcCodec.encodeValue(query)
            let result = try await session.call(method: "metadata/search", params: params)
            return try JsonRpcCodec.decodeValue(MetadataSearchResult.self, from: result).matches
        }
    }

    public func fetchLyrics(query: LyricsQuery) async throws -> LyricsMatch? {
        try await session.withLease {
            let params = try JsonRpcCodec.encodeValue(query)
            let result = try await session.call(method: "lyrics/fetch", params: params)
            return try JsonRpcCodec.decodeValue(LyricsFetchResult.self, from: result).match
        }
    }
}

// MARK: - Session Actor

private actor SessionActor {
    struct PendingRequest {
        var continuation: CheckedContinuation<JSONValue, Error>
        var onProgress: (@Sendable (PluginProgress) async -> Void)?
        var onPartialCandidates: (@Sendable ([Candidate]) async -> Void)?
    }

    let id: String
    let manifest: PluginManifest
    var name: String { manifest.name }
    let rootURL: URL
    let executableURL: URL?
    let hostInfo: PluginHostInfo
    let paths: PluginPaths
    let settingsProvider: @Sendable () async -> [String: JSONValue]
    let onStateChanged: (@Sendable (ExternalPluginProcessState, PluginStatusUpdate?) -> Void)?
    let onLogLine: (@Sendable (PluginLogEntry) -> Void)?
    let onAccountStatus: (@Sendable (PluginAccountStatus) -> Void)?

    private(set) var processState: ExternalPluginProcessState = .stopped
    private var lastStatusUpdate: PluginStatusUpdate?
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var pending: [String: PendingRequest] = [:]
    private var nextRequestID = 1
    private var activeLeases = 0
    private var hasShareLease = false
    private var startupTask: Task<PluginInitializeResult, Error>?
    private var initializeResult: PluginInitializeResult?
    private var intentionalShutdown = false
    private var crashTimestamps: [Date] = []
    private var rpcLoggingEnabled = false
    private var lastProgressPublish: [String: UInt64] = [:]

    init(
        id: String,
        manifest: PluginManifest,
        rootURL: URL,
        executableURL: URL?,
        hostInfo: PluginHostInfo,
        paths: PluginPaths,
        settingsProvider: @escaping @Sendable () async -> [String: JSONValue],
        onStateChanged: (@Sendable (ExternalPluginProcessState, PluginStatusUpdate?) -> Void)?,
        onLogLine: (@Sendable (PluginLogEntry) -> Void)?,
        onAccountStatus: (@Sendable (PluginAccountStatus) -> Void)?
    ) {
        self.id = id
        self.manifest = manifest
        self.rootURL = rootURL
        self.executableURL = executableURL
        self.hostInfo = hostInfo
        self.paths = paths
        self.settingsProvider = settingsProvider
        self.onStateChanged = onStateChanged
        self.onLogLine = onLogLine
        self.onAccountStatus = onAccountStatus
    }

    var isProcessRunning: Bool {
        process?.isRunning == true && initializeResult != nil
    }

    func setRPCLoggingEnabled(_ enabled: Bool) {
        rpcLoggingEnabled = enabled
    }

    func setShareLease(_ active: Bool) {
        hasShareLease = active
    }

    func restart() async {
        crashTimestamps.removeAll()
        await shutdown(timeoutSeconds: 2.0)
        updateState(.stopped, status: nil)
    }

    func getInitializeResult() async throws -> PluginInitializeResult {
        if let initializeResult, process?.isRunning == true {
            return initializeResult
        }
        return try await ensureStarted()
    }

    func withLease<T: Sendable>(_ operation: () async throws -> T) async throws -> T {
        activeLeases += 1
        do {
            _ = try await ensureStarted()
            let value = try await operation()
            activeLeases = max(0, activeLeases - 1)
            await shutdownIfIdle()
            return value
        } catch {
            activeLeases = max(0, activeLeases - 1)
            await shutdownIfIdle()
            throw error
        }
    }

    func shutdownIfIdle() async {
        guard activeLeases == 0, !hasShareLease, process != nil else { return }
        await shutdown(timeoutSeconds: 5.0)
    }

    private func ensureStarted() async throws -> PluginInitializeResult {
        if case .error(let msg) = processState {
            throw PluginError(code: .launchFailed, message: msg)
        }
        if let initializeResult, process?.isRunning == true {
            return initializeResult
        }
        if let startupTask {
            return try await startupTask.value
        }

        let task = Task { () throws -> PluginInitializeResult in
            try await self.launchAndInitialize()
        }
        startupTask = task
        do {
            let result = try await task.value
            startupTask = nil
            return result
        } catch {
            startupTask = nil
            throw error
        }
    }

    private func launchAndInitialize() async throws -> PluginInitializeResult {
        guard let executableURL else {
            let msg = "Not available on \(PluginPlatform.osDisplayName)"
            updateState(.error(msg), status: nil)
            throw PluginError(code: .launchFailed, message: msg)
        }
        let fm = FileManager.default
        guard fm.fileExists(atPath: executableURL.path) else {
            let msg = "Plug-in executable not found: \(executableURL.lastPathComponent)"
            updateState(.error(msg), status: nil)
            throw PluginError(code: .launchFailed, message: msg)
        }
        guard fm.isExecutableFile(atPath: executableURL.path) else {
            let msg = "Plug-in executable is not executable: \(executableURL.lastPathComponent)"
            updateState(.error(msg), status: nil)
            throw PluginError(code: .launchFailed, message: msg)
        }

        try? fm.createDirectory(atPath: paths.data, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: paths.cache, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: paths.temp, withIntermediateDirectories: true)

        updateState(.starting, status: nil)
        intentionalShutdown = false
        stdoutBuffer.removeAll(keepingCapacity: false)
        stderrBuffer.removeAll(keepingCapacity: false)

        let proc = Process()
        proc.executableURL = executableURL
        proc.currentDirectoryURL = rootURL
        var env = ProcessInfo.processInfo.environment
        #if os(Windows)
        if let appDir = Bundle.main.executableURL?.deletingLastPathComponent().path {
            let existing = env["PATH"] ?? ""
            env["PATH"] = existing.isEmpty ? appDir : "\(appDir);\(existing)"
        }
        #endif
        proc.environment = env

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            guard let self else { return }
            Task { await self.handleStdoutData(data) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            guard let self else { return }
            Task { await self.handleStderrData(data) }
        }
        proc.terminationHandler = { [weak self] p in
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            let status = p.terminationStatus
            guard let self else { return }
            Task { await self.handleTermination(status: status) }
        }

        do {
            try proc.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            let msg = "Couldn't start \(name): \(error.localizedDescription)"
            updateState(.error(msg), status: nil)
            throw PluginError(code: .launchFailed, message: msg)
        }

        self.process = proc
        self.stdinHandle = inPipe.fileHandleForWriting

        let settings = await settingsProvider()
        var initParamsDict = (try? JsonRpcCodec.encodeValue(
            PluginInitializeParams(
                apiVersion: PluginContract.supportedAPIVersion,
                host: hostInfo,
                paths: paths,
                settings: settings,
                config: manifest.config ?? [:]
            )
        ).objectValue) ?? [:]
        initParamsDict["pluginID"] = .string(id)

        do {
            let rawResult = try await callWithTimeout(
                method: "initialize",
                params: .object(initParamsDict),
                timeoutSeconds: 10.0,
                timeoutError: PluginError(code: .startTimeout, message: "\(name) timed out during startup.")
            )
            let initResult = try JsonRpcCodec.decodeValue(PluginInitializeResult.self, from: rawResult)
            self.initializeResult = initResult
            updateState(.running, status: lastStatusUpdate)
            return initResult
        } catch {
            await forceKillProcess()
            if let pluginErr = error as? PluginError, pluginErr.code == .startTimeout {
                updateState(.error(pluginErr.message), status: nil)
            }
            throw error
        }
    }

    func sendSettingsChanged(_ settings: [String: JSONValue]) {
        guard process?.isRunning == true, initializeResult != nil else { return }
        sendNotification(method: "settings/changed", params: .object(["settings": .object(settings)]))
    }

    func call(
        method: String,
        params: JSONValue,
        onProgress: (@Sendable (PluginProgress) async -> Void)? = nil,
        onPartialCandidates: (@Sendable ([Candidate]) async -> Void)? = nil
    ) async throws -> JSONValue {
        guard let stdinHandle, process?.isRunning == true else {
            throw PluginError(code: .pluginCrashed, message: "\(name) is not running.")
        }
        let reqIDNum = nextRequestID
        nextRequestID += 1
        let rpcID = JsonRpcID.int(reqIDNum)
        let key = rpcID.stringKey

        let envelope = JsonRpcEnvelope(id: rpcID, method: method, params: params)
        let lineData = try JsonRpcCodec.encodeLine(envelope)
        if rpcLoggingEnabled {
            emitLog(.rpc, "→ \(String(decoding: lineData, as: UTF8.self).trimmingCharacters(in: .newlines))")
        }

        let cancelledFlag = CancellationBox()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled || cancelledFlag.isCancelled {
                    continuation.resume(throwing: PluginError(code: .cancelled, message: "Cancelled"))
                    return
                }
                pending[key] = PendingRequest(
                    continuation: continuation,
                    onProgress: onProgress,
                    onPartialCandidates: onPartialCandidates
                )
                do {
                    try writeToHandle(stdinHandle, data: lineData)
                } catch {
                    if let removed = pending.removeValue(forKey: key) {
                        removed.continuation.resume(throwing: PluginError(code: .network, message: error.localizedDescription))
                    }
                }
            }
        } onCancel: {
            let needsSend = cancelledFlag.markCancelled()
            if needsSend {
                Task { await self.cancelRequest(rpcID: rpcID) }
            }
        }
    }

    private func callWithTimeout(
        method: String,
        params: JSONValue,
        timeoutSeconds: Double,
        timeoutError: PluginError
    ) async throws -> JSONValue {
        try await withThrowingTaskGroup(of: JSONValue.self) { group in
            group.addTask {
                try await self.call(method: method, params: params)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw timeoutError
            }
            guard let first = try await group.next() else {
                throw timeoutError
            }
            group.cancelAll()
            return first
        }
    }

    private func cancelRequest(rpcID: JsonRpcID) async {
        let key = rpcID.stringKey
        guard pending[key] != nil else { return }
        sendNotification(method: "$/cancelRequest", params: .object(["id": rpcID.jsonValue]))
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        if let entry = pending.removeValue(forKey: key) {
            entry.continuation.resume(throwing: PluginError(code: .cancelled, message: "Cancelled"))
        }
    }

    func shutdown(timeoutSeconds: Double) async {
        guard let proc = process else { return }
        intentionalShutdown = true
        if proc.isRunning && initializeResult != nil {
            _ = try? await callWithTimeout(
                method: "shutdown",
                params: .object([:]),
                timeoutSeconds: timeoutSeconds,
                timeoutError: PluginError(code: .startTimeout, message: "Shutdown timed out")
            )
            // Brief grace wait for process exit after responding to shutdown
            let deadline = Date().addingTimeInterval(0.3)
            while proc.isRunning && Date() < deadline {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        await forceKillProcess()
        if case .error = processState {
            // Keep error state until explicitly restarted
        } else {
            updateState(.stopped, status: nil)
        }
    }

    private func forceKillProcess() async {
        if let proc = process, proc.isRunning {
            proc.terminate()
            let deadline = Date().addingTimeInterval(0.5)
            while proc.isRunning && Date() < deadline {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        try? stdinHandle?.close()
        stdinHandle = nil
        process = nil
        initializeResult = nil
    }

    private func sendNotification(method: String, params: JSONValue) {
        guard let stdinHandle, process?.isRunning == true else { return }
        let envelope = JsonRpcEnvelope(method: method, params: params)
        guard let lineData = try? JsonRpcCodec.encodeLine(envelope) else { return }
        if rpcLoggingEnabled {
            emitLog(.rpc, "→ \(String(decoding: lineData, as: UTF8.self).trimmingCharacters(in: .newlines))")
        }
        try? writeToHandle(stdinHandle, data: lineData)
    }

    private func writeToHandle(_ handle: FileHandle, data: Data) throws {
        if #available(macOS 10.15.4, *) {
            try handle.write(contentsOf: data)
        } else {
            handle.write(data)
        }
    }

    // MARK: - Incoming Stdout / Stderr

    private func handleStdoutData(_ data: Data) async {
        guard !data.isEmpty else { return }
        stdoutBuffer.append(data)

        if stdoutBuffer.count > pluginMaxLineBytes && stdoutBuffer.firstIndex(of: 0x0A) == nil {
            await abortMessageTooLarge()
            return
        }

        while let nl = stdoutBuffer.firstIndex(of: 0x0A) {
            if nl > pluginMaxLineBytes {
                await abortMessageTooLarge()
                return
            }
            var lineData = Data(stdoutBuffer[stdoutBuffer.startIndex..<nl])
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...nl)
            if lineData.last == 0x0D { lineData.removeLast() }
            guard !lineData.isEmpty else { continue }
            await processStdoutLine(lineData)
        }
    }

    private func abortMessageTooLarge() async {
        stdoutBuffer.removeAll(keepingCapacity: false)
        let err = PluginError(code: .messageTooLarge, message: "Plug-in sent a JSON-RPC message exceeding 16 MiB.")
        emitLog(.error, err.message)
        failAllPending(with: err)
        intentionalShutdown = true
        await forceKillProcess()
        updateState(.error(err.message), status: nil)
    }

    private func processStdoutLine(_ lineData: Data) async {
        let rawLine = String(decoding: lineData, as: UTF8.self)
        guard let envelope = try? JsonRpcCodec.decoder.decode(JsonRpcEnvelope.self, from: lineData) else {
            emitLog(.log, "[warning] non-JSON line on stdout: \(rawLine)")
            return
        }
        if rpcLoggingEnabled {
            emitLog(.rpc, "← \(rawLine)")
        }

        if let id = envelope.id {
            let key = id.stringKey
            guard let request = pending.removeValue(forKey: key) else { return }
            lastProgressPublish.removeValue(forKey: key)
            if let err = envelope.error {
                let code = err.data.flatMap { PluginErrorCode(rawValue: $0.code) } ?? .internal
                request.continuation.resume(
                    throwing: PluginError(
                        code: code,
                        message: err.message,
                        retryAfterSeconds: err.data?.retryAfterSeconds
                    )
                )
            } else {
                request.continuation.resume(returning: envelope.result ?? .object([:]))
            }
            return
        }

        if let method = envelope.method {
            await handleIncomingNotification(method: method, params: envelope.params)
        }
    }

    private func handleIncomingNotification(method: String, params: JSONValue?) async {
        switch method {
        case "$/log":
            if let logMsg = try? JsonRpcCodec.decodeValue(PluginLogMessage.self, from: params) {
                let kind: PluginLogEntry.Kind = logMsg.level == .error ? .error : .log
                emitLog(kind, "[\(logMsg.level.rawValue)] \(logMsg.message)")
            }
        case "$/status":
            if let status = try? JsonRpcCodec.decodeValue(PluginStatusUpdate.self, from: params) {
                lastStatusUpdate = status
                if status.state == .error, let msg = status.message, !msg.isEmpty {
                    emitLog(.error, msg)
                    updateState(.error(msg), status: status)
                } else {
                    updateState(.running, status: status)
                }
            }
        case "$/progress":
            if let progress = try? JsonRpcCodec.decodeValue(PluginProgress.self, from: params),
               let req = pending[progress.requestID],
               let onProgress = req.onProgress {
                let now = DispatchTime.now().uptimeNanoseconds
                let last = lastProgressPublish[progress.requestID] ?? 0
                let isDone = progress.total.map { progress.done >= $0 } ?? false
                if isDone || last == 0 || (now &- last) >= 500_000_000 {
                    lastProgressPublish[progress.requestID] = now
                    await onProgress(progress)
                }
            }
        case "resolver/candidates":
            if let note = try? JsonRpcCodec.decodeValue(ResolverCandidatesNotification.self, from: params),
               let req = pending[note.requestID],
               let onPartial = req.onPartialCandidates {
                await onPartial(note.candidates)
            }
        case "account/status":
            if let status = try? JsonRpcCodec.decodeValue(PluginAccountStatus.self, from: params) {
                onAccountStatus?(status)
            }
        default:
            break
        }
    }

    private func handleStderrData(_ data: Data) {
        guard !data.isEmpty else { return }
        stderrBuffer.append(data)
        while let nl = stderrBuffer.firstIndex(of: 0x0A) {
            var line = Data(stderrBuffer[stderrBuffer.startIndex..<nl])
            stderrBuffer.removeSubrange(stderrBuffer.startIndex...nl)
            if line.last == 0x0D { line.removeLast() }
            let text = String(decoding: line, as: UTF8.self)
            if !text.isEmpty {
                emitLog(.stderr, text)
            }
        }
    }

    private func handleTermination(status: Int32) async {
        if !stderrBuffer.isEmpty {
            let text = String(decoding: stderrBuffer, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            stderrBuffer.removeAll()
            if !text.isEmpty { emitLog(.stderr, text) }
        }
        try? stdinHandle?.close()
        stdinHandle = nil
        process = nil
        initializeResult = nil

        if intentionalShutdown {
            intentionalShutdown = false
            failAllPending(with: PluginError(code: .cancelled, message: "Plug-in stopped"))
            if case .error = processState {
                // preserve explicit error
            } else {
                updateState(.stopped, status: nil)
            }
            return
        }

        let err = PluginError(
            code: .pluginCrashed,
            message: "\(name) exited unexpectedly (status \(status))."
        )
        emitLog(.error, err.message)
        failAllPending(with: err)

        let now = Date()
        crashTimestamps = crashTimestamps.filter { now.timeIntervalSince($0) <= 60.0 }
        crashTimestamps.append(now)
        if crashTimestamps.count >= 3 {
            let msg = "\(name) crashed 3 times in 60 seconds."
            updateState(.error(msg), status: nil)
        } else {
            updateState(.stopped, status: nil)
        }
    }

    private func failAllPending(with error: Error) {
        let items = pending
        pending.removeAll()
        lastProgressPublish.removeAll()
        for (_, req) in items {
            req.continuation.resume(throwing: error)
        }
    }

    private func updateState(_ state: ExternalPluginProcessState, status: PluginStatusUpdate?) {
        processState = state
        onStateChanged?(state, status)
    }

    private func emitLog(_ kind: PluginLogEntry.Kind, _ message: String) {
        onLogLine?(PluginLogEntry(kind: kind, text: message))
    }
}

private final class CancellationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    /// Marks cancelled once. Returns `true` on the first transition from false -> true.
    func markCancelled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { return false }
        cancelled = true
        return true
    }
}

private extension JsonRpcID {
    var jsonValue: JSONValue {
        switch self {
        case .int(let i): .int(i)
        case .string(let s): .string(s)
        }
    }
}
