import SwiftCrossUI

/// Same items as the SwiftUI app's `SidebarItem`.
@MainActor
enum ConnectedDeviceTitles {
    static var names: [String: String] = [:]
}

enum SidebarItem: Hashable {
    case device(String)
    case music, recentMusic, artists, albums, podcasts, audiobooks, videos, movies, tvShows, musicVideos, photos
    /// Sections kept out of the rail, behind its "…" menu.
    case games, contacts, calendars, notes, files, firmware
    case playlist(String)
    case videoPlaylist(String)

    /// Library rows, in the order the SwiftUI app shows them by default.
    static let library: [SidebarItem] = [.music, .podcasts, .audiobooks, .videos, .photos]
    /// Sections kept out of the rail, reached from its "…" menu.
    static let otherSections: [SidebarItem] = [.games, .contacts, .calendars, .notes, .files, .firmware]

    /// The page's name in settings.json (an iPod's page isn't remembered).
    var persistentName: String? {
        switch self {
        case .device: nil
        case .music: "music"
        case .recentMusic: "recentMusic"
        case .artists: "artists"
        case .albums: "albums"
        case .podcasts: "podcasts"
        case .audiobooks: "audiobooks"
        case .videos: "videos"
        case .movies: "movies"
        case .tvShows: "tvShows"
        case .musicVideos: "musicVideos"
        case .photos: "photos"
        case .games: "games"
        case .contacts: "contacts"
        case .calendars: "calendars"
        case .notes: "notes"
        case .files: "files"
        case .firmware: "firmware"
        case .playlist(let id): "playlist:" + id
        case .videoPlaylist(let id): "videoPlaylist:" + id
        }
    }
    init?(persistentName name: String) {
        if name.hasPrefix("playlist:") { self = .playlist(String(name.dropFirst("playlist:".count))); return }
        if name.hasPrefix("videoPlaylist:") { self = .videoPlaylist(String(name.dropFirst("videoPlaylist:".count))); return }
        let all: [SidebarItem] = [.music, .recentMusic, .artists, .albums, .podcasts, .audiobooks, .videos, .photos,
                                  .movies, .tvShows, .musicVideos, .games, .contacts, .calendars, .notes, .files, .firmware]
        guard let item = all.first(where: { $0.persistentName == name }) else { return nil }
        self = item
    }

    /// The library section this page belongs to (the rail's button); nil for an iPod's page.
    var media: SidebarItem? {
        switch self {
        case .music, .recentMusic, .artists, .albums, .playlist: .music
        case .videos, .movies, .tvShows, .musicVideos, .videoPlaylist: .videos
        case .podcasts, .audiobooks, .photos, .games, .contacts, .calendars, .notes, .files, .firmware: self
        case .device: nil
        }
    }

    /// The section's name in the rail's labels and in the saved order.
    var railName: String {
        switch self {
        case .music: "Music"
        case .podcasts: "Podcasts"
        case .audiobooks: "Audiobooks"
        case .videos: "Videos"
        case .movies, .tvShows, .musicVideos, .videoPlaylist: "Videos"
        case .photos: "Photos"
        case .games: "Games"
        case .contacts: "Contacts"
        case .calendars: "Calendars"
        case .notes: "Notes"
        case .files: "Files"
        case .firmware: "Firmware"
        default: "Section"
        }
    }

    /// Title of a library row; devices and playlists are titled by their name.
    @MainActor var title: String {
        switch self {
        case .device(let id): ConnectedDeviceTitles.names[id] ?? "iPod"
        case .music: "All Songs"
        case .recentMusic: "Recently Added"
        case .artists: "Artists"
        case .albums: "Albums"
        case .podcasts: "Podcasts"
        case .audiobooks: "Audiobooks"
        case .videos: "Videos"
        case .movies: "Movies"
        case .tvShows: "TV Shows"
        case .musicVideos: "Music Videos"
        case .photos: "Photos"
        case .games: "Games"
        case .contacts: "Contacts"
        case .calendars: "Calendars"
        case .notes: "Notes"
        case .files: "Files"
        case .firmware: "Firmware"
        case .playlist: "Playlist"
        case .videoPlaylist: "Video Playlist"
        }
    }

    var icon: String {
        switch self {
        case .device: "ipod"
        case .music: "apple-music"
        case .recentMusic: "clock"
        case .artists: "person.fill"
        case .albums: "square.stack"
        case .podcasts: "podcasts"
        case .audiobooks: "book"
        case .videos: "film.stack"
        case .movies: "film"
        case .tvShows: "tv"
        case .musicVideos: "music.note.tv"
        case .photos: "photo.on.rectangle.angled"
        case .games: "gamecontroller"
        case .contacts: "person"
        case .calendars: "calendar"
        case .notes: "long.text.page.and.pencil"
        case .files: "folder"
        case .firmware: "cpu"
        case .playlist: "music.note.list"
        case .videoPlaylist: "film.stack"
        }
    }
}

/// A section of the sidebar: a header that collapses it, then its rows.
struct SidebarSection {
    var title: String
    var rows: [Row]

    struct Row {
        var title: String
        var icon: String
        /// nil for placeholders ("No iPod connected", "New Playlist…"): dimmed, not selectable.
        var item: SidebarItem?
        /// iPods: an eject button at the row's right, as in the Finder.
        var ejectable = false
    }
}

/// The sidebar's sections, the same on every platform.
@MainActor
func sidebarSections(devices: [String], playlists: [Playlist], videoPlaylists: [Playlist] = [], media: SidebarItem = .music) -> [SidebarSection] {
    if media == .videos {
        return [
            SidebarSection(title: "Videos", rows: [SidebarItem.movies, .tvShows, .musicVideos].map {
                .init(title: $0.title, icon: $0.icon, item: $0)
            }),
            SidebarSection(title: "Video Playlists", rows: videoPlaylists.map {
                .init(title: $0.name, icon: "film.stack", item: .videoPlaylist($0.id))
            }),
        ]
    }
    // Another library section: its own header and its pages, no playlists (those are music's).
    if media != .music {
        return [SidebarSection(title: media.title, rows: [.init(title: "All \(media.title)", icon: media.icon, item: media)])]
    }
    return [
        SidebarSection(
            title: "iPods",
            rows: devices.isEmpty
                ? [.init(title: "No iPod connected", icon: "ipod", item: nil)]
                : devices.map { .init(title: ConnectedDeviceTitles.names[$0] ?? "iPod", icon: "ipod", item: .device($0), ejectable: true) }),
        SidebarSection(title: "Music", rows: [SidebarItem.recentMusic, .music, .artists, .albums].map {
            // The rail shows Apple Music's own icon for Music; the list names the section's songs.
            .init(title: $0.title, icon: $0 == .music ? "music.quarternote.3" : $0.icon, item: $0)
        }),
        SidebarSection(
            title: "Playlists",
            rows: playlists.map { .init(title: $0.name, icon: "music.note.list", item: .playlist($0.id)) }),
    ]
}

/// macOS's source-list sidebar at the default ("Medium") sidebar icon size, measured from an
/// NSOutlineView: GTK and WinUI draw theirs to these numbers. Points, from the sidebar's left edge.
enum SidebarMetrics {
    /// Below the title area, before the first header.
    static let topGap = 10.0
    /// Above every other header.
    static let sectionGap = 13.0
    static let headerHeight = 19.0
    static let headerTextX = 14.0
    static let headerFontSize = 11.0
    /// The library's big title (macOS): 17 pt was a little small.
    static let titleFontSize = 19.0
    /// A sub-section's native caption (Playlists): its row, and where its text starts.
    static let subHeaderHeight = 30.0
    static let subHeaderTextX = 6.0
    /// How far a section's big title (macOS) is raised from its row's center, to line up with the
    /// rail's top icon.
    static let headerLift = 2.25
    /// The collapse chevron, at the header's right.
    static let chevronWidth = 15.0
    static let chevronTrailing = 10.0
    static let rowHeight = 28.0
    static let rowFontSize = 13.0
    static let iconX = 18.0
    static let iconWidth = 22.0
    static let textX = 44.0
    /// The selection's rounded rectangle, inset from both sides.
    static let selectionInset = 10.0
    static let selectionRadius = 6.0
    /// Expand and collapse.
    static let collapseDuration = 0.25
    /// The eject button: glyph size, square hit area, and its distance from the selection's edge.
    static let ejectPointSize = 10.0
    static let ejectSize = 20.0
    static let ejectTrailing = 1.0
}

/// Translucent neutral selection, calibrated against Finder on a tinted sidebar.
/// Blending over the sidebar preserves its glass or wallpaper tint.
func sidebarSelectionRGBA(dark: Bool) -> (r: UInt8, g: UInt8, b: UInt8, alpha: Double) {
    let component: UInt8 = dark ? 255 : 0
    return (component, component, component, 0.14)
}

/// The SwiftUI sidebar's selection when the list isn't focused: a neutral gray, not the accent color.
let sidebarSelection = Color.adaptive(
    light: Color(white: 0, opacity: 0.1),
    dark: Color(white: 1, opacity: 0.1)
)
