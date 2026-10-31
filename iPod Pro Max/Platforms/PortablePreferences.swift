import Foundation
import iPodKit

/// Small common preferences, staged synchronously by controls and flushed at operation boundaries.
@MainActor
final class PortablePreferences {
    static let shared = PortablePreferences()
    private var pending: (store: PortableLibraryStore, mode: String, revision: Int)?
    private var revision = 0
    private var saveTask: Task<Void, Never>?
    private let writer = Writer()

    func stageMusicMode(_ mode: String, store: PortableLibraryStore) {
        guard pending?.mode != mode || pending?.store.data.url != store.data.url else { return }
        revision += 1
        pending = (store, mode, revision)
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            do { try await flush() }
            catch { ApplicationLifecycle.shared.report(error) }
        }
    }
    func flush() async throws {
        while let value = pending {
            try await writer.write(mode: value.mode, store: value.store)
            if pending?.revision == value.revision { pending = nil }
        }
    }
    private actor Writer {
        func write(mode: String, store: PortableLibraryStore) throws {
            try store.data.requireAvailableStorage()
            var value = try store.data.readChecked(PortableSettings.self, from: "settings.json") ?? PortableSettings()
            guard value.version == 1 else { throw IPodDBError.unsupported("Unsupported settings.json version") }
            guard value.musicViewMode != mode else { return }
            value.musicViewMode = mode
            try store.data.write(value, to: "settings.json")
        }
    }
}

/// Platform close hooks await this operation instead of discarding pending preferences or writes.
@MainActor
final class ApplicationLifecycle {
    static let shared = ApplicationLifecycle()
    var savePreferences: () async throws -> Void = {}
    var beforeExit: () async throws -> Void = {}
    var onError: (String) -> Void = { _ in }
    private var exitTask: Task<Void, Error>?
    func prepareForExit() async throws {
        if let exitTask { try await exitTask.value; return }
        let task = Task { try await beforeExit() }
        exitTask = task
        defer { exitTask = nil }
        try await task.value
    }
    func report(_ error: Error) {
        onError("Couldn't save preferences: \(error.localizedDescription)")
    }
}
