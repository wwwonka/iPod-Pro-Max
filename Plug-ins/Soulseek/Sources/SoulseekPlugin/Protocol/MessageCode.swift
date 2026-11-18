// Adapted from seeleseek (https://github.com/bretth18/seeleseek), MIT License
// Copyright 2026 Brett Henderson / COMPUTER DATA / The Virtuous Corporation

import Foundation

public enum ServerMessageCode: UInt32, Sendable {
    case login = 1
    case setListenPort = 2
    case getPeerAddress = 3
    case connectToPeer = 18
    case fileSearch = 26
    case setOnlineStatus = 28
    case ping = 32
    case sharedFoldersFiles = 35
    case relogged = 41
    case placeInLineRequest = 59
    case placeInLineResponse = 60
    case cantConnectToPeer = 1001
}

public enum PeerMessageCode: UInt8, Sendable {
    case pierceFirewall = 0
    case peerInit = 1
    case sharesRequest = 4
    case sharesReply = 5
    case searchReply = 9
    case userInfoRequest = 15
    case userInfoReply = 16
    case transferRequest = 40
    case transferReply = 41
    case queueDownload = 43
    case placeInQueueReply = 44
    case uploadFailed = 46
    case uploadDenied = 50
    case placeInQueueRequest = 51
}

public enum FileTransferDirection: UInt8, Sendable {
    case download = 0
    case upload = 1
}

public enum UserStatus: UInt32, Sendable {
    case offline = 0
    case away = 1
    case online = 2
}

public enum LoginResult: Sendable, Equatable {
    case success(greeting: String, ip: String, hash: String?)
    case failure(reason: String)
}
