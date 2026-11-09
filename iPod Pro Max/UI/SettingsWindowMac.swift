import SwiftCrossUI

extension View {
    /// Gives the Settings window the main window's material (macOS) and shows `title` in its title
    /// bar. Other platforms keep their own window frame.
    func settingsWindowChrome(title: String) -> some View {
        #if canImport(AppKitBackend)
        background(SettingsWindowChrome(title: title))
        #else
        self
        #endif
    }
}

#if canImport(AppKitBackend)
import AppKit
import AppKitBackend

/// A zero-size probe: once it is in the Settings window it gives it the main window's material
/// (glass edge to edge, transparent title bar over the full-size content) and keeps the title in
/// sync with the selected section.
struct SettingsWindowChrome: NSViewRepresentable {
    var title: String

    func makeNSView(context: Context) -> SettingsChromeProbe { SettingsChromeProbe() }
    func updateNSView(_ view: SettingsChromeProbe, context: Context) {
        view.title = title
        view.window?.title = title
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SettingsChromeProbe, context: Context) -> ViewSize {
        ViewSize(0, 0)
    }
}

final class SettingsChromeProbe: NSView {
    var title = ""
    private weak var configured: NSWindow?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, configured !== window else { return }
        configured = window
        window.title = title
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.isOpaque = false
        window.backgroundColor = .clear
        // Like a Settings window: only the close button works.
        window.standardWindowButton(.miniaturizeButton)?.isEnabled = false
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.isRestorable = false
        installGlass(on: window)
        centerWhenSized(window)
    }

    /// The window appears centered on the screen of the main window, not at the corner AppKit starts
    /// it in. Its size settles after the first layout, so it stays hidden for a moment, is centered
    /// again on each resize meanwhile, and is shown (always) after 0.25 s.
    private func centerWhenSized(_ window: NSWindow) {
        window.alphaValue = 0
        let opened = Date()
        let observer = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self, weak window] _ in
            guard let window, Date().timeIntervalSince(opened) < 0.5 else { return }
            MainActor.assumeIsolated { self?.center(window) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self, weak window] in
            NotificationCenter.default.removeObserver(observer)
            guard let window else { return }
            MainActor.assumeIsolated {
                self?.center(window)
                window.alphaValue = 1
            }
        }
    }

    @MainActor private func center(_ window: NSWindow) {
        let anchor = NSApp.windows.first { $0 !== window && $0.isVisible && $0.screen != nil }
        guard let frame = (anchor?.screen ?? window.screen ?? NSScreen.main)?.visibleFrame else { return }
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(x: (frame.midX - size.width / 2).rounded(), y: (frame.midY - size.height / 2).rounded()))
    }

    /// The main window's glass, edge to edge, as the iPod page shows it: the window-level
    /// `underWindowBackground` material with no tint (`MacChrome.installWindowGlass`).
    private func installGlass(on window: NSWindow) {
        guard let content = window.contentView, let frameView = content.superview else { return }
        let glass = NSVisualEffectView(frame: frameView.bounds)
        glass.material = .underWindowBackground
        glass.blendingMode = .behindWindow
        glass.state = .active  // stays glass when another app comes forward
        glass.autoresizingMask = [.width, .height]
        frameView.addSubview(glass, positioned: .below, relativeTo: content)
    }
}
#endif
