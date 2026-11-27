import Foundation

/// The player header's decisions, platform-neutral: which page owns the search and how it shows,
/// what the play button does and says, and when the launch window may reveal. Each UI backend
/// maps its events to these and draws the result; everything is O(1) and allocation-free.
public enum PlayerHeaderRules {
    // MARK: Search

    /// Below this window width the search field gives way to a magnifier button (like the Finder).
    public static let searchCollapseWidth = 900.0

    /// The header search: one page owns it at a time, and a narrow window collapses it.
    public struct Search: Equatable, Sendable {
        public enum Display: Equatable, Sendable { case hidden, field, button }

        /// The page holding the search, nil when the shown page has none.
        public private(set) var owner: ObjectIdentifier?
        /// In a narrow window, the field was brought back by the magnifier.
        public private(set) var expanded = false
        public init() {}

        public var hasOwner: Bool { owner != nil }
        /// ⌘F and "Find…" apply.
        public var canFind: Bool { owner != nil }
        public func isOwner(_ id: ObjectIdentifier) -> Bool { owner == id }

        /// A page claims the search. Returns whether the owner changed (the field then takes its text).
        @discardableResult
        public mutating func claim(_ id: ObjectIdentifier) -> Bool {
            defer { owner = id }
            return owner != id
        }

        /// A page gives the search up; only its owner can. Returns whether it was released.
        @discardableResult
        public mutating func release(_ id: ObjectIdentifier) -> Bool {
            guard owner == id else { return false }
            owner = nil
            return true
        }

        public func collapsed(windowWidth: Double) -> Bool {
            windowWidth < PlayerHeaderRules.searchCollapseWidth && !expanded
        }

        /// What the header shows. A wide window forgets the expansion.
        public mutating func display(windowWidth: Double) -> Display {
            if windowWidth >= PlayerHeaderRules.searchCollapseWidth { expanded = false }
            guard owner != nil else { return .hidden }
            return collapsed(windowWidth: windowWidth) ? .button : .field
        }

        /// The magnifier was clicked (or ⌘F in a narrow window).
        public mutating func expand() { expanded = true }

        /// Editing ended: an empty expanded field collapses back. Returns whether it did.
        @discardableResult
        public mutating func endEditing(text: String) -> Bool {
            guard expanded, text.isEmpty else { return false }
            expanded = false
            return true
        }
    }

    // MARK: Transport

    public enum PlayAction: Equatable, Sendable {
        case none, stop, toggle, startSelection
    }

    /// The play button's state. `stopArmed`: the header is hovered with ⌥ held over a track.
    public struct Transport: Equatable, Sendable {
        public var hasTrack: Bool
        public var playing: Bool
        public var hasSelection: Bool
        public var stopArmed: Bool

        public init(hasTrack: Bool, playing: Bool, hasSelection: Bool, optionHovered: Bool) {
            self.hasTrack = hasTrack; self.playing = playing; self.hasSelection = hasSelection
            stopArmed = optionHovered && hasTrack
        }

        public var action: PlayAction {
            if stopArmed { return .stop }
            if hasTrack { return .toggle }
            return hasSelection ? .startSelection : .none
        }
        public var playEnabled: Bool { hasTrack || hasSelection }
        public var skipEnabled: Bool { hasTrack }
        public var symbol: String { stopArmed ? "stop.fill" : playing ? "pause.fill" : "play.fill" }
        public var label: String { stopArmed ? "Stop" : playing ? "Pause" : "Play" }
    }

    /// The speaker symbol's level: 0 muted, then 1–3 waves.
    public static func speakerLevel(volume: Double) -> Int {
        volume == 0 ? 0 : volume < 0.33 ? 1 : volume < 0.67 ? 2 : 3
    }

    // MARK: Launch

    /// The launch window reveals once, when the app is ready (or the time limit passed) and the window exists.
    public struct Launch: Equatable, Sendable {
        public private(set) var ready = false
        public private(set) var revealed = false
        public init() {}

        public mutating func markReady() { ready = true }

        /// Whether to reveal now; true at most once.
        public mutating func reveal(hasWindow: Bool) -> Bool {
            guard ready, hasWindow, !revealed else { return false }
            revealed = true
            return true
        }
    }
}
