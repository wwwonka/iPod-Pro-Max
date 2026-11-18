import CSockets
import Foundation

public enum SocketError: Error, LocalizedError, Sendable {
    case cancelled
    case timeout
    case closed
    case dnsFailed(Int32)
    case ioError(Int32)
    case addressInUse
    case invalidState

    public var errorDescription: String? {
        switch self {
        case .cancelled: "Socket operation cancelled"
        case .timeout: "Socket operation timed out"
        case .closed: "Connection closed"
        case .dnsFailed(let code): "DNS resolution failed (\(code))"
        case .ioError(let code): "Socket I/O error (\(code))"
        case .addressInUse: "Port already in use"
        case .invalidState: "Socket invalid state"
        }
    }
}

/// Abstract bidirectional async TCP stream (`SLSK-1`).
public protocol SocketStream: AnyObject, Sendable {
    func read(maxBytes: Int, timeoutMs: Int32) async throws -> Data
    func readExact(count: Int, timeoutMs: Int32) async throws -> Data
    func pushBack(_ data: Data) async
    func write(_ data: Data, timeoutMs: Int32) async throws
    func close() async
}

/// Abstract async TCP listener (`SLSK-1`).
public protocol SocketListener: AnyObject, Sendable {
    var port: UInt16 { get }
    func accept(timeoutMs: Int32) async throws -> any SocketStream
    func close() async
}

/// Abstract portable transport backed on all OSes by `CSockets` (`SLSK-1`).
public protocol SocketTransport: Sendable {
    func connect(host: String, port: UInt16, timeoutMs: Int32) async throws -> any SocketStream
    func listen(port: UInt16) throws -> any SocketListener
}

/// Singleton reactor + Swift async bridge over C `CSockReactor`.
public final class CSocketTransport: SocketTransport, @unchecked Sendable {
    public static let shared = CSocketTransport()

    private let reactor: OpaquePointer

    public init() {
        guard let r = csock_reactor_create() else {
            fatalError("Failed to create CSockReactor")
        }
        self.reactor = r
    }

    deinit {
        csock_reactor_destroy(reactor)
    }

    public func connect(host: String, port: UInt16, timeoutMs: Int32 = 10_000) async throws -> any SocketStream {
        try Task.checkCancellation()
        final class Box: @unchecked Sendable {
            var continuation: CheckedContinuation<csock_fd_t, Error>?
            var opID: UInt64 = 0
            let lock = NSLock()
        }
        let box = Box()
        let fd: csock_fd_t = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                box.lock.lock()
                box.continuation = cont
                box.lock.unlock()

                let rawPtr = Unmanaged.passRetained(box).toOpaque()
                let opID = host.withCString { cHost in
                    csock_connect_async(reactor, cHost, port, timeoutMs, rawPtr) { ctx, fd, err, sysErr in
                        guard let ctx else { return }
                        let b = Unmanaged<Box>.fromOpaque(ctx).takeRetainedValue()
                        b.lock.lock()
                        let c = b.continuation
                        b.continuation = nil
                        b.lock.unlock()
                        if err == CSOCK_OK && fd != CSOCK_INVALID_FD {
                            c?.resume(returning: fd)
                        } else {
                            c?.resume(throwing: CSocketTransport.mapError(err: err, sysErr: sysErr))
                        }
                    }
                }
                box.lock.lock()
                box.opID = opID
                box.lock.unlock()
                if Task.isCancelled {
                    csock_cancel_op(reactor, opID)
                }
            }
        } onCancel: {
            box.lock.lock()
            let opID = box.opID
            box.lock.unlock()
            if opID != 0 {
                csock_cancel_op(reactor, opID)
            }
        }
        return CSocketStream(reactor: reactor, fd: fd)
    }

    public func listen(port: UInt16) throws -> any SocketListener {
        var actualPort: UInt16 = 0
        var err: Int32 = 0
        var sysErr: Int32 = 0
        let fd = csock_listen(port, 64, &actualPort, &err, &sysErr)
        if fd == CSOCK_INVALID_FD {
            throw Self.mapError(err: err, sysErr: sysErr)
        }
        return CSocketListener(reactor: reactor, fd: fd, port: actualPort)
    }

    fileprivate static func mapError(err: Int32, sysErr: Int32) -> SocketError {
        switch Int(err) {
        case CSOCK_ERR_CLOSED: .closed
        case CSOCK_ERR_CANCELLED: .cancelled
        case CSOCK_ERR_TIMEOUT: .timeout
        case CSOCK_ERR_DNS: .dnsFailed(sysErr)
        case CSOCK_ERR_ADDR_IN_USE: .addressInUse
        default: .ioError(sysErr)
        }
    }
}

public final class CSocketStream: SocketStream, @unchecked Sendable {
    private let reactor: OpaquePointer
    private let stateLock = NSLock()
    private var fd: csock_fd_t
    private var readBuffer = Data()
    private let writeSerializer = StreamWriteSerializer()

    fileprivate init(reactor: OpaquePointer, fd: csock_fd_t) {
        self.reactor = reactor
        self.fd = fd
    }

    deinit {
        let f: csock_fd_t
        stateLock.lock()
        f = fd
        fd = CSOCK_INVALID_FD
        stateLock.unlock()
        if f != CSOCK_INVALID_FD {
            csock_close_fd(reactor, f)
        }
    }

    private func popBuffered(maxBytes: Int) -> (chunk: Data?, fd: csock_fd_t) {
        stateLock.lock()
        defer { stateLock.unlock() }
        if !readBuffer.isEmpty {
            let chunk = Data(readBuffer.prefix(maxBytes))
            readBuffer.removeFirst(chunk.count)
            return (chunk, fd)
        }
        return (nil, fd)
    }

    private func currentSocketFD() -> csock_fd_t {
        stateLock.lock()
        defer { stateLock.unlock() }
        return fd
    }

    private func takeSocketFD() -> csock_fd_t {
        stateLock.lock()
        defer { stateLock.unlock() }
        let f = fd
        fd = CSOCK_INVALID_FD
        return f
    }

    private func prependBuffer(_ data: Data) {
        stateLock.lock()
        readBuffer.insert(contentsOf: data, at: 0)
        stateLock.unlock()
    }

    public func read(maxBytes: Int = 65536, timeoutMs: Int32 = 0) async throws -> Data {
        try Task.checkCancellation()
        let (cached, currentFD) = popBuffered(maxBytes: maxBytes)
        if let cached { return cached }

        guard currentFD != CSOCK_INVALID_FD else { throw SocketError.closed }

        final class Box: @unchecked Sendable {
            var continuation: CheckedContinuation<Data, Error>?
            var opID: UInt64 = 0
            let lock = NSLock()
        }
        let box = Box()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                box.lock.lock()
                box.continuation = cont
                box.lock.unlock()

                let rawPtr = Unmanaged.passRetained(box).toOpaque()
                let opID = csock_read_async(reactor, currentFD, maxBytes, timeoutMs, rawPtr) { ctx, ptr, len, err, sysErr in
                    guard let ctx else { return }
                    let b = Unmanaged<Box>.fromOpaque(ctx).takeRetainedValue()
                    b.lock.lock()
                    let c = b.continuation
                    b.continuation = nil
                    b.lock.unlock()
                    if err == CSOCK_OK, let ptr, len > 0 {
                        c?.resume(returning: Data(bytes: ptr, count: Int(len)))
                    } else {
                        c?.resume(throwing: CSocketTransport.mapError(err: err, sysErr: sysErr))
                    }
                }
                box.lock.lock()
                box.opID = opID
                box.lock.unlock()
                if Task.isCancelled {
                    csock_cancel_op(reactor, opID)
                }
            }
        } onCancel: {
            box.lock.lock()
            let opID = box.opID
            box.lock.unlock()
            if opID != 0 {
                csock_cancel_op(reactor, opID)
            }
        }
    }

    public func readExact(count: Int, timeoutMs: Int32 = 30_000) async throws -> Data {
        guard count > 0 else { return Data() }
        var collected = Data()
        collected.reserveCapacity(count)
        while collected.count < count {
            let chunk = try await read(maxBytes: count - collected.count, timeoutMs: timeoutMs)
            collected.append(chunk)
        }
        return collected
    }

    public func pushBack(_ data: Data) async {
        guard !data.isEmpty else { return }
        prependBuffer(data)
    }

    public func write(_ data: Data, timeoutMs: Int32 = 30_000) async throws {
        try Task.checkCancellation()
        guard !data.isEmpty else { return }

        try await writeSerializer.run {
            try await self.writeUnserialized(data, timeoutMs: timeoutMs)
        }
    }

    private func writeUnserialized(_ data: Data, timeoutMs: Int32) async throws {
        try Task.checkCancellation()
        let currentFD = currentSocketFD()
        guard currentFD != CSOCK_INVALID_FD else { throw SocketError.closed }

        final class Box: @unchecked Sendable {
            var continuation: CheckedContinuation<Void, Error>?
            var opID: UInt64 = 0
            let lock = NSLock()
        }
        let box = Box()

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                box.lock.lock()
                box.continuation = cont
                box.lock.unlock()

                let rawPtr = Unmanaged.passRetained(box).toOpaque()
                let opID = data.withUnsafeBytes { raw in
                    let base = raw.bindMemory(to: UInt8.self).baseAddress
                    return csock_write_async(reactor, currentFD, base, data.count, timeoutMs, rawPtr) { ctx, _, err, sysErr in
                        guard let ctx else { return }
                        let b = Unmanaged<Box>.fromOpaque(ctx).takeRetainedValue()
                        b.lock.lock()
                        let c = b.continuation
                        b.continuation = nil
                        b.lock.unlock()
                        if err == CSOCK_OK {
                            c?.resume()
                        } else {
                            c?.resume(throwing: CSocketTransport.mapError(err: err, sysErr: sysErr))
                        }
                    }
                }
                box.lock.lock()
                box.opID = opID
                box.lock.unlock()
                if Task.isCancelled {
                    csock_cancel_op(reactor, opID)
                }
            }
        } onCancel: {
            box.lock.lock()
            let opID = box.opID
            box.lock.unlock()
            if opID != 0 {
                csock_cancel_op(reactor, opID)
            }
        }
    }

    public func close() async {
        let f = takeSocketFD()
        if f != CSOCK_INVALID_FD {
            csock_close_fd(reactor, f)
        }
    }
}

public final class CSocketListener: SocketListener, @unchecked Sendable {
    public let port: UInt16
    private let reactor: OpaquePointer
    private let stateLock = NSLock()
    private var fd: csock_fd_t

    fileprivate init(reactor: OpaquePointer, fd: csock_fd_t, port: UInt16) {
        self.reactor = reactor
        self.fd = fd
        self.port = port
    }

    deinit {
        let f = takeSocketFD()
        if f != CSOCK_INVALID_FD {
            csock_close_fd(reactor, f)
        }
    }

    private func currentSocketFD() -> csock_fd_t {
        stateLock.lock()
        defer { stateLock.unlock() }
        return fd
    }

    private func takeSocketFD() -> csock_fd_t {
        stateLock.lock()
        defer { stateLock.unlock() }
        let f = fd
        fd = CSOCK_INVALID_FD
        return f
    }

    public func accept(timeoutMs: Int32 = 0) async throws -> any SocketStream {
        try Task.checkCancellation()
        let currentFD = currentSocketFD()
        guard currentFD != CSOCK_INVALID_FD else { throw SocketError.closed }

        final class Box: @unchecked Sendable {
            var continuation: CheckedContinuation<csock_fd_t, Error>?
            var opID: UInt64 = 0
            let lock = NSLock()
        }
        let box = Box()

        let clientFD: csock_fd_t = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                box.lock.lock()
                box.continuation = cont
                box.lock.unlock()

                let rawPtr = Unmanaged.passRetained(box).toOpaque()
                let opID = csock_accept_async(reactor, currentFD, timeoutMs, rawPtr) { ctx, cfd, err, sysErr in
                    guard let ctx else { return }
                    let b = Unmanaged<Box>.fromOpaque(ctx).takeRetainedValue()
                    b.lock.lock()
                    let c = b.continuation
                    b.continuation = nil
                    b.lock.unlock()
                    if err == CSOCK_OK && cfd != CSOCK_INVALID_FD {
                        c?.resume(returning: cfd)
                    } else {
                        c?.resume(throwing: CSocketTransport.mapError(err: err, sysErr: sysErr))
                    }
                }
                box.lock.lock()
                box.opID = opID
                box.lock.unlock()
                if Task.isCancelled {
                    csock_cancel_op(reactor, opID)
                }
            }
        } onCancel: {
            box.lock.lock()
            let opID = box.opID
            box.lock.unlock()
            if opID != 0 {
                csock_cancel_op(reactor, opID)
            }
        }
        return CSocketStream(reactor: reactor, fd: clientFD)
    }

    public func close() async {
        let f = takeSocketFD()
        if f != CSOCK_INVALID_FD {
            csock_close_fd(reactor, f)
        }
    }
}

/// Ensures overlapping `write(_:)` calls on one socket transmit frames sequentially without interleaving.
private actor StreamWriteSerializer {
    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run(_ operation: () async throws -> Void) async throws {
        while isBusy {
            await withCheckedContinuation { cont in
                waiters.append(cont)
            }
        }
        isBusy = true
        defer {
            isBusy = false
            if !waiters.isEmpty {
                waiters.removeFirst().resume()
            }
        }
        try await operation()
    }
}
