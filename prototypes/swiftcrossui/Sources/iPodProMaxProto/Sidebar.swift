import SwiftCrossUI

/// Same items as the SwiftUI app's `SidebarItem`.
enum SidebarItem: Hashable {
    case device(String)
    case music, podcasts, audiobooks, videos, photos
    case playlist(String)

    /// Library rows, in the order the SwiftUI app shows them by default.
    static let library: [SidebarItem] = [.music, .podcasts, .audiobooks, .videos, .photos]

    /// Title of a library row; devices and playlists are titled by their name.
    var title: String {
        switch self {
        case .device(let name): name
        case .music: "Music"
        case .podcasts: "Podcasts"
        case .audiobooks: "Audiobooks"
        case .videos: "Videos"
        case .photos: "Photos"
        case .playlist: "Playlist"
        }
    }

    var icon: String {
        switch self {
        case .device: "ipod"
        case .music: "music.note"
        case .podcasts: "antenna.radiowaves.left.and.right"
        case .audiobooks: "book"
        case .videos: "film"
        case .photos: "photo.on.rectangle.angled"
        case .playlist: "music.note.list"
        }
    }
}

#if !canImport(AppKitBackend) && !canImport(GtkBackend)
/// Off macOS (see SidebarMac.swift for the native one). Drawn by hand rather than with `List`: SwiftCrossUI's list has no sections, and a hand-drawn
/// sidebar looks the same on every backend.
struct Sidebar: View {
    @Binding var devices: [String]
    @Binding var library: Library?
    @Binding var selection: SidebarItem

    private var playlists: [Playlist] { library?.playlists ?? [] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header("iPods")
                if devices.isEmpty {
                    SidebarRow(title: "No iPod connected", icon: "ipod", tint: .secondary, dimmed: true)
                } else {
                    ForEach(devices, id: \.self) { name in
                        row(.device(name))
                    }
                }
                header("Library")
                ForEach(SidebarItem.library, id: \.self) { item in
                    row(item)
                }
                header("Playlists")
                ForEach(playlists) { playlist in
                    row(.playlist(playlist.id), title: playlist.name)
                }
                SidebarRow(title: "New Playlist…", icon: "plus", tint: .secondary, dimmed: true)
            }
            .padding(.horizontal, 10)
            .padding(.top, drawsWindowControls ? 52 : 10)
            .padding(.bottom, 10)
        }
        .frame(minWidth: 200)
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.gray)
            .padding(.leading, 6)
            .padding(.top, 14)
            .padding(.bottom, 4)
    }

    private func row(_ item: SidebarItem, title: String? = nil) -> some View {
        SidebarRow(title: title ?? item.title, icon: item.icon, isSelected: selection == item)
            .onTapGesture { selection = item }
    }
}

struct SidebarRow: View {
    var title: String
    var icon: String
    var tint: SymbolTint = .accent
    var isSelected = false
    var dimmed = false

    var body: some View {
        HStack(spacing: 7) {
            Symbol(name: icon, size: 18, pointSize: 14, tint: tint)
            if dimmed {
                Text(title).font(.system(size: 13)).foregroundColor(.gray)
            } else {
                Text(title).font(.system(size: 13))
            }
            Spacer()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        // Near-transparent rather than clear so the whole row, not only its text, takes clicks.
        .background(isSelected ? sidebarSelection : Color(white: 0.5, opacity: 0.001))
        .cornerRadius(6)
    }
}

#endif

/// The SwiftUI sidebar's selection when the list isn't focused: a neutral gray, not the accent color.
let sidebarSelection = Color.adaptive(
    light: Color(white: 0, opacity: 0.1),
    dark: Color(white: 1, opacity: 0.1)
)
