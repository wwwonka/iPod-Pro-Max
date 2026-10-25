import SwiftCrossUI

// Window chrome like the real app: no title bar, the sidebar runs to the top of the window and the
// traffic lights float over it. SwiftCrossUI has no API for this, so each backend's native window is
// reached through `inspectWindow`. Same backend order as DefaultBackend.

#if canImport(AppKitBackend)
    import AppKit
    import AppKitBackend
    import Foundation

    /// Where the sidebar's content starts: below the traffic lights, as in the SwiftUI app.
    let sidebarTopInset = 34

    extension View {
        func hiddenTitleBar() -> some View {
            inspectWindow { window in
                window.styleMask.insert(.fullSizeContentView)
                window.titlebarAppearsTransparent = true
                window.titleVisibility = .hidden
                window.isMovableByWindowBackground = true
                snapshotIfRequested(window)
            }
        }
    }

    /// `IPPM_SNAPSHOT=<file.png>`: saves the window as the app draws it, then quits. Lets the UI be
    /// checked without screen-recording permission.
    @MainActor
    private func snapshotIfRequested(_ window: NSWindow) {
        guard let path = ProcessInfo.processInfo.environment["IPPM_SNAPSHOT"] else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard let view = window.contentView?.superview,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            NSApp.terminate(nil)
        }
    }
#else
    // GTK and WinUI keep their system title bar for now.
    let sidebarTopInset = 0

    extension View {
        func hiddenTitleBar() -> some View { self }
    }
#endif
