#if canImport(AppKit)
import AppKit

/// Closing a window hides its live view graph. Dock reopening restores it without disk reads,
/// rebuilding the library, or writing session preferences onto the host.
@MainActor
final class MacWindowLifecycle: NSObject, NSApplicationDelegate {
    static let shared = MacWindowLifecycle()
    private var originalApplicationDelegate: (any NSApplicationDelegate)?
    private var windows: [ObjectIdentifier: CloseDelegate] = [:]
    private weak var lastHiddenWindow: NSWindow?

    func install(on window: NSWindow) {
        if NSApplication.shared.delegate !== self {
            originalApplicationDelegate = NSApplication.shared.delegate
            NSApplication.shared.delegate = self
        }
        let id = ObjectIdentifier(window)
        guard windows[id] == nil else { return }
        let proxy = CloseDelegate(window: window, inner: window.delegate, onHide: { [weak self] window in
            self?.lastHiddenWindow = window
        }, onClose: { [weak self] window in
            self?.windows[ObjectIdentifier(window)] = nil
            if self?.lastHiddenWindow === window { self?.lastHiddenWindow = nil }
        })
        windows[id] = proxy
        window.delegate = proxy
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else {
            return originalApplicationDelegate?.applicationShouldHandleReopen?(sender, hasVisibleWindows: flag) ?? true
        }
        guard let window = lastHiddenWindow ?? windows.values.compactMap(\.window).first else { return true }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        return false
    }

    // Keep SwiftCrossUI's application callbacks (including open URLs) and window callbacks.
    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (originalApplicationDelegate?.responds(to: selector) ?? false)
    }
    override func forwardingTarget(for selector: Selector!) -> Any? {
        originalApplicationDelegate?.responds(to: selector) == true ? originalApplicationDelegate : nil
    }

    private final class CloseDelegate: NSObject, NSWindowDelegate {
        weak var window: NSWindow?
        private let inner: (any NSWindowDelegate)?
        private let onHide: (NSWindow) -> Void
        private let onClose: (NSWindow) -> Void

        init(window: NSWindow, inner: (any NSWindowDelegate)?, onHide: @escaping (NSWindow) -> Void, onClose: @escaping (NSWindow) -> Void) {
            self.window = window; self.inner = inner; self.onHide = onHide; self.onClose = onClose
        }
        func windowWillClose(_ notification: Notification) {
            inner?.windowWillClose?(notification)
            if let window = notification.object as? NSWindow { onClose(window) }
        }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard inner?.windowShouldClose?(sender) != false else { return false }
            sender.orderOut(nil)
            onHide(sender)
            return false
        }
        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || (inner?.responds(to: selector) ?? false)
        }
        override func forwardingTarget(for selector: Selector!) -> Any? {
            inner?.responds(to: selector) == true ? inner : nil
        }
    }
}
#endif
