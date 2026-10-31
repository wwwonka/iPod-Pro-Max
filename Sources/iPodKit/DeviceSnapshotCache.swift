import Foundation

/// Small per-device summaries, retained for the connection lifetime. Reads are coalesced and
/// detached from the main actor; invalidated reads can never overwrite a newer snapshot.
@MainActor
public final class DeviceSnapshotCache<Value: Sendable> {
    private struct Read {
        let token: UUID
        let task: Task<Value, Never>
    }
    private var values: [IPodDevice: Value] = [:]
    private var reads: [IPodDevice: Read] = [:]
    public private(set) var readCount = 0

    public init() {}
    public func cached(for device: IPodDevice) -> Value? { values[device] }

    public func load(for device: IPodDevice, using loader: @escaping @Sendable (IPodDevice) async -> Value) async -> Value? {
        if let value = values[device] { return value }
        let read: Read
        if let pending = reads[device] { read = pending }
        else {
            readCount += 1
            read = Read(token: UUID(), task: Task.detached(priority: .utility) { await loader(device) })
            reads[device] = read
        }
        let value = await read.task.value
        guard reads[device]?.token == read.token else { return values[device] }
        values[device] = value
        reads[device] = nil
        return value
    }

    public func store(_ value: Value, for device: IPodDevice) {
        reads.removeValue(forKey: device)?.task.cancel()
        values[device] = value
    }
    public func invalidate(_ device: IPodDevice) {
        reads.removeValue(forKey: device)?.task.cancel()
        values[device] = nil
    }
}
