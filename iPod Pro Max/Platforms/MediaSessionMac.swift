#if os(macOS)
import AppKit
import MediaPlayer
import ImageIO
import MediaKit

@MainActor final class MacMediaSession: MediaSession {
    var onCommand: ((MediaSessionCommand) -> Void)?
    private var targets: [(MPRemoteCommand, Any)] = []
    private var artworkTask: Task<Void, Never>?
    private var artworkURL: URL?
    private var artwork: MPMediaItemArtwork?
    private var state = MediaSessionState()
    private var publishedAt = ProcessInfo.processInfo.systemUptime
    init() {
        let center = MPRemoteCommandCenter.shared()
        func bind(_ command: MPRemoteCommand, _ action: @escaping (MPRemoteCommandEvent) -> MediaSessionCommand?) {
            let token = command.addTarget { [weak self] event in
                guard let request = action(event) else { return .commandFailed }
                Task { @MainActor in self?.onCommand?(request) }
                return .success
            }
            targets.append((command, token))
        }
        bind(center.playCommand) { _ in .play }; bind(center.pauseCommand) { _ in .pause }
        bind(center.togglePlayPauseCommand) { _ in .toggle }
        bind(center.nextTrackCommand) { _ in .next }; bind(center.previousTrackCommand) { _ in .previous }
        bind(center.changePlaybackPositionCommand) { ($0 as? MPChangePlaybackPositionCommandEvent).map { .seek($0.positionTime) } }
        center.skipBackwardCommand.preferredIntervals = [15]; center.skipForwardCommand.preferredIntervals = [30]
        bind(center.skipBackwardCommand) { _ in .skip(-15) }; bind(center.skipForwardCommand) { _ in .skip(30) }
    }
    func publish(_ state: MediaSessionState) {
        self.state = state; publishedAt = ProcessInfo.processInfo.systemUptime
        let remote = MPRemoteCommandCenter.shared(), active = state.status != .stopped
        remote.playCommand.isEnabled = active; remote.pauseCommand.isEnabled = active
        remote.togglePlayPauseCommand.isEnabled = active
        remote.changePlaybackPositionCommand.isEnabled = active && state.duration > 0
        remote.nextTrackCommand.isEnabled = active && !state.spoken && state.canNext
        remote.previousTrackCommand.isEnabled = active && !state.spoken && state.canPrevious
        remote.skipBackwardCommand.isEnabled = active && state.spoken
        remote.skipForwardCommand.isEnabled = active && state.spoken
        if !active { artworkTask?.cancel(); artworkURL = nil; artwork = nil; apply(); return }
        if state.artworkURL != artworkURL || artwork == nil {
            artworkURL = state.artworkURL; artworkTask?.cancel()
            let generic: NSImage?
            if #available(macOS 11, *) { generic = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil) }
            else { generic = NSImage(named: NSImage.multipleDocumentsName) }
            if let generic {
                artwork = MPMediaItemArtwork(boundsSize: NSSize(width: 256, height: 256)) { _ in generic }
            }
            if let url = state.artworkURL {
                artworkTask = Task { [weak self] in
                    let image = await Task.detached(priority: .utility) { () -> CGImage? in
                        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1024, kCGImageSourceShouldCacheImmediately: true, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
                        return cg
                    }.value
                    guard !Task.isCancelled, let self, self.artworkURL == url, let image else { return }
                    self.artwork = MPMediaItemArtwork(boundsSize: NSSize(width: image.width, height: image.height)) { requested in NSImage(cgImage: image, size: requested) }
                    self.apply()
                }
            }
        }
        apply()
    }
    private func apply() {
        let center = MPNowPlayingInfoCenter.default()
        guard state.status != .stopped else { center.playbackState = .stopped; center.nowPlayingInfo = nil; return }
        var info: [String: Any] = [MPMediaItemPropertyTitle: state.title, MPMediaItemPropertyArtist: state.artist,
            MPMediaItemPropertyAlbumTitle: state.album, MPMediaItemPropertyPlaybackDuration: state.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: min(state.duration, state.position + (state.status == .playing ? (ProcessInfo.processInfo.systemUptime - publishedAt) * state.rate : 0)),
            MPNowPlayingInfoPropertyPlaybackRate: state.status == .playing ? state.rate : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: state.rate]
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        center.nowPlayingInfo = info
        center.playbackState = state.status == .playing ? .playing : .paused
    }
    deinit { for (command, token) in targets { command.removeTarget(token) }; artworkTask?.cancel() }
}
#endif
