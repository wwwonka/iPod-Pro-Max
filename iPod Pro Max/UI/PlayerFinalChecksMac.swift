#if canImport(AppKitBackend)
import AppKit
import MediaPlayer
import MediaKit

/// Real AVPlayer, live system metadata and native window lifecycle against the silent preview.
@MainActor func checkFinalPlayerMac() async -> Bool {
    let playback = PlaybackController.shared, display = PlayerDisplayController.shared
    guard let window = NSApp.windows.first(where: { $0.toolbar != nil }), let root = window.contentView?.superview else {
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

    let spectrum = display.spectrum!.frames, samples = playback.samples, before = playback.exactPosition
    await Task.detached(priority: .utility) { TemporaryMediaCache.shared.clear() }.value
    await TemporaryCacheController.shared.refresh()
    guard require(TemporaryCacheController.shared.sizes.values.reduce(0, +) == 0, "temporary cache cleared") else { return false }
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

    window.makeKeyAndOrderFront(nil)
    if !window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
    let entered = await waitUntil { window.styleMask.contains(.fullScreen) && !window.inLiveResize }
    guard require(entered, "entered full screen") else { return false }
    // Layout notifications can follow didEnterFullScreen. This bounded wait checks
    // actual clipping, not simply toolbar.isVisible, which is true even when auto-hidden.
    let visible = await waitUntil {
        for candidate in NSApp.windows where candidate.isVisible && candidate.alphaValue > 0 {
            if let frame = candidate.contentView?.superview, let lcd = findLCD(frame),
               !lcd.isHiddenOrHasHiddenAncestor, lcd.visibleRect.height >= lcd.bounds.height - 1 { return true }
        }
        return false
    }
    snapshot("fullscreen")
    for candidate in NSApp.windows {
        log("[check] full screen window: \(type(of: candidate)), visible=\(candidate.isVisible), alpha=\(candidate.alphaValue), frame=\(candidate.frame)")
        if let frame = candidate.contentView?.superview, let lcd = findLCD(frame) {
            log("[check] LCD host=\(type(of: candidate)), visible=\(lcd.visibleRect), hidden=\(lcd.isHiddenOrHasHiddenAncestor)")
            if candidate !== window, let bitmap = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
                frame.cacheDisplay(in: frame.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/plr-final-fullscreen-toolbar.png"))
            }
        }
    }
    if !visible, let currentRoot = window.contentView?.superview {
        log("[check] full screen root=\(currentRoot), oldRoot=\(root), delegate=\(String(describing: window.delegate)), options=\(NSApp.presentationOptions.rawValue), toolbar=\(String(describing: window.toolbar?.isVisible))")
        if let lcd = findLCD(currentRoot) {
            var cursor: NSView? = lcd
            while let view = cursor { log("[check] ancestor \(type(of: view)): frame=\(view.frame), bounds=\(view.bounds), visible=\(view.visibleRect), hidden=\(view.isHidden)"); cursor = view.superview }
        }
    }
    guard require(visible, "LCD stays visible in full screen") else { return false }
    window.toggleFullScreen(nil)
    let exited = await waitUntil { !window.styleMask.contains(.fullScreen) && !window.inLiveResize }
    guard require(exited && playback.playing, "exit full screen preserves playback") else { return false }
    log("PASS: enter/exit full screen keeps the toolbar player visible and audio playing")

    window.performClose(nil)
    guard require(!window.isVisible && playback.playing && center.nowPlayingInfo != nil, "closing hides the window and preserves playback/system session") else { return false }
    _ = MacWindowLifecycle.shared.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
    guard require(window.isVisible && playback.playing, "Dock reopen restores the live window") else { return false }
    log("PASS: close/reopen preserves the live player and media session")
    await playback.prepareForExit()
    guard require(center.nowPlayingInfo == nil, "stop removes system Now Playing metadata") else { return false }
    log("PASS: final native player integration checks complete")
    return true
}
#endif
