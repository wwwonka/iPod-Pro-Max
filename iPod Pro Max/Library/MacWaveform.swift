#if os(macOS)
import Foundation
import AVFoundation

enum WaveformAnalysis {
    private static let cache: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.totalCostLimit = 8 * 1024 * 1024
        return cache
    }()
    static func read(_ url: URL) -> [Float] {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let key = "\(url.path)|\(modified)|\(size)" as NSString
        if let cached = cache.object(forKey: key) {
            var values = [Float](repeating: 0, count: cached.length / MemoryLayout<Float>.size)
            values.withUnsafeMutableBytes { buffer in
                if let base = buffer.baseAddress { cached.getBytes(base, length: buffer.count) }
            }
            return values
        }
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .audio).first, let reader = try? AVAssetReader(asset: asset) else { return [] }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false])
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        guard reader.startReading() else { return [] }
        // Aggregate fixed blocks as the file is decoded; memory is bounded by duration rather than PCM size.
        var peaks: [Float] = []
        var peak: Int = 0, sampleCount = 0
        var samplesPerPeak = 4096
        while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
            if Task.isCancelled { reader.cancelReading(); return [] }
            let length = (CMBlockBufferGetDataLength(block) / 2) * 2
            guard length > 0 else { continue }
            var bytes = [Int16](repeating: 0, count: length / 2)
            let copied = bytes.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            guard copied == kCMBlockBufferNoErr else { continue }
            for sample in bytes {
                peak = max(peak, abs(Int(sample))); sampleCount += 1
                if sampleCount >= samplesPerPeak {
                    peaks.append(Float(peak) / 32768); peak = 0; sampleCount = 0
                    if peaks.count >= 2048 {
                        peaks = stride(from: 0, to: peaks.count, by: 2).map { max(peaks[$0], peaks[$0 + 1]) }
                        samplesPerPeak *= 2
                    }
                }
            }
        }
        if sampleCount > 0 { peaks.append(Float(peak) / 32768) }
        let maxPeak = peaks.max() ?? 0
        let result = maxPeak > 0 ? peaks.map { min(1, $0 / maxPeak) } : peaks
        if !Task.isCancelled && reader.status == .completed {
            let data = result.withUnsafeBytes { NSData(bytes: $0.baseAddress, length: $0.count) }
            cache.setObject(data, forKey: key, cost: data.length)
        }
        return result
    }
}
#endif
