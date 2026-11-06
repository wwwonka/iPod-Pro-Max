import Foundation
import MediaKit

/// One analysis at a time per playing track; bounded result cache keyed by file revision.
enum AudioWaveform {
    private static let cache: NSCache<NSString, NSData> = {
        let c = NSCache<NSString, NSData>(); c.totalCostLimit = 4 * 1024 * 1024; return c
    }()
    static func samples(_ url: URL) async -> [Float] {
        let worker = Task.detached(priority: .utility) { () -> [Float] in
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let key = "\(url.path)|\(attributes?[.size] ?? 0)|\(attributes?[.modificationDate] ?? Date.distantPast)" as NSString
            if let data = cache.object(forKey: key) {
                var result = [Float](repeating: 0, count: data.length / MemoryLayout<Float>.size)
                result.withUnsafeMutableBytes { if let p = $0.baseAddress { data.getBytes(p, length: $0.count) } }
                return result
            }
            let peaks: [Float]
            #if os(macOS)
            peaks = WaveformAnalysis.read(url)
            #else
            guard let binary = FFmpeg.binaryPath() else { return [] }
            let collector = PeakCollector()
            do {
                try await FFmpeg.run(binary, ["-v", "error", "-threads", "1", "-i", url.path, "-vn", "-ac", "1",
                    "-af", "asetnsamples=n=4096,astats=metadata=1:reset=1,ametadata=print:key=lavfi.astats.Overall.Peak_level:file=-",
                    "-f", "null", "-"], onOutput: { collector.append($0) })
            } catch { return [] }
            peaks = collector.values()
            #endif
            guard !Task.isCancelled, !peaks.isEmpty else { return [] }
            let bounded: [Float] = (0..<min(1024, peaks.count)).map { i in
                let start = i * peaks.count / min(1024, peaks.count)
                let end = max(start + 1, (i + 1) * peaks.count / min(1024, peaks.count))
                return peaks[start..<end].max() ?? 0
            }
            bounded.withUnsafeBytes { bytes in
                if let p = bytes.baseAddress { cache.setObject(NSData(bytes: p, length: bytes.count), forKey: key, cost: bytes.count) }
            }
            return bounded
        }
        return await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
    }
}

private final class PeakCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var peaks: [Float] = []
    private var stride = 1
    private var count = 0
    private var peak: Float = 0
    func append(_ line: String) {
        guard line.hasPrefix("lavfi.astats.Overall.Peak_level="), let db = Float(line.split(separator: "=").last ?? "") else { return }
        lock.lock(); defer { lock.unlock() }
        peak = max(peak, db.isFinite ? pow(10, db / 20) : 0); count += 1
        if count >= stride { peaks.append(peak); peak = 0; count = 0 }
        if peaks.count >= 2048 {
            peaks = Swift.stride(from: 0, to: peaks.count, by: 2).map { max(peaks[$0], peaks[$0 + 1]) }
            stride *= 2
        }
    }
    func values() -> [Float] { lock.lock(); defer { lock.unlock() }; return peaks + (count > 0 ? [peak] : []) }
}
