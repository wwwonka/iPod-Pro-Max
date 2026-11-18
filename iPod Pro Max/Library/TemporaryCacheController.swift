import Foundation
import MediaKit
import iPodKit
#if canImport(AppKitBackend)
import AppKit
#endif

@MainActor final class TemporaryCacheController {
    static let shared = TemporaryCacheController()
    private(set) var sizes: [String: Int64] = [:]
    private(set) var loading = false
    private(set) var limitMB = 200
    private(set) var clearSpectrum = false
    private(set) var clearWaveforms = false
    var onChange: () -> Void = {}
    private var store: PortableLibraryStore?
    private var refreshGeneration = 0
    private var configurationTask: Task<Void, Never>?
    private var policy: MediaCachePolicy {
        var value = MediaCachePolicy(); value.limitBytes = Int64(limitMB) * 1024 * 1024
        value.clearSpectrumOnExit = clearSpectrum; value.clearWaveformsOnExit = clearWaveforms
        return value
    }
    func load(_ settings: PortableSettings?, store: PortableLibraryStore) {
        self.store = store; limitMB = min(2048, max(10, settings?.temporaryCacheLimitMB ?? 200))
        clearSpectrum = settings?.clearSpectrumOnExit ?? false; clearWaveforms = settings?.clearWaveformsOnExit ?? false
        let policy = policy
        configure(policy, launchCleanup: true)
    }
    func startup() async {
        let settings = await Task.detached(priority: .utility) { () -> PortableSettings? in
            guard let root = PortableRoot.url else { return nil }
            return DeviceDataFolder(mountPoint: root).read(PortableSettings.self, from: "settings.json")
        }.value
        limitMB = min(2048, max(10, settings?.temporaryCacheLimitMB ?? 200))
        clearSpectrum = settings?.clearSpectrumOnExit ?? false; clearWaveforms = settings?.clearWaveformsOnExit ?? false
        let policy = policy
        await Task.detached(priority: .utility) { TemporaryMediaCache.shared.configure(policy, launchCleanup: true) }.value
    }
    func change(limitMB: Int? = nil, spectrum: Bool? = nil, waveforms: Bool? = nil) {
        if let limitMB { self.limitMB = min(2048, max(10, limitMB)) }
        if let spectrum { clearSpectrum = spectrum }; if let waveforms { clearWaveforms = waveforms }
        if let store { PortablePreferences.shared.stageCache(limitMB: self.limitMB, clearSpectrum: clearSpectrum, clearWaveforms: clearWaveforms, store: store) }
        let policy = policy
        onChange()
        configure(policy)
    }
    private func configure(_ policy: MediaCachePolicy, launchCleanup: Bool = false) {
        let previous = configurationTask
        configurationTask = Task {
            await previous?.value
            await Task.detached(priority: .utility) { TemporaryMediaCache.shared.configure(policy, launchCleanup: launchCleanup) }.value
            await refresh()
        }
    }
    func refresh() async {
        refreshGeneration += 1; let generation = refreshGeneration
        loading = true; onChange()
        let result = await Task.detached(priority: .utility) { TemporaryMediaCache.shared.sizes() }.value
        guard generation == refreshGeneration else { return }
        sizes = result; loading = false; onChange()
    }
    func clear() { Task { await Task.detached(priority: .utility) { TemporaryMediaCache.shared.clear() }.value; await refresh() } }
    func reveal() {
        #if canImport(AppKitBackend)
        Task {
            let root = await Task.detached(priority: .utility) { () -> URL in
                let root = TemporaryMediaCache.shared.root
                try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); return root
            }.value
            NSWorkspace.shared.open(root)
        }
        #endif
    }
    func exitCleanup() async { await configurationTask?.value; await Task.detached(priority: .utility) { TemporaryMediaCache.shared.cleanupOnExit() }.value }
}
