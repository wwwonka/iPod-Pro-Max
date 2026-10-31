import Foundation
import iPodKit
import MediaKit

/// One event-driven queue per connected device. No timer or idle work.
@MainActor
final class MusicTransfer {
    static let shared = MusicTransfer()
    var beforeTransfer: (IPodDevice) async throws -> Void = { _ in }
    var acceptingDrops = true
    var onActivityChanged: (Set<String>) -> Void = { _ in }
    var runningDeviceIDs: Set<String> { Set(tasks.keys) }
    var onStatus: (String) -> Void = { _ in }
    var onFinished: () -> Void = {}
    var onDeviceFinished: (IPodDevice) -> Void = { _ in }
    var onDrop: ([String], String) -> Bool = { _, _ in false }
    private var ejecting: Set<String> = []
    func beginEject(_ device: IPodDevice) -> Bool {
        guard !isRunning(device), !ejecting.contains(device.id) else { return false }
        ejecting.insert(device.id); return true
    }
    func endEject(_ device: IPodDevice) { ejecting.remove(device.id) }
    private var queues: [String: [UUID: LibraryTrack]] = [:]
    private var loadedByDevice: [String: LoadedPortableLibrary] = [:]
    private var podcastJobs: [String: ([PodcastShow], LoadedPortableLibrary)] = [:]
    var onPodcastResult: (SyncResult) -> Void = { _ in }
    private var tasks: [String: Task<Void, Never>] = [:]
    private var engines: [String: Task<SyncResult, Error>] = [:]
    private var cancelled = Set<String>()
    func finishActiveTransfers() async {
        for task in Array(tasks.values) { await task.value }
    }
    func isRunning(_ device: IPodDevice) -> Bool { tasks[device.id] != nil }
    func cancel(_ device: IPodDevice) {
        cancelled.insert(device.id); queues[device.id] = nil
        tasks[device.id]?.cancel(); engines[device.id]?.cancel()
    }
    func enqueue(ids: [UUID], device: IPodDevice, loaded: LoadedPortableLibrary) {
        guard acceptingDrops else { onStatus("Finishing current operations before closing…"); return }
        guard device.supportLevel != .unsupported else {
            onStatus("This iPod's database signature is not supported yet.")
            return
        }
        guard !ejecting.contains(device.id) else { onStatus("This iPod is being ejected."); return }
        let selected = Set(ids)
        loadedByDevice[device.id] = loaded
        for track in loaded.cache.tracks where selected.contains(track.id) && (track.kind == nil || track.kind == .song) {
            queues[device.id, default: [:]][track.id] = track
        }
        start(device)
    }

    /// Downloaded podcast episodes, chosen by each show's "keep the latest" rule, copied once.
    func enqueuePodcasts(shows: [PodcastShow], device: IPodDevice, loaded: LoadedPortableLibrary) {
        guard acceptingDrops else { onStatus("Finishing current operations before closing…"); return }
        guard device.supportLevel != .unsupported else {
            onStatus("This iPod's database signature is not supported yet.")
            return
        }
        guard device.supportsPodcasts else { onStatus("This iPod's firmware has no Podcasts menu."); return }
        guard !ejecting.contains(device.id) else { onStatus("This iPod is being ejected."); return }
        podcastJobs[device.id] = (shows, loaded)
        start(device)
    }

    private func start(_ device: IPodDevice) {
        guard tasks[device.id] == nil else { return }
        cancelled.remove(device.id)
        tasks[device.id] = Task {
            var changed = false
            defer { tasks[device.id] = nil; engines[device.id] = nil; queues[device.id] = nil; podcastJobs[device.id] = nil; onActivityChanged(runningDeviceIDs); if changed { onDeviceFinished(device) }; onFinished() }
            while !Task.isCancelled {
                do {
                    if let pending = queues.removeValue(forKey: device.id), !pending.isEmpty {
                        let loaded = loadedByDevice[device.id]
                        guard let loaded else { break }
                        let tracks = Array(pending.values).sorted { $0.id.uuidString < $1.id.uuidString }
                        onStatus("Preparing \(tracks.count) songs…")
                        let grouping = DeviceDataFolder(mountPoint: device.mountPoint).read(DeviceOptions.self, from: DeviceOptions.fileName)?.useAlbumArtistForGrouping ?? true
                        if let result = try await transfer(device, prepare: {
                            try await PortableMusicTransfer.prepare(tracks: tracks, device: device, store: loaded.store, albumArtistGrouping: grouping)
                        }) { changed = changed || result.added > 0 }
                    } else if let (shows, loaded) = podcastJobs.removeValue(forKey: device.id) {
                        onStatus("Preparing podcast episodes…")
                        if let result = try await transfer(device, prepare: {
                            try PortablePodcastTransfer.prepare(shows: shows, device: device, store: loaded.store)
                        }) {
                            changed = changed || result.added > 0
                            onPodcastResult(result)
                        }
                    } else { break }
                } catch {
                    onStatus(Task.isCancelled || cancelled.contains(device.id) ? "Transfer cancelled" : "Transfer failed: \(error.localizedDescription)")
                    queues[device.id] = nil; podcastJobs[device.id] = nil
                    break
                }
            }
        }
        onActivityChanged(runningDeviceIDs)
    }

    /// One engine run, shared by music and podcasts: nil when everything was already on the iPod.
    private func transfer(_ device: IPodDevice, prepare: @escaping @Sendable () async throws -> PortableMusicTransfer.Prepared) async throws -> SyncResult? {
        try await beforeTransfer(device)
        let preparation = Task.detached(priority: .userInitiated) { try await prepare() }
        let prepared = try await withTaskCancellationHandler(operation: { try await preparation.value }, onCancel: { preparation.cancel() })
        guard !Task.isCancelled else { throw CancellationError() }
        if prepared.request.tracks.isEmpty && prepared.request.shows.allSatisfy({ $0.episodes.isEmpty }) {
            onStatus("\(prepared.reused) already on iPod")
            return nil
        }
        let handler = onStatus
        let gate = TransferProgressGate()
        let engine = SyncEngine(request: prepared.request) { progress in
            guard gate.shouldPublish() else { return }
            Task { @MainActor in handler("\(progress.phase): \(progress.detail)") }
        }
        let task = Task.detached(priority: .userInitiated) { try await engine.run() }
        engines[device.id] = task
        let result = try await task.value
        engines[device.id] = nil
        try await Task.detached(priority: .utility) {
            // Pending entries are written before copy; only confirmed files are committed.
            let db = try device.readDatabase()
            let valid = Set(db.tracks.filter { $0.fileURL(mountPoint: device.mountPoint).map { FileManager.default.fileExists(atPath: $0.path) } ?? false }.map(\.dbid))
            var manifest = prepared.manifest
            manifest.tracks.removeAll { !valid.contains($0.dbid) }
            try DeviceDataFolder(mountPoint: device.mountPoint).write(manifest, to: "manifest.json")
        }.value
        onStatus("\(result.added) added · \(prepared.reused) already on iPod\(result.failed.isEmpty ? "" : " · \(result.failed.count) failed: \(result.failed.joined(separator: "; "))")")
        return result
    }
}

private final class TransferProgressGate: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast
    func shouldPublish() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        guard now.timeIntervalSince(last) >= 0.5 else { return false }
        last = now; return true
    }
}
