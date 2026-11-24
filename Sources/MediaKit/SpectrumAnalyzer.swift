import Foundation
#if canImport(Accelerate)
import Accelerate
#endif

/// Streaming stereo FFT: fixed PCM memory, logarithmic bands, no real-time audio tap.
public final class SpectrumAnalyzer {
    public let sampleRate: Double
    private let size = 2048
    private var left = [Float](repeating: 0, count: 2048), right = [Float](repeating: 0, count: 2048)
    // One owned workspace per analyzer, reused for every channel and frame.
    // No shared PCM state and no copy-on-write array mutation in the FFT loop.
    private let workspace = FFTWorkspace(size: 2048)
    private var count = 0
    private let hop: Int
    private let window: [Float]
    private let bands: [Range<Int>]
    private var frames: [[UInt8]] = []
    public var onFrame: (([UInt8]) -> Void)?
    #if canImport(Accelerate)
    private let setup: vDSP_DFT_Setup?
    #endif
    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        hop = max(1, Int(sampleRate / 20))
        window = (0..<2048).map { Float(0.5 - 0.5 * cos(2 * .pi * Double($0) / 2047)) }
        let high = min(20000, sampleRate / 2)
        bands = (0..<16).map { band in
            let lower = 35 * pow(high / 35, Double(band) / 16)
            let upper = 35 * pow(high / 35, Double(band + 1) / 16)
            let start = min(1023, max(1, Int(lower * 2048 / sampleRate)))
            return start..<min(1024, max(start + 1, Int(upper * 2048 / sampleRate)))
        }
        #if canImport(Accelerate)
        setup = vDSP_DFT_zop_CreateSetup(nil, 2048, .FORWARD)
        #endif
    }
    deinit {
        #if canImport(Accelerate)
        if let setup { vDSP_DFT_DestroySetup(setup) }
        #endif
    }
    public func consume(left l: Float, right r: Float) {
        guard count < Int(sampleRate * 7200) else { return }
        left[count % size] = l; right[count % size] = r; count += 1
        if count >= size && count % hop == 0 {
            let frame = energies(left) + energies(right)
            frames.append(frame); onFrame?(frame)
        }
    }
    public func result() -> PlayerSpectrum { PlayerSpectrum(frames: frames, framesPerSecond: sampleRate / Double(hop)) }
    private func energies(_ ring: [Float]) -> [UInt8] {
        let inputReal = workspace.inputReal, inputImaginary = workspace.inputImaginary
        for i in 0..<size {
            inputReal[i] = ring[(count + i) % size] * window[i]
            inputImaginary[i] = 0
        }
        #if canImport(Accelerate)
        if let setup {
            vDSP_DFT_Execute(setup, inputReal, inputImaginary, workspace.outputReal, workspace.outputImaginary)
            return bandEnergies(real: workspace.outputReal, imaginary: workspace.outputImaginary)
        }
        #endif
        Self.fft(UnsafeMutableBufferPointer(start: inputReal, count: size), UnsafeMutableBufferPointer(start: inputImaginary, count: size))
        return bandEnergies(real: inputReal, imaginary: inputImaginary)
    }
    private func bandEnergies(real: UnsafePointer<Float>, imaginary: UnsafePointer<Float>) -> [UInt8] {
        return bands.map { band in
            var energy: Float = 0
            for bin in band { energy += real[bin] * real[bin] + imaginary[bin] * imaginary[bin] }
            let amplitude = sqrt(energy / Float(band.count)) / Float(size / 2)
            let db = 20 * log10(max(0.00001, amplitude))
            return UInt8(max(0, min(255, (db + 72) / 72 * 255)))
        }
    }
    static func fft(_ realBuffer: UnsafeMutableBufferPointer<Float>, _ imaginaryBuffer: UnsafeMutableBufferPointer<Float>) {
        var real = realBuffer, imaginary = imaginaryBuffer
        let n = real.count
        var j = 0
        for i in 1..<n {
            var bit = n >> 1
            while j & bit != 0 { j ^= bit; bit >>= 1 }; j ^= bit
            if i < j { real.swapAt(i, j); imaginary.swapAt(i, j) }
        }
        var length = 2
        while length <= n {
            let angle = -2 * Double.pi / Double(length)
            let wr = Float(cos(angle)), wi = Float(sin(angle))
            for start in stride(from: 0, to: n, by: length) {
                var ur: Float = 1, ui: Float = 0
                for k in 0..<(length / 2) {
                    let a = start + k, b = a + length / 2
                    let tr = real[b] * ur - imaginary[b] * ui, ti = real[b] * ui + imaginary[b] * ur
                    real[b] = real[a] - tr; imaginary[b] = imaginary[a] - ti
                    real[a] += tr; imaginary[a] += ti
                    let next = ur * wr - ui * wi; ui = ur * wi + ui * wr; ur = next
                }
            }
            length *= 2
        }
    }
}

public enum SpectrumFile {
    public static let header = Data("IPSP0001".utf8)
    public static func encode(_ spectrum: PlayerSpectrum) -> Data {
        var data = header
        for frame in spectrum.frames where frame.count == 32 { data.append(contentsOf: frame) }
        return data
    }
    public static func decode(_ data: Data) -> PlayerSpectrum? {
        guard data.starts(with: header), data.count >= 8, (data.count - 8) % 32 == 0, data.count <= 5_000_000 else { return nil }
        guard !Task.isCancelled else { return nil }
        let bytes = Array(data.dropFirst(8))
        var frames: [[UInt8]] = []; frames.reserveCapacity(bytes.count / 32)
        for index in stride(from: 0, to: bytes.count, by: 32) {
            if index % 8192 == 0 && Task.isCancelled { return nil }
            frames.append(Array(bytes[index..<(index + 32)]))
        }
        return PlayerSpectrum(frames: frames)
    }
}

/// Fixed-size, initialized Float storage. Only the owning analyzer touches it;
/// decoding remains serial within that analyzer and deinit releases all buffers.
private final class FFTWorkspace {
    let inputReal: UnsafeMutablePointer<Float>
    let inputImaginary: UnsafeMutablePointer<Float>
    let outputReal: UnsafeMutablePointer<Float>
    let outputImaginary: UnsafeMutablePointer<Float>
    private let size: Int
    init(size: Int) {
        self.size = size
        inputReal = .allocate(capacity: size); inputImaginary = .allocate(capacity: size)
        outputReal = .allocate(capacity: size); outputImaginary = .allocate(capacity: size)
        for buffer in [inputReal, inputImaginary, outputReal, outputImaginary] { buffer.initialize(repeating: 0, count: size) }
    }
    deinit {
        for buffer in [inputReal, inputImaginary, outputReal, outputImaginary] { buffer.deinitialize(count: size); buffer.deallocate() }
    }
}
