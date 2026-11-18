// Adapted from seeleseek (https://github.com/bretth18/seeleseek), MIT License
// Copyright 2026 Brett Henderson / COMPUTER DATA / The Virtuous Corporation

import Foundation
import PluginKit

public struct SlskSearchQuery: Sendable, Equatable {
    public let token: UInt32
    public let query: String
}

public struct SlskSearchResult: Sendable, Equatable {
    public let username: String
    public let filename: String
    public let size: UInt64
    public let extensionName: String
    public let bitrateKbps: Int?
    public let durationSeconds: Int?
    public let sampleRateHz: Int?
    public let bitDepth: Int?
    public let freeSlots: Bool
    public let uploadSpeed: UInt32
    public let queueLength: UInt32
}

public struct SlskCandidateToken: Codable, Sendable {
    public let user: String
    public let file: String
    public let size: Int64
}

public struct SlskUser: Sendable, Equatable {
    public let username: String
    public let status: UserStatus
}

public struct SlskSharedFile: Sendable, Equatable {
    public let virtualDirectory: String
    public let filename: String
    public let fullVirtualPath: String
    public let realPath: String
    public let size: UInt64
    public let bitrate: UInt32?
    public let duration: UInt32?
}

public struct SlskTransfer: Sendable, Equatable {
    public let id: String
    public let username: String
    public let filename: String
    public let size: UInt64
    public let token: UInt32
}
