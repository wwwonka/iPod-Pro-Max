import Foundation

/// The playback position between engine reports: the last known position, advanced by the
/// elapsed time and the rate while playing, and pinned to a seek until the engine confirms it.
/// `now` is a monotonic time in seconds (`ProcessInfo.systemUptime` in the app; any value in tests).
/// Plain value, O(1): it is read on every LCD tick and media-session update.
public struct PlaybackClock: Equatable, Sendable {
    public private(set) var position = 0.0
    public private(set) var duration = 0.0
    public private(set) var rate = 1.0
    public private(set) var playing = false
    /// A seek the engine hasn't confirmed yet; engine progress is ignored meanwhile.
    public private(set) var pendingSeek: Double?
    private var anchor = 0.0

    public init() {}

    /// The position now. `enginePosition` is the engine's own exact reading, when it has one.
    public func current(at now: Double, enginePosition: Double? = nil) -> Double {
        if let pendingSeek { return min(duration, pendingSeek + elapsed(now)) }
        if let enginePosition, enginePosition.isFinite { return max(0, enginePosition) }
        return min(duration, position + elapsed(now))
    }

    private func elapsed(_ now: Double) -> Double { playing ? (now - anchor) * rate : 0 }

    /// A new track starts playing from the top.
    public mutating func load(rate: Double, at now: Double) {
        self = PlaybackClock()
        self.rate = rate; playing = true; anchor = now
    }

    public mutating func reset() { self = PlaybackClock() }

    /// The engine reported progress. Returns whether the duration just became known.
    @discardableResult
    public mutating func progress(position: Double, duration: Double, at now: Double) -> Bool {
        let wasUnknown = self.duration == 0
        if pendingSeek == nil {
            self.position = max(0, position.isFinite ? position : 0)
            anchor = now
        }
        self.duration = max(0, duration.isFinite ? duration : 0)
        return wasUnknown && self.duration > 0
    }

    /// Play or pause, freezing the position reached so far.
    public mutating func setPlaying(_ value: Bool, at now: Double, enginePosition: Double? = nil) {
        position = current(at: now, enginePosition: enginePosition); anchor = now; playing = value
    }

    public mutating func setRate(_ value: Double, at now: Double, enginePosition: Double? = nil) {
        position = current(at: now, enginePosition: enginePosition); anchor = now; rate = value
    }

    /// Starts a seek, clamped to the track. Returns the target.
    public mutating func beginSeek(to seconds: Double, at now: Double) -> Double {
        let value = min(max(0, seconds), duration)
        pendingSeek = value; position = value; anchor = now
        return value
    }

    /// The engine finished seeking to `value`. Returns false when a newer seek superseded it.
    @discardableResult
    public mutating func completeSeek(_ value: Double, at now: Double) -> Bool {
        guard pendingSeek == value else { return false }
        pendingSeek = nil; position = value; anchor = now
        return true
    }

    /// The track reached its end without a next one.
    public mutating func finish() { playing = false; position = duration }

    public mutating func stop() { playing = false }

    public var atEnd: Bool { duration > 0 && position >= duration }
}

/// Transport decisions that don't depend on the engine.
public enum PlaybackRules {
    /// Speeds offered for spoken content (podcasts, audiobooks); music always plays at 1×.
    public static let spokenRates: [Double] = [0.75, 1, 1.25, 1.5, 2]

    /// "Previous" past this point restarts the track instead.
    public static let restartThreshold = 3.0

    public static func previousRestarts(position: Double) -> Bool { position > restartThreshold }

    public static func canSetRate(_ rate: Double, spoken: Bool) -> Bool { spoken && spokenRates.contains(rate) }
}
