import Foundation
import iPodKit
import DeviceKit

func log(_ message: String) { fputs(message + "\n", stderr) }

@main struct DevicePageCheck {
    @MainActor static func main() async throws {
        let extra = CommandLine.arguments.firstIndex(of: "--extra-ipod").flatMap { i in
            i + 1 < CommandLine.arguments.count ? URL(fileURLWithPath: CommandLine.arguments[i + 1]) : nil
        }
        var devices = await Task.detached(priority: .utility) { DeviceScanner.scan(simulatedFolders: extra.map { [$0] } ?? []) }.value
        if let simulated = PortableRoot.simulatedIPod(besides: devices) { devices.append(simulated) }
        guard devices.count >= 2 else { fatalError("Use two connected or simulated devices") }
        let start = Date()
        for _ in 0..<3 {
            for device in devices { _ = await Task.detached(priority: .utility) { DeviceContentsSummary.read(from: device) }.value }
        }
        print("Before: \(devices.count * 3) device-page reads in \(Date().timeIntervalSince(start)) s")
        let cache = DevicePageCache()
        await cache.prefetch(devices)
        let reads = cache.readCount
        let warm = Date()
        for _ in 0..<100 { for device in devices { _ = await cache.load(device) } }
        print("After: \(devices.count * 100) cached switches in \(Date().timeIntervalSince(warm)) s; additional reads: \(cache.readCount - reads)")
        guard cache.readCount == devices.count else { fatalError("Unexpected repeated reads") }
        cache.invalidate(devices[0])
        guard cache.cached(for: devices[0]) != nil else { fatalError("Invalidation blanked the capacity bar") }
        _ = await cache.load(devices[0])
        guard cache.readCount == reads + 1 else { fatalError("Invalidation failed") }
        // Staged options must survive leaving the view, and be flushed before ejecting.
        let scratch = URL(fileURLWithPath: CommandLine.arguments[CommandLine.arguments.firstIndex(of: "--portable-root")! + 1])
        guard let simulated = IPodDevice.detect(volume: scratch, simulated: true), simulated.sysInfo["pszSerialNumber"] == "TEST0000000" else { fatalError("Missing simulated device") }
        let value = await cache.load(simulated)
        var options = value?.options ?? DeviceOptions(); options.syncPodcasts.toggle()
        cache.stage(options, for: simulated)
        let retained = await cache.load(simulated)
        guard retained?.options == options else { fatalError("Lost pending choices") }
        try await cache.flush(simulated)
        guard DeviceDataFolder(mountPoint: scratch).read(DeviceOptions.self, from: DeviceOptions.fileName) == options else { fatalError("Flush failed") }
        let store = PortableLibraryStore(root: scratch, hostID: "check")
        var common = PortableSettings(); common.syncArtwork = false
        try store.data.write(common, to: "settings.json")
        let preferences = PortablePreferences()
        preferences.stageMusicMode("By Artist", store: store)
        try await preferences.flush()
        let saved = store.data.read(PortableSettings.self, from: "settings.json")
        guard saved?.musicViewMode == "By Artist", saved?.syncArtwork == false else { fatalError("Common preferences not flushed or other field lost") }
        let gone = scratch.appendingPathComponent("not-mounted")
        let absent = PortableLibraryStore(root: gone, hostID: "check")
        preferences.stageMusicMode("All Songs", store: absent)
        do { try await preferences.flush(); fatalError("Missing volume accepted") } catch {}
        guard !FileManager.default.fileExists(atPath: gone.path) else { fatalError("Host folder recreated") }
        print("PASS: common preferences immediate flush, field preservation and unavailable storage refusal")
        print("PASS: per-device cache, event invalidation and preferences surviving navigation")
    }
}
