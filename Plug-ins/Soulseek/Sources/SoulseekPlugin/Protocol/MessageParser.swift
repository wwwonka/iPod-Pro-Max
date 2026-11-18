// Adapted from seeleseek (https://github.com/bretth18/seeleseek), MIT License
// Copyright 2026 Brett Henderson / COMPUTER DATA / The Virtuous Corporation

import Foundation

public enum MessageParser {
    public static let maxItemCount: UInt32 = 100_000
    public static let maxAttributeCount: UInt32 = 100
    public static let maxMessageSize: UInt32 = 100_000_000

    private static func plausibleItemCount(
        _ count: UInt32, at offset: Int, in data: Data, minBytesPerItem: Int = 8
    ) -> Bool {
        count <= UInt32(clamping: max(0, data.count - offset) / minBytesPerItem)
    }

    public struct ParsedFrame: Sendable, Equatable {
        public let code: UInt32
        public let payload: Data
    }

    public static func parseFrame(from data: Data) -> (frame: ParsedFrame, consumed: Int)? {
        guard data.count >= 8 else { return nil }
        guard let length = data.readUInt32(at: 0) else { return nil }
        guard length <= maxMessageSize, length >= 4 else { return nil }

        let totalLength = 4 + Int(length)
        guard data.count >= totalLength else { return nil }
        guard let code = data.readUInt32(at: 4) else { return nil }
        guard let payload = data.safeSubdata(in: 8..<totalLength) else { return nil }
        return (ParsedFrame(code: code, payload: payload), totalLength)
    }

    public static func parseInitOrPeerFrame(
        from data: Data,
        handshakeComplete: Bool
    ) -> (isInit: Bool, initCode: UInt8, peerCode: UInt32, payload: Data, consumed: Int)? {
        guard data.count >= 5 else { return nil }
        guard let length = data.readUInt32(at: 0) else { return nil }
        guard length <= maxMessageSize else { return nil }
        let totalLength = 4 + Int(length)
        guard data.count >= totalLength else { return nil }
        guard let firstByte = data.readUInt8(at: 4) else { return nil }

        if !handshakeComplete && (firstByte == PeerMessageCode.pierceFirewall.rawValue || firstByte == PeerMessageCode.peerInit.rawValue) {
            let payload = data.safeSubdata(in: 5..<totalLength) ?? Data()
            return (true, firstByte, UInt32(firstByte), payload, totalLength)
        }

        guard length >= 4, data.count >= 8, let code = data.readUInt32(at: 4) else {
            return nil
        }
        let payload = data.safeSubdata(in: 8..<totalLength) ?? Data()
        return (false, 0, code, payload, totalLength)
    }

    // MARK: - Server Messages

    public static func parseLoginResponse(_ payload: Data) -> LoginResult? {
        var offset = 0
        guard let success = payload.readBool(at: offset) else { return nil }
        offset += 1
        if success {
            guard let (greeting, greetingLen) = payload.readString(at: offset) else { return nil }
            offset += greetingLen
            guard let ip = payload.readUInt32(at: offset) else { return nil }
            offset += 4
            let ipString = formatLittleEndianIPv4(ip)
            let hashString = payload.readString(at: offset)?.string
            return .success(greeting: greeting, ip: ipString, hash: hashString)
        } else {
            let reason = payload.readString(at: offset)?.string ?? "Unknown error"
            return .failure(reason: reason)
        }
    }

    public struct PeerAddressInfo: Sendable, Equatable {
        public let username: String
        public let ip: String
        public let port: UInt32
        public let obfuscationType: UInt32
        public let obfuscatedPort: UInt16
    }

    public static func parseGetPeerAddress(_ payload: Data) -> PeerAddressInfo? {
        var offset = 0
        guard let (username, uLen) = payload.readString(at: offset) else { return nil }
        offset += uLen
        guard let ip = payload.readUInt32(at: offset) else { return nil }
        offset += 4
        guard let port = payload.readUInt32(at: offset) else { return nil }
        offset += 4

        var obfType: UInt32 = 0
        var obfPort: UInt16 = 0
        if let t = payload.readUInt32(at: offset), t == ObfuscationType.rotated.rawValue,
           let p = payload.readUInt16(at: offset + 4) {
            obfType = t
            obfPort = p
        }
        return PeerAddressInfo(
            username: username,
            ip: formatLittleEndianIPv4(ip),
            port: port,
            obfuscationType: obfType,
            obfuscatedPort: obfPort
        )
    }

    public struct PeerInfo: Sendable, Equatable {
        public let username: String
        public let connectionType: String
        public let ip: String
        public let port: UInt32
        public let token: UInt32
        public let privileged: Bool
        public let obfuscationType: UInt32
        public let obfuscatedPort: UInt32
    }

    public static func parseConnectToPeer(_ payload: Data) -> PeerInfo? {
        var offset = 0
        guard let (username, uLen) = payload.readString(at: offset) else { return nil }
        offset += uLen
        guard let (connectionType, tLen) = payload.readString(at: offset) else { return nil }
        offset += tLen
        guard let ip = payload.readUInt32(at: offset) else { return nil }
        offset += 4
        guard let port = payload.readUInt32(at: offset) else { return nil }
        offset += 4
        guard let token = payload.readUInt32(at: offset) else { return nil }
        offset += 4
        let privileged = payload.readBool(at: offset) ?? false
        offset += 1
        let obfType = payload.readUInt32(at: offset) ?? 0
        offset += 4
        let obfPort = payload.readUInt32(at: offset) ?? 0

        return PeerInfo(
            username: username,
            connectionType: connectionType,
            ip: formatLittleEndianIPv4(ip),
            port: port,
            token: token,
            privileged: privileged,
            obfuscationType: obfType,
            obfuscatedPort: obfPort
        )
    }

    public static func parseCantConnectToPeer(_ payload: Data) -> (token: UInt32, username: String?)? {
        guard let token = payload.readUInt32(at: 0) else { return nil }
        let username = payload.readString(at: 4)?.string
        return (token, username)
    }

    // MARK: - Peer Init & Messages

    public struct PeerInitInfo: Sendable, Equatable {
        public let username: String
        public let connectionType: String
        public let token: UInt32
    }

    public static func parsePeerInit(_ payload: Data) -> PeerInitInfo? {
        var offset = 0
        guard let (username, uLen) = payload.readString(at: offset) else { return nil }
        offset += uLen
        guard let (connType, tLen) = payload.readString(at: offset) else { return nil }
        offset += tLen
        let token = payload.readUInt32(at: offset) ?? 0
        return PeerInitInfo(username: username, connectionType: connType, token: token)
    }

    public static func parsePierceFirewall(_ payload: Data) -> UInt32? {
        payload.readUInt32(at: 0)
    }

    public struct FileAttribute: Sendable, Equatable {
        public let type: UInt32
        public let value: UInt32
    }

    public struct SearchResultFile: Sendable, Equatable {
        public let filename: String
        public let size: UInt64
        public let `extension`: String
        public let attributes: [FileAttribute]
        public let isPrivate: Bool

        public var bitrate: UInt32? { attributes.first(where: { $0.type == 0 })?.value }
        public var duration: UInt32? { attributes.first(where: { $0.type == 1 })?.value }
        public var isVBR: Bool? { attributes.first(where: { $0.type == 2 }).map { $0.value == 1 } }
        public var sampleRate: UInt32? { attributes.first(where: { $0.type == 4 })?.value }
        public var bitDepth: UInt32? { attributes.first(where: { $0.type == 5 })?.value }
    }

    public struct SearchReplyInfo: Sendable, Equatable {
        public let username: String
        public let token: UInt32
        public let files: [SearchResultFile]
        public let freeSlots: Bool
        public let uploadSpeed: UInt32
        public let queueLength: UInt32
    }

    private static func readFileAttributes(_ payload: Data, offset: inout Int) -> [FileAttribute]? {
        guard let attrCount = payload.readUInt32(at: offset), attrCount <= maxAttributeCount else { return nil }
        offset += 4
        var attrs: [FileAttribute] = []
        attrs.reserveCapacity(Int(attrCount))
        for _ in 0..<attrCount {
            guard let t = payload.readUInt32(at: offset) else { return nil }
            offset += 4
            guard let v = payload.readUInt32(at: offset) else { return nil }
            offset += 4
            attrs.append(FileAttribute(type: t, value: v))
        }
        return attrs
    }

    private static func readSearchFileEntry(_ payload: Data, offset: inout Int, isPrivate: Bool) -> SearchResultFile? {
        guard payload.readUInt8(at: offset) != nil else { return nil }
        offset += 1
        guard let (filename, fLen) = payload.readString(at: offset) else { return nil }
        offset += fLen
        guard let size = payload.readUInt64(at: offset) else { return nil }
        offset += 8
        guard let (ext, eLen) = payload.readString(at: offset) else { return nil }
        offset += eLen
        guard let attrs = readFileAttributes(payload, offset: &offset) else { return nil }
        return SearchResultFile(filename: filename, size: size, extension: ext, attributes: attrs, isPrivate: isPrivate)
    }

    public static func parseSearchReply(_ payload: Data) -> SearchReplyInfo? {
        var offset = 0
        guard let (username, uLen) = payload.readString(at: offset) else { return nil }
        offset += uLen
        guard let token = payload.readUInt32(at: offset) else { return nil }
        offset += 4
        guard let fileCount = payload.readUInt32(at: offset), fileCount <= maxItemCount else { return nil }
        offset += 4

        var files: [SearchResultFile] = []
        files.reserveCapacity(min(Int(fileCount), 2048))
        for _ in 0..<fileCount {
            guard let file = readSearchFileEntry(payload, offset: &offset, isPrivate: false) else { return nil }
            files.append(file)
        }

        guard let freeSlots = payload.readBool(at: offset) else { return nil }
        offset += 1
        guard let uploadSpeed = payload.readUInt32(at: offset) else { return nil }
        offset += 4
        guard let queueLength = payload.readUInt32(at: offset) else { return nil }
        offset += 4

        // Skip unknown uint32 + optional private section (`SLSK-6` excludes locked folders)
        if offset + 4 <= payload.count {
            offset += 4
            if let privCount = payload.readUInt32(at: offset),
               privCount > 0, privCount <= maxItemCount {
                offset += 4
                for _ in 0..<privCount {
                    guard let privFile = readSearchFileEntry(payload, offset: &offset, isPrivate: true) else { break }
                    files.append(privFile)
                }
            }
        }

        return SearchReplyInfo(
            username: username,
            token: token,
            files: files,
            freeSlots: freeSlots,
            uploadSpeed: uploadSpeed,
            queueLength: queueLength
        )
    }

    public struct ShareFileInfo: Sendable, Equatable {
        public let filename: String
        public let size: UInt64
        public let bitrate: UInt32?
        public let duration: UInt32?
        public let isPrivate: Bool
    }

    private static func readShareFileEntry(_ payload: Data, offset: inout Int, dirName: String?, isPrivate: Bool) -> ShareFileInfo? {
        guard payload.readUInt8(at: offset) != nil else { return nil }
        offset += 1
        guard let (filename, fLen) = payload.readString(at: offset) else { return nil }
        offset += fLen
        guard let size = payload.readUInt64(at: offset) else { return nil }
        offset += 8
        guard let (_, eLen) = payload.readString(at: offset) else { return nil }
        offset += eLen
        guard let attrs = readFileAttributes(payload, offset: &offset) else { return nil }

        let bitrate = attrs.first(where: { $0.type == 0 })?.value
        let duration = attrs.first(where: { $0.type == 1 })?.value
        let full = dirName.map { "\($0)\\\(filename)" } ?? filename
        return ShareFileInfo(filename: full, size: size, bitrate: bitrate, duration: duration, isPrivate: isPrivate)
    }

    public static func parseSharesReply(_ decompressed: Data) -> [ShareFileInfo]? {
        var offset = 0
        guard let dirCount = decompressed.readUInt32(at: offset),
              plausibleItemCount(dirCount, at: offset + 4, in: decompressed) else { return nil }
        offset += 4

        var files: [ShareFileInfo] = []
        for _ in 0..<dirCount {
            guard let (dirName, dLen) = decompressed.readString(at: offset) else { return nil }
            offset += dLen
            guard let fileCount = decompressed.readUInt32(at: offset),
                  plausibleItemCount(fileCount, at: offset + 4, in: decompressed) else { return nil }
            offset += 4
            for _ in 0..<fileCount {
                guard let entry = readShareFileEntry(decompressed, offset: &offset, dirName: dirName, isPrivate: false) else { return nil }
                files.append(entry)
            }
        }
        return files
    }

    public struct TransferRequestInfo: Sendable, Equatable {
        public let direction: FileTransferDirection
        public let token: UInt32
        public let filename: String
        public let fileSize: UInt64?
    }

    public static func parseTransferRequest(_ payload: Data) -> TransferRequestInfo? {
        var offset = 0
        guard let directionRaw = payload.readUInt32(at: offset),
              let directionByte = UInt8(exactly: directionRaw),
              let direction = FileTransferDirection(rawValue: directionByte) else {
            return nil
        }
        offset += 4
        guard let token = payload.readUInt32(at: offset) else { return nil }
        offset += 4
        guard let (filename, fLen) = payload.readString(at: offset) else { return nil }
        offset += fLen

        var fileSize: UInt64?
        if direction == .upload {
            guard let size = payload.readUInt64(at: offset) else { return nil }
            fileSize = size
        }
        return TransferRequestInfo(direction: direction, token: token, filename: filename, fileSize: fileSize)
    }

    public struct TransferReplyInfo: Sendable, Equatable {
        public let token: UInt32
        public let allowed: Bool
        public let fileSize: UInt64?
        public let reason: String?
    }

    public static func parseTransferReply(_ payload: Data) -> TransferReplyInfo? {
        var offset = 0
        guard let token = payload.readUInt32(at: offset) else { return nil }
        offset += 4
        guard let allowed = payload.readBool(at: offset) else { return nil }
        offset += 1

        var fileSize: UInt64?
        var reason: String?
        if allowed {
            let rem = payload.count - offset
            if rem >= 8 {
                fileSize = payload.readUInt64(at: offset)
            } else if rem > 0 {
                return nil
            }
        } else {
            reason = payload.readString(at: offset)?.string
        }
        return TransferReplyInfo(token: token, allowed: allowed, fileSize: fileSize, reason: reason)
    }

    public static func parseQueueDownload(_ payload: Data) -> String? {
        payload.readString(at: 0)?.string
    }

    public static func parsePlaceInQueueResponse(_ payload: Data) -> (filename: String, place: UInt32)? {
        guard let (filename, len) = payload.readString(at: 0),
              let place = payload.readUInt32(at: len) else {
            return nil
        }
        return (filename, place)
    }

    public static func parsePlaceInQueueRequest(_ payload: Data) -> String? {
        payload.readString(at: 0)?.string
    }

    public static func parseUploadFailed(_ payload: Data) -> String? {
        payload.readString(at: 0)?.string
    }

    public static func parseUploadDenied(_ payload: Data) -> (filename: String, reason: String)? {
        guard let (filename, len) = payload.readString(at: 0) else { return nil }
        let reason = payload.readString(at: len)?.string ?? "Denied"
        return (filename, reason)
    }

    private static func formatLittleEndianIPv4(_ ip: UInt32) -> String {
        let b1 = (ip >> 24) & 0xFF
        let b2 = (ip >> 16) & 0xFF
        let b3 = (ip >> 8) & 0xFF
        let b4 = ip & 0xFF
        return "\(b1).\(b2).\(b3).\(b4)"
    }
}
