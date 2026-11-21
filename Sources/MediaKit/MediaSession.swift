import Foundation

public enum MediaSessionCommand: Equatable, Sendable {
    case play, pause, toggle, next, previous, seek(Double), skip(Double)
}
public struct MediaSessionState: Equatable, Sendable {
    public enum Status: String, Sendable { case playing, paused, stopped }
    public var title: String, artist: String, album: String
    public var artworkURL: URL?
    public var duration: Double, position: Double, rate: Double
    public var status: Status
    public var canPrevious: Bool, canNext: Bool, spoken: Bool
    public init(title: String = "", artist: String = "", album: String = "", artworkURL: URL? = nil, duration: Double = 0, position: Double = 0, rate: Double = 1, status: Status = .stopped, canPrevious: Bool = false, canNext: Bool = false, spoken: Bool = false) {
        self.title = title; self.artist = artist; self.album = album; self.artworkURL = artworkURL
        self.duration = duration; self.position = position; self.rate = rate; self.status = status
        self.canPrevious = canPrevious; self.canNext = canNext; self.spoken = spoken
    }
}
@MainActor public protocol MediaSession: AnyObject {
    var onCommand: ((MediaSessionCommand) -> Void)? { get set }
    func publish(_ state: MediaSessionState)
}
@MainActor public final class SimulatedMediaSession: MediaSession {
    public var onCommand: ((MediaSessionCommand) -> Void)?
    public private(set) var publications: [MediaSessionState] = []
    public init() {}
    public func publish(_ state: MediaSessionState) { publications.append(state) }
    public func send(_ command: MediaSessionCommand) { onCommand?(command) }
}
