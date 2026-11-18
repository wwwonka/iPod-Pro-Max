import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public extension URLSession {
    /// Cross-platform async `data(for:)` wrapper backed by `URLSessionDataTask` for macOS, Linux, and Windows.
    func portableData(for request: URLRequest) async throws -> (Data, URLResponse) {
        try Task.checkCancellation()
        let holder = PortableDataTaskHolder()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = dataTask(with: request) { data, response, error in
                    if let error {
                        let ns = error as NSError
                        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled {
                            continuation.resume(throwing: CancellationError())
                        } else {
                            continuation.resume(throwing: error)
                        }
                        return
                    }
                    guard let response else {
                        continuation.resume(throwing: URLError(.badServerResponse))
                        return
                    }
                    continuation.resume(returning: (data ?? Data(), response))
                }
                holder.set(task)
                task.resume()
            }
        } onCancel: {
            holder.cancel()
        }
    }
}

private final class PortableDataTaskHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var cancelled = false

    func set(_ t: URLSessionDataTask) {
        lock.lock()
        let shouldCancel = cancelled
        task = t
        lock.unlock()
        if shouldCancel { t.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let t = task
        lock.unlock()
        t?.cancel()
    }
}
