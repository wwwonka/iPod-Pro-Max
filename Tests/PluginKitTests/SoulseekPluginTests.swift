import CSockets
import Foundation
import PluginKit
@testable import SoulseekPlugin
import XCTest

final class SoulseekPluginTests: XCTestCase {
    // MARK: - SLSK-3: Protocol Framing & Roundtrips

    func testPortableMD5AndLoginFrame() throws {
        // RFC 1321 test vectors
        XCTAssertEqual(PortableMD5.hexDigest(""), "d41d8cd98f00b204e9800998ecf8427e")
        XCTAssertEqual(PortableMD5.hexDigest("abc"), "900150983cd24fb0d6963f7d28e17f72")
        XCTAssertEqual(PortableMD5.hexDigest("message digest"), "f96b697d7cb7938d525a2f31aaf161d0")

        let wire = MessageBuilder.loginMessage(username: "ipod-ab12cd", password: "secretPassword!")
        let parsed = MessageParser.parseFrame(from: wire)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.frame.code, ServerMessageCode.login.rawValue)

        let payload = try XCTUnwrap(parsed?.frame.payload)
        var offset = 0
        let (user, uLen) = try XCTUnwrap(payload.readString(at: offset))
        offset += uLen
        let (pass, pLen) = try XCTUnwrap(payload.readString(at: offset))
        offset += pLen
        let version = payload.readUInt32(at: offset)
        offset += 4
        let (hash, hLen) = try XCTUnwrap(payload.readString(at: offset))
        offset += hLen
        let minor = payload.readUInt32(at: offset)

        XCTAssertEqual(user, "ipod-ab12cd")
        XCTAssertEqual(pass, "secretPassword!")
        XCTAssertEqual(version, 169)
        XCTAssertEqual(hash, PortableMD5.hexDigest("ipod-ab12cdsecretPassword!"))
        XCTAssertEqual(minor, 3)
    }

    func testServerMessagesRoundTrip() throws {
        // SetWaitPort
        let waitWire = MessageBuilder.setListenPortMessage(port: 2234)
        let waitFrame = try XCTUnwrap(MessageParser.parseFrame(from: waitWire)?.frame)
        XCTAssertEqual(waitFrame.code, ServerMessageCode.setListenPort.rawValue)
        XCTAssertEqual(waitFrame.payload.readUInt32(at: 0), 2234)

        // FileSearch
        let searchWire = MessageBuilder.fileSearchMessage(token: 0xDEAD_BEEF, query: "olivia dean man i need")
        let searchFrame = try XCTUnwrap(MessageParser.parseFrame(from: searchWire)?.frame)
        XCTAssertEqual(searchFrame.code, ServerMessageCode.fileSearch.rawValue)
        XCTAssertEqual(searchFrame.payload.readUInt32(at: 0), 0xDEAD_BEEF)
        XCTAssertEqual(searchFrame.payload.readString(at: 4)?.string, "olivia dean man i need")

        // ConnectToPeer (server payload roundtrip)
        var ctpPayload = Data()
        ctpPayload.appendString("alice")
        ctpPayload.appendString("F")
        ctpPayload.appendUInt32(0x7F00_0001) // 127.0.0.1
        ctpPayload.appendUInt32(2234)
        ctpPayload.appendUInt32(99)
        ctpPayload.appendBool(true)
        ctpPayload.appendUInt32(ObfuscationType.rotated.rawValue)
        ctpPayload.appendUInt32(2235)
        let ctpInfo = try XCTUnwrap(MessageParser.parseConnectToPeer(ctpPayload))
        XCTAssertEqual(ctpInfo.username, "alice")
        XCTAssertEqual(ctpInfo.connectionType, "F")
        XCTAssertEqual(ctpInfo.ip, "127.0.0.1")
        XCTAssertEqual(ctpInfo.port, 2234)
        XCTAssertEqual(ctpInfo.token, 99)
        XCTAssertTrue(ctpInfo.privileged)
        XCTAssertEqual(ctpInfo.obfuscatedPort, 2235)

        // GetPeerAddress (with uint16 obfuscated port)
        var gpaPayload = Data()
        gpaPayload.appendString("bob")
        gpaPayload.appendUInt32(0xC0A8_0105) // 192.168.1.5
        gpaPayload.appendUInt32(2234)
        gpaPayload.appendUInt32(ObfuscationType.rotated.rawValue)
        gpaPayload.appendUInt16(2245)
        let gpa = try XCTUnwrap(MessageParser.parseGetPeerAddress(gpaPayload))
        XCTAssertEqual(gpa.username, "bob")
        XCTAssertEqual(gpa.ip, "192.168.1.5")
        XCTAssertEqual(gpa.port, 2234)
        XCTAssertEqual(gpa.obfuscatedPort, 2245)

        // SharedFoldersFiles & CantConnectToPeer
        let sffFrame = try XCTUnwrap(MessageParser.parseFrame(from: MessageBuilder.sharedFoldersFilesMessage(folders: 42, files: 1234))?.frame)
        XCTAssertEqual(sffFrame.code, ServerMessageCode.sharedFoldersFiles.rawValue)
        XCTAssertEqual(sffFrame.payload.readUInt32(at: 0), 42)
        XCTAssertEqual(sffFrame.payload.readUInt32(at: 4), 1234)

        let ccpFrame = try XCTUnwrap(MessageParser.parseFrame(from: MessageBuilder.cantConnectToPeerMessage(token: 777, username: "charlie"))?.frame)
        let ccp = try XCTUnwrap(MessageParser.parseCantConnectToPeer(ccpFrame.payload))
        XCTAssertEqual(ccp.token, 777)
        XCTAssertEqual(ccp.username, "charlie")
    }

    func testPeerInitPierceAndZlibSearchSharesMessages() throws {
        // 1-byte init messages
        let piWire = MessageBuilder.peerInitMessage(username: "ipod-123456", connectionType: "P", token: 55)
        let piFrame = try XCTUnwrap(MessageParser.parseInitOrPeerFrame(from: piWire, handshakeComplete: false))
        XCTAssertTrue(piFrame.isInit)
        XCTAssertEqual(piFrame.initCode, PeerMessageCode.peerInit.rawValue)
        let pi = try XCTUnwrap(MessageParser.parsePeerInit(piFrame.payload))
        XCTAssertEqual(pi.username, "ipod-123456")
        XCTAssertEqual(pi.connectionType, "P")
        XCTAssertEqual(pi.token, 55)

        let pfWire = MessageBuilder.pierceFirewallMessage(token: 8888)
        let pfFrame = try XCTUnwrap(MessageParser.parseInitOrPeerFrame(from: pfWire, handshakeComplete: false))
        XCTAssertTrue(pfFrame.isInit)
        XCTAssertEqual(pfFrame.initCode, PeerMessageCode.pierceFirewall.rawValue)
        XCTAssertEqual(MessageParser.parsePierceFirewall(pfFrame.payload), 8888)

        // FileSearchResponse (zlib compressed)
        let searchWire = MessageBuilder.searchReplyMessage(
            username: "losslesspeer",
            token: 4242,
            results: [
                (
                    filename: "@@Music\\Olivia Dean\\Man I Need.flac",
                    size: 28_000_000,
                    extension_: "flac",
                    attributes: [(0, 950), (1, 202), (4, 44100), (5, 16)]
                )
            ],
            hasFreeSlots: true,
            uploadSpeed: 1_500_000,
            queueLength: 0
        )
        let srFrame = try XCTUnwrap(MessageParser.parseInitOrPeerFrame(from: searchWire, handshakeComplete: true))
        XCTAssertEqual(srFrame.peerCode, UInt32(PeerMessageCode.searchReply.rawValue))
        let decompressedSearch = try ZlibCodec.decompress(srFrame.payload)
        let srInfo = try XCTUnwrap(MessageParser.parseSearchReply(decompressedSearch))
        XCTAssertEqual(srInfo.username, "losslesspeer")
        XCTAssertEqual(srInfo.token, 4242)
        XCTAssertEqual(srInfo.files.count, 1)
        XCTAssertEqual(srInfo.files[0].bitrate, 950)
        XCTAssertEqual(srInfo.files[0].duration, 202)
        XCTAssertEqual(srInfo.files[0].sampleRate, 44100)
        XCTAssertEqual(srInfo.files[0].bitDepth, 16)
        XCTAssertTrue(srInfo.freeSlots)

        // SharesReply (zlib compressed)
        let sharesWire = MessageBuilder.sharesReplyMessage(files: [
            (directory: "Music\\Olivia Dean", files: [
                (filename: "01 - Man I Need.mp3", size: 8_100_000, bitrate: 320, duration: 202),
            ])
        ])
        let shFrame = try XCTUnwrap(MessageParser.parseInitOrPeerFrame(from: sharesWire, handshakeComplete: true))
        let decompressedShares = try ZlibCodec.decompress(shFrame.payload)
        let shInfo = try XCTUnwrap(MessageParser.parseSharesReply(decompressedShares))
        XCTAssertEqual(shInfo.count, 1)
        XCTAssertEqual(shInfo[0].filename, "Music\\Olivia Dean\\01 - Man I Need.mp3")
        XCTAssertEqual(shInfo[0].bitrate, 320)

        // Transfer & queue control messages
        let quWire = MessageBuilder.queueDownloadMessage(filename: "Music\\Track.flac")
        let quFrame = try XCTUnwrap(MessageParser.parseFrame(from: quWire)?.frame)
        XCTAssertEqual(MessageParser.parseQueueDownload(quFrame.payload), "Music\\Track.flac")

        let pqWire = MessageBuilder.placeInQueueResponseMessage(filename: "Music\\Track.flac", place: 3)
        let pqFrame = try XCTUnwrap(MessageParser.parseFrame(from: pqWire)?.frame)
        let pq = try XCTUnwrap(MessageParser.parsePlaceInQueueResponse(pqFrame.payload))
        XCTAssertEqual(pq.filename, "Music\\Track.flac")
        XCTAssertEqual(pq.place, 3)

        let trReqWire = MessageBuilder.transferRequestMessage(direction: .upload, token: 77, filename: "Music\\Track.flac", fileSize: 12_345_678)
        let trReqFrame = try XCTUnwrap(MessageParser.parseFrame(from: trReqWire)?.frame)
        let trReq = try XCTUnwrap(MessageParser.parseTransferRequest(trReqFrame.payload))
        XCTAssertEqual(trReq.direction, .upload)
        XCTAssertEqual(trReq.token, 77)
        XCTAssertEqual(trReq.fileSize, 12_345_678)

        let trRepWire = MessageBuilder.transferReplyMessage(token: 77, allowed: true)
        let trRepFrame = try XCTUnwrap(MessageParser.parseFrame(from: trRepWire)?.frame)
        let trRep = try XCTUnwrap(MessageParser.parseTransferReply(trRepFrame.payload))
        XCTAssertTrue(trRep.allowed)
        XCTAssertEqual(trRep.token, 77)

        let udWire = MessageBuilder.uploadDeniedMessage(filename: "Music\\Track.flac", reason: "File not shared.")
        let udFrame = try XCTUnwrap(MessageParser.parseFrame(from: udWire)?.frame)
        let ud = try XCTUnwrap(MessageParser.parseUploadDenied(udFrame.payload))
        XCTAssertEqual(ud.reason, "File not shared.")

        let ufWire = MessageBuilder.uploadFailedMessage(filename: "Music\\Track.flac")
        let ufFrame = try XCTUnwrap(MessageParser.parseFrame(from: ufWire)?.frame)
        XCTAssertEqual(MessageParser.parseUploadFailed(ufFrame.payload), "Music\\Track.flac")
    }

    func testObfuscationCodecRoundTrip() throws {
        let payload = Data([0x09, 0x00, 0x00, 0x00, 0x41, 0x42, 0x43, 0x44, 0x45])
        let wire = ObfuscationCodec.encodeMessage(payload: payload, key: [0x11, 0x22, 0x33, 0x44])
        let decoded = try XCTUnwrap(ObfuscationCodec.decodeMessage(from: wire))
        XCTAssertEqual(decoded.bytesConsumed, wire.count)
        XCTAssertEqual(decoded.payload, payload)
    }

    func testSearchQueryWideningAndCandidateConversion() throws {
        let track = TrackRef(
            source: "spotify",
            sourceID: "1",
            title: "All Too Well (10 Minute Version) (feat. Someone)",
            artists: ["Taylor Swift, Bon Iver"],
            album: "Red (Taylor's Version)"
        )
        let queries = SearchQueryBuilder.queries(for: track)
        XCTAssertEqual(queries.count, 3)
        XCTAssertEqual(queries[0], "Taylor Swift All Too Well 10 Minute Version")
        XCTAssertTrue(queries[1].contains("Red"))
        XCTAssertEqual(queries[2], "All Too Well 10 Minute Version")

        // Locked/private file must be excluded (`SLSK-6`)
        let locked = MessageParser.SearchResultFile(
            filename: "Music\\Track.flac", size: 1000, extension: "flac", attributes: [], isPrivate: true
        )
        XCTAssertNil(SearchQueryBuilder.makeCandidate(username: "u", file: locked, freeSlots: true, uploadSpeed: 100, queueLength: 0))
    }

    func testCSocketsLoopbackTransport() async throws {
        let transport = CSocketTransport()
        let listener = try transport.listen(port: 0)
        XCTAssertGreaterThan(listener.port, 0)

        let serverTask = Task { () -> Data in
            let accepted = try await listener.accept(timeoutMs: 3000)
            let data = try await accepted.readExact(count: 5, timeoutMs: 3000)
            try await accepted.write(Data("world".utf8), timeoutMs: 3000)
            await accepted.close()
            return data
        }

        let client = try await transport.connect(host: "127.0.0.1", port: listener.port, timeoutMs: 3000)
        try await client.write(Data("hello".utf8), timeoutMs: 3000)
        let reply = try await client.readExact(count: 5, timeoutMs: 3000)
        await client.close()
        await listener.close()

        let receivedByServer = try await serverTask.value
        XCTAssertEqual(String(data: receivedByServer, encoding: .utf8), "hello")
        XCTAssertEqual(String(data: reply, encoding: .utf8), "world")
    }
}
