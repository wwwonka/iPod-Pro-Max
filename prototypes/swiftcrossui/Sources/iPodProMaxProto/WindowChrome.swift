import SwiftCrossUI

// Window chrome like the real app: no title bar, the sidebar runs to the top of the window and the
// traffic lights float over it. SwiftCrossUI has no API for this, so each backend's native window is
// reached through `inspectWindow`. Same backend order as DefaultBackend.

#if canImport(AppKitBackend)
    import AppKit
    import AppKitBackend

    /// Height of the area the traffic lights float over, kept clear of content.
    let titleBarInset = 28

    extension View {
        func hiddenTitleBar() -> some View {
            inspectWindow { window in
                window.styleMask.insert(.fullSizeContentView)
                window.titlebarAppearsTransparent = true
                window.titleVisibility = .hidden
                window.isMovableByWindowBackground = true
            }
        }
    }
#else
    // GTK and WinUI keep their system title bar for now.
    let titleBarInset = 0

    extension View {
        func hiddenTitleBar() -> some View { self }
    }
#endif
