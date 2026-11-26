import Foundation
import SwiftCrossUI
import MediaKit

@MainActor final class PlayerActivityController: SwiftCrossUI.ObservableObject {
    static let shared = PlayerActivityController()
    @SwiftCrossUI.Published private(set) var list = PlayerActivityList()
    private var cancellations: [String: () -> Void] = [:]
    private var deadlines: [String: Task<Void, Never>] = [:]
    private var pending: [String: PlayerActivity] = [:]
    func begin(_ id: String, kind: PlayerActivity.Kind, title: String, cancel: (() -> Void)? = nil) {
        guard pending[id] == nil, !list.items.contains(where: { $0.id == id }) else { return }
        pending[id] = PlayerActivity(id: id, kind: kind, title: title, cancellable: cancel != nil)
        cancellations[id] = cancel
        deadlines[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, let self, let activity = self.pending.removeValue(forKey: id) else { return }
            self.list.update(activity); self.deadlines[id] = nil
        }
    }
    func progress(_ id: String, detail: String, fraction: Double? = nil) {
        guard var value = pending[id] ?? list.items.first(where: { $0.id == id }) else { return }
        value.detail = detail; value.fraction = fraction.map { $0.isFinite ? min(1, max(0, $0)) : 0 }
        if pending[id] != nil { pending[id] = value } else { list.update(value) }
    }
    func finish(_ id: String, error: String? = nil, cancelled: Bool = false) {
        guard var value = pending.removeValue(forKey: id) ?? list.items.first(where: { $0.id == id }) else { return }
        deadlines[id]?.cancel(); cancellations[id] = nil
        value.state = error == nil ? .completed : .failed
        value.title = error == nil ? (cancelled ? "Cancelled" : "Completed") : "Operation failed"
        value.detail = error ?? value.detail; value.fraction = error == nil ? 1 : value.fraction; value.cancellable = false
        list.update(value)
        if error == nil {
            deadlines[id] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled else { return }; self?.dismiss(id)
            }
        }
    }
    /// A one-off message (status, tip, error) shown on the player LCD, then dismissed after a few seconds.
    func notice(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let id = "notice"
        deadlines.removeValue(forKey: id)?.cancel(); list.remove(id)
        var value = PlayerActivity(id: id, kind: .notice, title: text, cancellable: false)
        value.state = .completed
        list.update(value)
        deadlines[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }; self?.dismiss(id)
        }
    }
    func waitForCompletion(_ id: String) async { await deadlines[id]?.value }
    func dismiss(_ id: String) { deadlines.removeValue(forKey: id)?.cancel(); pending[id] = nil; cancellations[id] = nil; list.remove(id) }
    func cancel(_ id: String) { cancellations[id]?() }
    func cycle(_ direction: Int) { list.cycle(direction) }
}
