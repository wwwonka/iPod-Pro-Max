#if canImport(AppKit)
import AppKit

/// Adds "Settings…" ⌘, to the application menu, under "About". The backend rebuilds the whole menu bar
/// whenever the scene refreshes, so the item is put back each time the main menu is replaced.
@MainActor
final class AppMenuMac: NSObject, NSMenuItemValidation {
    static let shared = AppMenuMac()
    private var observation: NSKeyValueObservation?

    func install() {
        guard observation == nil else { return }
        observation = NSApplication.shared.observe(\.mainMenu, options: [.initial, .new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.addSettingsItem() }
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

    @objc private func openSettings(_ sender: Any?) { AppCommands.openSettings?() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item.action == #selector(openSettings(_:)) ? AppCommands.openSettings != nil : true
    }
}
#endif
