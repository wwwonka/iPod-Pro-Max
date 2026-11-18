import Foundation
import MediaKit
#if canImport(AppKitBackend)
import AppKit
#endif

@MainActor func checkPlaybackController() {
    let engine = CheckAudioEngine()
    let session = SimulatedMediaSession()
    let controller = PlaybackController(engine: engine, session: session)
    let rows = [TrackRow(id: "a", title: "A", artist: "Artist", album: "Album", number: "1", year: "", duration: "1:00", path: "/missing-a"),
                TrackRow(id: "b", title: "B", artist: "Artist", album: "Album", number: "2", year: "", duration: "1:00", path: "/missing-b")]
    controller.start(rows[1], in: rows.reversed())
    precondition(engine.loaded?.path == "/missing-b" && controller.playing)
    engine.onProgress?(4, 60)
    let afterDuration = session.publications.count
    engine.onProgress?(4.1, 60); engine.onProgress?(4.2, 60)
    precondition(session.publications.count == afterDuration, "Progress must never continuously publish media state")
    controller.previous()
    precondition(engine.seekPosition == 0 && controller.track?.id == "b")
    engine.onProgress?(0, 60)
    controller.next()
    precondition(controller.track?.id == "a", "Playback must follow displayed order")
    controller.setVolume(0.37); controller.toggleMute()
    precondition(controller.volume == 0)
    controller.toggleMute(); precondition(controller.volume == 0.37)
    controller.setVolume(2); precondition(controller.volume == 1)
    controller.setVolume(-1); precondition(controller.volume == 0)
    controller.cycleRepeat(); controller.cycleRepeat()
    engine.onEnd?()
    precondition(controller.track?.id == "a" && controller.playing, "Repeat one must reload the completed track")
    controller.next()
    precondition(!controller.playing)
    #if canImport(AppKitBackend)
    precondition(controller.track == nil, "End of queue must return the toolbar to idle")
    controller.start(rows[0], in: rows)
    #endif
    engine.onError?("Missing file")
    precondition(controller.error == "Missing file" && !controller.playing)
    session.send(.pause); precondition(!controller.playing)
    session.send(.play); precondition(controller.playing)
    var spoken = rows[0]; spoken.playbackKind = .podcast
    controller.start(spoken, in: [spoken]); controller.setRate(1.5)
    precondition(controller.rate == 1.5 && session.publications.last?.rate == 1.5)
    controller.start(rows[0], in: rows); precondition(controller.rate == 1)
    controller.start(spoken, in: [spoken]); precondition(controller.rate == 1.5)
    controller.close()
    precondition(session.publications.last?.status == .stopped)
    precondition(controller.track == nil && !controller.playing)
    engine.onProgress?(12, 60)
    precondition(controller.position == 0, "A stale progress event must not revive the player")
    #if canImport(AppKitBackend)
    ToolbarPlayerMac(controller: controller).checkInteractions()
    let largeQueue = (0..<5000).map { index in TrackRow(id: "queue-\(index)", title: "Track \(index)", artist: "Artist", album: "Album", number: "", year: "", duration: "3:00", path: "/missing-queue") }
    controller.start(largeQueue[0], in: largeQueue)
    let opened = ProcessInfo.processInfo.systemUptime
    PlayerQueueViewController(playback: controller).checkPresentation(expectedCount: 5000)
    log(String(format: "PASS: native virtual queue 5000 rows, open/layout/clear %.2f ms", (ProcessInfo.processInfo.systemUptime - opened) * 1000))
    controller.close()
    let dockMenu = DockPlaybackMenu.shared.makeMenu()
    precondition(!dockMenu.items.isEmpty)
    #endif
    log("PASS: playback displayed queue, previous threshold, repeat one, end boundary, errors and teardown")
}

@MainActor private final class CheckAudioEngine: AudioEngine {
    var onProgress: ((Double, Double) -> Void)?
    var onEnd: (() -> Void)?
    var onError: ((String) -> Void)?
    var loaded: URL?
    var seekPosition = -1.0
    func load(_ url: URL) { loaded = url }
    func play() {}
    func pause() {}
    func seek(_ seconds: Double) { seekPosition = seconds }
    func setVolume(_ volume: Double) {}
    func setVisible(_ visible: Bool) {}
    func stop() {}
}

/// Opt-in decoder/output integration check; uses a short silent WAV fixture, never the library.
@MainActor func checkPlatformAudio(_ path: String) async -> Bool {
    let session = SimulatedMediaSession()
    let controller = PlaybackController(engine: PlatformAudioEngine(), session: session)
    controller.setVisible(true); controller.setVolume(0)
    let row = TrackRow(id: "audio-check", title: "Audio check", artist: "", album: "", number: "", year: "", duration: "", path: path)
    controller.start(row, in: [row])
    for _ in 0..<60 {
        if controller.position > 0 && controller.duration > 0 || !controller.error.isEmpty { break }
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    guard controller.position > 0, controller.duration > 0, controller.error.isEmpty else { controller.close(); log("FAIL: audio start/duration"); return false }
    let count = session.publications.count
    try? await Task.sleep(nanoseconds: 350_000_000)
    guard session.publications.count == count else { controller.close(); log("FAIL: periodic media publications"); return false }
    controller.setPlaying(false)
    let paused = controller.exactPosition
    try? await Task.sleep(nanoseconds: 350_000_000)
    guard abs(controller.exactPosition - paused) < 0.2 else { controller.close(); log("FAIL: audio pause"); return false }
    let target = max(0, controller.duration - 0.3)
    controller.seek(target)
    guard abs((session.publications.last?.position ?? -1) - target) < 0.01 else { controller.close(); log("FAIL: media seek publication"); return false }
    controller.setPlaying(true)
    for _ in 0..<50 {
        if !controller.playing || !controller.error.isEmpty { break }
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    #if canImport(AppKitBackend)
    guard controller.track == nil, session.publications.last?.status == .stopped else { controller.close(); log("FAIL: audio/session end"); return false }
    #endif
    var missing = row; missing.path = path + ".missing"
    controller.start(missing, in: [missing])
    for _ in 0..<40 {
        if !controller.error.isEmpty { break }
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    let failed = !controller.error.isEmpty; controller.close()
    guard failed else { log("FAIL: missing audio file produced no error"); return false }
    log("PASS: real audio decode/progress/pause/seek/end/error, media duration/rate/state, no periodic publications")
    return true
}

/// A local silent fixture makes every LCD state reviewable without changing the library.
@MainActor func previewPlayerLCD(_ mode: String, path: String) async {
    try? await Task.sleep(nanoseconds: 600_000_000)
    let row = TrackRow(id: "lcd-preview", title: "A quiet place to listen", artist: "iPod Pro Max", album: "Player preview", number: "1", year: "2026", duration: "2:00", path: path,
                       lyrics: "[00:00]A quiet place to listen\n[00:30]Let the music find its way\n[01:00]A little space between the notes\n[01:30]And time to stay")
    PlaybackController.shared.setVolume(0)
    PlaybackController.shared.start(row, in: [row])
    if ProcessInfo.processInfo.environment["IPPM_PLAYER_QA"] != nil { PlaybackController.shared.cycleRepeat() }
    PlayerDisplayController.shared.choose(MediaKit.PlayerLCDMode(rawValue: String(mode.split(separator: "-").first ?? "title")) ?? .title)
    if mode.hasSuffix("-paused") { PlaybackController.shared.setPlaying(false) }
    #if canImport(AppKitBackend)
    if mode.hasSuffix("-hover") {
        func hoverLCD(_ view: NSView) {
            if let lcd = view as? PlayerLCDContent {
                let event = NSEvent(cgEvent: CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: .zero, mouseButton: .left)!)!
                lcd.mouseEntered(with: event)
            }
            view.subviews.forEach(hoverLCD)
        }
        for window in NSApp.windows { if let root = window.contentView?.superview { hoverLCD(root) } }
    }
    if mode.hasSuffix("-release") {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        PlaybackController.shared.setPlaying(false)
    }
    #endif
    #if canImport(AppKitBackend)
    if mode.hasSuffix("-hidden") { for window in NSApp.windows { window.orderOut(nil) } }
    if ProcessInfo.processInfo.environment["IPPM_MEASURE_CPU"] != nil {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            let visible = NSApp.windows.contains { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) }
            log("CPU fixture \(mode): playing=\(PlaybackController.shared.playing), visible=\(visible), spectrumReady=\(PlayerDisplayController.shared.spectrum != nil)")
            flushLog()
        }
    }
    #endif
    if mode == "spectrum-fixture" {
        let frames: [[UInt8]] = (0..<240).map { frame in
            (0..<32).map { band in UInt8(max(0, min(255, (sin(Double(frame) * 0.18 + Double(band) * 0.6) + 1) * 110))) }
        }
        PlayerDisplayController.shared.setSpectrum(PlayerSpectrum(frames: frames), forTrackID: row.id)
    }
    if mode == "queue" {
        let tracks = (0..<5000).map { index in TrackRow(id: "preview-\(index)", title: index == 0 ? "A quiet place to listen" : "The next song \(index)", artist: "Artist", album: "Album", number: "", year: "", duration: "3:24", path: path) }
        PlaybackController.shared.start(tracks[0], in: tracks)
        if let destination = ProcessInfo.processInfo.environment["IPPM_QUEUE_SNAPSHOT"] { PlayerQueueViewController().snapshot(to: destination) }
    }
    #if canImport(AppKitBackend)
    if mode == "qa-final" {
        let passed = await checkFinalPlayerMac()
        flushLog(); exit(passed ? 0 : 1)
    }
    #endif
    if mode == "activity" {
        PlayerActivityController.shared.begin("preview", kind: .importing, title: "Importing music", cancel: { PlayerActivityController.shared.finish("preview", cancelled: true) })
        PlayerActivityController.shared.progress("preview", detail: "42 of 100 files · A quiet place to listen", fraction: 0.42)
    }
}

@MainActor func checkPlayerActivityDeadlines() async {
    let controller = PlayerActivityController()
    var cancelled = false
    controller.begin("quick", kind: .importing, title: "Import", cancel: { cancelled = true })
    precondition(controller.list.items.isEmpty, "Quick activities must not interrupt playback")
    controller.cancel("quick"); precondition(cancelled)
    controller.finish("quick", cancelled: true)
    precondition(controller.list.selected?.state == .completed)
    await controller.waitForCompletion("quick")
    precondition(controller.list.items.isEmpty, "Completion must expire without a repeating timer")
    controller.begin("failed", kind: .download, title: "Download")
    controller.finish("failed", error: "Disconnected")
    precondition(controller.list.selected?.state == .failed)
    controller.dismiss("failed"); precondition(controller.list.items.isEmpty)
    log("PASS: activity suppression, cancellation, single completion deadline and failure acknowledgement")
}

private final class SpectrumPreviewProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var first: (Double, Int)?
    func record(_ value: PlayerSpectrum) {
        lock.lock(); defer { lock.unlock() }
        if first == nil { first = (ProcessInfo.processInfo.systemUptime, value.frames.count) }
    }
    var result: (Double, Int)? { lock.lock(); defer { lock.unlock() }; return first }
}

@MainActor func checkDerivedAudio(_ path: String) async -> Bool {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ippm-analysis-check-" + UUID().uuidString)
    let cache = TemporaryMediaCache(root: root)
    func cleanup() async { await Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: root) }.value }
    let url = URL(fileURLWithPath: path), started = ProcessInfo.processInfo.systemUptime
    log("Starting derived analysis: \(url.lastPathComponent)"); flushLog()
    let probe = SpectrumPreviewProbe()
    let first = await AudioAnalysis.read(url, cache: cache, onSpectrum: { probe.record($0) })
    let elapsed = ProcessInfo.processInfo.systemUptime - started
    guard !first.samples.isEmpty, let spectrum = first.spectrum, !spectrum.frames.isEmpty else { log("FAIL: decoded waveform/spectrum missing"); await cleanup(); return false }
    guard let preview = probe.result, preview.1 < spectrum.frames.count else { log("FAIL: spectrum was not published before full analysis"); await cleanup(); return false }
    log(String(format: "PASS: first spectrum in %.3f s (%d frames), before full analysis %.3f s", preview.0 - started, preview.1, elapsed))
    let disk = await Task.detached(priority: .utility) { cache.sizes() }.value
    let warmStart = ProcessInfo.processInfo.systemUptime
    let second = await AudioAnalysis.read(url, cache: cache)
    guard second.samples == first.samples, second.spectrum?.frames == spectrum.frames else { log("FAIL: derived audio cache mismatch"); await cleanup(); return false }
    log(String(format: "PASS: derived audio %.3f s, %d waveform bins, %d stereo spectrum frames, %lld disk bytes; warm %.4f s", elapsed, first.samples.count, spectrum.frames.count, disk.values.reduce(0, +), ProcessInfo.processInfo.systemUptime - warmStart))
    await cleanup()
    return true
}
