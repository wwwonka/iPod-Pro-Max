#if canImport(AppKitBackend)
    import AppKit
    import AppKitBackend
    import SwiftCrossUI

    /// On macOS the sidebar is a real source-list NSOutlineView, like the one SwiftUI's
    /// `List(.sidebar)` makes: row height, fonts and icon size follow the "Sidebar icon size"
    /// setting, icons take the accent color, and selection looks native. Clicks don't go through
    /// SwiftCrossUI's layout, which keeps them cheap.
    struct Sidebar: NSViewRepresentable {
        // Bindings, not values: SwiftCrossUI hands a native view's updates the values it was
        // created with, so the playlists loaded later never showed.
        @Binding var devices: [String]
        @Binding var library: Library?
        @Binding var selection: SidebarItem

        private var playlists: [Playlist] { library?.playlists ?? [] }

        func makeCoordinator() -> Coordinator { Coordinator() }

        func makeNSView(context: Context) -> NSScrollView {
            let outline = NSOutlineView()
            outline.style = .sourceList
            outline.headerView = nil
            outline.floatsGroupRows = false
            outline.rowSizeStyle = .default
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
            outline.addTableColumn(column)
            outline.outlineTableColumn = column
            outline.dataSource = context.coordinator
            outline.delegate = context.coordinator

            let scroll = NSScrollView()
            scroll.documentView = outline
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            // Starts below the toolbar the traffic lights sit in, as SwiftUI's sidebar does.
            scroll.automaticallyAdjustsContentInsets = true
            return scroll
        }

        func updateNSView(_ scroll: NSScrollView, context: Context) {
            guard let outline = scroll.documentView as? NSOutlineView else { return }
            let coordinator = context.coordinator
            coordinator.onSelect = { item in selection = item }
            let key = devices + ["|"] + playlists.map { $0.id + $0.name }
            if key != coordinator.key {
                coordinator.key = key
                coordinator.sections = Self.sections(devices: devices, playlists: playlists)
                outline.reloadData()
                outline.expandItem(nil, expandChildren: true)
            }
            coordinator.select(selection, in: outline)
        }

        private static func sections(devices: [String], playlists: [Playlist]) -> [Node] {
            let ipods =
                devices.isEmpty
                ? [Node(title: "No iPod connected", icon: "ipod", item: nil)]
                : devices.map { Node(title: $0, icon: "ipod", item: .device($0)) }
            return [
                Node(title: "iPods", children: ipods),
                Node(title: "Library", children: SidebarItem.library.map {
                    Node(title: $0.title, icon: $0.icon, item: $0)
                }),
                Node(title: "Playlists", children: playlists.map {
                    Node(title: $0.name, icon: "music.note.list", item: .playlist($0.id))
                } + [Node(title: "New Playlist…", icon: "plus", item: nil)]),
            ]
        }

        final class Node: NSObject {
            let title: String
            let icon: String?
            let item: SidebarItem?
            let children: [Node]

            init(title: String, icon: String? = nil, item: SidebarItem? = nil, children: [Node] = []) {
                self.title = title
                self.icon = icon
                self.item = item
                self.children = children
            }

            var isGroup: Bool { icon == nil }
        }

        /// Icons in the accent color, white on the selected row, gray when dimmed: what SwiftUI's
        /// sidebar `Label` does.
        final class SidebarCell: NSTableCellView {
            var dimmed = false { didSet { updateTint() } }

            override var backgroundStyle: NSView.BackgroundStyle {
                didSet { updateTint() }
            }

            private func updateTint() {
                imageView?.contentTintColor =
                    dimmed ? .secondaryLabelColor
                    : backgroundStyle == .emphasized ? .alternateSelectedControlTextColor
                    : .controlAccentColor
            }
        }

        final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
            var sections: [Node] = []
            var key: [String] = []
            var onSelect: (SidebarItem) -> Void = { _ in }
            private var isSyncingSelection = false

            func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
                (item as? Node)?.children.count ?? sections.count
            }

            func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
                (item as? Node)?.children[index] ?? sections[index]
            }

            func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
                (item as? Node)?.isGroup ?? false
            }

            func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
                (item as? Node)?.isGroup ?? false
            }

            func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
                (item as? Node)?.item != nil
            }

            func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
                guard let node = item as? Node else { return nil }
                let id = NSUserInterfaceItemIdentifier(node.isGroup ? "HeaderCell" : "DataCell")
                let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView
                    ?? Self.makeCell(id, group: node.isGroup)
                cell.textField?.stringValue = node.title
                if let icon = node.icon {
                    cell.imageView?.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
                }
                // Placeholder rows ("No iPod connected", "New Playlist…") are dimmed, as in SwiftUI.
                let dimmed = !node.isGroup && node.item == nil
                cell.textField?.textColor = dimmed ? .secondaryLabelColor : nil
                (cell as? SidebarCell)?.dimmed = dimmed
                return cell
            }

            func outlineViewSelectionDidChange(_ notification: Notification) {
                guard !isSyncingSelection, let outline = notification.object as? NSOutlineView,
                      let item = (outline.item(atRow: outline.selectedRow) as? Node)?.item
                else { return }
                onSelect(item)
            }

            func select(_ selection: SidebarItem, in outline: NSOutlineView) {
                let row = outline.row(forItem: sections.lazy.flatMap(\.children).first { $0.item == selection })
                guard row >= 0, row != outline.selectedRow else { return }
                isSyncingSelection = true
                outline.selectRowIndexes([row], byExtendingSelection: false)
                isSyncingSelection = false
            }

            /// Source-list cells: NSTableCellView sizes the text and icon for the row size style.
            private static func makeCell(_ id: NSUserInterfaceItemIdentifier, group: Bool) -> NSTableCellView {
                let cell = SidebarCell()
                cell.identifier = id
                let text = NSTextField(labelWithString: "")
                text.lineBreakMode = .byTruncatingTail
                text.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(text)
                cell.textField = text
                var constraints = [
                    text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    text.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
                ]
                if group {
                    constraints.append(text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2))
                } else {
                    let image = NSImageView()
                    image.translatesAutoresizingMaskIntoConstraints = false
                    cell.addSubview(image)
                    cell.imageView = image
                    // Fixed-width icon column, so every title starts at the same x.
                    image.imageAlignment = .alignCenter
                    constraints += [
                        image.widthAnchor.constraint(equalToConstant: 22),
                        image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                        image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                        text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
                    ]
                }
                NSLayoutConstraint.activate(constraints)
                return cell
            }
        }
    }
#endif
