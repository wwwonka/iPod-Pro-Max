import Foundation

/// The sidebar's interaction rules, platform-neutral: which rows drag, where a dragged playlist
/// lands, what a finished drag does, and which actions a playlist row offers. Each UI backend
/// (AppKit, GTK, WinUI) only maps pointer events to these inputs and draws the result.
/// Everything is O(rows) per pointer move and allocation-light, since it runs on every drag event.
public enum SidebarRules {
    // MARK: Dragging

    /// A row drags when it can move somewhere: it has siblings, sits in a folder, or is a playlist
    /// (which can always go into a folder or onto an iPod).
    public static func canDrag(siblingCount: Int, inFolder: Bool, isPlaylist: Bool) -> Bool {
        siblingCount > 1 || inFolder || isPlaylist
    }

    /// The pointer left sideways (towards the content or an iPod): stop reordering.
    public static func isHorizontalIntent(dx: Double, dy: Double) -> Bool {
        let dx = abs(dx), dy = abs(dy)
        return dx > 28 && dx > dy * 1.5
    }

    /// Whether the pointer is still over the dragged row's group. A top-level section has no
    /// lower bound (the end of the list counts); a folder ends half a row below its last child.
    public static func isInsideGroup(pointerY: Double, top: Double, bottom: Double, rowHeight: Double, groupIsFolder: Bool) -> Bool {
        guard pointerY >= top - rowHeight * 0.5 else { return false }
        return !groupIsFolder || pointerY <= bottom + rowHeight * 0.5
    }

    /// Insertion points between rows (`spans` = each row's minY/maxY, top to bottom): index 0
    /// above the first row, `i + 1` below row `i`. Returns the one nearest `y`.
    public static func nearestInsertion(spans: [(minY: Double, maxY: Double)], to y: Double) -> (index: Int, y: Double)? {
        guard let first = spans.first else { return nil }
        var best = (index: 0, y: first.minY)
        var bestDistance = abs(first.minY - y)
        for (offset, span) in spans.enumerated() {
            let distance = abs(span.maxY - y)
            if distance < bestDistance {
                best = (offset + 1, span.maxY)
                bestDistance = distance
            }
        }
        return best
    }

    /// The slot whose middle is nearest `midY`, with blocks of `heights` stacked from `top`
    /// in their current (dragged) order.
    public static func nearestSlot(midY: Double, heights: [Double], top: Double) -> Int? {
        var y = top
        var best: Int?
        var bestDistance = Double.infinity
        for (index, height) in heights.enumerated() {
            let distance = abs(midY - (y + height * 0.5))
            if distance < bestDistance { best = index; bestDistance = distance }
            y += height
        }
        return best
    }

    // MARK: Dropping

    /// Where the drag stands when the button is released.
    public struct DragState: Equatable, Sendable {
        public var cancelled = false
        /// An iPod under the pointer (any playlist or folder can be sent).
        public var deviceID: String?
        /// A folder row under the pointer.
        public var folderID: String?
        /// An insertion point between a folder's children.
        public var folderInsert: (folderID: String, index: Int)?
        /// An insertion point among the top-level playlists, when leaving a folder.
        public var topLevelIndex: Int?
        /// Reordering within the group: from the original slot to the current one.
        public var reorder: (from: Int, to: Int)?
        public init() {}

        public static func == (a: DragState, b: DragState) -> Bool {
            a.cancelled == b.cancelled && a.deviceID == b.deviceID && a.folderID == b.folderID
                && a.folderInsert?.folderID == b.folderInsert?.folderID && a.folderInsert?.index == b.folderInsert?.index
                && a.topLevelIndex == b.topLevelIndex && a.reorder?.from == b.reorder?.from && a.reorder?.to == b.reorder?.to
        }
    }

    public enum Drop: Equatable, Sendable {
        case none
        case sendToDevice(playlistID: String, deviceID: String)
        /// `index` nil: at the end of the folder, keeping list order.
        case moveToFolder(playlistID: String, folderID: String?, index: Int?)
        case reorder(from: Int, to: Int)
    }

    /// What a released drag does. `playlistID` is the dragged playlist or folder, nil for other
    /// rows; `movable` says the dragged row is a playlist that can change folder (not a folder).
    public static func drop(_ state: DragState, playlistID: String?, movable: Bool) -> Drop {
        guard !state.cancelled else { return .none }
        if let playlistID, let device = state.deviceID { return .sendToDevice(playlistID: playlistID, deviceID: device) }
        if movable, let playlistID {
            if let folder = state.folderID { return .moveToFolder(playlistID: playlistID, folderID: folder, index: nil) }
            if let insert = state.folderInsert { return .moveToFolder(playlistID: playlistID, folderID: insert.folderID, index: insert.index) }
            if let index = state.topLevelIndex { return .moveToFolder(playlistID: playlistID, folderID: nil, index: index) }
        }
        if let reorder = state.reorder, reorder.from != reorder.to { return .reorder(from: reorder.from, to: reorder.to) }
        return .none
    }

    // MARK: Row actions

    public enum PlaylistAction: Equatable, Sendable {
        case stop, refresh, openSource(name: String), rename, delete, unsubscribe

        public var title: String {
            switch self {
            case .stop: "Stop"
            case .refresh: "Refresh"
            case .openSource(let name): "Open in \(name)"
            case .rename: "Rename"
            case .delete: "Delete"
            case .unsubscribe: "Unsubscribe…"
            }
        }
    }

    /// A playlist row's context menu, in order; nil marks a separator.
    /// `sourceName` is the subscription's service, nil for a playlist of the user's own.
    public static func actions(subscribed: Bool, syncing: Bool, sourceName: String?) -> [PlaylistAction?] {
        guard subscribed else { return [.rename, .delete] }
        var actions: [PlaylistAction?] = [syncing ? .stop : .refresh]
        if let sourceName { actions.append(.openSource(name: sourceName)) }
        actions += [.rename, nil, .unsubscribe]
        return actions
    }
}
