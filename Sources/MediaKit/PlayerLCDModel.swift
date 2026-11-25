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

/// Short, event-triggered release and staggered attack; the renderer stops its clock when settled.
public struct PlayerSpectrumRelease: Sendable {
    public static let duration = 1.15
    public private(set) var levels = [Float](repeating: 0, count: 32)
    private var initial = [Float](repeating: 0, count: 32)
    private var delays = [Double](repeating: 0, count: 32)
    private var speeds = [Double](repeating: 1 / duration, count: 32)
    private var began: Double?
    private var riseInitial = [Float](repeating: 0, count: 32)
    private var riseDelays = [Double](repeating: 0, count: 32)
    private var riseDurations = [Double](repeating: 0.18, count: 32)
    private var riseBegan: Double?
    public var isReleasing: Bool { began != nil }
    public var isRising: Bool { riseBegan != nil }
    public init() {}
    public mutating func beginRise(at now: Double, animated: Bool) {
        began = nil
        guard animated else { riseBegan = nil; return }
        riseInitial = levels
        riseBegan = now
        for band in 0..<32 {
            riseDelays[band] = Double.random(in: 0...0.18)
            riseDurations[band] = Double.random(in: 0.13...0.22)
        }
    }
    public mutating func show(_ values: [Float], at now: Double? = nil) {
        began = nil
        let targets = (0..<32).map { values.indices.contains($0) && values[$0].isFinite ? min(1, max(0, values[$0])) : 0 }
        guard let riseStart = riseBegan, let now else {
            riseBegan = nil
            levels = targets
            return
        }
        let elapsed = max(0, now - riseStart)
        var done = true
        for band in 0..<32 {
            let t = (elapsed - riseDelays[band]) / max(0.01, riseDurations[band])
            if t < 1 { done = false }
            let clamped = min(1, max(0, t))
            let eased = Float(1 - (1 - clamped) * (1 - clamped))
            levels[band] = riseInitial[band] + (targets[band] - riseInitial[band]) * eased
        }
        if done { riseBegan = nil }
    }
    public mutating func pause(at now: Double, animated: Bool) {
        riseBegan = nil
        guard animated, levels.contains(where: { $0 > 0 }) else { finish(); return }
        initial = levels; began = now
        let leftFirst = Bool.random()
        for band in 0..<32 {
            let isLeft = band < 16
            let channelBias = (isLeft == leftFirst) ? 0.0 : Double.random(in: 0.12...0.24)
            let delay = channelBias + Double.random(in: 0...0.18)
            delays[band] = delay
            let span = Double.random(in: 0.38...max(0.42, Self.duration - delay))
            speeds[band] = 1.0 / span
        }
    }
    public mutating func advance(to now: Double) {
        guard let began else { return }
        let elapsed = max(0, now - began)
        for band in levels.indices {
            let active = max(0, elapsed - delays[band])
            levels[band] = max(0, initial[band] - Float(active * speeds[band]))
        }
        if levels.allSatisfy({ $0 == 0 }) { finish() }
    }
    public mutating func finish() { began = nil; riseBegan = nil; levels = Array(repeating: 0, count: 32) }
}


/// Each peak waits longer after its column drops, then snaps off cleanly without fading.
/// One display-link release drives all columns; no timers per band or idle work.
public struct PlayerSpectrumPeakRelease: Sendable {
    public static let holdDuration = 0.20
    public private(set) var opacities = [Double](repeating: 0, count: 32)
    public var opacity: Double { opacities.max() ?? 0 }
    private var offDelays = [Double](repeating: 0, count: 32)
    private var began: Double?
    public var isReleasing: Bool { began != nil }
    public init() {}
    public mutating func show() {
        began = nil
        for band in opacities.indices { opacities[band] = 1 }
    }
    public mutating func pause(at now: Double, levels: [Float], animated: Bool) {
        guard animated else { finish(); return }
        began = now
        let leftFirst = Bool.random()
        for band in opacities.indices {
            let value = levels.indices.contains(band) && levels[band].isFinite ? min(1, max(0, levels[band])) : 0
            if value > 0 {
                let channelBias = ((band < 16) == leftFirst) ? 0.0 : Double.random(in: 0.10...0.22)
                let baseDrop = Double(value) * Double.random(in: 0.50...0.95)
                offDelays[band] = baseDrop + Self.holdDuration + channelBias + Double.random(in: 0...0.12)
                opacities[band] = 1
            } else {
                offDelays[band] = 0
                opacities[band] = 0
            }
        }
    }
    public mutating func advance(to now: Double) {
        guard let began else { return }
        let elapsed = max(0, now - began)
        for band in opacities.indices {
            opacities[band] = elapsed < offDelays[band] ? 1 : 0
        }
        if opacities.allSatisfy({ $0 == 0 }) { finish() }
    }
    public mutating func finish() {
        began = nil
        for band in opacities.indices { opacities[band] = 0 }
    }
}
