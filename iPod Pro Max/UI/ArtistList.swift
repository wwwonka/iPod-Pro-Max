import Foundation
import SwiftCrossUI

// The "By Artist" list: a native, virtualized list on each platform, like the track table.
// SwiftCrossUI's List made a view per artist and asked for the height of all of them, which
// became the window's minimum height: switching modes resized the window to over 1,200 pt and
// kept it there.

#if canImport(AppKitBackend)
    import AppKit
    import AppKitBackend
    import ImageIO

    struct ArtistList: NSViewRepresentable {
        var artists: [NamedGroup]
        var tracksByArtist: [String: [TrackRow]]
        @Binding var selection: String?

        func makeCoordinator() -> Coordinator { Coordinator() }

        func makeNSView(context: Context) -> NSScrollView {
            let table = NSTableView()
            if #available(macOS 11, *) { table.style = .plain }
            table.headerView = nil
            table.rowHeight = 46
            table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("artist")))
            table.dataSource = context.coordinator
            table.delegate = context.coordinator
            table.setDraggingSourceOperationMask(.copy, forLocal: true)
            let scroll = NSScrollView()
            scroll.documentView = table
            scroll.hasVerticalScroller = true
            scroll.drawsBackground = false
            return scroll
        }

        func updateNSView(_ scroll: NSScrollView, context: Context) {
            guard let table = scroll.documentView as? NSTableView else { return }
            let coordinator = context.coordinator
            coordinator.onSelect = { selection = $0 }
            coordinator.tracksByArtist = tracksByArtist
            if !coordinator.artists.sameStorage(as: artists) {
                coordinator.artists = artists
                // Photos arrive while an artist is selected: reloading must not look like the user deselecting it.
                coordinator.isSyncing = true
                table.reloadData()
                coordinator.isSyncing = false
            }
            let row = selection.flatMap { name in artists.firstIndex { $0.id == name } } ?? -1
            if table.selectedRow != row {
                coordinator.isSyncing = true
                if row >= 0 { table.selectRowIndexes([row], byExtendingSelection: false) } else { table.deselectAll(nil) }
                coordinator.isSyncing = false
            }
        }

        func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> ViewSize {
            ViewSize(proposal.width ?? 250, proposal.height ?? 400)
        }

        final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
            var artists: [NamedGroup] = []
            var tracksByArtist: [String: [TrackRow]] = [:]
                var onSelect: (String?) -> Void = { _ in }
            var isSyncing = false
            private let thumbnails = NSCache<NSString, NSImage>()

            /// A 68 px round-ready thumbnail of the cover, decoded once.
            private func thumbnail(_ photo: URL?) -> NSImage? {
                guard let photo else { return nil }
                let key = photo.path
                if let cached = thumbnails.object(forKey: key as NSString) { return cached }
                let url = photo as CFURL
                guard let source = CGImageSourceCreateWithURL(url, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 68,
                        kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
                let result = NSImage(cgImage: image, size: NSSize(width: 34, height: 34))
                thumbnails.setObject(result, forKey: key as NSString)
                return result
            }

            private var dragPayload: String?
            func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
                guard artists.indices.contains(row) else { return nil }
                if dragPayload == nil { dragPayload = TrackDrag.begin((tracksByArtist[artists[row].id] ?? []).map(\.id)) }
                guard let dragPayload else { return nil }
                let item = NSPasteboardItem()
                item.setString(dragPayload, forType: .string)
                return item
            }
            func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
                dragPayload = nil
                TrackDrag.end()
            }

            func numberOfRows(in tableView: NSTableView) -> Int { artists.count }

            func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
                let id = NSUserInterfaceItemIdentifier("artistCell")
                let cell = tableView.makeView(withIdentifier: id, owner: nil) as? ArtistCell ?? ArtistCell(id: id)
                let artist = artists[row]
                cell.name.stringValue = artist.id
                cell.count.stringValue = "\(artist.albumCount) album\(artist.albumCount == 1 ? "" : "s") · \(artist.count) song\(artist.count == 1 ? "" : "s")"
                cell.photo.image = thumbnail(artist.photo)
                cell.placeholder.isHidden = cell.photo.image != nil
                return cell
            }

            func tableViewSelectionDidChange(_ notification: Notification) {
                guard !isSyncing, let table = notification.object as? NSTableView else { return }
                onSelect(table.selectedRow >= 0 ? artists[table.selectedRow].id : nil)
            }
        }

        /// A round cover, the artist's name, and "N albums · M songs" in gray under it.
        final class ArtistCell: NSTableCellView {
            let photo = NSImageView()
            let placeholder = NSImageView()
            let name = NSTextField(labelWithString: "")
            let count = NSTextField(labelWithString: "")

            init(id: NSUserInterfaceItemIdentifier) {
                super.init(frame: .zero)
                identifier = id
                for view in [photo, placeholder] {
                    view.wantsLayer = true
                    view.layer?.cornerRadius = 17
                    view.layer?.masksToBounds = true
                    view.translatesAutoresizingMaskIntoConstraints = false
                    addSubview(view)
                }
                photo.imageScaling = .scaleProportionallyUpOrDown
                placeholder.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
                if #available(macOS 11, *) {
                    placeholder.image = NSImage(systemSymbolName: "music.mic", accessibilityDescription: nil)
                    placeholder.symbolConfiguration = .init(pointSize: 14, weight: .regular)
                }
                placeholder.contentTintColor = .secondaryLabelColor
                name.lineBreakMode = .byTruncatingTail
                count.lineBreakMode = .byTruncatingTail
                count.font = .systemFont(ofSize: 11)
                count.textColor = .secondaryLabelColor
                for field in [name, count] {
                    field.translatesAutoresizingMaskIntoConstraints = false
                    addSubview(field)
                    field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                }
                NSLayoutConstraint.activate([
                    photo.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
                    photo.centerYAnchor.constraint(equalTo: centerYAnchor),
                    photo.widthAnchor.constraint(equalToConstant: 34), photo.heightAnchor.constraint(equalToConstant: 34),
                    placeholder.leadingAnchor.constraint(equalTo: photo.leadingAnchor),
                    placeholder.centerYAnchor.constraint(equalTo: centerYAnchor),
                    placeholder.widthAnchor.constraint(equalToConstant: 34), placeholder.heightAnchor.constraint(equalToConstant: 34),
                    name.leadingAnchor.constraint(equalTo: photo.trailingAnchor, constant: 10),
                    name.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
                    name.bottomAnchor.constraint(equalTo: centerYAnchor, constant: 1),
                    count.leadingAnchor.constraint(equalTo: name.leadingAnchor),
                    count.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
                    count.topAnchor.constraint(equalTo: centerYAnchor, constant: 1),
                ])
            }

            required init?(coder: NSCoder) { fatalError() }
        }
    }
#elseif canImport(GtkBackend)
    import CGtk
    import Gtk
    import GtkBackend

    /// A GtkListView over a string list of the names; cells read the counts from a Swift array.
    struct ArtistList: GtkWidgetRepresentable {
        var artists: [NamedGroup]
        var tracksByArtist: [String: [TrackRow]]
        @Binding var selection: String?

        func makeCoordinator() -> Coordinator { Coordinator() }

        func makeGtkWidget(context: Context) -> Gtk.Widget {
            let coordinator = context.coordinator
            // The selection takes the model's reference (transfer full): give it one of its own.
            g_object_ref(cast(coordinator.model))
            let selectionModel = gtk_single_selection_new(cast(coordinator.model))!
            gtk_single_selection_set_autoselect(selectionModel, 0)
            gtk_single_selection_set_can_unselect(selectionModel, 1)
            coordinator.selectionModel = selectionModel
            // Each handler owns a weak reference to the coordinator; GLib releases it with the handler,
            // so a signal after the view is gone finds nothing rather than a freed object.
            g_signal_connect_data(cast(selectionModel), "notify::selected", unsafeBitCast(artistSelected, to: GCallback.self),
                                  ArtistBinding.retained(coordinator), releaseArtistBinding, GConnectFlags(rawValue: 0))
            let factory = gtk_signal_list_item_factory_new()
            g_signal_connect_data(cast(factory), "setup", unsafeBitCast(setupArtist, to: GCallback.self), nil, nil, GConnectFlags(rawValue: 0))
            g_signal_connect_data(cast(factory), "bind", unsafeBitCast(bindArtist, to: GCallback.self),
                                  ArtistBinding.retained(coordinator), releaseArtistBinding, GConnectFlags(rawValue: 0))
            let list = gtk_list_view_new(cast(selectionModel), factory)!
            let drag = gtk_drag_source_new()!
            gtk_drag_source_set_actions(drag, GDK_ACTION_COPY)
            g_signal_connect_data(cast(drag), "prepare", unsafeBitCast(prepareArtistDrag, to: GCallback.self),
                ArtistBinding.retained(coordinator), releaseArtistBinding, GConnectFlags(rawValue: 0))
            g_signal_connect_data(cast(drag), "drag-end", unsafeBitCast(endArtistDrag, to: GCallback.self), nil, nil, GConnectFlags(rawValue: 0))
            g_signal_connect_data(cast(drag), "drag-begin", unsafeBitCast(beginArtistDrag, to: GCallback.self), nil, nil, GConnectFlags(rawValue: 0))
            gtk_widget_add_controller(list, cast(drag))
            let scroll = gtk_scrolled_window_new()!
            gtk_scrolled_window_set_policy(cast(scroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
            gtk_scrolled_window_set_child(cast(scroll), list)
            return Gtk.Widget(scroll)
        }

        func updateGtkWidget(_ widget: Gtk.Widget, context: Context) {
            let coordinator = context.coordinator
            coordinator.onSelect = { selection = $0 }
            coordinator.tracksByArtist = tracksByArtist
            coordinator.show(artists)
            let position = selection.flatMap { name in artists.firstIndex { $0.id == name } }.map(UInt32.init)
                ?? UInt32.max  // GTK_INVALID_LIST_POSITION
            if let model = coordinator.selectionModel, gtk_single_selection_get_selected(model) != position {
                coordinator.isSyncing = true
                gtk_single_selection_set_selected(model, position)
                coordinator.isSyncing = false
            }
        }

        func sizeThatFits(_ proposal: ProposedViewSize, gtkWidget: Gtk.Widget, context: Context) -> ViewSize {
            ViewSize(proposal.width ?? 250, proposal.height ?? 400)
        }

        @MainActor
        final class Coordinator {
            let model = gtk_string_list_new(nil)!
            var selectionModel: OpaquePointer?
            var artists: [NamedGroup] = []
            var tracksByArtist: [String: [TrackRow]] = [:]
                var onSelect: (String?) -> Void = { _ in }
            var isSyncing = false

            func show(_ newArtists: [NamedGroup]) {
                guard !artists.sameStorage(as: newArtists) else { return }
                let old = artists.count
                artists = newArtists
                let names = newArtists.map { strdup($0.id) }
                defer { names.forEach { free($0) } }
                var items = names.map { UnsafePointer($0) } + [nil]
                // Replacing the items drops the selection: not the user's doing.
                isSyncing = true
                items.withUnsafeMutableBufferPointer {
                    gtk_string_list_splice(model, 0, UInt32(old), $0.baseAddress)
                }
                isSyncing = false
            }

            fileprivate func selectionChanged() {
                guard !isSyncing, let selectionModel else { return }
                let position = Int(gtk_single_selection_get_selected(selectionModel))
                onSelect(position < artists.count ? artists[position].id : nil)
            }

            deinit {
                g_object_unref(cast(model))
            }
        }
    }

    final class ArtistBinding {
        weak var coordinator: ArtistList.Coordinator?

        static func retained(_ coordinator: ArtistList.Coordinator) -> UnsafeMutableRawPointer {
            let binding = ArtistBinding()
            binding.coordinator = coordinator
            return Unmanaged.passRetained(binding).toOpaque()
        }
    }

    private let releaseArtistBinding: @convention(c) (gpointer?, UnsafeMutablePointer<GClosure>?) -> Void = { data, _ in
        guard let data else { return }
        Unmanaged<ArtistBinding>.fromOpaque(data).release()
    }

    private let setupArtist: @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { _, item, _ in
        MainActor.assumeIsolated { installArtistCSS() }
        let box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 10)!
        gtk_widget_set_margin_start(box, 8)
        gtk_widget_set_margin_end(box, 8)
        gtk_widget_set_margin_top(box, 4)
        gtk_widget_set_margin_bottom(box, 4)
        // The round cover; a gray disc when the artist has none.
        let photo = gtk_image_new()!
        gtk_image_set_pixel_size(cast(photo), 34)
        gtk_widget_set_size_request(photo, 34, 34)
        gtk_widget_set_overflow(photo, GTK_OVERFLOW_HIDDEN)
        gtk_widget_add_css_class(photo, "ippm-artist-photo")
        let text = gtk_box_new(GTK_ORIENTATION_VERTICAL, 1)!
        gtk_widget_set_valign(text, GTK_ALIGN_CENTER)
        gtk_widget_set_hexpand(text, 1)
        let name = gtk_label_new(nil)!
        gtk_label_set_xalign(cast(name), 0)
        gtk_label_set_ellipsize(cast(name), PANGO_ELLIPSIZE_END)
        let count = gtk_label_new(nil)!
        gtk_label_set_xalign(cast(count), 0)
        gtk_label_set_ellipsize(cast(count), PANGO_ELLIPSIZE_END)
        gtk_widget_add_css_class(count, "dim-label")
        gtk_widget_add_css_class(count, "caption")
        gtk_box_append(cast(text), name)
        gtk_box_append(cast(text), count)
        gtk_box_append(cast(box), photo)
        gtk_box_append(cast(box), text)
        gtk_list_item_set_child(cast(item), box)
    }

    @MainActor private var artistCSSInstalled = false
    @MainActor private func installArtistCSS() {
        guard !artistCSSInstalled else { return }
        artistCSSInstalled = true
        let provider = gtk_css_provider_new()!
        loadCSS(provider, ".ippm-artist-photo { border-radius: 17px; background-color: alpha(currentColor, 0.12); }")
        gtk_style_context_add_provider_for_display(gdk_display_get_default(), cast(provider), 800)
    }

    private let bindArtist: @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { _, item, data in
        guard let data, let box = gtk_list_item_get_child(cast(item)),
              let photo = gtk_widget_get_first_child(box), let text = gtk_widget_get_next_sibling(photo),
              let name = gtk_widget_get_first_child(text), let count = gtk_widget_get_next_sibling(name) else { return }
        let position = Int(gtk_list_item_get_position(cast(item)))
        MainActor.assumeIsolated {
            guard let coordinator = Unmanaged<ArtistBinding>.fromOpaque(data).takeUnretainedValue().coordinator,
                  position < coordinator.artists.count else { return }
            let artist = coordinator.artists[position]
            gtk_label_set_text(cast(name), artist.id)
            gtk_label_set_text(cast(count), "\(artist.albumCount) album\(artist.albumCount == 1 ? "" : "s") · \(artist.count) song\(artist.count == 1 ? "" : "s")")
            if let file = artist.photo {
                gtk_image_set_from_file(cast(photo), file.path)
            } else {
                gtk_image_clear(cast(photo))
            }
        }
    }

    private let prepareArtistDrag: @convention(c) (OpaquePointer?, Double, Double, gpointer?) -> UnsafeMutablePointer<GdkContentProvider>? = { _, _, _, data in
        guard let data else { return nil }
        return MainActor.assumeIsolated {
            guard let c = Unmanaged<ArtistBinding>.fromOpaque(data).takeUnretainedValue().coordinator,
                  let model = c.selectionModel else { return nil }
            let row = Int(gtk_single_selection_get_selected(model))
            guard c.artists.indices.contains(row),
                  let payload = TrackDrag.begin((c.tracksByArtist[c.artists[row].id] ?? []).map(\.id)) else { return nil }
            var value = GValue()
            g_value_init(&value, g_type_from_name("gchararray"))
            g_value_set_string(&value, payload)
            defer { g_value_unset(&value) }
            return gdk_content_provider_new_for_value(&value)
        }
    }
    private let beginArtistDrag: @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { _, drag, _ in
        MainActor.assumeIsolated { showMusicDragCount(drag) }
    }
    private let endArtistDrag: @convention(c) (OpaquePointer?, OpaquePointer?, gboolean, gpointer?) -> Void = { _, _, _, _ in
        MainActor.assumeIsolated { TrackDrag.end() }
    }

    private let artistSelected: @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { _, _, data in
        guard let data else { return }
        MainActor.assumeIsolated {
            Unmanaged<ArtistBinding>.fromOpaque(data).takeUnretainedValue().coordinator?.selectionChanged()
        }
    }
#elseif canImport(WinUIBackend)
    import UWP
    import WindowsFoundation
    import WinUI
    import WinUIBackend

    /// A ListView of rows with the name and, in gray at the right, the song count.
    struct ArtistList: WinUIElementRepresentable {
        var artists: [NamedGroup]
        var tracksByArtist: [String: [TrackRow]]
        @SwiftCrossUI.Binding var selection: String?

        func makeCoordinator() -> Coordinator { Coordinator() }

        func makeWinUIElement(context: Context) -> ListView {
            let list = ListView()
            list.selectionMode = .single
            list.canDragItems = true
            list.dragItemsStarting.addHandler { [weak coordinator = context.coordinator, weak list] _, args in
                guard let coordinator, let list, let args else { return }
                MainActor.assumeIsolated {
                    let row = Int(list.selectedIndex)
                    guard coordinator.artists.indices.contains(row),
                          let payload = TrackDrag.begin((coordinator.tracksByArtist[coordinator.artists[row].id] ?? []).map(\.id))
                    else { args.cancel = true; return }
                    do { try args.data.setText(payload) } catch { TrackDrag.end(); args.cancel = true; return }
                    args.data.requestedOperation = .copy
                    args.data.properties.title = "\(TrackDrag.ids.count) songs"
                }
            }
            list.dragItemsCompleted.addHandler { _, _ in MainActor.assumeIsolated { TrackDrag.end() } }
            list.selectionChanged.addHandler { [weak coordinator = context.coordinator, weak list] _, _ in
                guard let list else { return }
                MainActor.assumeIsolated { coordinator?.selectionChanged(Int(list.selectedIndex)) }
            }
            return list
        }

        func updateWinUIElement(_ list: ListView, context: Context) {
            let coordinator = context.coordinator
            coordinator.onSelect = { selection = $0 }
            coordinator.tracksByArtist = tracksByArtist
            if !coordinator.artists.sameStorage(as: artists) {
                coordinator.artists = artists
                coordinator.isSyncing = true
                list.items.clear()
                for artist in artists { list.items.append(Self.row(artist)) }
                coordinator.isSyncing = false
            }
            let index = Int32(selection.flatMap { name in artists.firstIndex { $0.id == name } } ?? -1)
            if list.selectedIndex != index {
                coordinator.isSyncing = true
                list.selectedIndex = index
                coordinator.isSyncing = false
            }
        }

        func sizeThatFits(_ proposal: ProposedViewSize, winUIElement: ListView, context: Context) -> ViewSize {
            ViewSize(proposal.width ?? 250, proposal.height ?? 400)
        }

        private static func row(_ artist: NamedGroup) -> ListViewItem {
            let grid = WinUI.Grid()
            for width in [GridLength(value: 34, gridUnitType: .pixel), GridLength(value: 1, gridUnitType: .star)] {
                let column = ColumnDefinition()
                column.width = width
                grid.columnDefinitions.append(column)
            }
            grid.columnSpacing = 10
            grid.padding = Thickness(left: 0, top: 4, right: 0, bottom: 4)
            // The round cover, over a gray disc.
            let photo = Border()
            photo.width = 34
            photo.height = 34
            photo.cornerRadius = CornerRadius(topLeft: 17, topRight: 17, bottomRight: 17, bottomLeft: 17)
            photo.background = SolidColorBrush(UWP.Color(a: 40, r: 128, g: 128, b: 128))
            if let file = artist.photo {
                let image = WinUI.Image()
                image.stretch = .uniformToFill
                let bitmap = BitmapImage(WindowsFoundation.Uri(file.absoluteString))
                bitmap.decodePixelWidth = 68
                image.source = bitmap
                photo.child = image
            }
            WinUI.Grid.setColumn(photo, 0)
            let text = StackPanel()
            text.verticalAlignment = .center
            let name = TextBlock()
            name.text = artist.id
            name.textTrimming = .characterEllipsis
            let count = TextBlock()
            count.text = "\(artist.albumCount) album\(artist.albumCount == 1 ? "" : "s") · \(artist.count) song\(artist.count == 1 ? "" : "s")"
            count.fontSize = 11
            count.opacity = 0.55
            count.textTrimming = .characterEllipsis
            text.children.append(name)
            text.children.append(count)
            WinUI.Grid.setColumn(text, 1)
            grid.children.append(photo)
            grid.children.append(text)
            let item = ListViewItem()
            item.content = grid
            item.horizontalContentAlignment = .stretch
            return item
        }

        @MainActor
        final class Coordinator {
            var artists: [NamedGroup] = []
            var tracksByArtist: [String: [TrackRow]] = [:]
            var onSelect: (String?) -> Void = { _ in }
            var isSyncing = false

            func selectionChanged(_ index: Int) {
                guard !isSyncing else { return }
                onSelect(index >= 0 && index < artists.count ? artists[index].id : nil)
            }
        }
    }
#endif
