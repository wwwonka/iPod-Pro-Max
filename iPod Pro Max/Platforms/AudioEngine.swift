import Foundation

#if os(macOS)
import AVFoundation
import AppKit

@MainActor final class PlatformAudioEngine: AudioEngine {
    var onProgress: ((Double, Double) -> Void)?
    var onEnd: (() -> Void)?
    var onError: ((String) -> Void)?
    private let player = AVPlayer()
    private var timeObserver: Any?
    private var statusObserver: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var visible = true
    private var active = false
    private var generation = 0
    private var windowObservers: [NSObjectProtocol] = []
    init() {
        for name in [NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification, NSWindow.didChangeOcclusionStateNotification] {
            windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.setVisible(NSApp.windows.contains { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) })
                }
            })
        }
    }
    deinit {
        if let token = timeObserver { player.removeTimeObserver(token) }
        if let token = endObserver { NotificationCenter.default.removeObserver(token) }
        for token in windowObservers { NotificationCenter.default.removeObserver(token) }
        player.pause()
    }
    func load(_ url: URL) {
        stop()
        let revision = generation
        let item = AVPlayerItem(url: url)
        statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            if item.status == .readyToPlay {
                let duration = item.duration.seconds
                Task { @MainActor [weak self] in
                    guard let self, self.generation == revision else { return }
                    self.onProgress?(self.player.currentTime().seconds, duration)
                }
            }
            if item.status == .failed {
                let message = item.error?.localizedDescription ?? "This audio file couldn't be played."
                Task { @MainActor [weak self] in
                    guard self?.generation == revision else { return }; self?.onError?(message)
                }
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.generation == revision { self?.onEnd?() } }
        }
        player.replaceCurrentItem(with: item)
    }
    func play() { active = true; player.play(); updateObserver() }
    func pause() { active = false; player.pause(); updateObserver() }
    func seek(_ seconds: Double) { player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600)) }
    func setVolume(_ volume: Double) { player.volume = Float(volume) }
    func setVisible(_ visible: Bool) { self.visible = visible; updateObserver() }
    private func updateObserver() {
        if (!visible || !active), let token = timeObserver { player.removeTimeObserver(token); timeObserver = nil }
        guard visible, active, timeObserver == nil else { return }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.onProgress?(time.seconds, self.player.currentItem?.duration.seconds ?? 0)
            }
        }
    }
    func stop() {
        generation += 1; pause(); statusObserver = nil
        if let token = endObserver { NotificationCenter.default.removeObserver(token); endObserver = nil }
        player.replaceCurrentItem(with: nil)
    }
}
#elseif os(Windows)
import UWP
import WindowsFoundation
import WinAppSDK

@MainActor final class PlatformAudioEngine: AudioEngine {
    var onProgress: ((Double, Double) -> Void)?
    var onEnd: (() -> Void)?
    var onError: ((String) -> Void)?
    private var player: UWP.MediaPlayer!
    private var progressTimer: WinAppSDK.DispatcherQueueTimer?
    private var visible = true
    private var active = false
    init() {
        audioTrace("Creating Windows MediaPlayer")
        player = UWP.MediaPlayer()
        audioTrace("Registering Windows media events")
        player.mediaEnded.addHandler { [weak self] _, _ in Task { @MainActor in self?.onEnd?() } }
        player.mediaFailed.addHandler { [weak self] _, args in
            let message = args?.errorMessage ?? "This audio file couldn't be played."
            Task { @MainActor in self?.onError?(message) }
        }
        audioTrace("Registering Windows position events")
        player.playbackSession.positionChanged.addHandler { [weak self] _, _ in
            Task { @MainActor in
                guard let self, self.visible, self.active else { return }
                self.onProgress?(Double(self.player.playbackSession.position.duration) / 10_000_000,
                                 Double(self.player.playbackSession.naturalDuration.duration) / 10_000_000)
            }
        }
    }
    func load(_ url: URL) {
        audioTrace("Loading Windows audio source")
        player.source = MediaSource.createFromUri(Uri(url.absoluteString))
    }
    func play() {
        do { try player.play(); active = true; updateProgressClock() }
        catch { onError?(error.localizedDescription) }
    }
    func pause() { try? player.pause(); active = false; updateProgressClock() }
    func seek(_ seconds: Double) { player.playbackSession.position = TimeSpan(duration: Int64(seconds * 10_000_000)) }
    func setVolume(_ volume: Double) { player.volume = volume }
    func setVisible(_ visible: Bool) { self.visible = visible; updateProgressClock() }
    private func updateProgressClock() {
        try? progressTimer?.stop(); progressTimer = nil
        guard visible, active else { return }
        // WinUI doesn't pump Foundation's timer run loop. Use its native dispatcher clock.
        guard let dispatcher = WinAppSDK.DispatcherQueue.getForCurrentThread(), let timer = try? dispatcher.createTimer() else { return }
        timer.interval = WindowsFoundation.TimeSpan(duration: 2_500_000)
        timer.isRepeating = true
        timer.tick.addHandler { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, self.visible, self.active else { return }
                let session = self.player.playbackSession!
                self.onProgress?(Double(session.position.duration) / 10_000_000, Double(session.naturalDuration.duration) / 10_000_000)
            }
        }
        progressTimer = timer
        try? timer.start()
    }
    func stop() { pause(); player.source = nil }
}
#elseif os(Linux)
import CGStreamerPlayback

@MainActor final class PlatformAudioEngine: AudioEngine {
    var onProgress: ((Double, Double) -> Void)?
    var onEnd: (() -> Void)?
    var onError: ((String) -> Void)?
    private var handle: OpaquePointer?
    private var timer: Timer?
    private var active = false
    private var visible = true
    init() {
        handle = ippm_audio_create({ context, event, message in
            guard let context else { return }
            let owner = Unmanaged<PlatformAudioEngine>.fromOpaque(context).takeUnretainedValue()
            let error = message.map { String(cString: $0) }
            Task { @MainActor [weak owner] in
                if event == 1 { owner?.onEnd?() }
                else if event == 2 { owner?.onError?(error ?? "This audio file couldn't be played.") }
            }
        }, Unmanaged.passUnretained(self).toOpaque())
    }
    func load(_ url: URL) {
        guard let handle else { onError?("GStreamer audio playback is unavailable."); return }
        ippm_audio_load(handle, url.absoluteString)
    }
    func play() { if let handle { ippm_audio_play(handle) }; active = true; updateClock() }
    func pause() { if let handle { ippm_audio_pause(handle) }; active = false; updateClock() }
    func seek(_ seconds: Double) { if let handle { ippm_audio_seek(handle, seconds) } }
    func setVolume(_ volume: Double) { if let handle { ippm_audio_volume(handle, volume) } }
    func setVisible(_ visible: Bool) { self.visible = visible; updateClock() }
    private func updateClock() {
        timer?.invalidate(); timer = nil
        guard visible, active else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let handle = self.handle else { return }
                self.onProgress?(ippm_audio_position(handle), ippm_audio_duration(handle))
            }
        }
    }
    func stop() { pause(); if let handle { ippm_audio_stop(handle) } }
    deinit { timer?.invalidate(); if let handle { ippm_audio_destroy(handle) } }
}
#endif
