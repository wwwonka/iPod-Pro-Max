import Foundation
import iPodKit
import MediaKit
import PluginKit

/// Keeps sharing plug-ins (`ShareProvider`, e.g. Soulseek) synchronized with the local Music folders
/// or connected iPod (`SUB-17`). Event-driven, throttled to at most once every 30 seconds on mutations.
@MainActor
final class ShareController {
    static let shared = ShareController()

    private(set) var shareStatusSummary: String = "Not sharing"
    private var observers: [AnyHashable: () -> Void] = [:]

    func observe(_ key: AnyHashable, _ handler: @escaping () -> Void) {
        observers[key] = handler
    }

    private func notify() {
        for handler in observers.values { handler() }
    }

    private var store: PortableLibraryStore?
    private var lastTracks: [LibraryTrack] = []
    private var connectedDevice: IPodDevice?
    private var lastPushedAt: Date = .distantPast
    private var pendingPushTask: Task<Void, Never>?
    private var isPushing = false

    private init() {}

    func attach(store: PortableLibraryStore?, tracks: [LibraryTrack], connectedDevice: IPodDevice?) {
        self.store = store
        self.lastTracks = tracks
        self.connectedDevice = connectedDevice
        schedulePush(immediate: lastPushedAt == .distantPast)
    }

    func update(tracks: [LibraryTrack], connectedDevice: IPodDevice?) {
        self.lastTracks = tracks
        self.connectedDevice = connectedDevice
        schedulePush(immediate: false)
    }

    func refreshIfShareEnabled() {
        schedulePush(immediate: true)
    }

    func shutdown() async {
        pendingPushTask?.cancel()
        pendingPushTask = nil
        guard let registry = PluginController.shared.registry else { return }
        for plugin in PluginController.shared.plugins where plugin.manifest?.knownRoles.contains(PluginRole.share) == true {
            if let runtime = registry.runtime(for: plugin.id) {
                try? await runtime.stop()
            }
        }
        shareStatusSummary = "Not sharing"
        notify()
    }

    private func schedulePush(immediate: Bool) {
        pendingPushTask?.cancel()
        guard let store, let registry = PluginController.shared.registry else {
            if shareStatusSummary != "Not sharing" {
                shareStatusSummary = "Not sharing"
                notify()
            }
            return
        }

        let sharePlugins = PluginController.shared.plugins.filter { plugin in
            guard let manifest = plugin.manifest,
                  manifest.knownRoles.contains(PluginRole.share),
                  PluginController.shared.isEnabled(plugin.id),
                  plugin.isEnabledEligible else {
                return false
            }
            return (PluginController.shared.settingsValues[plugin.id]?["share"]?.boolValue ?? true)
        }

        guard !sharePlugins.isEmpty else {
            if shareStatusSummary != "Not sharing" {
                shareStatusSummary = "Not sharing"
                notify()
            }
            return
        }

        let elapsed = Date().timeIntervalSince(lastPushedAt)
        let delaySec = immediate ? 0.0 : max(0.0, 30.0 - elapsed)
        let tracksSnapshot = lastTracks
        let deviceSnapshot = connectedDevice
        let targets = sharePlugins.compactMap { registry.runtime(for: $0.id) }

        pendingPushTask = Task { [weak self] in
            if delaySec > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delaySec * 1_000_000_000))
            }
            guard !Task.isCancelled, let self, !self.isPushing else { return }
            self.isPushing = true
            defer { self.isPushing = false }

            let built = await Task.detached(priority: .utility) {
                ShareIndexBuilder.build(
                    store: store,
                    tracks: tracksSnapshot,
                    connectedDevice: deviceSnapshot
                )
            }.value

            guard !Task.isCancelled else { return }
            self.lastPushedAt = Date()
            if self.shareStatusSummary != built.summary {
                self.shareStatusSummary = built.summary
                self.notify()
            }

            for runtime in targets {
                try? await runtime.setIndex(entries: built.entries, uploadSlots: built.uploadSlots)
            }
        }
    }
}
