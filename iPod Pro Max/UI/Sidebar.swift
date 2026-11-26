import Foundation
import MediaKit
import SwiftCrossUI

/// Same items as the SwiftUI app's `SidebarItem`.
@MainActor
enum ConnectedDeviceTitles {
    static var names: [String: String] = [:]
}

enum SidebarItem: Hashable {
    case device(String)
    case music, recentMusic, artists, albums, soundtracks, classical, favorites, podcasts, recentPodcasts, audiobooks, videos, movies, tvShows, webVideos, musicVideos, photos
    /// Sections kept out of the rail, behind its "…" menu.
    case games, contacts, calendars, notes, files, firmware
    case playlist(String)
    case videoPlaylist(String)

    /// Library rows, in the order the SwiftUI app shows them by default.
    static let library: [SidebarItem] = [.music, .podcasts, .audiobooks, .videos, .photos]
    /// Sections kept out of the rail, reached from its "…" menu.
    static let otherSections: [SidebarItem] = [.games, .contacts, .calendars, .notes, .files, .firmware]

    /// The page's name in settings.json (an iPod's page isn't remembered).
    /// The album shelf this page shows, for Soundtracks and Classical.
    var albumShelf: AlbumShelf? {
        switch self {
        case .soundtracks: .soundtracks
        case .classical: .classical
        default: nil
        }
    }
    /// Pages drawn as an album cover grid.
    var isAlbumGrid: Bool { self == .albums || albumShelf != nil }

    var persistentName: String? {
        switch self {
        case .device: nil
        case .music: "music"
        case .recentMusic: "recentMusic"
        case .artists: "artists"
        case .albums: "albums"
        case .soundtracks: "soundtracks"
        case .classical: "classical"
        case .favorites: "favorites"
        case .podcasts: "podcasts"
        case .recentPodcasts: "recentPodcasts"
        case .audiobooks: "audiobooks"
        case .videos: "videos"
        case .movies: "movies"
        case .tvShows: "tvShows"
        case .webVideos: "webVideos"
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
        let all: [SidebarItem] = [.music, .recentMusic, .artists, .albums, .soundtracks, .classical, .favorites, .podcasts, .recentPodcasts, .audiobooks, .videos, .photos,
                                  .movies, .tvShows, .webVideos, .musicVideos, .games, .contacts, .calendars, .notes, .files, .firmware]
        guard let item = all.first(where: { $0.persistentName == name }) else { return nil }
        self = item
    }

    /// The library section this page belongs to (the rail's button); nil for an iPod's page.
    var media: SidebarItem? {
        switch self {
        case .music, .recentMusic, .artists, .albums, .soundtracks, .classical, .favorites, .playlist: .music
        case .videos, .movies, .tvShows, .webVideos, .musicVideos, .videoPlaylist: .videos
        case .recentPodcasts: .podcasts
        case .podcasts, .audiobooks, .photos, .games, .contacts, .calendars, .notes, .files, .firmware: self
        case .device: nil
        }
    }

    /// The section's name in the rail's labels and in the saved order.
    var railName: String {
        switch self {
        case .music: "Music"
        case .podcasts, .recentPodcasts: "Podcasts"
        case .audiobooks: "Audiobooks"
        case .videos: "Videos"
        case .movies, .tvShows, .webVideos, .musicVideos, .videoPlaylist: "Videos"
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
        case .soundtracks: "Soundtracks"
        case .classical: "Classical"
        case .favorites: "Favorites"
        case .podcasts: "Podcasts"
        case .recentPodcasts: "Recently Updated"
        case .audiobooks: "Audiobooks"
        case .videos: "Videos"
        case .movies: "Movies"
        case .tvShows: "TV Shows"
        case .webVideos: "Web Videos"
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
        case .artists: "microphone.dynamic.on.stand"
        case .albums: "square.stack"
        case .soundtracks: "film.music"
        case .classical: "music.quarternote.3"
        case .favorites: "star"
        case .podcasts: "podcasts"
        case .recentPodcasts: "clock"
        case .audiobooks: "book"
        case .videos: "film.stack"
        case .movies: "film"
        case .tvShows: "tv"
        case .webVideos: "play.tv"
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
        var isFolder = false
        var children: [Row] = []
        /// Non-nil for subscribed playlists (`SUB-3`, `SUB-4`).
        var subscriptionID: String? = nil
        var sourcePluginID: String? = nil
        var isSyncing = false
        var hasError = false
        var errorTooltip: String? = nil
    }
}

/// Applies a persisted `SidebarItem.persistentName` order to a section's rows, keeping any new
/// items at the end and ignoring obsolete identifiers.
func orderedSidebarRows(_ rows: [SidebarSection.Row], order: [String]?) -> [SidebarSection.Row] {
    guard let order, !order.isEmpty else { return rows }
    var byKey: [String: SidebarSection.Row] = [:]
    var unkeyed: [SidebarSection.Row] = []
    for row in rows {
        if let name = row.item?.persistentName { byKey[name] = row }
        else { unkeyed.append(row) }
    }
    var result: [SidebarSection.Row] = []
    result.reserveCapacity(rows.count)
    for name in order {
        if let row = byKey.removeValue(forKey: name) { result.append(row) }
    }
    for row in rows {
        if let name = row.item?.persistentName, byKey[name] != nil { result.append(row) }
    }
    result.append(contentsOf: unkeyed)
    return result
}

/// The sidebar's sections, the same on every platform.
@MainActor
func sidebarSections(devices: [String], playlists: [Playlist], videoPlaylists: [Playlist] = [], media: SidebarItem = .music, sidebarOrder: [String: [String]] = [:]) -> [SidebarSection] {
    if media == .podcasts {
        let rows = [SidebarItem.recentPodcasts, .podcasts].map {
            SidebarSection.Row(title: $0 == .podcasts ? "All Podcasts" : $0.title, icon: $0.icon, item: $0)
        }
        return [SidebarSection(title: "Podcasts", rows: orderedSidebarRows(rows, order: sidebarOrder["Podcasts"]))]
    }
    if media == .videos {
        let videoRows = [SidebarItem.movies, .tvShows, .webVideos, .musicVideos].map {
            SidebarSection.Row(title: $0.title, icon: $0.icon, item: $0)
        }
        return [
            SidebarSection(title: "Videos", rows: orderedSidebarRows(videoRows, order: sidebarOrder["Videos"])),
            SidebarSection(title: "Video Playlists", rows: videoPlaylists.map {
                .init(title: $0.name, icon: "film.stack", item: .videoPlaylist($0.id))
            }),
        ]
    }
    // Another library section: its own header and its pages, no playlists (those are music's).
    if media != .music {
        return [SidebarSection(title: media.title, rows: [.init(title: "All \(media.title)", icon: media.icon, item: media)])]
    }
    let musicRows = [SidebarItem.recentMusic, .artists, .albums, .soundtracks, .classical, .favorites, .music].map {
        // The rail shows Apple Music's own icon for Music; the list names the section's songs.
        let favoriteSymbol = ListAppearance.shared.favoriteIcon == .heart ? "heart" : "star"
        let icon = $0 == .music ? "music.note" : ($0 == .favorites ? favoriteSymbol : $0.icon)
        return SidebarSection.Row(title: $0.title, icon: icon, item: $0)
    }
    let folderIDs = Set(playlists.filter(\.isFolder).map(\.id))
    let childrenByParent = Dictionary(grouping: playlists.filter { $0.parentID != nil && folderIDs.contains($0.parentID!) }) { $0.parentID! }
    let topPlaylists = playlists.filter { $0.parentID == nil || !folderIDs.contains($0.parentID!) }
    func makePlaylistRow(_ p: Playlist) -> SidebarSection.Row {
        let sub = p.subscriptionID.flatMap { idStr -> SubscriptionEntry? in
            SubscriptionController.shared.subscription(forPlaylistID: p.id)
                ?? UUID(uuidString: idStr).flatMap { SubscriptionController.shared.subscription(id: $0) }
        }
        let isSub = p.subscriptionID != nil
        let isSyncing = isSub && SubscriptionController.shared.isSyncing(playlistID: p.id)
        let err = isSub ? sub?.lastError : nil
        return SidebarSection.Row(
            title: p.name,
            icon: p.isFolder ? "folder" : (isSub ? "playlist-lines" : "music.note.list"),
            item: .playlist(p.id),
            isFolder: p.isFolder,
            subscriptionID: p.subscriptionID,
            sourcePluginID: sub?.sourcePluginID,
            isSyncing: isSyncing,
            hasError: !(err ?? "").isEmpty,
            errorTooltip: err
        )
    }
    let playlistRows: [SidebarSection.Row] = topPlaylists.map { p in
        var row = makePlaylistRow(p)
        row.children = (childrenByParent[p.id] ?? []).map(makePlaylistRow)
        return row
    }
    return [
        SidebarSection(
            title: "iPods",
            rows: devices.isEmpty
                ? [.init(title: "No iPod connected", icon: "ipod", item: nil)]
                : devices.map { .init(title: ConnectedDeviceTitles.names[$0] ?? "iPod", icon: "ipod", item: .device($0), ejectable: true) }),
        SidebarSection(title: "Music", rows: orderedSidebarRows(musicRows, order: sidebarOrder["Music"])),
        SidebarSection(
            title: "Playlists",
            rows: orderedSidebarRows(playlistRows, order: sidebarOrder["Playlists"])),
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
    static let subHeaderHeight = 18.0
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
