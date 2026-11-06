import Foundation

/// A snapshot of the displayed order. UI filtering and sorting never mutate a playing queue.
public struct PlaybackQueue: Sendable {
    public enum RepeatMode: Int, CaseIterable, Sendable { case off, all, one }
    public private(set) var ids: [String] = []
    public private(set) var index = 0
    public private(set) var shuffled = false
    public var repeatMode: RepeatMode = .off
    private var original: [String] = []
    public var current: String? { ids.indices.contains(index) ? ids[index] : nil }
    public init() {}
    public mutating func start(ids: [String], at id: String) {
        var seen = Set<String>()
        original = ids.filter { seen.insert($0).inserted }
        self.ids = original
        index = self.ids.firstIndex(of: id) ?? 0
        if shuffled { arrangeShuffle() }
    }
    public mutating func setShuffled(_ enabled: Bool) {
        guard enabled != shuffled else { return }
        let selected = current
        shuffled = enabled
        if enabled { arrangeShuffle() }
        else { ids = original; index = selected.flatMap { ids.firstIndex(of: $0) } ?? 0 }
    }
    private mutating func arrangeShuffle() {
        guard let current else { return }
        ids = [current] + original.filter { $0 != current }.shuffled()
        index = 0
    }
    public mutating func next(automatic: Bool = false) -> String? {
        guard !ids.isEmpty else { return nil }
        if automatic && repeatMode == .one { return current }
        if index + 1 < ids.count { index += 1; return current }
        if repeatMode == .all { index = 0; return current }
        return nil
    }
    public mutating func previous() -> String? {
        guard !ids.isEmpty else { return nil }
        if index > 0 { index -= 1 }
        else if repeatMode == .all { index = ids.count - 1 }
        return current
    }
    public mutating func clear() { ids = []; original = []; index = 0 }
}
