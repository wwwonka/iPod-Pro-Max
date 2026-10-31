import Foundation
import iPodKit
import MediaKit

@main
struct PortableCheck {
    @MainActor static func main() async throws {
        guard let i = CommandLine.arguments.firstIndex(of: "--music-folder"), i + 1 < CommandLine.arguments.count,
              let root = PortableRoot.url else { fatalError("--music-folder <path> --portable-root <scratch iPod>") }
        let source = URL(fileURLWithPath: CommandLine.arguments[i + 1])
        try IPodDevice.createSimulatedIPod(at: root)
        let start = Date()
        let initial = try await PortableLoading.load(folder: source, refresh: true)
        print("Initial scan: \(initial.cache.tracks.count) tracks, \(Date().timeIntervalSince(start)) s")
        let cacheStart = Date()
        let cached = try await PortableLoading.load()
        print("Cache load + availability check: \(Date().timeIntervalSince(cacheStart)) s")
        let refreshStart = Date()
        let refreshed = try await PortableLoading.load(refresh: true)
        print("Incremental scan: \(Date().timeIntervalSince(refreshStart)) s")
        guard cached.cache.tracks.map(\.id) == refreshed.cache.tracks.map(\.id) else { fatalError("IDs changed") }
        var selected = Array(refreshed.cache.tracks.filter { !$0.needsTranscode }.prefix(2))
        if let convertible = refreshed.cache.tracks.first(where: { $0.needsTranscode }), !selected.isEmpty {
            selected = [selected[0], convertible]
            print("Testing compatible audio plus \(convertible.fileExtension) → AAC conversion")
        }
        guard selected.count == 2 else { fatalError("Need two music files") }
        guard let device = IPodDevice.detect(volume: root, simulated: true) else { fatalError("Device missing") }
        MusicTransfer.shared.onStatus = { print($0) }
        MusicTransfer.shared.onDrop = { ids, target in
            guard target == device.id else { return false }
            MusicTransfer.shared.enqueue(ids: ids.compactMap(UUID.init(uuidString:)), device: device, loaded: refreshed)
            return true
        }
        await withCheckedContinuation { continuation in
            MusicTransfer.shared.onFinished = { continuation.resume() }
            let payload = TrackDrag.begin(selected.map { $0.id.uuidString })
            guard !TrackDrag.accept("external text", device: device.id),
                  !TrackDrag.accept(payload, device: "wrong device"),
                  TrackDrag.accept(payload, device: device.id) else { fatalError("Drag endpoint failed") }
            TrackDrag.end()
        }
        guard try device.readDatabase().tracks.count == 2 else { fatalError("First transfer failed") }
        await withCheckedContinuation { continuation in
            MusicTransfer.shared.onFinished = { continuation.resume() }
            MusicTransfer.shared.enqueue(ids: selected.map(\.id), device: device, loaded: refreshed)
        }
        guard try device.readDatabase().tracks.count == 2 else { fatalError("Repeat duplicated tracks") }
        print("PASS: portable library, incremental scan, transfer queue and repeat drop")
    }
}
