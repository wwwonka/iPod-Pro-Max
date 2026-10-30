//
//  SHA1.swift
//  iPod Pro Max
//
//  SHA-1 in pure Swift, for the hash58 database signature. CryptoKit only exists on Apple platforms,
//  and hash58 hashes one database per sync, so a small portable implementation is all it takes.
//

import Foundation

public struct SHA1: Sendable {
    private var h: (UInt32, UInt32, UInt32, UInt32, UInt32) = (0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0)
    private var buffer: [UInt8] = []
    private var length: UInt64 = 0

    public init() { buffer.reserveCapacity(64) }

    public mutating func update<S: Sequence>(data: S) where S.Element == UInt8 {
        update(data: Array(data))
    }

    /// Faster path for large contiguous inputs such as a whole iTunesDB.
    public mutating func update(data: [UInt8]) {
        length &+= UInt64(data.count)
        var i = 0
        if !buffer.isEmpty {
            while i < data.count && buffer.count < 64 { buffer.append(data[i]); i += 1 }
            if buffer.count == 64 { processBlock(buffer); buffer.removeAll(keepingCapacity: true) }
        }
        data.withUnsafeBufferPointer { p in
            while i + 64 <= p.count {
                processBlock(UnsafeBufferPointer(rebasing: p[i..<(i + 64)]))
                i += 64
            }
        }
        while i < data.count { buffer.append(data[i]); i += 1 }
    }

    public mutating func finalize() -> [UInt8] {
        let bitLength = length &* 8
        var tail = buffer
        tail.append(0x80)
        while tail.count % 64 != 56 { tail.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) { tail.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift))) }
        for start in stride(from: 0, to: tail.count, by: 64) { processBlock(tail[start..<(start + 64)]) }
        var out: [UInt8] = []
        out.reserveCapacity(20)
        for word in [h.0, h.1, h.2, h.3, h.4] {
            out.append(UInt8(word >> 24)); out.append(UInt8((word >> 16) & 0xFF))
            out.append(UInt8((word >> 8) & 0xFF)); out.append(UInt8(word & 0xFF))
        }
        return out
    }

    public static func hash(_ data: [UInt8]) -> [UInt8] {
        var s = SHA1()
        s.update(data: data)
        return s.finalize()
    }

    private mutating func processBlock<C: Collection>(_ block: C) where C.Element == UInt8, C.Index == Int {
        // Stack scratch space: a heap array per 64-byte block would be thousands of allocations per cover.
        withUnsafeTemporaryAllocation(of: UInt32.self, capacity: 80) { w in
            compress(block, w)
        }
    }

    private mutating func compress<C: Collection>(_ block: C, _ w: UnsafeMutableBufferPointer<UInt32>) where C.Element == UInt8, C.Index == Int {
        let base = block.startIndex
        for t in 0..<16 {
            let i = base + t * 4
            w[t] = UInt32(block[i]) << 24 | UInt32(block[i + 1]) << 16 | UInt32(block[i + 2]) << 8 | UInt32(block[i + 3])
        }
        for t in 16..<80 {
            let x = w[t - 3] ^ w[t - 8] ^ w[t - 14] ^ w[t - 16]
            w[t] = (x << 1) | (x >> 31)
        }
        var (a, b, c, d, e) = h
        for t in 0..<80 {
            let f: UInt32, k: UInt32
            switch t {
            case 0..<20: f = (b & c) | (~b & d); k = 0x5A827999
            case 20..<40: f = b ^ c ^ d; k = 0x6ED9EBA1
            case 40..<60: f = (b & c) | (b & d) | (c & d); k = 0x8F1BBCDC
            default: f = b ^ c ^ d; k = 0xCA62C1D6
            }
            let temp = ((a << 5) | (a >> 27)) &+ f &+ e &+ k &+ w[t]
            e = d; d = c; c = (b << 30) | (b >> 2); b = a; a = temp
        }
        h = (h.0 &+ a, h.1 &+ b, h.2 &+ c, h.3 &+ d, h.4 &+ e)
    }
}
