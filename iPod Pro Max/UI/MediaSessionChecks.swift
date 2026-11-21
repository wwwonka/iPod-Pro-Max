#if canImport(AppKitBackend)
import Foundation
import MediaPlayer
import MediaKit

@MainActor func checkMacMediaSession() {
    let session = MacMediaSession()
    session.publish(MediaSessionState(title: "Media session check", artist: "Artist", duration: 120, position: 12, rate: 1.5, status: .playing, canPrevious: true, canNext: true, spoken: true))
    let center = MPNowPlayingInfoCenter.default(), remote = MPRemoteCommandCenter.shared()
    precondition(center.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == "Media session check")
    precondition(center.nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 1.5)
    precondition(remote.skipForwardCommand.isEnabled && !remote.nextTrackCommand.isEnabled)
    session.publish(MediaSessionState(title: "Media session check", duration: 120, position: 20, status: .paused))
    precondition((center.nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? NSNumber)?.doubleValue == 0)
    session.publish(MediaSessionState())
    precondition(center.nowPlayingInfo == nil && !remote.playCommand.isEnabled)
    log("PASS: macOS Now Playing metadata/rate/pause/stop and spoken remote-command availability")
}
#endif
