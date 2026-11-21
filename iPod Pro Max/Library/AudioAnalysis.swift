import Foundation
import MediaKit

struct AudioAnalysisResult: Sendable {
    var samples: [Float]
    var spectrum: PlayerSpectrum?
}

/// One operation per playing track; no file metadata access from row drawing or the main actor.
enum AudioAnalysis {
    private static let memory: NSCache<NSString, Cached> = {
        let cache = NSCache<NSString, Cached>(); cache.totalCostLimit = 12 * 1024 * 1024; return cache
    }()
    private final class Cached: NSObject { let result: AudioAnalysisResult; init(_ value: AudioAnalysisResult) { result = value } }
    static func read(_ url: URL, cache: TemporaryMediaCache = .shared, onSpectrum: (@Sendable (PlayerSpectrum) -> Void)? = nil) async -> AudioAnalysisResult {
        let cancellation = AudioAnalysisCancellation()
        let worker = Task.detached(priority: .utility) { () -> AudioAnalysisResult in
            let key = TemporaryMediaCache.key(for: url)
            let memoryKey = cache.root.path + "|" + key
            if let cached = memory.object(forKey: memoryKey as NSString) {
                cache.touch(.waveforms, key: key); cache.touch(.spectrum, key: key)
                return cached.result
            }
            let peaks = cache.read(.waveforms, key: key).flatMap(decodeWaveform)
            let spectrum = cache.read(.spectrum, key: key).flatMap(SpectrumFile.decode)
            if let peaks, let spectrum {
                let result = AudioAnalysisResult(samples: peaks, spectrum: spectrum.frames.isEmpty ? nil : spectrum)
                memory.setObject(Cached(result), forKey: memoryKey as NSString, cost: peaks.count * 4 + spectrum.frames.count * 64)
                return result
            }
            if let spectrum, !spectrum.frames.isEmpty { onSpectrum?(spectrum) }
            #if os(macOS)
            let result = MacAudioAnalysis.read(url, cachedSamples: peaks, cachedSpectrum: spectrum, key: key, cache: cache, cancellation: cancellation, onSpectrum: onSpectrum)
            #else
            let result = AudioAnalysisResult(samples: peaks ?? [], spectrum: spectrum)
            #endif
            guard !Task.isCancelled else { return AudioAnalysisResult(samples: [], spectrum: nil) }
            if !result.samples.isEmpty { cache.write(encodeWaveform(result.samples), category: .waveforms, key: key) }
            let cost = result.samples.count * 4 + (result.spectrum?.frames.count ?? 0) * 64
            memory.setObject(Cached(result), forKey: memoryKey as NSString, cost: cost)
            return result
        }
        return await withTaskCancellationHandler { await worker.value } onCancel: { cancellation.cancel(); worker.cancel() }
    }
    static func encodeWaveform(_ values: [Float]) -> Data {
        var data = Data("IPWF0001".utf8)
        for value in values { var bits = value.bitPattern.littleEndian; withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) } }
        return data
    }
    static func decodeWaveform(_ data: Data) -> [Float]? {
        guard data.starts(with: Data("IPWF0001".utf8)), data.count > 8, (data.count - 8) % 4 == 0, data.count <= 4104 else { return nil }
        let bytes = [UInt8](data.dropFirst(8))
        let values = stride(from: 0, to: bytes.count, by: 4).map { i -> Float in
            let a = UInt32(bytes[i]), b = UInt32(bytes[i+1]) << 8
            let c = UInt32(bytes[i+2]) << 16, d = UInt32(bytes[i+3]) << 24
            return Float(bitPattern: a | b | c | d)
        }
        return values.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 } ? values : nil
    }
}

/// Cancellation can interrupt AVAssetReader even while its next disk read is blocked.
final class AudioAnalysisCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var interrupt: (() -> Void)?
    func register(_ callback: @escaping () -> Void) {
        lock.lock()
        if cancelled { lock.unlock(); callback() } else { interrupt = callback; lock.unlock() }
    }
    func cancel() { lock.lock(); cancelled = true; let callback = interrupt; interrupt = nil; lock.unlock(); callback?() }
    func clear() { lock.lock(); interrupt = nil; lock.unlock() }
}
