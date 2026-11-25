import Foundation

/// Portable SHA-1 implementation in pure Swift (no CryptoKit dependency, works on macOS, Linux, Windows).
public struct PluginSHA1: Sendable {
    private var state: (UInt32, UInt32, UInt32, UInt32, UInt32) = (
        0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0
    )
    private var buffer: [UInt8] = []
    private var length: UInt64 = 0

    public init() {
        buffer.reserveCapacity(64)
    }

    public mutating func update(data: Data) {
        data.withUnsafeBytes { raw in
            guard let ptr = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            update(bytes: UnsafeBufferPointer(start: ptr, count: raw.count))
        }
    }

    public mutating func update(bytes: UnsafeBufferPointer<UInt8>) {
        length &+= UInt64(bytes.count)
        var i = 0
        if !buffer.isEmpty {
            while i < bytes.count && buffer.count < 64 {
                buffer.append(bytes[i])
                i += 1
            }
            if buffer.count == 64 {
                buffer.withUnsafeBufferPointer { processBlock($0) }
                buffer.removeAll(keepingCapacity: true)
            }
        }
        while i + 64 <= bytes.count {
            processBlock(UnsafeBufferPointer(rebasing: bytes[i..<(i + 64)]))
            i += 64
        }
        while i < bytes.count {
            buffer.append(bytes[i])
            i += 1
        }
    }

    public mutating func finalize() -> [UInt8] {
        let bitLength = length &* 8
        var tail = buffer
        tail.append(0x80)
        while tail.count % 64 != 56 { tail.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            tail.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift)))
        }
        tail.withUnsafeBufferPointer { p in
            for start in stride(from: 0, to: p.count, by: 64) {
                processBlock(UnsafeBufferPointer(rebasing: p[start..<(start + 64)]))
            }
        }
        var out: [UInt8] = []
        out.reserveCapacity(20)
        for word in [state.0, state.1, state.2, state.3, state.4] {
            out.append(UInt8((word >> 24) & 0xFF))
            out.append(UInt8((word >> 16) & 0xFF))
            out.append(UInt8((word >> 8) & 0xFF))
            out.append(UInt8(word & 0xFF))
        }
        return out
    }

    public static func hash(_ data: Data) -> [UInt8] {
        var h = PluginSHA1()
        h.update(data: data)
        return h.finalize()
    }

    public static func hex(_ data: Data) -> String {
        hash(data).map { String(format: "%02x", $0) }.joined()
    }

    private mutating func processBlock(_ block: UnsafeBufferPointer<UInt8>) {
        withUnsafeTemporaryAllocation(of: UInt32.self, capacity: 80) { w in
            for t in 0..<16 {
                let i = t * 4
                w[t] = UInt32(block[i]) << 24 | UInt32(block[i + 1]) << 16 | UInt32(block[i + 2]) << 8 | UInt32(block[i + 3])
            }
            for t in 16..<80 {
                let x = w[t - 3] ^ w[t - 8] ^ w[t - 14] ^ w[t - 16]
                w[t] = (x << 1) | (x >> 31)
            }
            var (a, b, c, d, e) = state
            for t in 0..<80 {
                let f: UInt32
                let k: UInt32
                switch t {
                case 0..<20:
                    f = (b & c) | (~b & d)
                    k = 0x5A827999
                case 20..<40:
                    f = b ^ c ^ d
                    k = 0x6ED9EBA1
                case 40..<60:
                    f = (b & c) | (b & d) | (c & d)
                    k = 0x8F1BBCDC
                default:
                    f = b ^ c ^ d
                    k = 0xCA62C1D6
                }
                let temp = ((a << 5) | (a >> 27)) &+ f &+ e &+ k &+ w[t]
                e = d
                d = c
                c = (b << 30) | (b >> 2)
                b = a
                a = temp
            }
            state = (state.0 &+ a, state.1 &+ b, state.2 &+ c, state.3 &+ d, state.4 &+ e)
        }
    }
}
