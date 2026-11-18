#if os(macOS)
import Foundation
import AVFoundation
import MediaKit

/// Decode once into small PCM blocks; persist spectrum frames incrementally, never retain PCM.
enum MacAudioAnalysis {
    static func read(_ url: URL, cachedSamples: [Float]?, cachedSpectrum: PlayerSpectrum?, key: String, cache: TemporaryMediaCache = .shared, cancellation: AudioAnalysisCancellation = AudioAnalysisCancellation(), onSpectrum: (@Sendable (PlayerSpectrum) -> Void)? = nil) -> AudioAnalysisResult {
        let asset = AVURLAsset(url: url)
        guard !Task.isCancelled, let track = asset.tracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { return .init(samples: cachedSamples ?? [], spectrum: cachedSpectrum) }
        let duration = asset.duration.seconds
        let analyzer = cachedSpectrum == nil && duration.isFinite && duration <= 7200 ? SpectrumAnalyzer(sampleRate: 44100) : nil
        if cachedSamples != nil, duration > 7200 {
            cache.write(SpectrumFile.header, category: .spectrum, key: key)
            return .init(samples: cachedSamples ?? [], spectrum: nil)
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44100, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false])
        guard reader.canAdd(output) else { return .init(samples: cachedSamples ?? [], spectrum: cachedSpectrum) }
        reader.add(output); cancellation.register { reader.cancelReading() }; defer { cancellation.clear() }
        guard reader.startReading() else { return .init(samples: [], spectrum: nil) }
        let scratch = cache.scratchURL(extension: "spectrum")
        FileManager.default.createFile(atPath: scratch.path, contents: SpectrumFile.header)
        let writer = analyzer == nil ? nil : try? FileHandle(forWritingTo: scratch)
        writer?.seekToEndOfFile()
        var pending = Data()
        var writeFailed = false
        var decodedFrames = 0
        var lastPreviewAt: Double?
        analyzer?.onFrame = { frame in
            decodedFrames += 1
            pending.append(contentsOf: frame)
            if pending.count >= 8192 { do { try writer?.write(contentsOf: pending) } catch { writeFailed = true }; pending.removeAll(keepingCapacity: true) }
        }
        defer { try? writer?.close(); try? FileManager.default.removeItem(at: scratch) }
        var peaks: [Float] = [], peak: Float = 0
        var count = 0, strideSize = 4096
        while let sample = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sample) {
            if Task.isCancelled { reader.cancelReading(); return .init(samples: [], spectrum: nil) }
            let length = CMBlockBufferGetDataLength(block)
            guard length >= 8 else { continue }
            var pcm = [Float](repeating: 0, count: length / 4)
            let copied = pcm.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
            guard copied == kCMBlockBufferNoErr else { continue }
            for index in Swift.stride(from: 0, to: pcm.count - 1, by: 2) {
                let left = pcm[index], right = pcm[index + 1]
                analyzer?.consume(left: left, right: right)
                if cachedSamples == nil {
                    peak = max(peak, abs(left), abs(right)); count += 1
                    if count >= strideSize { peaks.append(peak); peak = 0; count = 0 }
                    if peaks.count >= 2048 {
                        peaks = Swift.stride(from: 0, to: peaks.count, by: 2).map { max(peaks[$0], peaks[$0+1]) }; strideSize *= 2
                    }
                }
            }
            // Publish the first 200 ms of audio promptly, then batch updates at
            // most twice per second. Rendering never waits for the whole track.
            if let onSpectrum, let analyzer, decodedFrames >= 4, !Task.isCancelled {
                let now = ProcessInfo.processInfo.systemUptime
                if lastPreviewAt == nil || now - lastPreviewAt! >= 0.5 {
                    lastPreviewAt = now; onSpectrum(analyzer.result())
                }
            }
        }
        guard !Task.isCancelled, reader.status == .completed else { return .init(samples: cachedSamples ?? [], spectrum: cachedSpectrum) }
        if count > 0 { peaks.append(peak) }
        let bins = min(1024, peaks.count)
        var bounded: [Float] = []
        if bins > 0 {
            for i in 0..<bins {
                let start = i * peaks.count / bins
                let end = max(start + 1, (i + 1) * peaks.count / bins)
                bounded.append(peaks[start..<end].max() ?? 0)
            }
        }
        let top = bounded.max() ?? 0
        let normalized = top > 0 ? bounded.map { min(1, $0 / top) } : bounded
        let spectrum = cachedSpectrum ?? analyzer?.result()
        if analyzer != nil, writer != nil, let spectrum, !spectrum.frames.isEmpty {
            do { try writer?.write(contentsOf: pending); try writer?.close() } catch { writeFailed = true }
            if !writeFailed { cache.commitScratch(scratch, category: .spectrum, key: key) }
        }
        if duration > 7200 { cache.write(SpectrumFile.header, category: .spectrum, key: key) }
        return .init(samples: cachedSamples ?? normalized, spectrum: spectrum)
    }
}
#endif
