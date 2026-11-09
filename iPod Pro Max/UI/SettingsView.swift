import Foundation
import SwiftCrossUI
#if canImport(AppKitBackend)
import AppKit
#endif

/// The accent the app draws selections with: the system accent on macOS (as the sidebar and the
/// player do), the app's blue elsewhere.
enum AppAccent {
    static var color: Color {
        #if canImport(AppKitBackend)
        var resolved = Color(red: 0.04, green: 0.52, blue: 1)
        if let c = NSColor.controlAccentColor.usingColorSpace(.sRGB) {
            resolved = Color(red: Double(c.redComponent), green: Double(c.greenComponent), blue: Double(c.blueComponent))
        }
        return resolved
        #else
        return MacColor.accent
        #endif
    }
}

/// The tabs of the Settings window, in the order of the toolbar.
enum SettingsTab: String, CaseIterable {
    case general = "General"
    case playback = "Playback"
    case syncing = "Syncing"
    case devices = "Devices"
    case plugins = "Plug-ins"
    case advanced = "Advanced"

    var symbol: String {
        switch self {
        case .general: "gear"
        case .playback: "play.circle"
        case .syncing: "ipod"
        case .devices: "desktopcomputer"
        case .plugins: "puzzlepiece.extension"
        case .advanced: "wrench.and.screwdriver"
        }
    }
}

/// The Settings window (⌘, / Settings…): a second scene of the app, with the layout people know
/// from Mac preferences (a row of icon tabs, then grouped settings). It never polls: the shared
/// `SettingsController` calls back when the main window attaches a library or a value changes.
/// Folders are chosen here, in this window; the main window only does the resulting work.
struct SettingsView: View {
    @Environment(\.chooseFile) private var chooseFile
    @State private var revision = 0
    @State private var tab: SettingsTab = .general
    @State private var hoveredTab: SettingsTab?

    var body: some View {
        let _ = revision  // re-render when the controller reports a change
        VStack(spacing: 0) {
            tabBar
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    switch tab {
                    case .general: general
                    case .syncing: syncing
                    case .playback: empty("Playback settings will appear here.")
                    case .devices: empty("Settings for each connected iPod will appear here.")
                    case .plugins: empty("No plug-ins installed.")
                    case .advanced: empty("No advanced settings yet.")
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(width: 540, height: 540)
        .settingsWindowChrome(title: tab.rawValue)
        .task {
            SettingsController.shared.onChange = { revision += 1 }
        }
    }

    // MARK: Tabs

    /// Like the toolbar of a Mac preferences window: each item hugs its icon and label, the selected
    /// one is highlighted and the others light up under the pointer.
    private var tabBar: some View {
        // No gap between the items: each one carries 1 pt of margin on both sides, inside its hover and
        // click area, so the pointer is always over some tab, as in a native toolbar.
        HStack(spacing: 0) {
            ForEach(SettingsTab.allCases, id: \.self) { item in
                let selected = item == tab
                let hovered = item == hoveredTab
                // Icon and label sit close together, as in a native toolbar item.
                VStack(spacing: 1) {
                    Symbol(name: item.symbol, size: 22, pointSize: 19, tint: selected ? .accent : .secondary)
                    Text(item.rawValue)
                        .font(.system(size: 11))
                        .foregroundColor(selected ? AppAccent.color : MacColor.secondaryText)
                }
                .frame(width: Double(item.rawValue.count) * 6.4 + 16)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 7)
                    .fill(Color(white: 1, opacity: selected ? 0.11 : (hovered ? 0.07 : 0))))
                .padding(.horizontal, 1)
                .onHover { inside in
                    if inside { hoveredTab = item } else if hoveredTab == item { hoveredTab = nil }
                }
                .onTapGesture { tab = item }
            }
        }
        .padding(.top, 30)  // under the traffic lights and the title
        .padding(.bottom, 2)
        .frame(maxWidth: .infinity)
    }

    // MARK: General

    private var general: some View {
        VStack(alignment: .leading, spacing: 26) {
            if !SettingsController.shared.hasLibrary {
                Caption("Open an iPod library to see its folders.")
            }
            group("Music") { folders(kind: "music", picker: "Choose Music Folder") }
            group("Podcasts") {
                note("Subscriptions and downloads are kept with the library.")
            }
            group("Audiobooks") { folders(kind: "audiobooks", picker: "Choose Audiobooks Folder") }
            // One level down: the section, then a small titled card for each kind of video.
            VStack(alignment: .leading, spacing: 14) {
                Text("Videos").font(.system(size: 14, weight: .semibold)).padding(.leading, 2)
                subgroup("Movies", kind: "movies", picker: "Choose Movies Folder")
                subgroup("TV Shows", kind: "tvShows", picker: "Choose TV Shows Folder")
                subgroup("Music Videos", kind: "musicVideos", picker: "Choose Music Videos Folder")
                subgroup("Web Videos", kind: "webVideos", picker: "Choose Web Videos Folder")
            }
            group("Photos") { folders(kind: "photos", picker: "Choose a Folder of Pictures") }
        }
    }

    /// The folders of one kind: a row each (the path, Remove), then a row ending with Add Folder.
    private func folders(kind: String, picker: String) -> some View {
        let controller = SettingsController.shared
        let mine = controller.sources.filter { $0.kind == kind }
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(mine.enumerated()), id: \.offset) { index, source in
                if index > 0 { Divider() }
                HStack {
                    Text(source.path).font(.system(size: 12))
                    Spacer()
                    Button("Remove") { AppCommands.removeSource?(source.id) }
                        .buttonStyle(.borderless)
                        .foregroundColor(MacColor.secondaryText)
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
            }
            if !mine.isEmpty { Divider() }
            HStack {
                if mine.isEmpty { Text("No folder added yet.").foregroundColor(MacColor.secondaryText) }
                Spacer()
                Button("Add Folder…") { choose(kind, title: picker) }
                    .disabled(!controller.hasLibrary)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
        }
    }

    /// Picks a folder in this window (not the main one) and hands it to the main window's library.
    private func choose(_ kind: String, title: String) {
        Task {
            guard let folder = await chooseFile(title: title, defaultButtonLabel: "Add Folder",
                allowSelectingFiles: false, allowSelectingDirectories: true) else { return }
            AppCommands.addSource?(kind, folder)
        }
    }

    // MARK: Syncing

    private var syncing: some View {
        let controller = SettingsController.shared
        return group("Syncing") {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Sync album artwork")
                    Spacer()
                    Toggle("", isOn: Binding(get: { controller.syncArtwork }, set: { controller.setSyncArtwork($0) }))
                        .toggleStyle(.switch)
                        .disabled(!controller.hasLibrary)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                Divider()
                note("Artwork is converted to the iPod's native thumbnail sizes during each sync.")
            }
        }
    }

    // MARK: Pieces

    /// A titled card, as in Mac settings: the title above, rows inside a lightly filled, outlined box.
    private func group<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 14, weight: .semibold)).padding(.leading, 2)
            card(content)
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ZStack {
                RoundedRectangle(cornerRadius: 8).fill(MacColor.groupFill)
                RoundedRectangle(cornerRadius: 8).stroke(MacColor.groupBorder)
            })
    }

    /// A smaller titled card under a section title (the kinds of video).
    private func subgroup(_ title: String, kind: String, picker: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundColor(MacColor.secondaryText).padding(.leading, 4)
            card { folders(kind: kind, picker: picker) }
        }
    }

    private func note(_ text: String) -> some View {
        Caption(text).padding(.horizontal, 12).padding(.vertical, 9)
    }

    private func empty(_ text: String) -> some View {
        Text(text).foregroundColor(MacColor.secondaryText)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 60)
    }
}
