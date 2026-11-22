#if canImport(AppKitBackend)
import AppKit
import MediaPlayer
import MediaKit

/// Real AVPlayer, live system metadata and native window lifecycle against the silent preview.
@MainActor func checkFinalPlayerMac() async -> Bool {
    let playback = PlaybackController.shared, display = PlayerDisplayController.shared
    guard let window = NSApp.windows.first(where: { $0.contentView?.subviews.contains(where: { $0 is PlayerHeaderMac }) == true }), let root = window.contentView?.superview else {
        log("FAIL: final player check needs the native window"); return false
    }
    func require(_ condition: Bool, _ message: String) -> Bool {
        if !condition { log("FAIL: " + message) }; return condition
    }
    func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }
    func findLCD(_ view: NSView) -> NSView? {
        if view.identifier?.rawValue == "playerLCD" { return view }
        for child in view.subviews { if let found = findLCD(child) { return found } }
        return nil
    }
    func snapshot(_ name: String) {
        let root = window.contentView?.superview ?? root
        root.layoutSubtreeIfNeeded()
        guard let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return }
        root.cacheDisplay(in: root.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/plr-final-" + name + ".png"))
    }
    window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    _ = await waitUntil { window.isKeyWindow && window.occlusionState.contains(.visible) }
    display.choose(.spectrum)
    await playback.waitForAnalysis()
    let ready = await waitUntil { playback.duration > 0 && display.spectrum != nil }
    guard require(ready && playback.playing && playback.error.isEmpty, "real playback and spectrum readiness") else { return false }
    guard require(window.toolbar == nil, "player uses no native toolbar"), let originalLCD = findLCD(root), let originalHeader = originalLCD.superview else { return false }
    // A real replacement exercises AVPlayer's asynchronous rate KVO, which the
    // in-memory engine cannot reproduce. Loading must not flash Play in between.
    if let oldTrack = playback.track {
        let replacement = TrackRow(id: "replacement-check", title: "A quiet place to listen — a long song title that continues beyond the player and loops back to its beginning", artist: oldTrack.artist, album: "A long album title to read while the music continues playing, with a gentle pause between each loop", number: oldTrack.number, year: oldTrack.year, duration: oldTrack.duration, path: oldTrack.path)
        var sawPause = false
        let observation = playback.didChange.observe { if !playback.playing { sawPause = true } }
        playback.start(replacement, in: [oldTrack, replacement])
        await playback.waitForAnalysis()
        _ = await waitUntil { playback.position > 0.25 && playback.duration > 0 }
        withExtendedLifetime(observation) {}
        guard require(!sawPause && playback.playing, "real track replacement never publishes a transient paused state") else { return false }
        log("PASS: real AVPlayer track replacement keeps Pause stable throughout loading")
    }
    (originalLCD as? PlayerLCD)?.checkComposition()
    let center = MPNowPlayingInfoCenter.default()
    guard require(center.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == playback.track?.title, "live system Now Playing metadata") else { return false }

    // Exercise the exact menu returned by the application delegate to the Dock.
    guard let menu = MacWindowLifecycle.shared.applicationDockMenu(NSApp), let pause = menu.items.first(where: { $0.title == "Pause" }), let action = pause.action else {
        log("FAIL: Dock pause menu"); return false
    }
    guard require(NSApp.sendAction(action, to: pause.target, from: pause) && !playback.playing, "Dock pause action") else { return false }
    guard require((center.nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? NSNumber)?.doubleValue == 0, "system metadata paused rate") else { return false }
    let resumed = DockPlaybackMenu.shared.makeMenu()
    guard let play = resumed.items.first(where: { $0.title == "Play" }), let playAction = play.action else { return false }
    guard require(NSApp.sendAction(playAction, to: play.target, from: play) && playback.playing, "Dock play action") else { return false }
    log("PASS: live Now Playing metadata and actual application Dock-menu pause/play actions")
    playback.setPlaying(false)
    let settled = await waitUntil { (originalLCD as? PlayerLCD)?.isSpectrumAnimating == false }
    guard require(settled && (playback.activeEngine as? PlatformAudioEngine)?.isProgressObserverInstalled == false,
                  "paused spectrum release stops both display and progress clocks") else { return false }
    playback.setPlaying(true)
    log("PASS: pause release reaches zero active spectrum/progress clocks and playback resumes")

    let spectrum = display.spectrum!.frames, samples = playback.samples, before = playback.exactPosition
    await Task.detached(priority: .utility) { TemporaryMediaCache.shared.clear() }.value
    await TemporaryCacheController.shared.refresh()
    guard require(TemporaryCacheController.shared.clearableBytes == 0, "temporary cache cleared") else { return false }
    guard require(playback.playing && display.spectrum?.frames == spectrum && playback.samples == samples, "clearing preserves the playing track's in-memory visualization") else { return false }
    let advancing = await waitUntil { playback.exactPosition > before + 0.2 }
    guard require(advancing, "playback continues after cache clear") else { return false }
    log("PASS: clearing the disk cache during real playback preserves spectrum/waveform and advancing audio")

    // The launch argument -AppleInterfaceStyle is process-local and feeds the
    // SwiftCrossUI environment as well as AppKit's per-app appearance override.
    // Overriding only the window would leave SwiftCrossUI labels in the old theme.
    let expected: NSAppearance.Name = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" ? .darkAqua : .aqua
    snapshot(expected == .aqua ? "light" : "dark")
    guard require(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expected, "native and declarative appearance agree") else { return false }
    log("PASS: native/declarative appearance \(expected.rawValue)")

    guard require(await MacChrome.shared.checkPlayerHeaderSearch(), "integrated search behavior") else { return false }
    window.makeKeyAndOrderFront(nil)
    var finishedEntering = window.styleMask.contains(.fullScreen)
    var finishedExiting = false
    let enteredObserver = NotificationCenter.default.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main) { _ in finishedEntering = true }
    let exitedObserver = NotificationCenter.default.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { _ in finishedExiting = true }
    defer { NotificationCenter.default.removeObserver(enteredObserver); NotificationCenter.default.removeObserver(exitedObserver) }
    if !window.styleMask.contains(.fullScreen) { window.standardWindowButton(.zoomButton)?.performClick(nil) }
    let entered = await waitUntil { finishedEntering && MacChrome.shared.playerUsesFullScreenSpacing }
    guard require(entered, "entered full screen") else { return false }
    guard require(MacChrome.shared.playerUsesFullScreenSpacing, "fullscreen removes the traffic-light clearance from playback controls") else { return false }
    let visible = await waitUntil {
        originalLCD.window === window && originalLCD.superview === originalHeader && originalHeader.isDescendant(of: window.contentView!) &&
        !originalLCD.isHiddenOrHasHiddenAncestor && originalLCD.visibleRect.height >= originalLCD.bounds.height - 1
    }
    snapshot("fullscreen")
    for candidate in NSApp.windows { log("[check] fullscreen host \(type(of: candidate)): visible=\(candidate.isVisible) alpha=\(candidate.alphaValue) frame=\(candidate.frame)") }
    guard require(window.contentView?.subviews.contains(where: { $0.identifier?.rawValue == "windowGlass" && $0.window === window }) == true && !window.isOpaque, "translucent background remains in the content window"),
          require(visible && window.toolbar == nil, "LCD remains in its original content header in full screen") else { return false }
    // Force the reveal state, rather than checking the host's alpha only at rest.
    if let host = MacChrome.shared.fullScreenRevealHost {
        let alpha = host.alphaValue
        host.alphaValue = 1
        guard require(MacChrome.shared.fullScreenTrafficLightsVisible, "menu-bar reveal exposes clickable window buttons in the content header") else { return false }
        host.contentView?.isHidden = false
        host.ignoresMouseEvents = false
        guard require(host.contentView?.isHidden == true && !host.isOpaque && host.backgroundColor.alphaComponent == 0 && host.ignoresMouseEvents,
                      "hover-revealed native host stays transparent and cannot intercept the player") else { return false }
        if let root = host.contentView?.superview, let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
            root.cacheDisplay(in: root.bounds, to: bitmap)
            var maxAlpha: CGFloat = 0
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 4) {
                for x in stride(from: 0, to: bitmap.pixelsWide, by: 4) { maxAlpha = max(maxAlpha, bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) }
            }
            guard require(maxAlpha < 0.01, "native titlebar reveal paints no opaque pixels over the player") else { return false }
            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/plr-hover-reveal-surface.png"))
        }
        host.alphaValue = alpha
    }
    log("PASS: revealed native titlebar remains transparent and ignores mouse events, including AppKit property resets")
    guard require(window.isKeyWindow && NSApp.mainWindow === window, "fullscreen content window keeps keyboard and menu ownership") else { return false }
    let fullScreenFrame = window.frame
    if let event = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 2, pressure: 1) {
        originalHeader.mouseDown(with: event)
    }
    guard require(window.frame == fullScreenFrame, "double click on fullscreen header cannot zoom the window") else { return false }
    let lcdPosition = originalLCD.frame
    originalHeader.needsLayout = true; originalHeader.layoutSubtreeIfNeeded()
    guard require(originalLCD.superview === originalHeader && originalLCD.frame == lcdPosition, "full-screen resize restores the same header layout") else { return false }
    if let host = NSApp.windows.first(where: { String(describing: type(of: $0)) == "NSToolbarFullScreenWindow" }) { host.alphaValue = 1 }
    guard require(MacChrome.shared.fullScreenTrafficLightsVisible, "window buttons remain available on reveal") else { return false }
    MacChrome.shared.revealedFullScreenZoomButton?.performClick(nil)
    let exited = await waitUntil { finishedExiting }
    guard require(exited && playback.playing, "exit full screen preserves playback") else { return false }
    guard require(originalLCD.window === window && originalLCD.superview === originalHeader && window.toolbar == nil && window.styleMask.contains(.titled), "exit full screen keeps content ownership and restores native titlebar") else { return false }
    guard require(!MacChrome.shared.playerUsesFullScreenSpacing && MacChrome.shared.exitButtonLayoutSamples > 0 && MacChrome.shared.exitButtonClippedSamples == 0,
                  "native buttons stay unclipped during fullscreen exit layout passes") else { return false }
    log("PASS: fullscreen spacing collapses; exit button layouts=\(MacChrome.shared.exitButtonLayoutSamples), clipped=\(MacChrome.shared.exitButtonClippedSamples)")
    MacChrome.shared.checkPlayerToolbarLayout()
    // Check after the next main-loop turn too: AppKit restores its saved style late.
    await Task.yield()
    guard require(window.styleMask.contains(.titled) && window.standardWindowButton(.closeButton)?.window === window, "native window buttons remain after final AppKit style restoration") else { return false }
    log("PASS: enter/exit full screen keeps the content player stable without auxiliary toolbar, audio playing")

    window.standardWindowButton(.miniaturizeButton)?.performClick(nil)
    let minimized = await waitUntil { window.isMiniaturized }
    guard require(minimized && playback.playing, "hosted native minimize button preserves playback") else { return false }
    window.deminiaturize(nil)
    let restored = await waitUntil { !window.isMiniaturized && window.isVisible }
    guard require(restored, "native window returns from the Dock") else { return false }
    window.standardWindowButton(.closeButton)?.performClick(nil)
    guard require(!window.isVisible && playback.playing && center.nowPlayingInfo != nil, "closing hides the window and preserves playback/system session") else { return false }
    let auxiliary = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 140, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
    auxiliary.isReleasedWhenClosed = false; auxiliary.orderFront(nil)
    NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: auxiliary)
    let clockStopped = await waitUntil { (playback.activeEngine as? PlatformAudioEngine)?.isProgressObserverInstalled == false }
    guard require(clockStopped, "auxiliary window cannot reactivate a hidden player's progress observer") else { return false }
    auxiliary.orderOut(nil)
    log("PASS: hidden player keeps its progress observer stopped while an auxiliary window is visible")
    _ = MacWindowLifecycle.shared.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
    guard require(window.isVisible && playback.playing, "Dock reopen restores the live window") else { return false }
    log("PASS: close/reopen preserves the live player and media session")
    await playback.prepareForExit()
    guard require(center.nowPlayingInfo == nil, "stop removes system Now Playing metadata") else { return false }
    log("PASS: final native player integration checks complete")
    return true
}
#endif
