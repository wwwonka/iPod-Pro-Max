import Foundation

@MainActor func checkPlaybackController() {
    let engine = CheckAudioEngine()
    let controller = PlaybackController(engine: engine)
    let rows = [TrackRow(id: "a", title: "A", artist: "Artist", album: "Album", number: "1", year: "", duration: "1:00", path: "/missing-a"),
                TrackRow(id: "b", title: "B", artist: "Artist", album: "Album", number: "2", year: "", duration: "1:00", path: "/missing-b")]
    controller.start(rows[1], in: rows.reversed())
    precondition(engine.loaded?.path == "/missing-b" && controller.playing)
    engine.onProgress?(4, 60)
    controller.previous()
    precondition(engine.seekPosition == 0 && controller.track?.id == "b")
    engine.onProgress?(0, 60)
    controller.next()
    precondition(controller.track?.id == "a", "Playback must follow displayed order")
    controller.cycleRepeat(); controller.cycleRepeat()
    engine.onEnd?()
    precondition(controller.track?.id == "a" && controller.playing, "Repeat one must reload the completed track")
    controller.next()
    precondition(!controller.playing)
    engine.onError?("Missing file")
    precondition(controller.error == "Missing file" && !controller.playing)
    controller.close()
    precondition(controller.track == nil && !controller.playing)
    engine.onProgress?(12, 60)
    precondition(controller.position == 0, "A stale progress event must not revive the player")
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
    audioTrace("Starting native audio check")
    let engine = PlatformAudioEngine()
    audioTrace("Native audio engine created")
    var position = 0.0, duration = 0.0, ended = false, failure: String?
    engine.onProgress = { position = $0; duration = $1 }
    engine.onEnd = { ended = true }
    engine.onError = { failure = $0 }
    engine.setVisible(true); engine.setVolume(0.2)
    engine.load(URL(fileURLWithPath: path)); engine.play()
    for _ in 0..<60 {
        if position > 0 && duration > 0 || failure != nil { break }
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    guard position > 0, duration > 0, failure == nil else {
        engine.stop(); log("FAIL: audio start: \(failure ?? "no position/duration callback")"); return false
    }
    engine.pause()
    let paused = position
    try? await Task.sleep(nanoseconds: 350_000_000)
    guard abs(position - paused) < 0.2 else { engine.stop(); log("FAIL: audio keeps advancing while paused"); return false }
    engine.seek(max(0, duration - 0.3)); engine.play()
    for _ in 0..<50 {
        if ended || failure != nil { break }
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    engine.stop()
    guard ended, failure == nil else { log("FAIL: audio seek/end: \(failure ?? "no end event")"); return false }
    failure = nil
    engine.load(URL(fileURLWithPath: path + ".missing")); engine.play()
    for _ in 0..<40 {
        if failure != nil { break }
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    engine.stop()
    guard failure != nil else { log("FAIL: missing audio file produced no error"); return false }
    log("PASS: real audio decode/output, progress, pause, seek, end and missing-file error")
    return true
}
