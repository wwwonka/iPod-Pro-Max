import Foundation
import PluginKit

/// Benchmark / spike runner for `--spike-search "<artist> - <title>"` or `--bench` (`SLSK-15`),
/// otherwise starts the JSON-RPC plugin loop cleanly on stdin/stdout.
private final class SpikeTimingBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Int?
    var value: Int? { lock.withLock { _value } }
    func markIfUnset(_ ms: Int) {
        lock.withLock { if _value == nil { _value = ms } }
    }
}

private struct PrintContext: PluginRuntimeContext {
    func log(_ level: PluginLogLevel, _ message: String) async {
        FileHandle.standardError.write(Data("[\(level.rawValue)] \(message)\n".utf8))
    }
    func reportStatus(_ state: PluginRuntimeState, message: String?) async {
        if let message {
            FileHandle.standardError.write(Data("[status:\(state.rawValue)] \(message)\n".utf8))
        }
    }
    func reportAccountStatus(_ status: PluginAccountStatus) async {}
}

let args = CommandLine.arguments
if args.count >= 3 && args[1] == "--spike-search" {
    let artist = args.count >= 4 ? args[2] : "Olivia Dean"
    let title = args.count >= 4 ? args[3] : args[2]
    let window = (args.count >= 5 ? Int(args[4]) : nil) ?? 8

    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("slsk-spike-\(UUID().uuidString)", isDirectory: true)
    let dataDir = tempDir.appendingPathComponent("Data", isDirectory: true)
    try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let idMgr = IdentityManager(dataDirectory: dataDir.path)
    let client = SoulseekClient(transport: CSocketTransport.shared, identity: idMgr)
    var cfg = SoulseekClient.Config()
    cfg.searchWindowSeconds = window
    await client.configure(context: PrintContext(), config: cfg, shareEnabled: false)

    let started = Date()
    let firstBox = SpikeTimingBox()
    let track = TrackRef(source: "spotify", sourceID: "spike", title: title, artists: [artist])
    do {
        let candidates = try await client.searchTrack(
            track: track,
            policy: QualityPolicy(),
            searchWindowSeconds: window,
            onPartialCandidates: { partial in
                if !partial.isEmpty {
                    firstBox.markIfUnset(Int(Date().timeIntervalSince(started) * 1000))
                }
            }
        )
        let totalMs = Int(Date().timeIntervalSince(started) * 1000)
        let summary: [String: Any] = [
            "query": "\(artist) - \(title)",
            "windowSeconds": window,
            "count": candidates.count,
            "firstCandidateMs": firstBox.value ?? totalMs,
            "totalMs": totalMs,
            "sample": candidates.prefix(5).map { "\($0.container) \($0.bitrateKbps ?? 0)k slots=\($0.availability?.freeSlot ?? false) :: \($0.displayName)" },
        ]
        if let json = try? JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted]) {
            FileHandle.standardOutput.write(json + Data("\n".utf8))
        }
        await client.stopAll()
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("Spike error: \(error.localizedDescription)\n".utf8))
        await client.stopAll()
        exit(1)
    }
} else {
    await PluginMain.run(roles: [SoulseekHandler()], pluginID: "soulseek", version: "1.0.0")
}
