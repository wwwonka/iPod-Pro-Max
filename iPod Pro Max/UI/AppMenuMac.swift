#if canImport(AppKit)
import AppKit

/// Adds "Settings…" ⌘, to the application menu, under "About". The backend rebuilds the whole menu bar
/// whenever the scene refreshes, so the item is put back each time the main menu is replaced.
@MainActor
final class AppMenuMac: NSObject, NSMenuItemValidation {
    static let shared = AppMenuMac()
    private var observation: NSKeyValueObservation?
    private var windowObserver: NSObjectProtocol?

    func install() {
        guard observation == nil else { return }
        observation = NSApplication.shared.observe(\.mainMenu, options: [.initial, .new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.updateMenus() }
        }
        windowObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.addFileMenuItems()
                self?.addViewMenu()
            }
        }
    }

    private func updateMenus() {
        addSettingsItem()
        addFileMenuItems()
        addViewMenu()
    }

    private func addFileMenuItems() {
        guard let mainMenu = NSApp.mainMenu,
              let fileMenu = mainMenu.items.first(where: { $0.title == "File" || $0.submenu?.title == "File" })?.submenu,
              !fileMenu.items.contains(where: { $0.action == #selector(newPlaylist(_:)) }) else { return }
        let playlistItem = NSMenuItem(title: "New Playlist", action: #selector(newPlaylist(_:)), keyEquivalent: "n")
        playlistItem.keyEquivalentModifierMask = [.command]
        playlistItem.target = self
        let folderItem = NSMenuItem(title: "New Folder", action: #selector(newPlaylistFolder(_:)), keyEquivalent: "N")
        folderItem.keyEquivalentModifierMask = [.command, .shift]
        folderItem.target = self
        let subscriptionItem = NSMenuItem(title: "New Subscription…", action: #selector(newSubscription(_:)), keyEquivalent: "n")
        subscriptionItem.keyEquivalentModifierMask = [.command, .option]
        subscriptionItem.target = self
        let infoItem = NSMenuItem(title: "Track Info", action: #selector(openTrackInfo(_:)), keyEquivalent: "i")
        infoItem.keyEquivalentModifierMask = [.command]
        infoItem.target = self
        fileMenu.insertItem(playlistItem, at: 0)
        fileMenu.insertItem(folderItem, at: 1)
        fileMenu.insertItem(subscriptionItem, at: 2)
        fileMenu.insertItem(infoItem, at: 3)
        if fileMenu.items.count > 4 {
            fileMenu.insertItem(.separator(), at: 4)
        }
    }

    private func addSettingsItem() {
        guard let menu = NSApp.mainMenu?.items.first?.submenu else { return }
        // The backend names the items after the process ("iPodProMaxApp").
        let process = ProcessInfo.processInfo.processName
        for item in menu.items where item.title.hasSuffix(process) {
            item.title = item.title.replacingOccurrences(of: process, with: "iPod Pro Max")
        }
        guard
              !menu.items.contains(where: { $0.action == #selector(openSettings(_:)) }),
              let about = menu.items.firstIndex(where: { $0.title.hasPrefix("About") }) else { return }
        let item = NSMenuItem(title: "Settings…", action: #selector(openSettings(_:)), keyEquivalent: ",")
        item.target = self
        menu.insertItem(.separator(), at: about + 1)
        menu.insertItem(item, at: about + 2)
    }

    private func addViewMenu() {
        guard let mainMenu = NSApp.mainMenu,
              let viewMenu = mainMenu.items.first(where: { $0.title == "View" || $0.submenu?.title == "View" })?.submenu,
              !viewMenu.items.contains(where: { $0.action == #selector(toggleSidebar(_:)) }) else { return }
        let sidebarItem = NSMenuItem(
            title: MacChrome.shared.isSidebarVisible ? "Hide Sidebar" : "Show Sidebar",
            action: #selector(toggleSidebar(_:)),
            keyEquivalent: "s"
        )
        sidebarItem.keyEquivalentModifierMask = [.command, .control]
        sidebarItem.target = self
        viewMenu.insertItem(sidebarItem, at: 0)
        if viewMenu.items.count > 1 {
            viewMenu.insertItem(.separator(), at: 1)
        }
    }

    @objc private func openSettings(_ sender: Any?) { AppCommands.openSettings?() }
    @objc private func openTrackInfo(_ sender: Any?) { AppCommands.openTrackInfo?() }
    @objc private func toggleSidebar(_ sender: Any?) { MacChrome.shared.toggleSidebar() }
    @objc private func newPlaylist(_ sender: Any?) { AppCommands.createPlaylist?(false) }
    @objc private func newPlaylistFolder(_ sender: Any?) { AppCommands.createPlaylist?(true) }
    @objc private func newSubscription(_ sender: Any?) { AppCommands.newSubscription?() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(openSettings(_:)) {
            return AppCommands.openSettings != nil
        }
        if item.action == #selector(openTrackInfo(_:)) {
            return AppCommands.canOpenTrackInfo?() ?? false
        }
        if item.action == #selector(newPlaylist(_:)) || item.action == #selector(newPlaylistFolder(_:)) {
            return AppCommands.createPlaylist != nil
        }
        if item.action == #selector(newSubscription(_:)) {
            return AppCommands.newSubscription != nil
        }
        if item.action == #selector(toggleSidebar(_:)) {
            item.title = MacChrome.shared.isSidebarVisible ? "Hide Sidebar" : "Show Sidebar"
            return MacChrome.shared.isSidebarAvailable
        }
        return true
    }
}
#endif
