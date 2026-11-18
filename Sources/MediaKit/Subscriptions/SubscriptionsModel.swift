import Foundation
import iPodKit
import PluginKit

/// Persisted state of a subscribed track inside `subscriptions.json`.
public enum PersistedSubscribedTrackStatus: String, Codable, Hashable, Sendable {
    case pending
    case available
    case notFound
    case failed
}

/// Persisted record for a track inside a subscribed playlist (`SUB-7`).
public struct SubscribedTrackEntry: Codable, Hashable, Sendable {
    public var key: String
    public var trackRef: TrackRef
    public var position: Int
    public var libraryTrackID: UUID?
    public var status: PersistedSubscribedTrackStatus
    public var isYouTubeFallback: Bool
    public var lastFailureReason: String?
    public var lastFailureAt: Date?
    public var failedAttempts: Int

    public init(
        key: String,
        trackRef: TrackRef,
        position: Int,
        libraryTrackID: UUID? = nil,
        status: PersistedSubscribedTrackStatus = .pending,
        isYouTubeFallback: Bool = false,
        lastFailureReason: String? = nil,
        lastFailureAt: Date? = nil,
        failedAttempts: Int = 0
    ) {
        self.key = key
        self.trackRef = trackRef
        self.position = position
        self.libraryTrackID = libraryTrackID
        self.status = status
        self.isYouTubeFallback = isYouTubeFallback
        self.lastFailureReason = lastFailureReason
        self.lastFailureAt = lastFailureAt
        self.failedAttempts = failedAttempts
    }

    public static func makeKey(for ref: TrackRef, position: Int) -> String {
        if !ref.sourceID.isEmpty {
            return "\(ref.source):\(ref.sourceID)"
        }
        let artist = ref.artists.first ?? ""
        return "\(ref.source):\(position):\(artist):\(ref.title)"
    }
}

/// Live UI status of a subscribed track (`SUB-6`).
public enum SubscribedTrackState: Equatable, Sendable {
    case available(isYouTubeFallback: Bool)
    case waiting
    case searching(resolver: String)
    case downloading(resolver: String, progress: Double)
    case notFound
    case failed(reason: String)
    case noDownloadSource
}

/// Persisted subscription metadata for a playlist (`SUB-7`).
public struct SubscriptionEntry: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var playlistID: UUID
    public var sourcePluginID: String
    public var sourceName: String
    public var sourceURL: String
    public var sourcePlaylistID: String
    public var title: String
    public var owner: String?
    public var artworkURL: URL?
    public var artworkKey: String?
    public var revision: String?
    public var lastSyncedAt: Date?
    public var lastError: String?
    public var dateAdded: Date
    public var tracks: [SubscribedTrackEntry]

    public init(
        id: UUID = UUID(),
        playlistID: UUID = UUID(),
        sourcePluginID: String,
        sourceName: String,
        sourceURL: String,
        sourcePlaylistID: String = "",
        title: String,
        owner: String? = nil,
        artworkURL: URL? = nil,
        artworkKey: String? = nil,
        revision: String? = nil,
        lastSyncedAt: Date? = nil,
        lastError: String? = nil,
        dateAdded: Date = Date(),
        tracks: [SubscribedTrackEntry] = []
    ) {
        self.id = id
        self.playlistID = playlistID
        self.sourcePluginID = sourcePluginID
        self.sourceName = sourceName
        self.sourceURL = sourceURL
        self.sourcePlaylistID = sourcePlaylistID
        self.title = title
        self.owner = owner
        self.artworkURL = artworkURL
        self.artworkKey = artworkKey
        self.revision = revision
        self.lastSyncedAt = lastSyncedAt
        self.lastError = lastError
        self.dateAdded = dateAdded
        self.tracks = tracks
    }
}

/// Root document stored in `Persistent Data/subscriptions.json` (`SUB-7`).
public struct SubscriptionsDocument: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var subscriptions: [SubscriptionEntry] = []

    public init(version: Int = 1, subscriptions: [SubscriptionEntry] = []) {
        self.version = version
        self.subscriptions = subscriptions
    }
}

/// Outcome of loading `Persistent Data/subscriptions.json` with `.bak` recovery.
public struct SubscriptionsLoadResult: Sendable {
    public var document: SubscriptionsDocument
    public var recoveredFromBackup: Bool
    public var bothCorrupted: Bool

    public init(
        document: SubscriptionsDocument,
        recoveredFromBackup: Bool = false,
        bothCorrupted: Bool = false
    ) {
        self.document = document
        self.recoveredFromBackup = recoveredFromBackup
        self.bothCorrupted = bothCorrupted
    }
}

/// Reads and writes `Persistent Data/subscriptions.json` safely with `.bak` fallback (`SUB-7`).
public enum SubscriptionsStore {
    public static let fileName = "subscriptions.json"

    public static func load(from folder: DeviceDataFolder) -> SubscriptionsLoadResult {
        do {
            if let doc = try folder.readChecked(SubscriptionsDocument.self, from: fileName) {
                return SubscriptionsLoadResult(document: doc)
            }
            return SubscriptionsLoadResult(document: SubscriptionsDocument())
        } catch {
            // DeviceDataFolder.readChecked already falls back to .bak if the primary is corrupt;
            // arriving here means both primary and .bak failed (or didn't exist cleanly).
            let primaryExists = FileManager.default.fileExists(atPath: folder.url.appendingPathComponent(fileName).path)
            let backupExists = FileManager.default.fileExists(atPath: folder.url.appendingPathComponent(fileName + ".bak").path)
            return SubscriptionsLoadResult(
                document: SubscriptionsDocument(),
                recoveredFromBackup: false,
                bothCorrupted: primaryExists || backupExists
            )
        }
    }

    public static func save(_ document: SubscriptionsDocument, to folder: DeviceDataFolder) throws {
        try folder.write(document, to: fileName)
    }

    /// Removes orphaned `.part` files inside `downloadFolder` left behind by interrupted downloads (`SUB-7`).
    public static func cleanupOrphanedPartFiles(in downloadFolder: URL) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: downloadFolder.path, isDirectory: &isDir), isDir.boolValue else { return }
        var stack: [URL] = [downloadFolder]
        while let dir = stack.popLast() {
            guard let contents = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for url in contents {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    stack.append(url)
                } else if url.pathExtension.lowercased() == "part" {
                    try? fm.removeItem(at: url)
                }
            }
        }
    }
}
