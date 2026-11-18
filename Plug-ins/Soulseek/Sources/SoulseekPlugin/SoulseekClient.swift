import Foundation
import PluginKit

/// Core Soulseek protocol coordinator (`SLSK-5`…`SLSK-12`):
/// manages lazy server login, reconnection, listener, NAT peer punch-through, searches, and peer message routing.
public actor SoulseekClient {
    public struct Config: Sendable {
        public var serverHost: String = "server.slsknet.org"
        public var serverPort: UInt16 = 2242
        public var listenPort: UInt16 = 2234
        public var searchWindowSeconds: Int = 8
        public var onIPod: Bool = false
    }

    private let transport: any SocketTransport
    private let identity: IdentityManager
    private var context: (any PluginRuntimeContext)?
    private var config = Config()

    // Server session state
    private var serverStream: (any SocketStream)?
    private var serverReadTask: Task<Void, Never>?
    private var connectTask: Task<Void, Error>?
    private var isLoggedIn = false
    private var activeUsername: String?
    private var kickedRelogged = false

    // Listener state
    private var listener: (any SocketListener)?
    private var acceptTask: Task<Void, Never>?
    private var actualListenPort: UInt16 = 0
    private var listenWarning: String?

    // Active peer `P` sessions & pending waiters
    private var peerSessions: [String: PeerSession] = [:]
    private var peerAddressWaiters: [String: [CheckedContinuation<MessageParser.PeerAddressInfo, Error>]] = [:]
    private var inboundPierceWaiters: [UInt32: CheckedContinuation<any SocketStream, Error>] = [:]
    private var activeSearchCollectors: [UInt32: SearchCollector] = [:]

    // Coordinated transfer & share sub-module
    private let transferManager = TransferCoordinator()

    // Track whether background connection should be kept alive
    private var activeOperationsCount = 0
    private var shareEnabled = true

    public init(transport: any SocketTransport = CSocketTransport.shared, identity: IdentityManager) {
        self.transport = transport
        self.identity = identity
    }

    public func configure(
        context: any PluginRuntimeContext,
        config: Config,
        shareEnabled: Bool
    ) {
        self.context = context
        self.config = config
        self.shareEnabled = shareEnabled
    }

    public func updateSettings(listenPort: UInt16, searchWindowSeconds: Int, shareEnabled: Bool) async {
        let portChanged = listenPort != config.listenPort
        config.listenPort = listenPort
        config.searchWindowSeconds = max(3, min(20, searchWindowSeconds))
        self.shareEnabled = shareEnabled

        if portChanged && isLoggedIn {
            await restartListenerIfNeeded()
            if actualListenPort > 0 {
                try? await serverStream?.write(MessageBuilder.setListenPortMessage(port: UInt32(actualListenPort)), timeoutMs: 10_000)
            }
        }
    }

    // MARK: - Connection & Login (`SLSK-5`)

    public func ensureConnected() async throws {
        if isLoggedIn, serverStream != nil { return }
        if kickedRelogged {
            throw PluginError(code: .unauthorized, message: "Signed in from another computer")
        }
        if let connectTask {
            return try await connectTask.value
        }

        let task = Task { [weak self] in
            guard let self else { throw CancellationError() }
            try await self.performConnectAndLogin()
        }
        self.connectTask = task
        do {
            try await task.value
            self.connectTask = nil
        } catch {
            self.connectTask = nil
            throw error
        }
    }

    public func reconnectWithCredentials(_ creds: IdentityManager.Credentials) async throws -> PluginAccountStatus {
        await disconnectServer()
        kickedRelogged = false
        try await performLoginOnce(creds: creds)
        return PluginAccountStatus(status: "signedIn", displayName: creds.username)
    }

    private func performConnectAndLogin() async throws {
        await context?.reportStatus(.connecting, message: "Connecting…")
        var attempt = 0
        var creds = await identity.currentOrGenerate()

        while true {
            try Task.checkCancellation()
            attempt += 1
            do {
                try await performLoginOnce(creds: creds)
                return
            } catch let pErr as PluginError where pErr.code == .unauthorized && creds.mode == "auto" && attempt < 3 {
                await context?.log(.warning, "Automatic Soulseek username '\(creds.username)' rejected; regenerating (\(attempt)/3)")
                creds = await identity.regenerateAutoIdentity()
            } catch {
                await context?.reportStatus(.error, message: error is PluginError ? error.localizedDescription : "Can't connect to Soulseek")
                throw error
            }
        }
    }

    private func performLoginOnce(creds: IdentityManager.Credentials) async throws {
        await context?.reportStatus(.connecting, message: "Connecting…")
        let stream: any SocketStream
        do {
            stream = try await transport.connect(host: config.serverHost, port: config.serverPort, timeoutMs: 12_000)
        } catch {
            throw PluginError(code: .network, message: "Can't connect to Soulseek")
        }

        await startListenerIfNeeded()

        do {
            try await stream.write(MessageBuilder.loginMessage(username: creds.username, password: creds.password), timeoutMs: 10_000)
        } catch {
            await stream.close()
            throw PluginError(code: .network, message: "Can't connect to Soulseek")
        }

        // Wait synchronously on socket for the very first ServerResponse(.login).
        var buffer = Data()
        var loginOutcome: LoginResult?
        while loginOutcome == nil {
            let chunk: Data
            do {
                chunk = try await stream.read(maxBytes: 65536, timeoutMs: 12_000)
            } catch {
                await stream.close()
                throw PluginError(code: .network, message: "Can't connect to Soulseek")
            }
            buffer.append(chunk)
            while let parsed = MessageParser.parseFrame(from: buffer) {
                buffer.removeFirst(parsed.consumed)
                if parsed.frame.code == ServerMessageCode.login.rawValue {
                    loginOutcome = MessageParser.parseLoginResponse(parsed.frame.payload)
                    break
                }
            }
        }

        switch loginOutcome {
        case .success:
            self.serverStream = stream
            self.isLoggedIn = true
            self.activeUsername = creds.username
            self.kickedRelogged = false

            await transferManager.configure(client: self, myUsername: creds.username, onIPod: config.onIPod)

            if actualListenPort > 0 {
                try? await stream.write(MessageBuilder.setListenPortMessage(port: UInt32(actualListenPort)), timeoutMs: 10_000)
            }
            try? await stream.write(MessageBuilder.setOnlineStatusMessage(status: .online), timeoutMs: 10_000)
            await announceShareCountsToServer()

            await reportReadySummary()
            startServerReadLoop(stream: stream, initialBuffer: buffer)

        case .failure(let reason):
            await stream.close()
            let lower = reason.lowercased()
            if lower.contains("invalidpass") || lower.contains("invalid password") {
                throw PluginError(code: .unauthorized, message: "Wrong username or password.")
            }
            throw PluginError(code: .unauthorized, message: reason)

        case nil:
            await stream.close()
            throw PluginError(code: .network, message: "Can't connect to Soulseek")
        }
    }

    public func disconnectServer() async {
        serverReadTask?.cancel()
        serverReadTask = nil
        if let s = serverStream {
            await s.close()
            serverStream = nil
        }
        isLoggedIn = false
        activeUsername = nil
        for (_, waiters) in peerAddressWaiters {
            for w in waiters { w.resume(throwing: PluginError(code: .network, message: "Disconnected")) }
        }
        peerAddressWaiters.removeAll()
        for (_, cont) in inboundPierceWaiters {
            cont.resume(throwing: PluginError(code: .network, message: "Disconnected"))
        }
        inboundPierceWaiters.removeAll()
        for (_, s) in peerSessions { await s.close() }
        peerSessions.removeAll()
    }

    public func stopAll() async {
        await transferManager.stopSharing()
        await disconnectServer()
        acceptTask?.cancel()
        acceptTask = nil
        if let listener {
            await listener.close()
            self.listener = nil
        }
        actualListenPort = 0
        await context?.reportStatus(.ready, message: "Not connected")
    }

    // MARK: - Listener (`SLSK-8`, edge case +10 ports)

    private func startListenerIfNeeded() async {
        if listener != nil { return }
        let basePort = config.listenPort
        for offset in 0...10 {
            let candidate = UInt16(min(Int(basePort) + offset, 65535))
            if let l = try? transport.listen(port: candidate) {
                self.listener = l
                self.actualListenPort = l.port
                self.listenWarning = (offset > 0) ? "Port \(basePort) busy; using \(l.port)" : nil
                startAcceptLoop(listener: l)
                return
            }
        }
        self.actualListenPort = 0
        self.listenWarning = "Listening port unavailable; indirect connections only"
        await context?.log(.warning, "Could not bind listening ports \(basePort)...\(min(Int(basePort) + 10, 65535)); falling back to indirect mode")
    }

    private func restartListenerIfNeeded() async {
        acceptTask?.cancel()
        acceptTask = nil
        if let l = listener { await l.close() }
        listener = nil
        actualListenPort = 0
        await startListenerIfNeeded()
    }

    private func startAcceptLoop(listener: any SocketListener) {
        acceptTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let inbound = try await listener.accept(timeoutMs: 0)
                    guard let self else { await inbound.close(); return }
                    await self.handleInboundSocket(inbound)
                } catch {
                    if Task.isCancelled { break }
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
            }
        }
    }

    private func handleInboundSocket(_ stream: any SocketStream) {
        Task { [weak self] in
            guard let self else { await stream.close(); return }
            do {
                // First message on inbound connection is either PierceFirewall (0) or PeerInit (1).
                var buf = Data()
                while true {
                    let chunk = try await stream.read(maxBytes: 65536, timeoutMs: 10_000)
                    buf.append(chunk)
                    if let frame = MessageParser.parseInitOrPeerFrame(from: buf, handshakeComplete: false) {
                        buf.removeFirst(frame.consumed)
                        if frame.isInit && frame.initCode == PeerMessageCode.pierceFirewall.rawValue,
                           let token = MessageParser.parsePierceFirewall(frame.payload) {
                            await self.deliverInboundPierce(token: token, stream: stream, trailingData: buf)
                            return
                        }
                        if frame.isInit && frame.initCode == PeerMessageCode.peerInit.rawValue,
                           let info = MessageParser.parsePeerInit(frame.payload) {
                            await self.routeInboundPeerInit(info: info, stream: stream, trailingData: buf)
                            return
                        }
                        break
                    }
                }
            } catch {
                await stream.close()
            }
        }
    }

    private func deliverInboundPierce(token: UInt32, stream: any SocketStream, trailingData: Data) async {
        if !trailingData.isEmpty {
            await stream.pushBack(trailingData)
        }
        if let waiter = inboundPierceWaiters.removeValue(forKey: token) {
            waiter.resume(returning: stream)
        } else {
            await stream.close()
        }
    }

    private func routeInboundPeerInit(
        info: MessageParser.PeerInitInfo,
        stream: any SocketStream,
        trailingData: Data
    ) async {
        if info.connectionType == "F" {
            await transferManager.handleIncomingFileStream(stream: stream, prebuffered: trailingData, peerUsername: info.username)
        } else {
            let session = registerOrReplacePeerSession(username: info.username, stream: stream, initialBuffer: trailingData)
            await session.startReading(client: self)
        }
    }

    // MARK: - Server Read Loop & Reconnect Backoff (`SLSK-5`)

    private func startServerReadLoop(stream: any SocketStream, initialBuffer: Data) {
        serverReadTask = Task { [weak self] in
            var buffer = initialBuffer
            while !Task.isCancelled {
                do {
                    let chunk = try await stream.read(maxBytes: 65536, timeoutMs: 0)
                    buffer.append(chunk)
                    while let parsed = MessageParser.parseFrame(from: buffer) {
                        buffer.removeFirst(parsed.consumed)
                        await self?.handleServerFrame(code: parsed.frame.code, payload: parsed.frame.payload)
                    }
                } catch {
                    if Task.isCancelled { break }
                    await self?.handleServerDisconnect()
                    break
                }
            }
        }
    }

    private func handleServerFrame(code: UInt32, payload: Data) async {
        guard let msgCode = ServerMessageCode(rawValue: code) else { return }
        switch msgCode {
        case .relogged:
            kickedRelogged = true
            await disconnectServer()
            await context?.reportStatus(.error, message: "Signed in from another computer")

        case .getPeerAddress:
            guard let info = MessageParser.parseGetPeerAddress(payload) else { return }
            let waiters = peerAddressWaiters.removeValue(forKey: info.username) ?? []
            for w in waiters {
                w.resume(returning: info)
            }

        case .connectToPeer:
            guard let info = MessageParser.parseConnectToPeer(payload) else { return }
            handleConnectToPeerNotification(info)

        case .cantConnectToPeer:
            guard let info = MessageParser.parseCantConnectToPeer(payload) else { return }
            if let waiter = inboundPierceWaiters.removeValue(forKey: info.token) {
                waiter.resume(throwing: PluginError(code: .network, message: "Peer cannot connect"))
            }

        default:
            break
        }
    }

    private func shouldKeepReconnecting() async -> Bool {
        if activeOperationsCount > 0 { return true }
        guard shareEnabled else { return false }
        return !(await transferManager.isEmpty())
    }

    private func handleServerDisconnect() async {
        await disconnectServer()
        guard !kickedRelogged else { return }
        guard await shouldKeepReconnecting() else {
            await context?.reportStatus(.ready, message: "Not connected")
            return
        }
        await context?.reportStatus(.connecting, message: "Reconnecting…")
        for delay in [5, 15, 60] {
            guard !Task.isCancelled, !kickedRelogged else { return }
            guard await shouldKeepReconnecting() else {
                await context?.reportStatus(.ready, message: "Not connected")
                return
            }
            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            do {
                try await performConnectAndLogin()
                return
            } catch {
                continue
            }
        }
        await context?.reportStatus(.error, message: "Can't connect to Soulseek")
    }

    private func handleConnectToPeerNotification(_ info: MessageParser.PeerInfo) {
        Task { [weak self] in
            guard let self else { return }
            guard info.ip != "0.0.0.0" else { return }
            let useObfuscated = (info.port == 0 && info.obfuscatedPort > 0)
            let targetPort = UInt16(clamping: useObfuscated ? info.obfuscatedPort : info.port)
            guard targetPort > 0 else { return }
            do {
                let rawStream = try await self.transport.connect(host: info.ip, port: targetPort, timeoutMs: 8_000)
                let stream: any SocketStream = useObfuscated ? ObfuscatedSocketStream(inner: rawStream) : rawStream
                try await stream.write(MessageBuilder.pierceFirewallMessage(token: info.token), timeoutMs: 5_000)
                if info.connectionType == "F" {
                    await self.transferManager.handleIncomingFileStream(stream: stream, prebuffered: Data(), peerUsername: info.username)
                } else {
                    let session = await self.registerOrReplacePeerSession(username: info.username, stream: stream, initialBuffer: Data())
                    await session.startReading(client: self)
                }
            } catch {
                // Best-effort reverse punch; ignore transient NAT failure.
            }
        }
    }

    // MARK: - Search (`SLSK-6`, `SLSK-7`)

    public func searchTrack(
        track: TrackRef,
        policy: QualityPolicy,
        searchWindowSeconds: Int,
        onPartialCandidates: @escaping @Sendable ([Candidate]) async -> Void
    ) async throws -> [Candidate] {
        activeOperationsCount += 1
        defer { decrementOps() }

        try await ensureConnected()

        let queries = SearchQueryBuilder.queries(for: track)
        var allCandidates: [Candidate] = []
        var seenTokens = Set<String>()

        for (tierIdx, query) in queries.enumerated() {
            try Task.checkCancellation()
            let batch = try await runSingleSearch(
                query: query,
                windowSeconds: searchWindowSeconds,
                onPartial: { partial in
                    await onPartialCandidates(partial)
                }
            )
            for c in batch where seenTokens.insert(c.token).inserted {
                allCandidates.append(c)
            }
            // Stop widening as soon as this tier returned usable audio matches with title coverage
            if !batch.isEmpty && (tierIdx == queries.count - 1 || hasLikelyTitleMatch(in: batch, title: track.title)) {
                break
            }
        }

        return allCandidates
    }

    private func runSingleSearch(
        query: String,
        windowSeconds: Int,
        onPartial: @escaping @Sendable ([Candidate]) async -> Void
    ) async throws -> [Candidate] {
        let token = UInt32.random(in: 1...UInt32.max - 1)
        let collector = SearchCollector(maxAudioCount: 500, maxRawResponses: 2000)
        activeSearchCollectors[token] = collector
        defer { activeSearchCollectors.removeValue(forKey: token) }

        guard let stream = serverStream else {
            throw PluginError(code: .network, message: "Not connected to Soulseek")
        }
        try await stream.write(MessageBuilder.fileSearchMessage(token: token, query: query), timeoutMs: 8_000)

        let hardCeilingMs = max(3, min(20, windowSeconds)) * 1000
        let minWaitMs = min(2800, hardCeilingMs)
        let quietWaitMs = 2000

        let start = Date()
        var lastCount = 0
        var lastNewAt = start
        var emittedCount = 0

        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 250_000_000)
            try Task.checkCancellation()

            let snapshot = await collector.snapshot()
            let now = Date()
            if snapshot.count > lastCount {
                lastCount = snapshot.count
                lastNewAt = now
                if snapshot.count > emittedCount {
                    let delta = Array(snapshot[emittedCount...])
                    emittedCount = snapshot.count
                    await onPartial(delta)
                }
            }

            let elapsedMs = Int(now.timeIntervalSince(start) * 1000)
            let quietMs = Int(now.timeIntervalSince(lastNewAt) * 1000)
            if elapsedMs >= hardCeilingMs { break }
            if elapsedMs >= minWaitMs && lastCount > 0 && quietMs >= quietWaitMs { break }
            if await collector.reachedCap() { break }
        }

        try Task.checkCancellation()
        return await collector.snapshot()
    }

    fileprivate func deliverSearchReply(_ reply: MessageParser.SearchReplyInfo) async {
        guard let collector = activeSearchCollectors[reply.token] else { return }
        await collector.append(reply)
    }

    // MARK: - Download (`SLSK-8`..`SLSK-10`)

    public func downloadCandidate(
        candidate: Candidate,
        destinationDir: URL,
        onProgress: @escaping @Sendable (PluginProgress) async -> Void
    ) async throws -> URL {
        activeOperationsCount += 1
        defer { decrementOps() }

        try await ensureConnected()
        return try await transferManager.download(
            candidate: candidate,
            destinationDir: destinationDir,
            onProgress: onProgress
        )
    }

    // MARK: - Sharing (`SLSK-11`..`SLSK-13`)

    public func setShareIndex(entries: [ShareIndexEntry], uploadSlots: Int) async throws {
        await transferManager.setShareIndex(entries: entries, uploadSlots: uploadSlots)
        if shareEnabled && !entries.isEmpty {
            try? await ensureConnected()
        }
        await announceShareCountsToServer()
        await reportReadySummary()
    }

    public func stopShare() async {
        await transferManager.stopSharing()
        await announceShareCountsToServer()
        await reportReadySummary()
    }

    private func announceShareCountsToServer() async {
        guard isLoggedIn, let stream = serverStream else { return }
        let (dirs, files) = shareEnabled ? await transferManager.shareCounts() : (0, 0)
        try? await stream.write(MessageBuilder.sharedFoldersFilesMessage(folders: UInt32(dirs), files: UInt32(files)), timeoutMs: 10_000)
    }

    public func reportReadySummary() async {
        if let listenWarning {
            await context?.reportStatus(.ready, message: listenWarning)
            return
        }
        if shareEnabled {
            let (dirs, files) = await transferManager.shareCounts()
            if files > 0 {
                let uploads = await transferManager.activeUploadCount()
                let suffix = uploads > 0 ? " · \(uploads) upload\(uploads == 1 ? "" : "s")" : ""
                let base = config.onIPod
                    ? "Sharing your iPod: \(files) files"
                    : "Sharing \(files) files in \(dirs) folders"
                await context?.reportStatus(.ready, message: base + suffix)
                return
            }
        }
        if let activeUsername {
            await context?.reportStatus(.ready, message: "Connected as \(activeUsername)")
        } else {
            await context?.reportStatus(.ready, message: "Not connected")
        }
    }

    // MARK: - Peer Messaging Helpers (`P` & `F` dial/pierce)

    public func getPeerAddress(username: String) async throws -> MessageParser.PeerAddressInfo {
        guard let stream = serverStream else {
            throw PluginError(code: .network, message: "Not connected to Soulseek")
        }
        let alreadyInFlight = !(peerAddressWaiters[username] ?? []).isEmpty
        return try await withThrowingTaskGroup(of: MessageParser.PeerAddressInfo.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { cont in
                    Task { await self.registerAddressWaiter(username: username, cont: cont) }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 10_000_000_000)
                throw PluginError(code: .network, message: "Timed out looking up peer address")
            }
            if !alreadyInFlight {
                try? await stream.write(MessageBuilder.getPeerAddressMessage(username: username), timeoutMs: 8_000)
            }
            guard let res = try await group.next() else {
                throw PluginError(code: .network, message: "Address lookup failed")
            }
            group.cancelAll()
            return res
        }
    }

    private func registerAddressWaiter(username: String, cont: CheckedContinuation<MessageParser.PeerAddressInfo, Error>) {
        peerAddressWaiters[username, default: []].append(cont)
    }

    public func evictPeerSession(for username: String) async {
        if let existing = peerSessions.removeValue(forKey: username) {
            await existing.close()
        }
    }

    public func obtainPeerMessageSession(for username: String) async throws -> PeerSession {
        if let existing = peerSessions[username], await existing.isOpen {
            return existing
        }
        let addr = try await getPeerAddress(username: username)
        guard addr.ip != "0.0.0.0", addr.port > 0 || addr.obfuscatedPort > 0 else {
            throw PluginError(code: .network, message: "\(username) is offline")
        }
        let token = UInt32.random(in: 1...UInt32.max - 1)
        let myName: String
        if let activeUsername {
            myName = activeUsername
        } else {
            myName = await identity.currentOrGenerate().username
        }

        let stream = try await openConnectionToPeer(
            username: username,
            ip: addr.ip,
            port: UInt16(clamping: addr.port),
            obfuscatedPort: addr.obfuscatedPort,
            type: "P",
            token: token,
            myUsername: myName
        )
        let session = registerOrReplacePeerSession(username: username, stream: stream, initialBuffer: Data())
        await session.startReading(client: self)
        return session
    }

    public func openOutboundFileStream(to username: String, token: UInt32) async throws -> any SocketStream {
        let addr = try await getPeerAddress(username: username)
        guard addr.ip != "0.0.0.0", addr.port > 0 || addr.obfuscatedPort > 0 else {
            throw PluginError(code: .network, message: "\(username) is offline")
        }
        let myName: String
        if let activeUsername {
            myName = activeUsername
        } else {
            myName = await identity.currentOrGenerate().username
        }
        return try await openConnectionToPeer(
            username: username,
            ip: addr.ip,
            port: UInt16(clamping: addr.port),
            obfuscatedPort: addr.obfuscatedPort,
            type: "F",
            token: token,
            myUsername: myName
        )
    }

    private func openConnectionToPeer(
        username: String,
        ip: String,
        port: UInt16,
        obfuscatedPort: UInt16,
        type: String,
        token: UInt32,
        myUsername: String
    ) async throws -> any SocketStream {
        if let srv = serverStream {
            try? await srv.write(MessageBuilder.connectToPeerMessage(token: token, username: username, connectionType: type), timeoutMs: 8_000)
        }

        let transportRef = self.transport
        return try await withThrowingTaskGroup(of: (any SocketStream).self) { group in
            let dialPort = port > 0 ? port : obfuscatedPort
            let useObf = (port == 0 && obfuscatedPort > 0)
            if dialPort > 0 {
                group.addTask {
                    let raw = try await transportRef.connect(host: ip, port: dialPort, timeoutMs: 8_000)
                    let s: any SocketStream = useObf ? ObfuscatedSocketStream(inner: raw) : raw
                    try await s.write(MessageBuilder.peerInitMessage(username: myUsername, connectionType: type, token: token), timeoutMs: 5_000)
                    return s
                }
            }

            group.addTask { [weak self] in
                guard let self else { throw CancellationError() }
                return try await self.waitForInboundPierce(token: token, timeoutSeconds: 12)
            }

            while let result = await group.nextResult() {
                if case .success(let stream) = result {
                    group.cancelAll()
                    return stream
                }
            }
            throw PluginError(code: .network, message: "Could not connect to peer \(username)")
        }
    }

    private func waitForInboundPierce(token: UInt32, timeoutSeconds: Double) async throws -> any SocketStream {
        defer { inboundPierceWaiters.removeValue(forKey: token) }
        return try await withThrowingTaskGroup(of: (any SocketStream).self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { cont in
                    Task { await self.setInboundPierceWaiter(token: token, cont: cont) }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw PluginError(code: .network, message: "Inbound peer pierce timed out")
            }
            guard let first = try await group.next() else {
                throw PluginError(code: .network, message: "Pierce failed")
            }
            group.cancelAll()
            return first
        }
    }

    private func setInboundPierceWaiter(token: UInt32, cont: CheckedContinuation<any SocketStream, Error>) {
        inboundPierceWaiters[token] = cont
    }

    private func registerOrReplacePeerSession(
        username: String,
        stream: any SocketStream,
        initialBuffer: Data
    ) -> PeerSession {
        let session = PeerSession(username: username, stream: stream, initialBuffer: initialBuffer)
        peerSessions[username] = session
        return session
    }

    fileprivate func handlePeerMessage(from username: String, code: UInt32, payload: Data, session: PeerSession) async {
        guard let pCode = PeerMessageCode(rawValue: UInt8(clamping: code)), code <= 255 else { return }
        switch pCode {
        case .searchReply:
            if let decompressed = try? ZlibCodec.decompress(payload),
               let parsed = MessageParser.parseSearchReply(decompressed) {
                await deliverSearchReply(parsed)
            }

        case .sharesRequest:
            let replyData = await transferManager.buildSharesReply(enabled: shareEnabled)
            try? await session.send(replyData)

        case .queueDownload:
            if let file = MessageParser.parseQueueDownload(payload) {
                await transferManager.handleIncomingQueueDownload(username: username, filename: file, session: session, shareEnabled: shareEnabled)
            }

        case .placeInQueueRequest:
            if let file = MessageParser.parsePlaceInQueueRequest(payload) {
                await transferManager.handleIncomingPlaceInQueueRequest(username: username, filename: file, session: session)
            }

        case .placeInQueueReply:
            if let info = MessageParser.parsePlaceInQueueResponse(payload) {
                await transferManager.handlePlaceInQueueResponse(username: username, filename: info.filename, place: info.place)
            }

        case .transferRequest:
            if let info = MessageParser.parseTransferRequest(payload) {
                await transferManager.handleIncomingTransferRequest(username: username, info: info, session: session)
            }

        case .transferReply:
            if let info = MessageParser.parseTransferReply(payload) {
                await transferManager.handleIncomingTransferReply(username: username, info: info)
            }

        case .uploadDenied:
            if let info = MessageParser.parseUploadDenied(payload) {
                await transferManager.handleUploadDenied(username: username, filename: info.filename, reason: info.reason)
            }

        case .uploadFailed:
            if let file = MessageParser.parseUploadFailed(payload) {
                await transferManager.handleUploadFailed(username: username, filename: file)
            }

        default:
            break
        }
    }

    fileprivate func decrementOps() {
        activeOperationsCount = max(0, activeOperationsCount - 1)
    }

    private func hasLikelyTitleMatch(in candidates: [Candidate], title: String) -> Bool {
        let words = SearchQueryBuilder.cleanTerm(title).lowercased()
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { $0.count >= 3 && $0 != "the" && $0 != "and" }
        guard !words.isEmpty else { return !candidates.isEmpty }
        return candidates.contains { c in
            let corpus = (c.displayName + " " + (c.title ?? "")).lowercased()
            return words.allSatisfy { corpus.contains($0) }
        }
    }
}

// MARK: - Supporting Peer Session & Collectors

public actor PeerSession {
    public let username: String
    private let stream: any SocketStream
    private var buffer: Data
    private var readTask: Task<Void, Never>?
    private var closed = false

    public var isOpen: Bool { !closed }

    public init(username: String, stream: any SocketStream, initialBuffer: Data) {
        self.username = username
        self.stream = stream
        self.buffer = initialBuffer
    }

    public func send(_ data: Data) async throws {
        guard !closed else { throw SocketError.closed }
        try await stream.write(data, timeoutMs: 15_000)
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        readTask?.cancel()
        readTask = nil
        await stream.close()
    }

    fileprivate func startReading(client: SoulseekClient) {
        guard readTask == nil else { return }
        readTask = Task { [weak client] in
            while !Task.isCancelled && !closed {
                while let frame = MessageParser.parseInitOrPeerFrame(from: buffer, handshakeComplete: true) {
                    buffer.removeFirst(frame.consumed)
                    if !frame.isInit {
                        await client?.handlePeerMessage(from: username, code: frame.peerCode, payload: frame.payload, session: self)
                    }
                }
                do {
                    let chunk = try await stream.read(maxBytes: 65536, timeoutMs: 0)
                    buffer.append(chunk)
                } catch {
                    await close()
                    break
                }
            }
        }
    }
}

private actor SearchCollector {
    private let maxAudioCount: Int
    private let maxRawResponses: Int
    private var rawResponseCount = 0
    private var candidates: [Candidate] = []

    init(maxAudioCount: Int, maxRawResponses: Int) {
        self.maxAudioCount = maxAudioCount
        self.maxRawResponses = maxRawResponses
    }

    func reachedCap() -> Bool {
        rawResponseCount >= maxRawResponses || candidates.count >= maxAudioCount
    }

    func append(_ reply: MessageParser.SearchReplyInfo) {
        guard !reachedCap() else { return }
        rawResponseCount += 1
        for file in reply.files {
            if candidates.count >= maxAudioCount { break }
            if let cand = SearchQueryBuilder.makeCandidate(
                username: reply.username,
                file: file,
                freeSlots: reply.freeSlots,
                uploadSpeed: reply.uploadSpeed,
                queueLength: reply.queueLength
            ) {
                candidates.append(cand)
            }
        }
    }

    func snapshot() -> [Candidate] { candidates }
}

/// Transparent ROTATED obfuscation adapter over `SocketStream` for obfuscated peers.
private final class ObfuscatedSocketStream: SocketStream, @unchecked Sendable {
    private let inner: any SocketStream
    private var readBuf = Data()
    private var plainQueue = Data()

    init(inner: any SocketStream) {
        self.inner = inner
    }

    func read(maxBytes: Int, timeoutMs: Int32) async throws -> Data {
        if !plainQueue.isEmpty {
            let chunk = Data(plainQueue.prefix(maxBytes))
            plainQueue.removeFirst(chunk.count)
            return chunk
        }
        while plainQueue.isEmpty {
            let raw = try await inner.read(maxBytes: 65536, timeoutMs: timeoutMs)
            readBuf.append(raw)
            while let decoded = try ObfuscationCodec.decodeMessage(from: readBuf) {
                readBuf.removeFirst(decoded.bytesConsumed)
                plainQueue.append(MessageBuilder.wrapMessage(decoded.payload))
            }
        }
        let out = Data(plainQueue.prefix(maxBytes))
        plainQueue.removeFirst(out.count)
        return out
    }

    func readExact(count: Int, timeoutMs: Int32) async throws -> Data {
        var acc = Data()
        while acc.count < count {
            acc.append(try await read(maxBytes: count - acc.count, timeoutMs: timeoutMs))
        }
        return acc
    }

    func write(_ data: Data, timeoutMs: Int32) async throws {
        let wire = ObfuscationCodec.encodeMessage(payload: data.count > 4 ? Data(data.dropFirst(4)) : data)
        try await inner.write(wire, timeoutMs: timeoutMs)
    }

    func pushBack(_ data: Data) async {
        guard !data.isEmpty else { return }
        plainQueue.insert(contentsOf: data, at: 0)
    }

    func close() async {
        await inner.close()
    }
}
