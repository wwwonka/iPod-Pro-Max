#if canImport(AppKit)
import AppKit

/// Closing a window hides its live view graph. Dock reopening restores it without disk reads,
/// rebuilding the library, or writing session preferences onto the host.
@MainActor
final class MacWindowLifecycle: NSObject, NSApplicationDelegate {
    static let shared = MacWindowLifecycle()
    var beforeTerminate: (() async throws -> Void)?
    var afterHide: (() -> Void)?
    var onTerminationError: (Error) -> Void = { _ in }
    private var terminationTask: Task<Void, Never>?
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
            self?.afterHide?()
        }, onClose: { [weak self] window in
            self?.windows[ObjectIdentifier(window)] = nil
            if self?.lastHiddenWindow === window { self?.lastHiddenWindow = nil }
        })
        windows[id] = proxy
        window.delegate = proxy
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? { DockPlaybackMenu.shared.makeMenu() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        log("[lifecycle] reopen, visible=\(flag)")
        guard !flag else {
            return originalApplicationDelegate?.applicationShouldHandleReopen?(sender, hasVisibleWindows: flag) ?? true
        }
        guard let window = lastHiddenWindow ?? windows.values.compactMap(\.window).first else { return true }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        log("[lifecycle] quit requested, pid=\(ProcessInfo.processInfo.processIdentifier)")
        guard let beforeTerminate else { return originalApplicationDelegate?.applicationShouldTerminate?(sender) ?? .terminateNow }
        guard terminationTask == nil else { return .terminateLater }
        terminationTask = Task {
            defer { terminationTask = nil }
            do {
                try await beforeTerminate()
                let reply = originalApplicationDelegate?.applicationShouldTerminate?(sender) ?? .terminateNow
                if reply != .terminateLater { sender.reply(toApplicationShouldTerminate: reply == .terminateNow) }
            } catch {
                onTerminationError(error)
                lastHiddenWindow?.makeKeyAndOrderFront(nil)
                sender.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
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
        func windowWillEnterFullScreen(_ notification: Notification) {
            inner?.windowWillEnterFullScreen?(notification)
            // A titled full-screen window gets an auxiliary sliding titlebar even with
            // toolbar == nil. The content header owns this space for the whole session.
            if let window = notification.object as? NSWindow {
                window.styleMask.remove(.titled); window.isOpaque = false; window.backgroundColor = .clear
            }
            log("[lifecycle] entering fullscreen without titlebar")
        }
        func windowDidFailToEnterFullScreen(_ window: NSWindow) {
            window.styleMask.insert(.titled)
            inner?.windowDidFailToEnterFullScreen?(window)
        }
        func windowWillExitFullScreen(_ notification: Notification) {
            if let window = notification.object as? NSWindow {
                window.styleMask.insert(.titled); window.isOpaque = false; window.backgroundColor = .clear
            }
            inner?.windowWillExitFullScreen?(notification)
        }
        func windowDidExitFullScreen(_ notification: Notification) {
            inner?.windowDidExitFullScreen?(notification)
            guard let window = notification.object as? NSWindow else { return }
            func restore() {
                guard !window.styleMask.contains(.fullScreen) else { return }
                window.styleMask.insert(.titled); window.isOpaque = false; window.backgroundColor = .clear
            }
            restore()
            // AppKit can apply its saved pre-transition style after the delegate callback.
            DispatchQueue.main.async { restore() }
        }
        func windowDidFailToExitFullScreen(_ window: NSWindow) {
            window.styleMask.remove(.titled)
            inner?.windowDidFailToExitFullScreen?(window)
        }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            log("[lifecycle] close requested; hide window")
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
