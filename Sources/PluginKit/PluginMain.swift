import Foundation
#if os(Windows)
import WinSDK
#elseif canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Out-of-process JSON-RPC 2.0 host loop for plug-ins (`PLG-3`).
///
/// Reads one UTF-8 JSON-RPC message per line from `stdin`, dispatches to the matching role
/// handler(s), handles `$/cancelRequest` and `shutdown`, and exits cleanly as soon as `stdin`
/// closes (preventing orphan processes on any OS).
public enum PluginMain {
    public static func run(
        roles: [any PluginRoleHandler],
        pluginID: String? = nil,
        version: String = "1.0.0"
    ) async {
        let server = PluginServer(roles: roles, defaultPluginID: pluginID, defaultVersion: version)
        await server.run()
    }

    public static func runSync(
        roles: [any PluginRoleHandler],
        pluginID: String? = nil,
        version: String = "1.0.0"
    ) {
        let sem = DispatchSemaphore(value: 0)
        Task {
            await run(roles: roles, pluginID: pluginID, version: version)
            sem.signal()
        }
        sem.wait()
    }
}

private final class StdoutWriter: @unchecked Sendable {
    private let lock = NSLock()

    func writeEnvelope(_ envelope: JsonRpcEnvelope) {
        guard let line = try? JsonRpcCodec.encodeLine(envelope) else { return }
        lock.lock()
        defer { lock.unlock() }
        line.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var remaining = raw.count
            var ptr = base
            while remaining > 0 {
                #if os(Windows)
                let handle = FileHandle.standardOutput
                handle.write(Data(bytes: ptr, count: remaining))
                remaining = 0
                #else
                let written = DarwinOrLibcWrite(STDOUT_FILENO, ptr, remaining)
                if written <= 0 { break }
                remaining -= written
                ptr = ptr.advanced(by: written)
                #endif
            }
        }
    }

    func sendResponse(id: JsonRpcID, result: JSONValue) {
        writeEnvelope(JsonRpcEnvelope(id: id, result: result))
    }

    func sendError(id: JsonRpcID, code: Int = -32000, errorCode: PluginErrorCode, message: String, retryAfterSeconds: Int? = nil) {
        let err = JsonRpcErrorObject(
            code: code,
            message: message,
            data: JsonRpcErrorData(code: errorCode.rawValue, retryAfterSeconds: retryAfterSeconds)
        )
        writeEnvelope(JsonRpcEnvelope(id: id, error: err))
    }

    func sendNotification(method: String, params: JSONValue) {
        writeEnvelope(JsonRpcEnvelope(method: method, params: params))
    }
}

#if !os(Windows)
private func DarwinOrLibcWrite(_ fd: Int32, _ ptr: UnsafeRawPointer, _ count: Int) -> Int {
    write(fd, ptr, count)
}
#endif

private final class RuntimeContextImpl: PluginRuntimeContext {
    private let writer: StdoutWriter

    init(writer: StdoutWriter) {
        self.writer = writer
    }

    func log(_ level: PluginLogLevel, _ message: String) async {
        if let value = try? JsonRpcCodec.encodeValue(PluginLogMessage(level: level, message: message)) {
            writer.sendNotification(method: "$/log", params: value)
        }
    }

    func reportStatus(_ state: PluginRuntimeState, message: String?) async {
        if let value = try? JsonRpcCodec.encodeValue(PluginStatusUpdate(state: state, message: message)) {
            writer.sendNotification(method: "$/status", params: value)
        }
    }

    func reportAccountStatus(_ status: PluginAccountStatus) async {
        if let value = try? JsonRpcCodec.encodeValue(status) {
            writer.sendNotification(method: "account/status", params: value)
        }
    }
}

private final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var lastSentNs: UInt64 = 0
    private let minIntervalNs: UInt64 = 250_000_000 // max 4 notifications / sec
    private let requestID: String
    private let writer: StdoutWriter

    init(requestID: String, writer: StdoutWriter) {
        self.requestID = requestID
        self.writer = writer
    }

    func emit(_ progress: PluginProgress) {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        let isFinal = progress.total.map { progress.done >= $0 } ?? false
        let allow = isFinal || lastSentNs == 0 || (now &- lastSentNs) >= minIntervalNs
        if allow { lastSentNs = now }
        lock.unlock()
        guard allow else { return }

        var payload = progress
        payload.requestID = requestID
        if let value = try? JsonRpcCodec.encodeValue(payload) {
            writer.sendNotification(method: "$/progress", params: value)
        }
    }
}

private actor PluginServer {
    private let playlistSource: (any PlaylistSource)?
    private let playlistReorderable: (any PlaylistReorderable)?
    private let playlistEditable: (any PlaylistEditable)?
    private let resolver: (any Resolver)?
    private let downloader: (any Downloader)?
    private let shareProvider: (any ShareProvider)?
    private let metadataProvider: (any MetadataLookupProvider)?
    private let lyricsProvider: (any LyricsLookupProvider)?
    private let configurable: (any PluginConfigurable)?
    private let accountHandler: (any PluginAccountHandling)?
    private let actionHandler: (any PluginActionHandling)?
    private let declaredRoles: [String]
    private var pluginID: String?
    private let version: String
    private let writer = StdoutWriter()
    private lazy var context = RuntimeContextImpl(writer: writer)

    private var activeTasks: [JsonRpcID: Task<Void, Never>] = [:]
    private var cancelledIDs: Set<JsonRpcID> = []
    private var shareParts: [Int: [ShareIndexEntry]] = [:]
    private var shouldStop = false
    private var stdinStreamContinuation: AsyncStream<Data>.Continuation?

    init(roles: [any PluginRoleHandler], defaultPluginID: String?, defaultVersion: String) {
        var foundRoles: [String] = []
        var ps: (any PlaylistSource)?
        var psReorder: (any PlaylistReorderable)?
        var psEditable: (any PlaylistEditable)?
        var res: (any Resolver)?
        var dl: (any Downloader)?
        var sh: (any ShareProvider)?
        var md: (any MetadataLookupProvider)?
        var ly: (any LyricsLookupProvider)?
        var cfg: (any PluginConfigurable)?
        var acc: (any PluginAccountHandling)?
        var act: (any PluginActionHandling)?

        for handler in roles {
            if ps == nil, let h = handler as? any PlaylistSource { ps = h; foundRoles.append(PluginRole.playlistSource.rawValue) }
            if psReorder == nil, let h = handler as? any PlaylistReorderable { psReorder = h }
            if psEditable == nil, let h = handler as? any PlaylistEditable { psEditable = h }
            if res == nil, let h = handler as? any Resolver { res = h; foundRoles.append(PluginRole.resolver.rawValue) }
            if dl == nil, let h = handler as? any Downloader { dl = h; foundRoles.append(PluginRole.downloader.rawValue) }
            if sh == nil, let h = handler as? any ShareProvider { sh = h; foundRoles.append(PluginRole.share.rawValue) }
            if md == nil, let h = handler as? any MetadataLookupProvider { md = h; foundRoles.append(PluginRole.metadataProvider.rawValue) }
            if ly == nil, let h = handler as? any LyricsLookupProvider { ly = h; foundRoles.append(PluginRole.lyricsProvider.rawValue) }
            if cfg == nil, let h = handler as? any PluginConfigurable { cfg = h }
            if acc == nil, let h = handler as? any PluginAccountHandling { acc = h }
            if act == nil, let h = handler as? any PluginActionHandling { act = h }
        }

        self.playlistSource = ps
        self.playlistReorderable = psReorder
        self.playlistEditable = psEditable
        self.resolver = res
        self.downloader = dl
        self.shareProvider = sh
        self.metadataProvider = md
        self.lyricsProvider = ly
        self.configurable = cfg
        self.accountHandler = acc
        self.actionHandler = act
        self.declaredRoles = foundRoles
        self.pluginID = defaultPluginID
        self.version = defaultVersion
    }

    func run() async {
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        self.stdinStreamContinuation = continuation
        Self.startStdinReader(continuation: continuation)

        for await lineData in stream {
            if lineData.count > pluginMaxLineBytes {
                continue
            }
            guard !lineData.isEmpty else { continue }
            guard let envelope = try? JsonRpcCodec.decoder.decode(JsonRpcEnvelope.self, from: lineData) else {
                continue
            }
            await handleEnvelope(envelope)
            if shouldStop { break }
        }

        await cancelAllAndCleanup()
    }

    private static func startStdinReader(continuation: AsyncStream<Data>.Continuation) {
        let queue = DispatchQueue(label: "ipodpromax.pluginkit.stdin", qos: .utility)
        queue.async {
            var buffer = Data()
            #if os(Windows)
            let handle = FileHandle.standardInput
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty {
                    if !buffer.isEmpty {
                        continuation.yield(trimCR(buffer))
                    }
                    continuation.finish()
                    return
                }
                appendChunk(chunk, buffer: &buffer, continuation: continuation)
            }
            #else
            var raw = [UInt8](repeating: 0, count: 65536)
            while true {
                let count = raw.withUnsafeMutableBytes { ptr in
                    read(STDIN_FILENO, ptr.baseAddress, ptr.count)
                }
                if count > 0 {
                    let chunk = Data(raw[0..<count])
                    appendChunk(chunk, buffer: &buffer, continuation: continuation)
                } else if count == 0 {
                    if !buffer.isEmpty {
                        continuation.yield(trimCR(buffer))
                    }
                    continuation.finish()
                    return
                } else {
                    if errno == EINTR { continue }
                    continuation.finish()
                    return
                }
            }
            #endif
        }
    }

    private static func appendChunk(
        _ chunk: Data,
        buffer: inout Data,
        continuation: AsyncStream<Data>.Continuation
    ) {
        buffer.append(chunk)
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newlineIndex]
            buffer.removeSubrange(buffer.startIndex...newlineIndex)
            let cleaned = trimCR(Data(line))
            if !cleaned.isEmpty {
                continuation.yield(cleaned)
            }
        }
        if buffer.count > pluginMaxLineBytes {
            buffer.removeAll(keepingCapacity: false)
        }
    }

    private static func trimCR(_ data: Data) -> Data {
        if data.last == 0x0D {
            return data.dropLast()
        }
        return data
    }

    private func handleEnvelope(_ envelope: JsonRpcEnvelope) async {
        guard let method = envelope.method else { return }

        // Notification
        guard let id = envelope.id else {
            await handleNotification(method: method, params: envelope.params)
            return
        }

        if method == "shutdown" {
            for (_, task) in activeTasks { task.cancel() }
            activeTasks.removeAll()
            try? await shareProvider?.stop()
            writer.sendResponse(id: id, result: .object([:]))
            shouldStop = true
            stdinStreamContinuation?.finish()
            return
        }

        if method == "initialize" {
            await handleInitialize(id: id, params: envelope.params)
            return
        }

        let task = Task { [weak self] in
            guard let self else { return }
            await self.dispatchRequest(id: id, method: method, params: envelope.params)
            await self.taskFinished(id: id)
        }
        activeTasks[id] = task
        if cancelledIDs.remove(id) != nil {
            task.cancel()
        }
    }

    private func taskFinished(id: JsonRpcID) {
        activeTasks.removeValue(forKey: id)
    }

    private func handleNotification(method: String, params: JSONValue?) async {
        switch method {
        case "$/cancelRequest":
            if let obj = params?.objectValue, let rawID = obj["id"] {
                let targetID: JsonRpcID? = switch rawID {
                case .int(let i): .int(i)
                case .string(let s): .string(s)
                default: nil
                }
                if let targetID {
                    if let task = activeTasks[targetID] {
                        task.cancel()
                    } else {
                        cancelledIDs.insert(targetID)
                    }
                }
            }
        case "settings/changed":
            let settings = params?.objectValue?["settings"]?.objectValue ?? [:]
            await configurable?.settingsChanged(settings)
        default:
            break
        }
    }

    private func handleInitialize(id: JsonRpcID, params: JSONValue?) async {
        do {
            let decoded = try JsonRpcCodec.decodeValue(PluginInitializeParams.self, from: params)
            guard decoded.apiVersion <= PluginContract.supportedAPIVersion else {
                writer.sendError(
                    id: id,
                    errorCode: .unsupported,
                    message: "Unsupported apiVersion \(decoded.apiVersion)"
                )
                return
            }
            if let explicitID = params?.objectValue?["pluginID"]?.stringValue, !explicitID.isEmpty {
                self.pluginID = explicitID
            }
            if let configurable {
                try await configurable.initialize(params: decoded, context: context)
            }
            let result = PluginInitializeResult(roles: declaredRoles, version: version)
            writer.sendResponse(id: id, result: try JsonRpcCodec.encodeValue(result))
        } catch let e as PluginError {
            writer.sendError(id: id, errorCode: e.code, message: e.message, retryAfterSeconds: e.retryAfterSeconds)
        } catch {
            writer.sendError(id: id, errorCode: .internal, message: error.localizedDescription)
        }
    }

    private func dispatchRequest(id: JsonRpcID, method: String, params: JSONValue?) async {
        do {
            try Task.checkCancellation()
            switch method {
            case "source/fetch":
                guard let playlistSource else {
                    throw PluginError(code: .unsupported, message: "Plug-in does not implement playlistSource.")
                }
                let req = try JsonRpcCodec.decodeValue(SourceFetchParams.self, from: params)
                guard let url = URL(string: req.url) else {
                    throw PluginError(code: .notFound, message: "Invalid URL: \(req.url)")
                }
                let result = try await playlistSource.fetch(url: url)
                try Task.checkCancellation()
                writer.sendResponse(id: id, result: try JsonRpcCodec.encodeValue(result))

            case "source/reorder":
                guard let playlistReorderable else {
                    throw PluginError(code: .unsupported, message: "Plug-in does not support reordering playlists.")
                }
                let req = try JsonRpcCodec.decodeValue(PlaylistReorderRequest.self, from: params)
                try await playlistReorderable.reorder(request: req)
                try Task.checkCancellation()
                writer.sendResponse(id: id, result: .object([:]))

            case "source/addTracks":
                guard let playlistEditable else {
                    throw PluginError(code: .unsupported, message: "Plug-in does not support adding tracks to playlists.")
                }
                let req = try JsonRpcCodec.decodeValue(PlaylistAddTracksRequest.self, from: params)
                let added = try await playlistEditable.addTracks(request: req)
                try Task.checkCancellation()
                writer.sendResponse(id: id, result: try JsonRpcCodec.encodeValue(added))

            case "resolver/search":
                guard let resolver else {
                    throw PluginError(code: .unsupported, message: "Plug-in does not implement resolver.")
                }
                let req = try JsonRpcCodec.decodeValue(ResolverSearchParams.self, from: params)
                let requestID = id.stringKey
                let localWriter = writer
                let candidates = try await resolver.search(track: req.track, policy: req.policy ?? QualityPolicy()) { partial in
                    guard !partial.isEmpty else { return }
                    let payload = ResolverCandidatesNotification(requestID: requestID, candidates: partial)
                    if let val = try? JsonRpcCodec.encodeValue(payload) {
                        localWriter.sendNotification(method: "resolver/candidates", params: val)
                    }
                }
                try Task.checkCancellation()
                let resp = ResolverSearchResult(candidates: candidates)
                writer.sendResponse(id: id, result: try JsonRpcCodec.encodeValue(resp))

            case "downloader/download":
                guard let downloader else {
                    throw PluginError(code: .unsupported, message: "Plug-in does not implement downloader.")
                }
                let req = try JsonRpcCodec.decodeValue(DownloaderDownloadParams.self, from: params)
                if let expectedID = pluginID, !expectedID.isEmpty, req.candidate.resolver != expectedID {
                    throw PluginError(
                        code: .wrongResolver,
                        message: "Candidate belongs to '\(req.candidate.resolver)', not '\(expectedID)'."
                    )
                }
                let destDir = URL(fileURLWithPath: req.destinationDir, isDirectory: true)
                let throttle = ProgressThrottle(requestID: id.stringKey, writer: writer)
                let downloadedURL = try await downloader.download(candidate: req.candidate, destinationDir: destDir) { progress in
                    throttle.emit(progress)
                }
                try Task.checkCancellation()
                let resp = DownloaderDownloadResult(path: downloadedURL.path)
                writer.sendResponse(id: id, result: try JsonRpcCodec.encodeValue(resp))

            case "share/setIndex":
                guard let shareProvider else {
                    throw PluginError(code: .unsupported, message: "Plug-in does not implement share.")
                }
                let req = try JsonRpcCodec.decodeValue(ShareSetIndexParams.self, from: params)
                shareParts[req.part] = req.entries
                if req.lastPart {
                    let ordered = shareParts.keys.sorted().flatMap { shareParts[$0] ?? [] }
                    shareParts.removeAll(keepingCapacity: false)
                    try await shareProvider.setIndex(entries: ordered, uploadSlots: req.uploadSlots)
                }
                try Task.checkCancellation()
                writer.sendResponse(id: id, result: .object([:]))

            case "share/stop":
                guard let shareProvider else {
                    throw PluginError(code: .unsupported, message: "Plug-in does not implement share.")
                }
                shareParts.removeAll(keepingCapacity: false)
                try await shareProvider.stop()
                writer.sendResponse(id: id, result: .object([:]))

            case "metadata/search":
                guard let metadataProvider else {
                    throw PluginError(code: .unsupported, message: "Plug-in does not implement metadataProvider.")
                }
                let query = try JsonRpcCodec.decodeValue(MetadataQuery.self, from: params)
                let matches = try await metadataProvider.search(query: query)
                try Task.checkCancellation()
                writer.sendResponse(id: id, result: try JsonRpcCodec.encodeValue(MetadataSearchResult(matches: matches)))

            case "lyrics/fetch":
                guard let lyricsProvider else {
                    throw PluginError(code: .unsupported, message: "Plug-in does not implement lyricsProvider.")
                }
                let query = try JsonRpcCodec.decodeValue(LyricsQuery.self, from: params)
                let match = try await lyricsProvider.fetchLyrics(query: query)
                try Task.checkCancellation()
                writer.sendResponse(id: id, result: try JsonRpcCodec.encodeValue(LyricsFetchResult(match: match)))

            case "account/login":
                guard let accountHandler else {
                    throw PluginError(code: .unsupported, message: "Plug-in does not support accounts.")
                }
                let req = try JsonRpcCodec.decodeValue(AccountLoginParams.self, from: params)
                let status = try await accountHandler.login(key: req.key, fields: req.fields)
                try Task.checkCancellation()
                writer.sendResponse(id: id, result: try JsonRpcCodec.encodeValue(status))

            case "account/logout":
                guard let accountHandler else {
                    throw PluginError(code: .unsupported, message: "Plug-in does not support accounts.")
                }
                let status = try await accountHandler.logout()
                writer.sendResponse(id: id, result: try JsonRpcCodec.encodeValue(status))

            case "account/status":
                guard let accountHandler else {
                    throw PluginError(code: .unsupported, message: "Plug-in does not support accounts.")
                }
                let status = try await accountHandler.status()
                writer.sendResponse(id: id, result: try JsonRpcCodec.encodeValue(status))

            case _ where method.hasPrefix("action/"):
                guard let actionHandler else {
                    throw PluginError(code: .unsupported, message: "Plug-in does not support actions.")
                }
                let key = String(method.dropFirst("action/".count))
                let result = try await actionHandler.performAction(key: key)
                try Task.checkCancellation()
                writer.sendResponse(id: id, result: try JsonRpcCodec.encodeValue(result))

            default:
                throw PluginError(code: .unsupported, message: "Unknown method '\(method)'")
            }
        } catch is CancellationError {
            writer.sendError(id: id, errorCode: .cancelled, message: "Cancelled")
        } catch let e as PluginError {
            writer.sendError(id: id, errorCode: e.code, message: e.message, retryAfterSeconds: e.retryAfterSeconds)
        } catch {
            writer.sendError(id: id, errorCode: .internal, message: error.localizedDescription)
        }
    }

    private func cancelAllAndCleanup() async {
        for (_, task) in activeTasks { task.cancel() }
        activeTasks.removeAll()
        try? await shareProvider?.stop()
    }
}

// MARK: - Internal RPC Param/Result DTOs

struct SourceFetchParams: Codable {
    var url: String
}

struct ResolverSearchParams: Codable {
    var track: TrackRef
    var policy: QualityPolicy?
}

struct ResolverSearchResult: Codable {
    var candidates: [Candidate]
}

struct ResolverCandidatesNotification: Codable {
    var requestID: String
    var candidates: [Candidate]
}

struct DownloaderDownloadParams: Codable {
    var candidate: Candidate
    var destinationDir: String
}

struct DownloaderDownloadResult: Codable {
    var path: String
}

struct ShareSetIndexParams: Codable {
    var part: Int
    var lastPart: Bool
    var entries: [ShareIndexEntry]
    var uploadSlots: Int
}

struct MetadataSearchResult: Codable {
    var matches: [MetadataMatch]
}

struct LyricsFetchResult: Codable {
    var match: LyricsMatch?
}

struct AccountLoginParams: Codable {
    var key: String
    var fields: [String: String]
}
