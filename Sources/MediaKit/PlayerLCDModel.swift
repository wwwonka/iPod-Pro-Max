import Foundation

public enum PlayerLCDMode: String, Codable, CaseIterable, Sendable {
    case title, spectrum, waveform, lyrics
    public func next(hasLyrics: Bool) -> Self {
        let modes = Self.allCases.filter { $0 != .lyrics || hasLyrics }
        return modes[((modes.firstIndex(of: self) ?? -1) + 1) % modes.count]
    }
    public func resolved(hasLyrics: Bool) -> Self { self == .lyrics && !hasLyrics ? .title : self }
}

public struct PlaybackChapter: Equatable, Sendable {
    public var time: Double
    public var title: String
    public init(time: Double, title: String) { self.time = time; self.title = title }
}

public struct TimedLyric: Equatable, Sendable {
    public var time: Double
    public var text: String
    public init(time: Double, text: String) { self.time = time; self.text = text }
}

public enum SynchronizedLyrics {
    /// Invalid or out-of-order timing makes the whole source unavailable. Plain lyrics never scroll automatically.
    public static func parse(_ source: String?) -> [TimedLyric] {
        guard let source else { return [] }
        var result: [TimedLyric] = []
        for line in source.components(separatedBy: .newlines) {
            var rest = line[...]
            var times: [Double] = []
            while rest.first == "[", let end = rest.firstIndex(of: "]") {
                let stamp = rest[rest.index(after: rest.startIndex)..<end]
                rest = rest[rest.index(after: end)...]
                let parts = stamp.split(separator: ":", omittingEmptySubsequences: false)
                guard parts.count == 2, let minutes = Double(parts[0]), let seconds = Double(parts[1]) else {
                    if stamp.first?.isNumber == true { return [] }
                    continue
                }
                guard minutes.isFinite, seconds.isFinite, minutes >= 0, seconds >= 0, seconds < 60 else { return [] }
                times.append(minutes * 60 + seconds)
            }
            for time in times { result.append(TimedLyric(time: time, text: rest.trimmingCharacters(in: .whitespaces))) }
        }
        guard !result.isEmpty, zip(result, result.dropFirst()).allSatisfy({ $0.time <= $1.time }) else { return [] }
        return result
    }
    public static func index(at position: Double, in lines: [TimedLyric]) -> Int? {
        var low = 0, high = lines.count
        while low < high {
            let middle = (low + high) / 2
            if lines[middle].time <= position { low = middle + 1 } else { high = middle }
        }
        return low == 0 ? nil : low - 1
    }
}

public struct PlayerScrub: Sendable {
    public private(set) var trackID: String?
    public private(set) var proposed: Double?
    public init() {}
    public mutating func begin(trackID: String, position: Double) { self.trackID = trackID; proposed = position }
    public mutating func update(fraction: Double, duration: Double, width: Double, chapters: [PlaybackChapter]) {
        guard trackID != nil, duration.isFinite, duration > 0, fraction.isFinite else { return }
        var target = min(1, max(0, fraction)) * duration
        if width > 0, let chapter = chapters.min(by: { abs($0.time - target) < abs($1.time - target) }),
           abs(chapter.time - target) / duration * width <= 6 { target = chapter.time }
        proposed = min(duration, max(0, target))
    }
    public mutating func finish(currentTrackID: String?) -> Double? {
        defer { cancel() }
        return currentTrackID == trackID ? proposed : nil
    }
    public mutating func cancel() { trackID = nil; proposed = nil }
}

public struct PlayerActivity: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable { case importing, sync, transcoding, download }
    public enum State: Equatable, Sendable { case running, completed, failed }
    public var id: String
    public var kind: Kind
    public var title: String
    public var detail: String
    public var fraction: Double?
    public var state: State = .running
    public var started: Date
    public var cancellable: Bool
    public init(id: String, kind: Kind, title: String, detail: String = "", fraction: Double? = nil, started: Date = Date(), cancellable: Bool = true) {
        self.id = id; self.kind = kind; self.title = title; self.detail = detail
        self.fraction = fraction; self.started = started; self.cancellable = cancellable
    }
}

/// Selection policy independent of rendering, clocks or tasks. Failed activities remain until dismissed.
public struct PlayerActivityList: Sendable {
    public private(set) var items: [PlayerActivity] = []
    public private(set) var selectedID: String?
    public init() {}
    public var selected: PlayerActivity? { items.first { $0.id == selectedID } }
    public mutating func update(_ activity: PlayerActivity) {
        if let index = items.firstIndex(where: { $0.id == activity.id }) { items[index] = activity }
        else { items.append(activity); selectedID = activity.id }
    }
    public mutating func remove(_ id: String) { items.removeAll { $0.id == id }; if selectedID == id { selectedID = nil } }
    public mutating func cycle(_ direction: Int) {
        let ids: [String?] = [nil] + items.map { Optional($0.id) }
        let index = ids.firstIndex(of: selectedID) ?? 0
        selectedID = ids[(index + direction + ids.count) % ids.count]
    }
}

/// Timed, precomputed frequency frames (16 bands/channel, bytes 0...255).
/// The PLR16 analyzer supplies this data; the renderer never analyzes audio.
public struct PlayerSpectrum: Sendable {
    public var frames: [[UInt8]]
    public var framesPerSecond: Double
    public init(frames: [[UInt8]], framesPerSecond: Double = 20) { self.frames = frames; self.framesPerSecond = framesPerSecond }
    public func levels(at position: Double) -> [Float] {
        guard !frames.isEmpty, framesPerSecond.isFinite, framesPerSecond > 0, position.isFinite else { return Array(repeating: 0, count: 32) }
        let coordinate = min(Double(frames.count - 1), max(0, position * framesPerSecond))
        let index = Int(coordinate), next = min(frames.count - 1, index + 1)
        let blend = Float(coordinate - Double(index))
        return (0..<32).map { band in
            func value(_ frame: [UInt8]) -> Float {
                let channelBand = frame.count == 16 ? band % 16 : band
                return frame.indices.contains(channelBand) ? Float(frame[channelBand]) / 255 : 0
            }
            return value(frames[index]) * (1 - blend) + value(frames[next]) * blend
        }
    }
}

public struct PlayerSpectrumPeaks: Sendable {
    public private(set) var values = [Float](repeating: 0, count: 32)
    public init() {}
    public mutating func update(levels: [Float], elapsed: Double, reset: Bool = false) {
        for band in values.indices {
            let level = levels.indices.contains(band) ? levels[band] : 0
            values[band] = reset ? level : max(level, values[band] - Float(max(0, elapsed)) * 0.4)
        }
    }
}

/// Short, event-triggered release; the renderer stops its clock when this settles.
public struct PlayerSpectrumRelease: Sendable {
    public static let duration = 0.45
    public private(set) var levels = [Float](repeating: 0, count: 32)
    private var initial = [Float](repeating: 0, count: 32)
    private var began: Double?
    public var isReleasing: Bool { began != nil }
    public init() {}
    public mutating func show(_ values: [Float]) {
        began = nil
        levels = (0..<32).map { values.indices.contains($0) && values[$0].isFinite ? min(1, max(0, values[$0])) : 0 }
    }
    public mutating func pause(at now: Double, animated: Bool) {
        guard animated, levels.contains(where: { $0 > 0 }) else { finish(); return }
        initial = levels; began = now
    }
    public mutating func advance(to now: Double) {
        guard let began else { return }
        let progress = min(1, max(0, (now - began) / Self.duration))
        if progress >= 1 { finish(); return }
        let gain = Float((1 - progress) * (1 - progress))
        levels = initial.map { $0 * gain }
    }
    public mutating func finish() { began = nil; levels = Array(repeating: 0, count: 32) }
}
