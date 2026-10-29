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

/// The SwiftUI sidebar's selection when the list isn't focused: a neutral gray, not the accent color.
let sidebarSelection = Color.adaptive(
    light: Color(white: 0, opacity: 0.1),
    dark: Color(white: 1, opacity: 0.1)
)
