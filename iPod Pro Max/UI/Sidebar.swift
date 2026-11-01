import SwiftCrossUI

/// Same items as the SwiftUI app's `SidebarItem`.
@MainActor
enum ConnectedDeviceTitles {
    static var names: [String: String] = [:]
}

enum SidebarItem: Hashable {
    case device(String)
    case music, podcasts, audiobooks, videos, photos
    case playlist(String)

    /// Library rows, in the order the SwiftUI app shows them by default.
    static let library: [SidebarItem] = [.music, .podcasts, .audiobooks, .videos, .photos]

    /// Title of a library row; devices and playlists are titled by their name.
    @MainActor var title: String {
        switch self {
        case .device(let id): ConnectedDeviceTitles.names[id] ?? "iPod"
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
func sidebarSections(devices: [String], playlists: [Playlist]) -> [SidebarSection] {
    [
        SidebarSection(
            title: "iPods",
            rows: devices.isEmpty
                ? [.init(title: "No iPod connected", icon: "ipod", item: nil)]
                : devices.map { .init(title: ConnectedDeviceTitles.names[$0] ?? "iPod", icon: "ipod", item: .device($0), ejectable: true) }),
        SidebarSection(title: "Library", rows: SidebarItem.library.map { .init(title: $0.title, icon: $0.icon, item: $0) }),
        SidebarSection(
            title: "Playlists",
            rows: playlists.map { .init(title: $0.name, icon: "music.note.list", item: .playlist($0.id)) }
                + [.init(title: "New Playlist…", icon: "plus", item: nil)]),
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
    static let ejectTrailing = 4.0
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
