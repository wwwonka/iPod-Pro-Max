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
    /// A slice avoids copying the entire remaining queue before mapping row models.
    public var currentAndUpcoming: ArraySlice<String> {
        ids.dropFirst(min(index, ids.count))
    }
    public var upcoming: [String] { index + 1 < ids.count ? Array(ids[(index + 1)...]) : [] }
    public var canGoPrevious: Bool { current != nil && (index > 0 || repeatMode == .all) }
    public var canGoNext: Bool { current != nil && (index + 1 < ids.count || repeatMode == .all) }
    public mutating func jump(to id: String) -> Bool {
        guard let index = ids.firstIndex(of: id) else { return false }; self.index = index; return true
    }
    /// Existing entries move rather than duplicate. The playing entry is never moved.
    public mutating func insert(_ incoming: [String], at upcomingIndex: Int) {
        let selected = current
        var seen = Set<String>()
        let added = incoming.filter { $0 != selected && seen.insert($0).inserted }
        guard !added.isEmpty else { return }
        let addedSet = Set(added)
        let destination = min(ids.count, max(index + (selected == nil ? 0 : 1), index + 1 + upcomingIndex))
        let removedBefore = ids.prefix(destination).filter { addedSet.contains($0) }.count
        ids.removeAll { addedSet.contains($0) }
        ids.insert(contentsOf: added, at: max(0, min(ids.count, destination - removedBefore)))
        index = selected.flatMap { ids.firstIndex(of: $0) } ?? 0
        if shuffled {
            let existing = Set(original)
            let inserted = added.filter { !existing.contains($0) }
            let originalIndex = selected.flatMap { original.firstIndex(of: $0) }.map { $0 + 1 } ?? original.count
            original.insert(contentsOf: inserted, at: originalIndex)
        } else { original = ids }
    }
    public mutating func append(_ incoming: [String]) { insert(incoming, at: ids.count) }
    public mutating func remove(_ removed: Set<String>) {
        let selected = current
        let allowed = removed.subtracting(selected.map { [$0] } ?? [])
        ids.removeAll { allowed.contains($0) }; original.removeAll { allowed.contains($0) }
        index = selected.flatMap { ids.firstIndex(of: $0) } ?? 0
    }
    public mutating func clearUpcoming() { remove(Set(upcoming)) }
    public mutating func move(_ id: String, to upcomingIndex: Int) { move([id], to: upcomingIndex) }
    /// Move the whole drag in its displayed order. Unknown IDs never enter the queue.
    public mutating func move(_ incoming: [String], to upcomingIndex: Int) {
        let existing = Set(ids)
        insert(incoming.filter { existing.contains($0) }, at: upcomingIndex)
    }
    public mutating func clear() { ids = []; original = []; index = 0 }
}
