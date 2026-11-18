// Adapted from seeleseek (https://github.com/bretth18/seeleseek), MIT License
// Copyright 2026 Brett Henderson / COMPUTER DATA / The Virtuous Corporation
// Portable zlib wrapper backed by CZlib (miniz) instead of Apple Compression (`SLSK-2`).

import CZlib
import Foundation

public enum DecompressionError: Error {
    case dataTooShort
    case decompressionFailed
    case suspiciousCompressionRatio
    case decompressedSizeExceeded
    case presetDictionaryUnsupported
    case checksumMismatch
}

public enum ZlibCodec {
    public static let maxDecompressedSize = 256 * 1024 * 1024
    public static let maxCompressionRatio = 1000

    /// Compresses `data` into standard RFC 1950 zlib format (`0x78 0x9C` + DEFLATE + big-endian Adler-32).
    public static func compress(_ data: Data) -> Data {
        var destLen = mz_compressBound(mz_ulong(data.count))
        if destLen < 64 { destLen = 64 }
        var out = Data(count: Int(destLen))
        let status: Int32 = out.withUnsafeMutableBytes { dstBuf in
            data.withUnsafeBytes { srcBuf in
                let dstPtr = dstBuf.bindMemory(to: UInt8.self).baseAddress
                let srcPtr = srcBuf.bindMemory(to: UInt8.self).baseAddress
                return mz_compress(dstPtr, &destLen, srcPtr, mz_ulong(data.count))
            }
        }
        if status == MZ_OK {
            out.count = Int(destLen)
            return out
        }
        return Data()
    }

    /// Decompresses RFC 1950 zlib data (or falls back to raw DEFLATE if no zlib CMF header).
    public static func decompress(_ data: Data) throws -> Data {
        guard data.count > 6 else {
            throw DecompressionError.dataTooShort
        }

        let cmf = data[data.startIndex]
        let isZlib = (cmf & 0x0F) == 8
        if isZlib {
            let flg = data[data.index(after: data.startIndex)]
            if (flg & 0x20) != 0 {
                throw DecompressionError.presetDictionaryUnsupported
            }
        }

        return try inflateStreaming(data, windowBits: isZlib ? MZ_DEFAULT_WINDOW_BITS : -MZ_DEFAULT_WINDOW_BITS)
    }

    private static func inflateStreaming(_ data: Data, windowBits: Int32) throws -> Data {
        var stream = mz_stream()
        memset(&stream, 0, MemoryLayout<mz_stream>.size)

        let initRC = mz_inflateInit2(&stream, windowBits)
        guard initRC == MZ_OK else {
            throw DecompressionError.decompressionFailed
        }
        defer { mz_inflateEnd(&stream) }

        return try data.withUnsafeBytes { srcRaw in
            guard let srcBase = srcRaw.bindMemory(to: UInt8.self).baseAddress else {
                throw DecompressionError.decompressionFailed
            }
            stream.next_in = srcBase
            stream.avail_in = UInt32(data.count)

            let chunkSize = max(min(max(data.count * 4, 65536), 4 * 1024 * 1024), 65536)
            var scratch = [UInt8](repeating: 0, count: chunkSize)
            var result = Data()
            result.reserveCapacity(min(data.count * 4, 16 * 1024 * 1024))

            while true {
                let status: Int32 = scratch.withUnsafeMutableBytes { dstRaw in
                    stream.next_out = dstRaw.bindMemory(to: UInt8.self).baseAddress
                    stream.avail_out = UInt32(chunkSize)
                    return mz_inflate(&stream, Int32(MZ_NO_FLUSH))
                }

                let produced = chunkSize - Int(stream.avail_out)
                if produced > 0 {
                    if result.count + produced > maxDecompressedSize {
                        throw DecompressionError.decompressedSizeExceeded
                    }
                    result.append(contentsOf: scratch[0..<produced])
                }

                if status == MZ_STREAM_END {
                    let ratio = result.count / max(data.count, 1)
                    if ratio > maxCompressionRatio {
                        throw DecompressionError.suspiciousCompressionRatio
                    }
                    return result
                }
                if status != MZ_OK {
                    throw DecompressionError.decompressionFailed
                }
                if produced == 0 && stream.avail_in == 0 {
                    throw DecompressionError.decompressionFailed
                }
            }
        }
    }
}
