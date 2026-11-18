// Adapted from seeleseek (https://github.com/bretth18/seeleseek), MIT License
// Copyright 2026 Brett Henderson / COMPUTER DATA / The Virtuous Corporation

import Foundation

public enum MessageBuilder {
    // MARK: - Server Messages

    public static func loginMessage(username: String, password: String) -> Data {
        serverMessage(.login) {
            $0.appendString(username)
            $0.appendString(password)
            $0.appendUInt32(169)
            $0.appendString(PortableMD5.hexDigest(username + password))
            $0.appendUInt32(3)
        }
    }

    public static func setListenPortMessage(port: UInt32, obfuscatedPort: UInt32 = 0) -> Data {
        serverMessage(.setListenPort) {
            $0.appendUInt32(port)
            if obfuscatedPort > 0 {
                $0.appendUInt32(ObfuscationType.rotated.rawValue)
                $0.appendUInt32(obfuscatedPort)
            }
        }
    }

    public static func setOnlineStatusMessage(status: UserStatus) -> Data {
        serverMessage(.setOnlineStatus) { $0.appendUInt32(status.rawValue) }
    }

    public static func sharedFoldersFilesMessage(folders: UInt32, files: UInt32) -> Data {
        serverMessage(.sharedFoldersFiles) {
            $0.appendUInt32(folders)
            $0.appendUInt32(files)
        }
    }

    public static func pingMessage() -> Data {
        serverMessage(.ping)
    }

    public static func fileSearchMessage(token: UInt32, query: String) -> Data {
        serverMessage(.fileSearch) {
            $0.appendUInt32(token)
            $0.appendString(query)
        }
    }

    public static func getPeerAddressMessage(username: String) -> Data {
        serverMessage(.getPeerAddress) { $0.appendString(username) }
    }

    public static func connectToPeerMessage(token: UInt32, username: String, connectionType: String) -> Data {
        serverMessage(.connectToPeer) {
            $0.appendUInt32(token)
            $0.appendString(username)
            $0.appendString(connectionType)
        }
    }

    public static func cantConnectToPeerMessage(token: UInt32, username: String) -> Data {
        serverMessage(.cantConnectToPeer) {
            $0.appendUInt32(token)
            $0.appendString(username)
        }
    }

    // MARK: - Peer Messages

    public static func peerInitMessage(username: String, connectionType: String, token: UInt32) -> Data {
        var payload = Data()
        payload.appendUInt8(PeerMessageCode.peerInit.rawValue)
        payload.appendString(username)
        payload.appendString(connectionType)
        payload.appendUInt32(token)
        return wrapMessage(payload)
    }

    public static func pierceFirewallMessage(token: UInt32) -> Data {
        var payload = Data()
        payload.appendUInt8(PeerMessageCode.pierceFirewall.rawValue)
        payload.appendUInt32(token)
        return wrapMessage(payload)
    }

    public static func sharesRequestMessage() -> Data {
        peerMessage(.sharesRequest)
    }

    public static func sharesReplyMessage(
        files: [(directory: String, files: [(filename: String, size: UInt64, bitrate: UInt32?, duration: UInt32?)])],
        privateFiles: [(directory: String, files: [(filename: String, size: UInt64, bitrate: UInt32?, duration: UInt32?)])] = []
    ) -> Data {
        var uncompressedPayload = Data()

        func appendDirectories(_ dirs: [(directory: String, files: [(filename: String, size: UInt64, bitrate: UInt32?, duration: UInt32?)])]) {
            uncompressedPayload.appendUInt32(UInt32(dirs.count))
            for dir in dirs {
                uncompressedPayload.appendString(dir.directory)
                uncompressedPayload.appendUInt32(UInt32(dir.files.count))
                for file in dir.files {
                    uncompressedPayload.appendUInt8(1)
                    uncompressedPayload.appendString(file.filename)
                    uncompressedPayload.appendUInt64(file.size)
                    let dotIdx = file.filename.lastIndex(of: ".")
                    let ext = dotIdx.map { String(file.filename[file.filename.index(after: $0)...]) } ?? ""
                    uncompressedPayload.appendString(ext)

                    var attrs: [(UInt32, UInt32)] = []
                    if let bitrate = file.bitrate { attrs.append((0, bitrate)) }
                    if let duration = file.duration { attrs.append((1, duration)) }
                    uncompressedPayload.appendUInt32(UInt32(attrs.count))
                    for attr in attrs {
                        uncompressedPayload.appendUInt32(attr.0)
                        uncompressedPayload.appendUInt32(attr.1)
                    }
                }
            }
        }

        appendDirectories(files)
        uncompressedPayload.appendUInt32(0)
        appendDirectories(privateFiles)

        let compressed = ZlibCodec.compress(uncompressedPayload)
        return peerMessage(.sharesReply) { $0.append(compressed) }
    }

    public static func userInfoResponseMessage(
        description: String,
        totalUploads: UInt32,
        queueSize: UInt32,
        hasFreeSlots: Bool
    ) -> Data {
        peerMessage(.userInfoReply) {
            $0.appendString(description)
            $0.appendUInt8(0)
            $0.appendUInt32(totalUploads)
            $0.appendUInt32(queueSize)
            $0.appendUInt8(hasFreeSlots ? 1 : 0)
        }
    }

    public static func searchReplyMessage(
        username: String,
        token: UInt32,
        results: [(filename: String, size: UInt64, extension_: String, attributes: [(UInt32, UInt32)])],
        hasFreeSlots: Bool = true,
        uploadSpeed: UInt32 = 0,
        queueLength: UInt32 = 0
    ) -> Data {
        var uncompressedPayload = Data()
        uncompressedPayload.appendString(username)
        uncompressedPayload.appendUInt32(token)
        uncompressedPayload.appendUInt32(UInt32(results.count))
        for result in results {
            uncompressedPayload.appendUInt8(1)
            uncompressedPayload.appendString(result.filename)
            uncompressedPayload.appendUInt64(result.size)
            uncompressedPayload.appendString(result.extension_)
            uncompressedPayload.appendUInt32(UInt32(result.attributes.count))
            for attr in result.attributes {
                uncompressedPayload.appendUInt32(attr.0)
                uncompressedPayload.appendUInt32(attr.1)
            }
        }
        uncompressedPayload.appendBool(hasFreeSlots)
        uncompressedPayload.appendUInt32(uploadSpeed)
        uncompressedPayload.appendUInt32(queueLength)
        uncompressedPayload.appendUInt32(0)
        uncompressedPayload.appendUInt32(0)

        let compressed = ZlibCodec.compress(uncompressedPayload)
        return peerMessage(.searchReply) { $0.append(compressed) }
    }

    public static func queueDownloadMessage(filename: String) -> Data {
        peerMessage(.queueDownload) { $0.appendString(filename) }
    }

    public static func transferRequestMessage(
        direction: FileTransferDirection,
        token: UInt32,
        filename: String,
        fileSize: UInt64? = nil
    ) -> Data {
        peerMessage(.transferRequest) {
            $0.appendUInt32(UInt32(direction.rawValue))
            $0.appendUInt32(token)
            $0.appendString(filename)
            if direction == .upload {
                $0.appendUInt64(fileSize ?? 0)
            }
        }
    }

    public static func transferReplyMessage(
        token: UInt32,
        allowed: Bool,
        fileSize: UInt64? = nil,
        reason: String? = nil
    ) -> Data {
        peerMessage(.transferReply) {
            $0.appendUInt32(token)
            $0.appendBool(allowed)
            if allowed, let fileSize {
                $0.appendUInt64(fileSize)
            } else if !allowed, let reason {
                $0.appendString(reason)
            }
        }
    }

    public static func placeInQueueRequestMessage(filename: String) -> Data {
        peerMessage(.placeInQueueRequest) { $0.appendString(filename) }
    }

    public static func placeInQueueResponseMessage(filename: String, place: UInt32) -> Data {
        peerMessage(.placeInQueueReply) {
            $0.appendString(filename)
            $0.appendUInt32(place)
        }
    }

    public static func uploadFailedMessage(filename: String) -> Data {
        peerMessage(.uploadFailed) { $0.appendString(filename) }
    }

    public static func uploadDeniedMessage(filename: String, reason: String) -> Data {
        peerMessage(.uploadDenied) {
            $0.appendString(filename)
            $0.appendString(reason)
        }
    }

    // MARK: - Framing

    private static func serverMessage(_ code: ServerMessageCode, _ fields: (inout Data) -> Void = { _ in }) -> Data {
        framed(code.rawValue, fields)
    }

    private static func peerMessage(_ code: PeerMessageCode, _ fields: (inout Data) -> Void = { _ in }) -> Data {
        precondition(code != .peerInit && code != .pierceFirewall)
        return framed(UInt32(code.rawValue), fields)
    }

    private static func framed(_ code: UInt32, _ fields: (inout Data) -> Void) -> Data {
        var payload = Data()
        payload.appendUInt32(code)
        fields(&payload)
        return wrapMessage(payload)
    }

    public static func wrapMessage(_ payload: Data) -> Data {
        var message = Data()
        message.appendUInt32(UInt32(payload.count))
        message.append(payload)
        return message
    }
}
