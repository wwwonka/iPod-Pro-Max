import Foundation

/// Marker protocol for every plug-in role implementation passed to `PluginMain.run(roles:)`.
public protocol PluginRoleHandler: Sendable {}

/// Fetches a playlist or album as a `Playlist` header and ordered `TrackRef` items.
public protocol PlaylistSource: PluginRoleHandler {
    func fetch(url: URL) async throws -> PlaylistFetchResult
}

/// Optional capability on a `PlaylistSource` plug-in that can mirror local track reordering back upstream.
public protocol PlaylistReorderable: PlaylistSource {
    func reorder(request: PlaylistReorderRequest) async throws
}

/// Optional capability on a `PlaylistSource` plug-in that can search, edit, create, and update artwork for remote playlists.
public protocol PlaylistEditable: PlaylistSource {
    func addTracks(request: PlaylistAddTracksRequest) async throws -> PlaylistAddTracksResult
    func removeTracks(request: PlaylistRemoveTracksRequest) async throws
    func renamePlaylist(request: PlaylistRenameRequest) async throws
    func createPlaylist(request: PlaylistCreateRequest) async throws -> PlaylistCreateResult
    func setPlaylistArtwork(request: PlaylistArtworkRequest) async throws
}

/// Optional capability on a `PlaylistSource` plug-in that can list playlists from the signed-in account.
public protocol PlaylistBrowsable: PlaylistSource {
    func listUserPlaylists() async throws -> [RemotePlaylistSummary]
}

/// Searches for downloadable candidates matching a `TrackRef` and a `QualityPolicy`.
public protocol Resolver: PluginRoleHandler {
    func search(
        track: TrackRef,
        policy: QualityPolicy,
        onPartialCandidates: @escaping @Sendable ([Candidate]) async -> Void
    ) async throws -> [Candidate]
}

public extension Resolver {
    func search(track: TrackRef, policy: QualityPolicy) async throws -> [Candidate] {
        try await search(track: track, policy: policy, onPartialCandidates: { _ in })
    }
}

/// Downloads a `Candidate` produced by the same plug-in into `destinationDir`.
public protocol Downloader: PluginRoleHandler {
    func download(
        candidate: Candidate,
        destinationDir: URL,
        onProgress: @escaping @Sendable (PluginProgress) async -> Void
    ) async throws -> URL
}

public extension Downloader {
    func download(candidate: Candidate, destinationDir: URL) async throws -> URL {
        try await download(candidate: candidate, destinationDir: destinationDir, onProgress: { _ in })
    }
}

/// Serves an index of shared files provided by the host application.
public protocol ShareProvider: PluginRoleHandler {
    func setIndex(entries: [ShareIndexEntry], uploadSlots: Int) async throws
    func stop() async throws
}

/// Optional protocol for plug-ins that react to `initialize` and `settings/changed`.
public protocol PluginConfigurable: Sendable {
    func initialize(params: PluginInitializeParams, context: PluginRuntimeContext) async throws
    func settingsChanged(_ settings: [String: JSONValue]) async
}

/// Optional protocol for plug-ins that expose an `account` setting block.
public protocol PluginAccountHandling: Sendable {
    func login(key: String, fields: [String: String]) async throws -> PluginAccountStatus
    func logout() async throws -> PluginAccountStatus
    func status() async throws -> PluginAccountStatus
}

/// Optional protocol for plug-ins that expose `action` buttons (`action/<key>`).
public protocol PluginActionHandling: Sendable {
    func performAction(key: String) async throws -> PluginActionResult
}

/// Runtime callbacks available to an out-of-process plug-in inside `PluginMain`.
public protocol PluginRuntimeContext: Sendable {
    func log(_ level: PluginLogLevel, _ message: String) async
    func reportStatus(_ state: PluginRuntimeState, message: String?) async
    func reportAccountStatus(_ status: PluginAccountStatus) async
}
