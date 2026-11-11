#if canImport(AppKitBackend)
import AppKit
import AppKitBackend
import iPodKit

/// Exercises the real AppKit backend without touching a real iPod or its preferences.
@MainActor
func checkNativeSidebarPersistence() async {
    let backend = AppKitBackend()
    func makeSplit() -> NSCustomSplitView {
        let split = backend.createSplitView(leadingChild: NSView(), trailingChild: NSView()) as! NSCustomSplitView
        backend.setSidebarWidthBounds(ofSplitView: split, minimum: 180, maximum: 400)
        return split
    }
    func window(_ split: NSCustomSplitView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = split
        window.layoutIfNeeded()
        split.layoutSubtreeIfNeeded()
        return window
    }
    func verifyWidth(_ split: NSCustomSplitView, _ expected: CGFloat, _ message: String) {
        precondition(abs(split.subviews[0].frame.width - expected) < 2, "\(message): got \(split.subviews[0].frame.width), expected \(expected)")
        precondition(abs(CGFloat(backend.sidebarWidth(ofSplitView: split)) - expected) < 2, "\(message): backend width out of sync")
    }

    // Preferences can arrive before the window's first real layout.
    let open = makeSplit()
    open.applySidebarWidth(310)
    let firstWindow = window(open)
    verifyWidth(open, 310, "restored width on first layout")
    firstWindow.setContentSize(NSSize(width: 1100, height: 700))
    firstWindow.layoutIfNeeded()
    verifyWidth(open, 310, "restored width after resize")
    firstWindow.close()

    // The iPod page hides the sidebar regardless of the user's preference; returning to Music
    // must restore the remembered width, even if the first split layout happened while hidden.
    let device = makeSplit()
    device.applySidebarWidth(325)
    device.setSidebarOpenAtOnce(false)
    let deviceWindow = window(device)
    precondition(!device.isSidebarOpen && backend.sidebarWidth(ofSplitView: device) == 0, "sidebar must stay hidden on iPod")
    deviceWindow.setContentSize(NSSize(width: 1100, height: 700))
    deviceWindow.layoutIfNeeded()
    precondition(!device.isSidebarOpen && backend.sidebarWidth(ofSplitView: device) == 0, "resize must not reopen hidden sidebar")
    device.setSidebarOpenAtOnce(true)
    deviceWindow.layoutIfNeeded()
    verifyWidth(device, 325, "width restored after iPod → Music")
    device.setSidebarOpenAtOnce(false)
    deviceWindow.layoutIfNeeded()
    precondition(!device.isSidebarOpen && backend.sidebarWidth(ofSplitView: device) == 0, "user-closed sidebar must remain closed")
    device.setSidebarOpenAtOnce(true)
    deviceWindow.layoutIfNeeded()
    verifyWidth(device, 325, "width restored after user reopens")
    deviceWindow.close()

    // Exercise the actual MacChrome state machine as well as its native split backend. A closed
    // preference must survive a temporary iPod page without being written as a new user choice.
    if MacChrome.nativeSplitMode {
        let closed = makeSplit()
        let closedWindow = window(closed)
        let chrome = MacChrome.sidebarCheckChrome(window: closedWindow)
        chrome.setSidebarAvailable(false) // The iPod may be selected before the toolbar is created.
        let toolbar = NSToolbar(identifier: "sidebar-state-check")
        let toggle = chrome.toolbar(toolbar, itemForItemIdentifier: NSToolbarItem.Identifier("toggleSidebar"), willBeInsertedIntoToolbar: true)!
        if #available(macOS 15.0, *) { precondition(toggle.isHidden, "late toolbar must start hidden on iPod") }
        func pressToolbar() {
            precondition(toggle.isEnabled, "toolbar sidebar control must be enabled on Music")
            guard let action = toggle.action else { preconditionFailure("toolbar sidebar control has no action") }
            precondition(NSApp.sendAction(action, to: toggle.target, from: toggle), "toolbar sidebar control did not dispatch")
        }
        var userChoices: [Bool] = []
        var reportedWidths: [Double] = []
        chrome.onSidebarChange = { userChoices.append($0) }
        chrome.setSidebarAvailable(false) // iPod page on launch
        chrome.restoreSidebar(open: false, width: 325) { reportedWidths.append($0) }
        precondition(!closed.isSidebarOpen && !closed.dividerDragEnabled, "closed preference on iPod")
        precondition(!toggle.isEnabled, "toolbar control must be disabled on iPod")
        chrome.setSidebarAvailable(true) // Music, while the saved preference is closed
        precondition(toggle.isEnabled, "toolbar control must become enabled on Music")
        if #available(macOS 15.0, *) { precondition(!toggle.isHidden, "toolbar must reappear on Music") }
        precondition(!closed.isSidebarOpen && !closed.dividerDragEnabled, "return to Music must respect closed preference")
        closedWindow.setContentSize(NSSize(width: 1100, height: 700))
        closedWindow.layoutIfNeeded()
        precondition(!closed.isSidebarOpen && backend.sidebarWidth(ofSplitView: closed) == 0, "window resize must keep sidebar closed")
        pressToolbar()
        try? await Task.sleep(nanoseconds: 500_000_000)
        precondition(closed.isSidebarOpen && closed.dividerDragEnabled, "user toggle must open sidebar")
        verifyWidth(closed, 325, "MacChrome toggle must restore saved width")
        pressToolbar()
        try? await Task.sleep(nanoseconds: 500_000_000)
        chrome.setSidebarAvailable(false)
        chrome.setSidebarAvailable(true)
        precondition(!closed.isSidebarOpen && !closed.dividerDragEnabled, "closed choice must survive another iPod round trip")
        precondition(userChoices == [false, true, false], "temporary iPod page must not change user preference")
        precondition(reportedWidths.isEmpty, "restoration must not be saved as a drag")
        closedWindow.close()

        // When the persisted choice is open, launching on iPod must not turn the first
        // click on Music into a no-op by confusing temporary hiding with the user's choice.
        let savedOpen = makeSplit()
        let savedOpenWindow = window(savedOpen)
        let openChrome = MacChrome.sidebarCheckChrome(window: savedOpenWindow)
        let openToolbar = NSToolbar(identifier: "sidebar-open-check")
        let openToggle = openChrome.toolbar(openToolbar, itemForItemIdentifier: NSToolbarItem.Identifier("toggleSidebar"), willBeInsertedIntoToolbar: true)!
        openChrome.setSidebarAvailable(false)
        openChrome.restoreSidebar(open: true, width: 295) { _ in preconditionFailure("restoring a width must not persist it") }
        precondition(!savedOpen.isSidebarOpen && !openToggle.isEnabled, "iPod temporarily hides open preference")
        openChrome.setSidebarAvailable(true)
        precondition(savedOpen.isSidebarOpen && openToggle.isEnabled, "Music must restore open preference")
        verifyWidth(savedOpen, 295, "Music restores open preference width")
        precondition(NSApp.sendAction(openToggle.action!, to: openToggle.target, from: openToggle))
        try? await Task.sleep(nanoseconds: 500_000_000)
        precondition(!savedOpen.isSidebarOpen, "first toolbar click after iPod must close sidebar")
        precondition(NSApp.sendAction(openToggle.action!, to: openToggle.target, from: openToggle))
        try? await Task.sleep(nanoseconds: 500_000_000)
        precondition(savedOpen.isSidebarOpen, "second toolbar click after iPod must reopen sidebar")
        verifyWidth(savedOpen, 295, "toolbar reopens at saved width")
        savedOpenWindow.close()

        // A slow initial hierarchy must not lose preferences or enable a dead toolbar button.
        let deferredWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        deferredWindow.isReleasedWhenClosed = false
        deferredWindow.contentView = NSView()
        let deferred = MacChrome.sidebarCheckChrome(window: deferredWindow)
        let deferredToolbar = NSToolbar(identifier: "sidebar-deferred-check")
        let deferredToggle = deferred.toolbar(deferredToolbar, itemForItemIdentifier: NSToolbarItem.Identifier("toggleSidebar"), willBeInsertedIntoToolbar: true)!
        deferred.setSidebarAvailable(false)
        deferred.restoreSidebar(open: false, width: 312) { _ in preconditionFailure("restore is not a drag") }
        deferred.setSidebarAvailable(true)
        precondition(!deferredToggle.isEnabled, "button must be disabled until the split is ready")
        _ = NSApp.sendAction(deferredToggle.action!, to: deferredToggle.target, from: deferredToggle)
        let deferredSplit = makeSplit()
        deferredWindow.contentView = deferredSplit
        deferredWindow.layoutIfNeeded()
        deferredSplit.layoutSubtreeIfNeeded()
        deferred.sidebarHierarchyDidChange()
        precondition(deferredToggle.isEnabled && !deferredSplit.isSidebarOpen, "late split must retain the requested closed state")
        precondition(NSApp.sendAction(deferredToggle.action!, to: deferredToggle.target, from: deferredToggle))
        try? await Task.sleep(nanoseconds: 500_000_000)
        precondition(deferredSplit.isSidebarOpen, "first enabled click must open the late split")
        verifyWidth(deferredSplit, 312, "late split restores saved width")
        deferredWindow.close()

        // A user may close or resize the sidebar before settings finish loading.
        let earlySplit = makeSplit()
        let earlyWindow = window(earlySplit)
        let earlyChrome = MacChrome.sidebarCheckChrome(window: earlyWindow)
        let earlyToolbar = NSToolbar(identifier: "sidebar-early-check")
        let earlyToggle = earlyChrome.toolbar(earlyToolbar, itemForItemIdentifier: NSToolbarItem.Identifier("toggleSidebar"), willBeInsertedIntoToolbar: true)!
        earlyChrome.setSidebarAvailable(true)
        earlySplit.onDragEnd?(337)
        precondition(NSApp.sendAction(earlyToggle.action!, to: earlyToggle.target, from: earlyToggle))
        try? await Task.sleep(nanoseconds: 500_000_000)
        var earlyWidths: [Double] = []
        let chosen = earlyChrome.restoreSidebar(open: true, width: 240) { earlyWidths.append($0) }
        precondition(!chosen && !earlySplit.isSidebarOpen, "late settings must not undo the user's early close")
        precondition(earlyWidths == [337], "early resize must be saved after settings load")
        precondition(NSApp.sendAction(earlyToggle.action!, to: earlyToggle.target, from: earlyToggle))
        try? await Task.sleep(nanoseconds: 500_000_000)
        verifyWidth(earlySplit, 337, "early user width must override the older saved width")
        earlyWindow.close()

        // Exercise the actual preference writer against a disposable simulated iPod. Close and
        // flush immediately (before the debounce), then create a fresh chrome from the saved JSON.
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("sidebar-preferences-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        try! FileManager.default.createDirectory(at: tempRoot.appendingPathComponent("iPod_Control", isDirectory: true), withIntermediateDirectories: true)
        let store = PortableLibraryStore(root: tempRoot, hostID: "sidebar-check")
        var initial = PortableSettings()
        initial.sidebarWidth = 319
        initial.sidebarOpen = true
        try! store.data.write(initial, to: "settings.json")
        let prior = makeSplit()
        let priorWindow = window(prior)
        let priorChrome = MacChrome.sidebarCheckChrome(window: priorWindow)
        let priorToolbar = NSToolbar(identifier: "sidebar-save-check")
        let priorToggle = priorChrome.toolbar(priorToolbar, itemForItemIdentifier: NSToolbarItem.Identifier("toggleSidebar"), willBeInsertedIntoToolbar: true)!
        priorChrome.onSidebarChange = { PortablePreferences.shared.stageSidebarOpen($0, store: store) }
        priorChrome.setSidebarAvailable(false)
        priorChrome.restoreSidebar(open: true, width: 319) { PortablePreferences.shared.stageSidebarWidth($0, store: store) }
        priorChrome.setSidebarAvailable(true)
        precondition(NSApp.sendAction(priorToggle.action!, to: priorToggle.target, from: priorToggle))
        try! await PortablePreferences.shared.flush()
        let saved = try! store.data.readChecked(PortableSettings.self, from: "settings.json")!
        precondition(!saved.sidebarOpen && saved.sidebarWidth == 319, "toolbar choice must be on disk before quit")
        priorWindow.close()

        let next = makeSplit()
        let nextWindow = window(next)
        let nextChrome = MacChrome.sidebarCheckChrome(window: nextWindow)
        let nextToolbar = NSToolbar(identifier: "sidebar-relaunch-check")
        let nextToggle = nextChrome.toolbar(nextToolbar, itemForItemIdentifier: NSToolbarItem.Identifier("toggleSidebar"), willBeInsertedIntoToolbar: true)!
        nextChrome.setSidebarAvailable(false)
        nextChrome.restoreSidebar(open: saved.sidebarOpen, width: saved.sidebarWidth) { _ in preconditionFailure("restore must not save a new width") }
        nextChrome.setSidebarAvailable(true)
        precondition(!next.isSidebarOpen, "relaunch through iPod must retain saved closed choice")
        precondition(NSApp.sendAction(nextToggle.action!, to: nextToggle.target, from: nextToggle))
        try? await Task.sleep(nanoseconds: 500_000_000)
        verifyWidth(next, 319, "button reopens the reloaded sidebar at its saved width")
        nextWindow.close()
        log("PASS: toolbar close persists before debounce and restores through iPod on relaunch")
    }
    log("PASS: sidebar first layout, iPod-to-Music restoration and resize retain saved width")
}
#endif
