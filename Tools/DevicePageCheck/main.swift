import Foundation
import iPodKit
import DeviceKit

func log(_ message: String) { fputs(message + "\n", stderr) }

@main struct DevicePageCheck {
    @MainActor static func main() async throws {
        var devices = await Task.detached(priority: .utility) { DeviceScanner.scan() }.value
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
        print("PASS: per-device cache, event invalidation and preferences surviving navigation")
    }
}
