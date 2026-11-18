// Adapted from seeleseek (https://github.com/bretth18/seeleseek), MIT License
// Copyright 2026 Brett Henderson / COMPUTER DATA / The Virtuous Corporation

import Foundation

public extension Data {
    func readUInt8(at offset: Int) -> UInt8? {
        guard offset >= 0, offset < count else { return nil }
        return self[startIndex.advanced(by: offset)]
    }

    func readUInt16(at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= count else { return nil }
        return withUnsafeBytes { bytes in
            UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
        }
    }

    func readUInt32(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        return withUnsafeBytes { bytes in
            UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
        }
    }

    func readUInt64(at offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= count else { return nil }
        return withUnsafeBytes { bytes in
            UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
        }
    }

    func readInt32(at offset: Int) -> Int32? {
        readUInt32(at: offset).map { Int32(bitPattern: $0) }
    }

    static let maxStringLength: UInt32 = 1_000_000

    func readString(at offset: Int) -> (string: String, bytesConsumed: Int)? {
        guard let length = readUInt32(at: offset) else { return nil }
        let len = Int(length)
        guard len <= Self.maxStringLength, offset + 4 + len <= count else { return nil }

        let start = startIndex.advanced(by: offset + 4)
        let end = start.advanced(by: len)
        let stringData = Data(self[start..<end])

        if let utf8 = String(data: stringData, encoding: .utf8) {
            return (utf8, 4 + len)
        }
        if let cp1252 = String(data: stringData, encoding: .windowsCP1252) {
            return (cp1252, 4 + len)
        }
        if let latin1 = String(data: stringData, encoding: .isoLatin1) {
            return (latin1, 4 + len)
        }
        return nil
    }

    func readBool(at offset: Int) -> Bool? {
        readUInt8(at: offset).map { $0 != 0 }
    }

    func safeSubdata(in range: Range<Int>) -> Data? {
        guard range.lowerBound >= 0,
              range.upperBound <= count,
              range.lowerBound <= range.upperBound else {
            return nil
        }
        let start = startIndex.advanced(by: range.lowerBound)
        let end = startIndex.advanced(by: range.upperBound)
        return Data(self[start..<end])
    }

    mutating func appendUInt8(_ value: UInt8) {
        append(value)
    }

    mutating func appendUInt16(_ value: UInt16) {
        var val = value.littleEndian
        Swift.withUnsafeBytes(of: &val) { append(contentsOf: $0) }
    }

    mutating func appendUInt32(_ value: UInt32) {
        var val = value.littleEndian
        Swift.withUnsafeBytes(of: &val) { append(contentsOf: $0) }
    }

    mutating func appendUInt64(_ value: UInt64) {
        var val = value.littleEndian
        Swift.withUnsafeBytes(of: &val) { append(contentsOf: $0) }
    }

    mutating func appendInt32(_ value: Int32) {
        appendUInt32(UInt32(bitPattern: value))
    }

    mutating func appendString(_ string: String) {
        let data = Data(string.utf8)
        appendUInt32(UInt32(data.count))
        append(data)
    }

    mutating func appendBool(_ value: Bool) {
        append(value ? 1 : 0)
    }
}
