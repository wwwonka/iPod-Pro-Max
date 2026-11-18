// Adapted from seeleseek (https://github.com/bretth18/seeleseek), MIT License
// Copyright 2026 Brett Henderson / COMPUTER DATA / The Virtuous Corporation

import Foundation

public enum ObfuscationType: UInt32, Sendable {
    case none = 0
    case rotated = 1
}

public enum ObfuscationCodec {
    static let keyLength = 4

    public struct Stream: Sendable {
        private var key: UInt32
        private var byteIndex: Int = 0

        public init(key: [UInt8]) {
            precondition(key.count == ObfuscationCodec.keyLength, "obfuscation key must be 4 bytes")
            self.key = UInt32(key[0])
                | (UInt32(key[1]) << 8)
                | (UInt32(key[2]) << 16)
                | (UInt32(key[3]) << 24)
        }

        public mutating func transform(_ bytes: Data) -> Data {
            var out = Data(count: bytes.count)
            out.withUnsafeMutableBytes { outBuf in
                bytes.withUnsafeBytes { inBuf in
                    let outPtr = outBuf.bindMemory(to: UInt8.self)
                    let inPtr = inBuf.bindMemory(to: UInt8.self)
                    for i in 0..<bytes.count {
                        if byteIndex % ObfuscationCodec.keyLength == 0 {
                            key = (key &>> 31) | (key &<< 1)
                        }
                        let keyByte = UInt8((key >> (8 * UInt32(byteIndex % ObfuscationCodec.keyLength))) & 0xff)
                        outPtr[i] = inPtr[i] ^ keyByte
                        byteIndex += 1
                    }
                }
            }
            return out
        }
    }

    public static func generateKey() -> [UInt8] {
        (0..<keyLength).map { _ in UInt8.random(in: 1...255) }
    }

    public static func encodeMessage(payload: Data, key: [UInt8]? = nil) -> Data {
        let k = key ?? generateKey()
        var stream = Stream(key: k)

        var lenBytes = Data()
        lenBytes.appendUInt32(UInt32(payload.count))

        var wire = Data()
        wire.reserveCapacity(keyLength + 4 + payload.count)
        wire.append(contentsOf: k)
        wire.append(stream.transform(lenBytes))
        wire.append(stream.transform(payload))
        return wire
    }

    public static func decodeMessage(
        from buffer: Data,
        maxPayloadLength: Int = Int(MessageParser.maxMessageSize)
    ) throws -> (payload: Data, bytesConsumed: Int)? {
        guard buffer.count >= keyLength + 4 else { return nil }
        let base = buffer.startIndex
        let keyBytes = Array(buffer.prefix(keyLength))
        var stream = Stream(key: keyBytes)

        let encodedLen = buffer.subdata(in: (base + keyLength)..<(base + keyLength + 4))
        let lenBytes = stream.transform(encodedLen)
        let payloadLen = lenBytes.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))) }

        if payloadLen > maxPayloadLength {
            throw DecodingError.payloadTooLarge(advertised: payloadLen, max: maxPayloadLength)
        }

        let totalNeeded = keyLength + 4 + payloadLen
        guard buffer.count >= totalNeeded else { return nil }

        let encodedPayload = buffer.subdata(in: (base + keyLength + 4)..<(base + totalNeeded))
        let payload = stream.transform(encodedPayload)
        return (payload, totalNeeded)
    }

    public enum DecodingError: Error, Equatable {
        case payloadTooLarge(advertised: Int, max: Int)
    }
}
