import Foundation
import PluginKit

/// Manages P2P downloads (resume `.part`, queue waits, cancellation) and outgoing shares
/// (`SharesReply`, slot enforcement, serialized 256 KiB reads on iPod) (`SLSK-9`…`SLSK-13`).
public actor TransferCoordinator {
    private enum DownloadEvent: Sendable {
        case queued(UInt32)
        case transferReady(token: UInt32, fileSize: UInt64?)
        case denied(String)
        case failed
    }

    private struct ActiveDownload {
        let username: String
        let filename: String
        var continuation: AsyncStream<DownloadEvent>.Continuation?
    }

    private struct PendingFileTransfer {
        let username: String?
        let token: UInt32
        let continuation: CheckedContinuation<(any SocketStream, Data), Error>
    }

    private struct PendingUpload {
        let username: String
        let filename: String
        let entry: SlskSharedFile
        let token: UInt32
        let offset: UInt64
        var continuation: CheckedContinuation<MessageParser.TransferReplyInfo, Error>?
    }

    private weak var client: SoulseekClient?
    private var myUsername: String = ""
    private var onIPod = false

    // Downloads
    private var activeDownloads: [String: ActiveDownload] = [:] // key = "\(user)\0\(file)"
    private var pendingIncomingFiles: [String: PendingFileTransfer] = [:] // key = "\(user ?? "*")\0\(token)" or "*\0\(token)"

    // Shares & Uploads
    private var shareByVirtualPath: [String: SlskSharedFile] = [:]
    private var groupedShareDirs: [(directory: String, files: [(filename: String, size: UInt64, bitrate: UInt32?, duration: UInt32?)])] = []
    private var uploadSlotsLimit = 2
    private var activeUploads = 0
    private var uploadQueue: [(username: String, filename: String, session: PeerSession)] = []
    private var pendingUploadReplies: [UInt32: CheckedContinuation<MessageParser.TransferReplyInfo, Error>] = [:]
    private var sharingStopped = false
    private let diskReadGate = IPodReadGate()

    public func configure(client: SoulseekClient, myUsername: String, onIPod: Bool) {
        self.client = client
        self.myUsername = myUsername
        self.onIPod = onIPod
        self.sharingStopped = false
    }

    // MARK: - Download (`SLSK-9`, `SLSK-10`)

    public func download(
        candidate: Candidate,
        destinationDir: URL,
        onProgress: @escaping @Sendable (PluginProgress) async -> Void
    ) async throws -> URL {
        guard let tokenData = candidate.token.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(SlskCandidateToken.self, from: tokenData) else {
            throw PluginError(code: .unsupported, message: "Invalid Soulseek candidate token.")
        }
        guard let client else {
            throw PluginError(code: .network, message: "Soulseek client not initialized.")
        }

        let fm = FileManager.default
        try fm.createDirectory(at: destinationDir, withIntermediateDirectories: true)

        let leafName = Self.leafFilename(from: decoded.file)
        let partURL = destinationDir.appendingPathComponent("\(leafName).part")
        var existingSize: UInt64 = 0
        if fm.fileExists(atPath: partURL.path),
           let attrs = try? fm.attributesOfItem(atPath: partURL.path),
           let sz = attrs[.size] as? NSNumber {
            existingSize = sz.uint64Value
        }

        let dlKey = Self.transferKey(username: decoded.user, filename: decoded.file)
        let (eventStream, eventCont) = AsyncStream<DownloadEvent>.makeStream()
        activeDownloads[dlKey] = ActiveDownload(username: decoded.user, filename: decoded.file, continuation: eventCont)
        defer {
            activeDownloads.removeValue(forKey: dlKey)
            eventCont.finish()
        }

        var session = try await client.obtainPeerMessageSession(for: decoded.user)
        try Task.checkCancellation()

        // Queue download request (code 43); if an existing cached P session died half-open, evict & dial once.
        do {
            try await session.send(MessageBuilder.queueDownloadMessage(filename: decoded.file))
        } catch {
            await client.evictPeerSession(for: decoded.user)
            session = try await client.obtainPeerMessageSession(for: decoded.user)
            try await session.send(MessageBuilder.queueDownloadMessage(filename: decoded.file))
        }

        // Wait up to 20s for initial response (`TransferRequest`, `PlaceInQueue`, `UploadDenied`, `UploadFailed`),
        // then up to 180s without queue position improvement if queued.
        let (transferToken, fileSize) = try await waitForTransferStart(
            stream: eventStream,
            session: session,
            filename: decoded.file,
            onProgress: onProgress
        )

        try Task.checkCancellation()

        // Register F-connection expectation before sending TransferReply(allowed: true)
        let pendingKey = "\(decoded.user)\0\(transferToken)"
        defer { pendingIncomingFiles.removeValue(forKey: pendingKey) }

        let (fileStream, prebuffered) = try await withThrowingTaskGroup(of: (any SocketStream, Data).self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { cont in
                    Task { await self.registerFileWaiter(key: pendingKey, token: transferToken, cont: cont) }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 25_000_000_000)
                throw PluginError(code: .network, message: "Timed out waiting for peer file connection.")
            }

            try await session.send(MessageBuilder.transferReplyMessage(token: transferToken, allowed: true))

            guard let pair = try await group.next() else {
                throw PluginError(code: .network, message: "File connection failed.")
            }
            group.cancelAll()
            return pair
        }

        // Write 8-byte LE resume offset on the F connection and stream to `.part`
        do {
            let totalExpected = fileSize ?? UInt64(max(0, decoded.size))
            if totalExpected > 0 && existingSize >= totalExpected {
                await fileStream.close()
                await onProgress(PluginProgress(done: Double(totalExpected), total: Double(totalExpected), message: "Complete"))
                return partURL
            }

            var offsetData = Data()
            offsetData.appendUInt64(existingSize)
            try await fileStream.write(offsetData, timeoutMs: 10_000)

            if !fm.fileExists(atPath: partURL.path) {
                _ = fm.createFile(atPath: partURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: partURL)
            defer {
                try? handle.close()
                Task { await fileStream.close() }
            }
            if existingSize > 0 {
                try handle.seekToEnd()
            }

            var received = existingSize
            var buf = prebuffered

            if !buf.isEmpty {
                try handle.write(contentsOf: buf)
                received += UInt64(buf.count)
                buf.removeAll(keepingCapacity: false)
                await onProgress(PluginProgress(
                    done: Double(received),
                    total: totalExpected > 0 ? Double(totalExpected) : nil,
                    message: "Downloading…"
                ))
            }

            while totalExpected == 0 || received < totalExpected {
                try Task.checkCancellation()
                let chunk: Data
                do {
                    chunk = try await fileStream.read(maxBytes: 256 * 1024, timeoutMs: 25_000)
                } catch SocketError.closed {
                    break
                }
                if chunk.isEmpty { break }
                try handle.write(contentsOf: chunk)
                received += UInt64(chunk.count)
                await onProgress(PluginProgress(
                    done: Double(received),
                    total: totalExpected > 0 ? Double(totalExpected) : nil,
                    message: "Downloading…"
                ))
            }

            if totalExpected > 0 && received < totalExpected {
                throw PluginError(code: .network, message: "Peer disconnected before download completed.")
            }
            return partURL
        } catch is CancellationError {
            await fileStream.close()
            throw CancellationError()
        }
    }

    private func waitForTransferStart(
        stream: AsyncStream<DownloadEvent>,
        session: PeerSession,
        filename: String,
        onProgress: @escaping @Sendable (PluginProgress) async -> Void
    ) async throws -> (token: UInt32, fileSize: UInt64?) {
        var iter = stream.makeAsyncIterator()
        var bestQueuePlace: UInt32 = .max
        var lastQueueImprovement = Date()
        var receivedAnyQueueSignal = false

        while true {
            let timeoutSec: Double = receivedAnyQueueSignal ? 180.0 : 20.0
            let isQueuedAlready = receivedAnyQueueSignal
            let nextEvent = try await nextWithTimeout(iterator: &iter, timeoutSeconds: timeoutSec) {
                if !isQueuedAlready {
                    throw PluginError(code: .network, message: "Peer did not answer QueueUpload in 20 s.")
                } else {
                    throw PluginError(code: .unsupported, message: "Queue too long")
                }
            }

            switch nextEvent {
            case .queued(let place):
                receivedAnyQueueSignal = true
                if place < bestQueuePlace {
                    bestQueuePlace = place
                    lastQueueImprovement = Date()
                } else if Date().timeIntervalSince(lastQueueImprovement) > 180 {
                    throw PluginError(code: .unsupported, message: "Queue too long")
                }
                await onProgress(PluginProgress(done: 0, total: nil, message: "Queued (position \(place))"))
                // Re-query queue position gently only if still queued; server/peer usually pushes updates too.
            case .transferReady(let token, let size):
                return (token, size)
            case .denied(let reason):
                throw PluginError(code: .notFound, message: reason.isEmpty ? "Upload denied by peer." : reason)
            case .failed:
                throw PluginError(code: .network, message: "Upload failed on peer.")
            }
        }
    }

    private func nextWithTimeout(
        iterator: inout AsyncStream<DownloadEvent>.Iterator,
        timeoutSeconds: Double,
        onTimeout: @Sendable () throws -> Never
    ) async throws -> DownloadEvent {
        // Wrap single await against deadline cleanly using TaskGroup
        var localIter = iterator
        defer { iterator = localIter }

        enum RaceResult {
            case event(DownloadEvent?)
            case timedOut
        }

        let winner: RaceResult = await withTaskGroup(of: RaceResult.self) { group in
            group.addTask {
                await .event(localIter.next())
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                return .timedOut
            }
            let first = await group.next() ?? .timedOut
            group.cancelAll()
            return first
        }
        switch winner {
        case .event(let ev):
            guard let ev else { throw PluginError(code: .network, message: "Download aborted") }
            return ev
        case .timedOut:
            try onTimeout()
        }
    }

    private func registerFileWaiter(key: String, token: UInt32, cont: CheckedContinuation<(any SocketStream, Data), Error>) {
        pendingIncomingFiles[key] = PendingFileTransfer(username: nil, token: token, continuation: cont)
    }

    public func handleIncomingFileStream(stream: any SocketStream, prebuffered: Data, peerUsername: String?) async {
        // Read 4-byte LE FileTransferInit token
        var buf = prebuffered
        while buf.count < 4 {
            do {
                let chunk = try await stream.read(maxBytes: 4 - buf.count, timeoutMs: 15_000)
                buf.append(chunk)
            } catch {
                await stream.close()
                return
            }
        }
        guard let token = buf.readUInt32(at: 0) else {
            await stream.close()
            return
        }
        let trailing = Data(buf.dropFirst(4))

        if let peerUsername, let pending = pendingIncomingFiles.removeValue(forKey: "\(peerUsername)\0\(token)") {
            pending.continuation.resume(returning: (stream, trailing))
            return
        }
        if let matchKey = pendingIncomingFiles.first(where: { $0.value.token == token })?.key,
           let pending = pendingIncomingFiles.removeValue(forKey: matchKey) {
            pending.continuation.resume(returning: (stream, trailing))
            return
        }
        await stream.close()
    }

    // MARK: - Download Event Dispatch from PeerSession

    public func handlePlaceInQueueResponse(username: String, filename: String, place: UInt32) {
        let key = Self.transferKey(username: username, filename: filename)
        activeDownloads[key]?.continuation?.yield(.queued(place))
    }

    public func handleIncomingTransferRequest(username: String, info: MessageParser.TransferRequestInfo, session: PeerSession) async {
        if info.direction == .upload {
            let key = Self.transferKey(username: username, filename: info.filename)
            if let dl = activeDownloads[key] {
                dl.continuation?.yield(.transferReady(token: info.token, fileSize: info.fileSize))
            } else {
                try? await session.send(MessageBuilder.transferReplyMessage(token: info.token, allowed: false, reason: "Not requested"))
            }
        }
    }

    public func handleIncomingTransferReply(username: String, info: MessageParser.TransferReplyInfo) {
        if let cont = pendingUploadReplies.removeValue(forKey: info.token) {
            cont.resume(returning: info)
        }
    }

    public func handleUploadDenied(username: String, filename: String, reason: String) {
        let key = Self.transferKey(username: username, filename: filename)
        activeDownloads[key]?.continuation?.yield(.denied(reason))
    }

    public func handleUploadFailed(username: String, filename: String) {
        let key = Self.transferKey(username: username, filename: filename)
        activeDownloads[key]?.continuation?.yield(.failed)
    }

    // MARK: - Share Index & Uploads (`SLSK-11`, `SLSK-12`, `SLSK-13`)

    public func setShareIndex(entries: [ShareIndexEntry], uploadSlots: Int) {
        self.sharingStopped = false
        self.uploadSlotsLimit = max(1, uploadSlots)
        var byPath: [String: SlskSharedFile] = [:]
        var dirs: [String: [(filename: String, size: UInt64, bitrate: UInt32?, duration: UInt32?)]] = [:]

        for entry in entries {
            let slskPath = entry.virtualPath.replacingOccurrences(of: "/", with: "\\")
            let parts = slskPath.split(separator: "\\", omittingEmptySubsequences: true)
            let dirName = parts.count > 1 ? parts.dropLast().joined(separator: "\\") : "Music"
            let fileNameOnly = parts.last.map(String.init) ?? slskPath
            let fullVirtual = "\(dirName)\\\(fileNameOnly)"

            let item = SlskSharedFile(
                virtualDirectory: dirName,
                filename: fileNameOnly,
                fullVirtualPath: fullVirtual,
                realPath: entry.realPath,
                size: UInt64(max(0, entry.size)),
                bitrate: entry.bitrateKbps.map { UInt32(max(0, $0)) },
                duration: entry.durationMs.map { UInt32(max(0, $0 / 1000)) }
            )
            byPath[fullVirtual] = item
            byPath[slskPath] = item
            dirs[dirName, default: []].append((
                filename: fileNameOnly,
                size: item.size,
                bitrate: item.bitrate,
                duration: item.duration
            ))
        }

        self.shareByVirtualPath = byPath
        self.groupedShareDirs = dirs.keys.sorted().map { dir in
            (directory: dir, files: dirs[dir] ?? [])
        }
    }

    public func stopSharing() {
        sharingStopped = true
        uploadQueue.removeAll()
        for (_, cont) in pendingUploadReplies {
            cont.resume(throwing: CancellationError())
        }
        pendingUploadReplies.removeAll()
    }

    public func isEmpty() -> Bool { groupedShareDirs.isEmpty }

    public func shareCounts() -> (dirs: Int, files: Int) {
        let dirCount = groupedShareDirs.count
        let fileCount = groupedShareDirs.reduce(0) { $0 + $1.files.count }
        return (dirCount, fileCount)
    }

    public func activeUploadCount() -> Int { activeUploads }

    public func buildSharesReply(enabled: Bool) -> Data {
        guard enabled && !sharingStopped else {
            return MessageBuilder.sharesReplyMessage(files: [])
        }
        return MessageBuilder.sharesReplyMessage(files: groupedShareDirs)
    }

    public func handleIncomingQueueDownload(username: String, filename: String, session: PeerSession, shareEnabled: Bool) async {
        guard shareEnabled && !sharingStopped else {
            try? await session.send(MessageBuilder.uploadDeniedMessage(filename: filename, reason: "Sharing is disabled."))
            return
        }
        guard let shared = shareByVirtualPath[filename] ?? shareByVirtualPath[filename.replacingOccurrences(of: "/", with: "\\")] else {
            try? await session.send(MessageBuilder.uploadDeniedMessage(filename: filename, reason: "File not shared."))
            return
        }

        if activeUploads < uploadSlotsLimit {
            Task { [weak self] in
                await self?.performUpload(to: username, requestedName: filename, item: shared, session: session)
            }
        } else {
            if !uploadQueue.contains(where: { $0.username == username && $0.filename == filename }) {
                uploadQueue.append((username, filename, session))
            }
            if let pos = uploadQueue.firstIndex(where: { $0.username == username && $0.filename == filename }) {
                try? await session.send(MessageBuilder.placeInQueueResponseMessage(filename: filename, place: UInt32(pos + 1)))
            }
        }
    }

    public func handleIncomingPlaceInQueueRequest(username: String, filename: String, session: PeerSession) async {
        if let idx = uploadQueue.firstIndex(where: { $0.username == username && $0.filename == filename }) {
            try? await session.send(MessageBuilder.placeInQueueResponseMessage(filename: filename, place: UInt32(idx + 1)))
        }
    }

    private func performUpload(to username: String, requestedName: String, item: SlskSharedFile, session: PeerSession) async {
        activeUploads += 1
        await client?.reportReadySummary()
        defer {
            activeUploads = max(0, activeUploads - 1)
            Task { [weak self] in
                await self?.drainNextQueuedUpload()
                await self?.client?.reportReadySummary()
            }
        }

        let fm = FileManager.default
        guard fm.fileExists(atPath: item.realPath),
              let attrs = try? fm.attributesOfItem(atPath: item.realPath),
              let diskSize = (attrs[.size] as? NSNumber)?.uint64Value else {
            shareByVirtualPath.removeValue(forKey: item.fullVirtualPath)
            shareByVirtualPath.removeValue(forKey: requestedName)
            removeFromGroupedDirs(directory: item.virtualDirectory, filename: item.filename)
            try? await session.send(MessageBuilder.uploadFailedMessage(filename: requestedName))
            return
        }

        let token = UInt32.random(in: 1...UInt32.max - 1)
        guard let reply = try? await requestUploadAcceptance(token: token, requestedName: requestedName, diskSize: diskSize, session: session),
              reply.allowed else {
            return
        }

        guard let client,
              let fileStream = try? await client.openOutboundFileStream(to: username, token: token) else {
            try? await session.send(MessageBuilder.uploadFailedMessage(filename: requestedName))
            return
        }
        defer { Task { await fileStream.close() } }

        // FileTransferInit: 4-byte token + wait for 8-byte offset
        var tokenData = Data()
        tokenData.appendUInt32(token)
        do {
            try await fileStream.write(tokenData, timeoutMs: 10_000)
            let offsetBytes = try await fileStream.readExact(count: 8, timeoutMs: 15_000)
            let offset = offsetBytes.readUInt64(at: 0) ?? 0
            try await streamFileSequentially(path: item.realPath, offset: offset, to: fileStream)
        } catch {
            try? await session.send(MessageBuilder.uploadFailedMessage(filename: requestedName))
        }
    }

    private func requestUploadAcceptance(
        token: UInt32,
        requestedName: String,
        diskSize: UInt64,
        session: PeerSession
    ) async throws -> MessageParser.TransferReplyInfo {
        defer { pendingUploadReplies.removeValue(forKey: token) }
        return try await withThrowingTaskGroup(of: MessageParser.TransferReplyInfo.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { cont in
                    Task { await self.setUploadReplyWaiter(token: token, cont: cont) }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 15_000_000_000)
                throw PluginError(code: .network, message: "Upload TransferReply timed out")
            }
            try await session.send(MessageBuilder.transferRequestMessage(
                direction: .upload,
                token: token,
                filename: requestedName,
                fileSize: diskSize
            ))
            guard let res = try await group.next() else {
                throw PluginError(code: .network, message: "Upload rejected")
            }
            group.cancelAll()
            return res
        }
    }

    private func setUploadReplyWaiter(token: UInt32, cont: CheckedContinuation<MessageParser.TransferReplyInfo, Error>) {
        pendingUploadReplies[token] = cont
    }

    private func streamFileSequentially(path: String, offset: UInt64, to stream: any SocketStream) async throws {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        if offset > 0 {
            try handle.seek(toOffset: offset)
        }
        let chunkSize = 256 * 1024 // 256 KiB sequential reads per SLSK-13
        while !sharingStopped {
            try Task.checkCancellation()
            let chunk: Data?
            if onIPod {
                chunk = try await diskReadGate.serializedRead(handle: handle, upTo: chunkSize)
            } else {
                chunk = try handle.read(upToCount: chunkSize)
            }
            guard let chunk, !chunk.isEmpty else { break }
            try await stream.write(chunk, timeoutMs: 25_000)
        }
    }

    private func drainNextQueuedUpload() async {
        guard !sharingStopped, activeUploads < uploadSlotsLimit, !uploadQueue.isEmpty else { return }
        let next = uploadQueue.removeFirst()
        if let item = shareByVirtualPath[next.filename] {
            Task { [weak self] in
                await self?.performUpload(to: next.username, requestedName: next.filename, item: item, session: next.session)
            }
        }
    }

    private func removeFromGroupedDirs(directory: String, filename: String) {
        groupedShareDirs = groupedShareDirs.compactMap { dir in
            guard dir.directory == directory else { return dir }
            let remaining = dir.files.filter { $0.filename != filename }
            return remaining.isEmpty ? nil : (directory: dir.directory, files: remaining)
        }
    }

    private static func transferKey(username: String, filename: String) -> String {
        "\(username)\0\(filename)"
    }

    private static func leafFilename(from remotePath: String) -> String {
        let normalized = remotePath.replacingOccurrences(of: "\\", with: "/")
        let base = URL(fileURLWithPath: normalized).lastPathComponent
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_ "))
        let safe = base.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let str = String(safe).trimmingCharacters(in: .whitespacesAndNewlines)
        return str.isEmpty ? "soulseek-track" : str
    }
}

/// Ensures at most 1 sequential 256 KiB disk read at a time when serving directly from an iPod (`SLSK-13`).
private actor IPodReadGate {
    func serializedRead(handle: FileHandle, upTo count: Int) throws -> Data? {
        try handle.read(upToCount: count)
    }
}
