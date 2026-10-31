import Foundation
import iPodKit

/// Connection-scoped page data and pending preferences survive navigation without disk work.
@MainActor
final class DevicePageCache {
    static let shared = DevicePageCache()
    struct Snapshot: Sendable {
        var contents: DeviceContentsSummary
        var options: DeviceOptions
    }
    private var lastKnown: [IPodDevice: Snapshot] = [:]
    private let snapshots = DeviceSnapshotCache<Snapshot>()
    private var pending: [IPodDevice: DeviceOptions] = [:]
    private var writes: [IPodDevice: Task<Void, Never>] = [:]
    private let writer = OptionsWriter()

    var readCount: Int { snapshots.readCount }

    func cached(for device: IPodDevice) -> Snapshot? { snapshots.cached(for: device) ?? lastKnown[device] }
    func load(_ device: IPodDevice) async -> Snapshot? {
        guard var value = await snapshots.load(for: device, using: { dev in
            Snapshot(contents: DeviceContentsSummary.read(from: dev), options:
                DeviceDataFolder(mountPoint: dev.mountPoint).read(DeviceOptions.self, from: DeviceOptions.fileName) ?? DeviceOptions())
        }) else { return nil }
        if let options = pending[device] {
            value.options = options
            snapshots.store(value, for: device)
        }
        lastKnown[device] = value
        return value
    }
    func prefetch(_ devices: [IPodDevice]) async {
        let workers = max(1, ProcessInfo.processInfo.activeProcessorCount)
        await withTaskGroup(of: Void.self) { group in
            var iterator = devices.makeIterator()
            func next() {
                guard let device = iterator.next() else { return }
                group.addTask { _ = await self.load(device) }
            }
            for _ in 0..<min(workers, devices.count) { next() }
            for await _ in group { next() }
        }
    }
    func invalidate(_ device: IPodDevice) { snapshots.invalidate(device) }
    func forget(_ device: IPodDevice) {
        invalidate(device)
        lastKnown[device] = nil
        writes.removeValue(forKey: device)?.cancel()
        pending[device] = nil
    }
    func renamed(_ device: IPodDevice, to name: String) {
        guard var value = cached(for: device) else { return }
        value.contents.name = name
        lastKnown[device] = value
        if snapshots.cached(for: device) != nil { snapshots.store(value, for: device) }
    }
    func stage(_ options: DeviceOptions, for device: IPodDevice) {
        if var value = cached(for: device) {
            value.options = options
            lastKnown[device] = value
            if snapshots.cached(for: device) != nil { snapshots.store(value, for: device) }
        }
        pending[device] = options
        writes[device]?.cancel()
        writes[device] = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            do { try await flush(device) }
            catch { log("[app] Couldn't save iPod options: \(error.localizedDescription)") }
        }
    }
    func flush(_ device: IPodDevice) async throws {
        guard let value = pending[device] else { return }
        try await writer.write(value, to: DeviceDataFolder(mountPoint: device.mountPoint))
        if pending[device] == value { pending[device] = nil }
    }
    private actor OptionsWriter {
        func write(_ value: DeviceOptions, to folder: DeviceDataFolder) throws {
            try folder.write(value, to: DeviceOptions.fileName)
        }
    }
}
