#if canImport(AppKitBackend)
import Foundation
import CoreVideo

/// VSync-driven, at most one queued UI update. Never started without visible spectrum data.
final class LCDSpectrumDisplayLink: @unchecked Sendable {
    private var link: CVDisplayLink?
    private let lock = NSLock()
    private var queued = false
    private var last = 0.0
    private var interval = 1.0 / 30
    private let onFrame: @MainActor () -> Void
    init(onFrame: @escaping @MainActor () -> Void) {
        self.onFrame = onFrame
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        if let link {
            CVDisplayLinkSetOutputCallback(link, { _, _, time, _, _, context in
                guard let context else { return kCVReturnSuccess }
                let owner = Unmanaged<LCDSpectrumDisplayLink>.fromOpaque(context).takeUnretainedValue()
                let stamp = Double(time.pointee.videoTime) / Double(max(1, time.pointee.videoTimeScale))
                owner.tick(stamp)
                return kCVReturnSuccess
            }, Unmanaged.passUnretained(self).toOpaque())
        }
    }
    func start(reducedMotion: Bool) {
        lock.lock(); interval = reducedMotion ? 0.1 : 1.0 / 30; lock.unlock()
        if let link, !CVDisplayLinkIsRunning(link) { CVDisplayLinkStart(link) }
    }
    var isRunning: Bool { link.map { CVDisplayLinkIsRunning($0) } ?? false }
    func stop() { if let link, CVDisplayLinkIsRunning(link) { CVDisplayLinkStop(link) } }
    private func tick(_ stamp: Double) {
        lock.lock()
        guard !queued, stamp - last >= interval else { lock.unlock(); return }
        queued = true; last = stamp; lock.unlock()
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.onFrame()
            self.frameDelivered()
        }
    }
    private func frameDelivered() {
        lock.lock(); defer { lock.unlock() }
        queued = false
    }
    deinit { stop() }
}
#endif
