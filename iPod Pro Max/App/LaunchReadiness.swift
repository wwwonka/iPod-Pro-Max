import Foundation

/// The launch is over when the first page can be drawn with everything it shows: the iPod page's
/// data and icon, and the local library's index. The app marks each milestone once; nothing polls.
@MainActor
final class LaunchReadiness {
    static let shared = LaunchReadiness()

    enum Milestone: CaseIterable {
        /// The device page shown first (its snapshot and volume icon), or nothing to wait for.
        case device
        /// The first load of the local library (index, settings), cached or fresh.
        case library
    }

    private var pending = Set(Milestone.allCases)
    private(set) var isReady = false
    /// Called once, on the main actor, when the last milestone is marked.
    var onReady: (() -> Void)? {
        didSet { if isReady { onReady?() } }
    }

    func mark(_ milestone: Milestone) {
        guard !isReady else { return }
        pending.remove(milestone)
        guard pending.isEmpty else { return }
        isReady = true
        onReady?()
    }
}
