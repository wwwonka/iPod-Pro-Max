import AppKit

@MainActor final class OriginalDelegate: NSObject, NSWindowDelegate, NSApplicationDelegate {
    var closed = 0
    var openedURLs = 0
    func windowWillClose(_ notification: Notification) { closed += 1 }
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize { NSSize(width: 800, height: 600) }
    func application(_ application: NSApplication, open urls: [URL]) { openedURLs += urls.count }
}

@main struct WindowReopenCheck {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let original = OriginalDelegate()
        app.delegate = original
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.delegate = original
        let view = NSTextField(labelWithString: "Artist view + search + selection")
        window.contentView = view
        let lifecycle = MacWindowLifecycle()
        lifecycle.install(on: window)
        lifecycle.install(on: window)
        for _ in 0..<3 {
            window.makeKeyAndOrderFront(nil)
            window.performClose(nil)
            precondition(!window.isVisible && original.closed == 0, "Close destroyed the window")
            precondition(!lifecycle.applicationShouldHandleReopen(app, hasVisibleWindows: false))
            precondition(window.isVisible && window.contentView === view)
            precondition(view.stringValue == "Artist view + search + selection")
        }
        precondition(window.delegate?.windowWillResize?(window, to: NSSize(width: 1, height: 1)) == NSSize(width: 800, height: 600))
        app.delegate?.application?(app, open: [URL(fileURLWithPath: "/test")])
        precondition(original.openedURLs == 1, "Application callback not forwarded")
        window.close() // Actual teardown, as opposed to the user's close action.
        precondition(original.closed == 1, "Final close callback not forwarded")
        print("PASS: close/reopen x3 retains view/state; resize, URL and final close callbacks forwarded")
    }
}
