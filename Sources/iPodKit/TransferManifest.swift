import Foundation

public struct TransferManifest: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var dbid: UInt64
        public var owner: String
        public var sourceID: UUID
        public var fingerprint: String
        public var references: [String]
        public var relativePath: String?
        public var sourceRootID: UUID?
        public init(dbid: UInt64, owner: String, sourceID: UUID, fingerprint: String, references: [String], relativePath: String? = nil, sourceRootID: UUID? = nil) {
            self.dbid = dbid; self.owner = owner; self.sourceID = sourceID
            self.fingerprint = fingerprint; self.references = references
            self.relativePath = relativePath; self.sourceRootID = sourceRootID
        }
    }
    public var version = 1
    public var tracks: [Entry] = []
    public init() {}
}

public enum FileFingerprint {
    /// Streaming content identity, not an audio similarity test. Never loads the whole song in RAM.
    public static func read(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var digest = SHA1(); var size = 0
        while let chunk = try file.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            if Task.isCancelled { throw CancellationError() }
            digest.update(data: chunk); size += chunk.count
        }
        return "sha1:\(size):" + digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
