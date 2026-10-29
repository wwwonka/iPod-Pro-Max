#if canImport(AppKitBackend)
    import AppKit
    import AppKitBackend
    import SwiftCrossUI

    /// On macOS the sidebar is a real source-list NSOutlineView, like the one SwiftUI's
    /// `List(.sidebar)` makes: row height, fonts and icon size follow the "Sidebar icon size"
    /// setting, icons take the accent color, and selection looks native. Clicks don't go through
    /// SwiftCrossUI's layout, which keeps them cheap. It takes whatever width the split view gives
    /// it (zero once hidden); during a slide the list keeps the open width, pinned to the right edge
    /// and clipped, so the rows slide with the divider instead of squeezing.
    struct Sidebar: NSViewRepresentable {
        // Bindings, not values: SwiftCrossUI hands a native view's updates the values it was
        // created with, so the playlists loaded later never showed.
        @Binding var devices: [String]
        @Binding var library: Library?
        @Binding var selection: SidebarItem

        private var playlists: [Playlist] { library?.playlists ?? [] }

        func makeCoordinator() -> Coordinator { Coordinator() }

        func makeNSView(context: Context) -> NSView {
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
            let container = SlidingContainer()
            container.addSubview(scroll)
            return container
        }

        func updateNSView(_ container: NSView, context: Context) {
            guard let scroll = container.subviews.first as? NSScrollView,
                  let outline = scroll.documentView as? NSOutlineView else { return }
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

        func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> ViewSize {
            ViewSize(proposal.width ?? sidebarWidth, proposal.height ?? 400)
        }

        /// Group rows are what NSOutlineView collapses: on hover they show a chevron at the right,
        /// and the section slides closed or open.
        private static func sections(devices: [String], playlists: [Playlist]) -> [Node] {
            sidebarSections(devices: devices, playlists: playlists).map { section in
                Node(title: section.title, children: section.rows.map { Node(title: $0.title, icon: $0.icon, item: $0.item) })
            }
        }

        /// The sidebar's translucent material (the desktop blurred behind the window), filled with
        /// the list except during a slide: then the list keeps the open width, pinned to the right
        /// edge and clipped.
        final class SlidingContainer: NSVisualEffectView {
            override init(frame: NSRect) {
                super.init(frame: frame)
                material = .sidebar
                blendingMode = .behindWindow
                state = .followsWindowActiveState
                clipsToBounds = true
            }

            required init?(coder: NSCoder) { fatalError() }

            override func resizeSubviews(withOldSize oldSize: NSSize) {
                let width = max(bounds.width, MacChrome.shared.pinnedSidebarContentWidth ?? 0)
                subviews.first?.frame = NSRect(x: bounds.width - width, y: 0, width: width, height: bounds.height)
            }
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
