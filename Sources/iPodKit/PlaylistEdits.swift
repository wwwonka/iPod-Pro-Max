import Foundation

/// A playlist as the playlist tree sees it: a row that may be a folder and may sit in one.
/// The saved `LibraryPlaylist` (UUID ids) and the app's displayed copy (String ids) both
/// conform, so each edit rule exists once and applies to both.
public protocol PlaylistTreeNode {
    associatedtype NodeID: Hashable
    associatedtype TrackID: Hashable
    var id: NodeID { get }
    var name: String { get set }
    var isFolder: Bool { get }
    var parentID: NodeID? { get set }
    var trackIDs: [TrackID] { get set }
    /// Subscription playlists are edited by their subscription, never directly.
    var isSubscribed: Bool { get }
}

extension LibraryPlaylist: PlaylistTreeNode {
    public var isSubscribed: Bool { subscriptionID != nil }
}

/// Edits of the user's playlist tree. Every function is pure and platform-neutral.
public enum PlaylistEdits {
    /// Moves a playlist into `folderID` (nil = top level). With `index`, it lands at that
    /// position among its new siblings; without, it keeps its place in the list.
    /// Folders don't move, and nothing moves into itself.
    public static func move<P: PlaylistTreeNode>(_ id: P.NodeID, toFolder folderID: P.NodeID?, atIndex index: Int?, in playlists: inout [P]) {
        guard folderID != id,
              let oldIndex = playlists.firstIndex(where: { $0.id == id }),
              !playlists[oldIndex].isFolder else { return }
        var item = playlists.remove(at: oldIndex)
        item.parentID = folderID
        guard let index else {
            playlists.insert(item, at: min(oldIndex, playlists.endIndex))
            return
        }
        let siblings = playlists.indices.filter { playlists[$0].parentID == folderID }
        let destination: Int
        if index <= 0 {
            destination = siblings.first ?? playlists.endIndex
        } else if index >= siblings.count {
            destination = siblings.last.map { $0 + 1 } ?? playlists.endIndex
        } else {
            destination = siblings[index]
        }
        playlists.insert(item, at: destination)
    }

    /// Moves `moving` tracks (kept in their current order) so they land before row `targetRow`
    /// of the playlist as it was displayed.
    public static func reorderTracks<P: PlaylistTreeNode>(_ moving: [P.TrackID], to targetRow: Int, inPlaylist id: P.NodeID, of playlists: inout [P]) {
        let movingSet = Set(moving)
        guard !movingSet.isEmpty, let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        var tracks = playlists[index].trackIDs
        let clamped = max(0, min(tracks.count, targetRow))
        let before = tracks[..<clamped].filter { movingSet.contains($0) }.count
        let ordered = tracks.filter { movingSet.contains($0) }
        tracks.removeAll { movingSet.contains($0) }
        tracks.insert(contentsOf: ordered, at: max(0, min(tracks.count, clamped - before)))
        playlists[index].trackIDs = tracks
    }

    /// Appends tracks not already in the playlist. Subscription playlists are left alone.
    public static func addTracks<P: PlaylistTreeNode>(_ ids: [P.TrackID], toPlaylist id: P.NodeID, of playlists: inout [P]) {
        guard let index = editableIndex(id, playlists) else { return }
        var existing = Set(playlists[index].trackIDs)
        for track in ids where existing.insert(track).inserted { playlists[index].trackIDs.append(track) }
    }

    public static func removeTracks<P: PlaylistTreeNode>(_ ids: [P.TrackID], fromPlaylist id: P.NodeID, of playlists: inout [P]) {
        guard let index = editableIndex(id, playlists) else { return }
        let removed = Set(ids)
        playlists[index].trackIDs.removeAll { removed.contains($0) }
    }

    /// Renames with a trimmed name; an empty name changes nothing.
    public static func rename<P: PlaylistTreeNode>(_ id: P.NodeID, to name: String, in playlists: inout [P]) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = editableIndex(id, playlists) else { return }
        playlists[index].name = trimmed
    }

    /// Puts the playlists in `orderedIDs` order; ones not listed follow in their current order.
    public static func reorder<P: PlaylistTreeNode>(_ orderedIDs: [P.NodeID], in playlists: inout [P]) {
        var byID = Dictionary(playlists.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result = orderedIDs.compactMap { byID.removeValue(forKey: $0) }
        result += playlists.filter { byID[$0.id] != nil }
        playlists = result
    }

    /// "New Playlist", then "New Playlist 2", "New Playlist 3"… whichever is free.
    public static func uniqueName(_ base: String, among names: some Sequence<String>) -> String {
        let taken = Set(names)
        var name = base
        var n = 2
        while taken.contains(name) {
            name = "\(base) \(n)"
            n += 1
        }
        return name
    }

    private static func editableIndex<P: PlaylistTreeNode>(_ id: P.NodeID, _ playlists: [P]) -> Int? {
        guard let index = playlists.firstIndex(where: { $0.id == id }), !playlists[index].isSubscribed else { return nil }
        return index
    }
}
