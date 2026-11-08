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
        @Binding var busyDevices: Set<String>
        var onEject: (SidebarItem) -> Void = { _ in }
        /// The "+" at the main section's header: adds to that library (a folder, a podcast…).
        var onAdd: (SidebarItem) -> Void = { _ in }

        private var playlists: [Playlist] { library?.playlists ?? [] }
        private var videoPlaylists: [Playlist] { library?.videoPlaylists ?? [] }

        func makeCoordinator() -> Coordinator { Coordinator() }

        func makeNSView(context: Context) -> NSView {
            let outline = MusicDropOutlineView()
            if #available(macOS 11, *) { outline.style = .sourceList }
            outline.headerView = nil
            // The outline view's own drop frame (a rounded rectangle around the whole row, larger than
            // the highlight) would show underneath: the row draws the one and only feedback, in the accent color.
            outline.draggingDestinationFeedbackStyle = .none
            // The system draws a source list's selection itself and never calls the rows' `drawSelection`: the
            // rows draw it (neutral gray, or the accent color under a drag) so one shape is ever on screen.
            outline.selectionHighlightStyle = .none
            outline.floatsGroupRows = false
            outline.rowSizeStyle = .default
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
            outline.addTableColumn(column)
            outline.outlineTableColumn = column
            outline.dataSource = context.coordinator
            outline.delegate = context.coordinator
            outline.registerForDraggedTypes([.string])

            let scroll = NSScrollView()
            scroll.documentView = outline
            scroll.drawsBackground = false
            // Nothing opaque or light between the list and the dark glass behind it.
            scroll.contentView.drawsBackground = false
            scroll.backgroundColor = .clear
            outline.backgroundColor = .clear
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
            // An iPod's page has no sidebar: it goes with the page, in this same update pass.
            if case .device = selection { MacChrome.shared.setSidebarAvailable(false) } else { MacChrome.shared.setSidebarAvailable(true) }
            coordinator.onEject = onEject
            coordinator.onAdd = onAdd
            // An iPod's page keeps the list of the section the user came from.
            if let media = selection.media { coordinator.media = media }
            let deviceKey: [String] = devices.map { $0 + (ConnectedDeviceTitles.names[$0] ?? "") }
            let playlistKey: [String] = (playlists + videoPlaylists).map { $0.id + $0.name }
            let key: [String] = deviceKey + ["|"] + playlistKey + ["|", coordinator.media.title]
            if key != coordinator.key {
                coordinator.key = key
                coordinator.sections = Self.sections(devices: devices, playlists: playlists, videoPlaylists: videoPlaylists, media: coordinator.media)
                outline.reloadData()
                outline.expandItem(nil, expandChildren: true)
            }
            coordinator.select(selection, in: outline)
            coordinator.updateActivity(busyDevices, in: outline)
        }

        func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> ViewSize {
            ViewSize(proposal.width ?? sidebarWidth, proposal.height ?? 400)
        }

        /// Group rows are what NSOutlineView collapses: on hover they show a chevron at the right,
        /// and the section slides closed or open.
        private static func sections(devices: [String], playlists: [Playlist], videoPlaylists: [Playlist], media: SidebarItem) -> [Node] {
            // The iPods live at the rail's bottom, not in this list.
            let nodes = sidebarSections(devices: devices, playlists: playlists, videoPlaylists: videoPlaylists, media: media).filter { $0.title != "iPods" }.map { section in
                Node(title: section.title, children: section.rows.map { Node(title: $0.title, icon: $0.icon, item: $0.item, ejectable: $0.ejectable) })
            }
            nodes.first?.isMain = true
            return nodes
        }

        /// Holds the list, filling it. The sidebar's glass card is drawn behind it by the column.
        final class SlidingContainer: NSView {
            override init(frame: NSRect) {
                super.init(frame: frame)
                clipsToBounds = true
                // The dark glass behind makes the list dark in either appearance.
                appearance = NSAppearance(named: .darkAqua)
            }

            required init?(coder: NSCoder) { fatalError() }

            /// Tells the window chrome which view to slide.
            override func viewDidMoveToSuperview() {
                super.viewDidMoveToSuperview()
                if superview != nil { MainActor.assumeIsolated { MacChrome.shared.sidebarAnchor = self } }
            }

            override func resizeSubviews(withOldSize oldSize: NSSize) {
                let width = max(bounds.width, MacChrome.shared.pinnedSidebarContentWidth ?? 0)
                subviews.first?.frame = NSRect(x: bounds.width - width, y: 0, width: width, height: bounds.height)
            }
        }

        final class Node: NSObject {
            let title: String
            let icon: String?
            let item: SidebarItem?
            let ejectable: Bool
            let children: [Node]
            /// The library's own section, at the top: it can't be collapsed, and has a "+" instead.
            var isMain = false

            init(title: String, icon: String? = nil, item: SidebarItem? = nil, ejectable: Bool = false, children: [Node] = []) {
                self.title = title
                self.icon = icon
                self.item = item
                self.ejectable = ejectable
                self.children = children
            }

            var isGroup: Bool { icon == nil }
        }

        /// An icon the sidebar's vibrancy leaves alone, so its accent color isn't washed out.
        final class FlatImageView: NSImageView {
            override var allowsVibrancy: Bool { false }
        }

        /// Icons in the accent color, white on the selected row, gray when dimmed: what SwiftUI's
        /// sidebar `Label` does.
        final class SidebarCell: NSTableCellView {
            var dimmed = false { didSet { updateTint() } }
            var customIcon: NSImage? { didSet { updateTint() } }
            /// iPod rows only.
            var ejectButton: EjectButton?
            /// A section's name: big and white, in a label of its own. The source list restyles the
            /// text field of a group row as a small gray caption, whatever is set on it.
            var headerLabel: NSTextField?
            /// The main section's "+".
            var plusButton: NSButton?
            var onPlus: () -> Void = {}
            @objc func plusClicked(_ sender: NSButton) { onPlus() }

            // The "+" shows while the pointer is on the section's header, fading in and out.
            private var headerTracking: NSTrackingArea?
            override func updateTrackingAreas() {
                super.updateTrackingAreas()
                if let headerTracking { removeTrackingArea(headerTracking) }
                guard plusButton != nil else { return }
                let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
                addTrackingArea(area)
                headerTracking = area
            }
            override func mouseEntered(with event: NSEvent) { fadePlus(to: 1) }
            override func mouseExited(with event: NSEvent) { fadePlus(to: 0) }
            private func fadePlus(to alpha: CGFloat) {
                guard let plus = plusButton, !plus.isHidden else { return }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = alpha == 0 ? 0.3 : 0.2
                    context.timingFunction = CAMediaTimingFunction(name: alpha == 0 ? .easeIn : .easeOut)
                    plus.animator().alphaValue = alpha
                }
            }
            /// A reused cell starts without the "+".
            func resetPlus() { plusButton?.alphaValue = 0 }

            override var backgroundStyle: NSView.BackgroundStyle {
                didSet {
                    updateTint()
                    ejectButton?.onAccent = backgroundStyle == .emphasized
                }
            }

            func updateTint() {
                let color: NSColor =
                    dimmed ? .secondaryLabelColor
                    : backgroundStyle == .emphasized ? .alternateSelectedControlTextColor
                    : .controlAccentColor
                imageView?.contentTintColor = color
                if let customIcon {
                    imageView?.image = Self.colored(customIcon, color: color)
                    return
                }
                // The source list overrides a template image's tint with its own gray, so the symbol
                // carries its color itself (a palette configuration the list can't restyle).
                if #available(macOS 12, *), let image = imageView?.image,
                   let tinted = image.withSymbolConfiguration(.init(paletteColors: [color])) {
                    imageView?.image = tinted
                }
            }

            private static func colored(_ source: NSImage, color: NSColor) -> NSImage {
                let result = NSImage(size: source.size, flipped: false) { rect in
                    source.draw(in: rect)
                    color.setFill()
                    rect.fill(using: .sourceIn)
                    return true
                }
                result.accessibilityDescription = source.accessibilityDescription
                return result
            }

            override func viewDidChangeEffectiveAppearance() {
                super.viewDidChangeEffectiveAppearance()
                updateTint()
            }
        }

        final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
            var sections: [Node] = []
            var key: [String] = []
            var media: SidebarItem = .music
            var onSelect: (SidebarItem) -> Void = { _ in }
            var onEject: (SidebarItem) -> Void = { _ in }
            var onAdd: (SidebarItem) -> Void = { _ in }
            /// Libraries that have something to add.
            private static let addable: Set<SidebarItem> = [.music, .podcasts, .audiobooks, .videos]
            private var isSyncingSelection = false

            // Drops are decided by `MusicDropOutlineView` itself (it answers the drag events, see there): the
            // table's own validate/accept path is what draws the frame we don't want.

            private var busyDevices: Set<String> = []
            func updateActivity(_ devices: Set<String>, in outline: NSOutlineView) {
                busyDevices = devices
                for row in 0..<outline.numberOfRows {
                    guard let node = outline.item(atRow: row) as? Node,
                          case .device(let id) = node.item,
                          let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarCell else { continue }
                    cell.ejectButton?.isBusy = devices.contains(id)
                }
            }
            func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
                NeutralSidebarRow()
            }

            func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
                (item as? Node)?.children.count ?? sections.count
            }

            func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
                (item as? Node)?.children[index] ?? sections[index]
            }

            func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
                (item as? Node)?.isGroup ?? false
            }

            /// The library's own section stays open, with no disclosure arrow.
            func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool {
                (item as? Node)?.isMain != true
            }

            func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
                (item as? Node)?.isMain != true
            }

            func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
                (item as? Node)?.isGroup ?? false
            }

            /// Room for the big section name; a sub-section's native caption takes less.
            func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
                guard let node = item as? Node, node.isGroup else { return max(outlineView.rowHeight, SidebarMetrics.rowHeight) }
                return node.isMain ? 38 : SidebarMetrics.subHeaderHeight
            }

            func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
                (item as? Node)?.item != nil
            }

            func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
                guard let node = item as? Node else { return nil }
                // The library's own section has a big title; any other group (Playlists) is a native
                // source-list header: a small gray caption the system draws and collapses.
                let id = NSUserInterfaceItemIdentifier(node.isMain ? "HeaderCell" : node.isGroup ? "SubHeaderCell" : node.ejectable ? "DeviceCell" : "DataCell")
                let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView
                    ?? Self.makeCell(id, group: node.isGroup, main: node.isMain, ejectable: node.ejectable)
                if let eject = (cell as? SidebarCell)?.ejectButton, let item = node.item {
                    eject.action = { [weak self] in self?.onEject(item) }
                    if case .device(let id) = item { eject.isBusy = busyDevices.contains(id) }
                }
                cell.textField?.stringValue = node.isMain ? "" : node.title
                if node.isMain { (cell as? SidebarCell)?.headerLabel?.stringValue = node.title }
                if let plus = (cell as? SidebarCell)?.plusButton {
                    plus.isHidden = !(node.isMain && Self.addable.contains(media))
                    (cell as? SidebarCell)?.resetPlus()
                    let target = media
                    (cell as? SidebarCell)?.onPlus = { [weak self] in self?.onAdd(target) }
                }
                if let icon = node.icon {
                    let image = systemSymbol(icon)
                    // AppKit automatically substitutes filled variants in source lists. Keep the
                    // TV Shows glyph on the explicitly requested outline `tv`, selected or not.
                    (cell as? SidebarCell)?.customIcon = customSymbols[icon] != nil || icon == "tv" ? image : nil
                    cell.imageView?.image = image
                }
                // Placeholder rows ("No iPod connected", "New Playlist…") are dimmed, as in SwiftUI.
                let dimmed = !node.isGroup && node.item == nil
                if !node.isGroup { cell.textField?.textColor = dimmed ? .secondaryLabelColor : nil }
                (cell as? SidebarCell)?.dimmed = dimmed
                (cell as? SidebarCell)?.updateTint()
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
            private static func makeCell(_ id: NSUserInterfaceItemIdentifier, group: Bool, main: Bool, ejectable: Bool) -> NSTableCellView {
                let cell = SidebarCell()
                cell.identifier = id
                let text = NSTextField(labelWithString: "")
                text.lineBreakMode = .byTruncatingTail
                text.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(text)
                cell.textField = text
                var constraints = [text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)]
                if ejectable {
                    let eject = EjectButton()
                    eject.translatesAutoresizingMaskIntoConstraints = false
                    cell.addSubview(eject)
                    cell.ejectButton = eject
                    typealias M = SidebarMetrics
                    constraints += [
                        eject.widthAnchor.constraint(equalToConstant: M.ejectSize),
                        eject.heightAnchor.constraint(equalToConstant: M.ejectSize),
                        eject.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                        eject.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -M.ejectTrailing),
                        text.trailingAnchor.constraint(lessThanOrEqualTo: eject.leadingAnchor, constant: -2),
                    ]
                } else {
                    constraints.append(text.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4))
                }
                if group && !main {
                    // A sub-section's caption lines up with the rows' icons, as in the Finder.
                    constraints.append(text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: SidebarMetrics.subHeaderTextX))
                } else if group {
                    constraints.append(text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2))
                    let label = NSTextField(labelWithString: "")
                    label.font = .systemFont(ofSize: SidebarMetrics.titleFontSize, weight: .bold)
                    label.textColor = .white
                    label.lineBreakMode = .byTruncatingTail
                    label.translatesAutoresizingMaskIntoConstraints = false
                    cell.addSubview(label)
                    cell.headerLabel = label
                    let plus = NSButton(image: systemSymbol("plus.circle", description: "Add", pointSize: 15) ?? NSImage(), target: nil, action: nil)
                    plus.isBordered = false
                    plus.contentTintColor = .secondaryLabelColor
                    plus.toolTip = "Add"
                    plus.isHidden = true
                    plus.target = cell
                    plus.action = #selector(SidebarCell.plusClicked(_:))
                    plus.translatesAutoresizingMaskIntoConstraints = false
                    cell.addSubview(plus)
                    cell.plusButton = plus
                    constraints += [
                        plus.widthAnchor.constraint(equalToConstant: 24),
                        plus.heightAnchor.constraint(equalToConstant: 24),
                        plus.centerYAnchor.constraint(equalTo: cell.centerYAnchor, constant: -SidebarMetrics.headerLift),
                        plus.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                    ]
                    constraints += [
                        label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                        // The first title is centered on the rail's top icon (the iPod's): measured, the
                        // text sat 2.75 pt lower than it.
                        label.centerYAnchor.constraint(equalTo: cell.centerYAnchor, constant: -SidebarMetrics.headerLift),
                        label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -24),
                    ]
                } else {
                    let image = FlatImageView()
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

    /// Own the visual target explicitly: source-list AppKit feedback does not reliably set
    /// NSTableRowView.isTargetForDropOperation when custom rows draw a neutral selection.
    final class MusicDropOutlineView: NSOutlineView {
        private var dropRow: Int?
        func highlightDrop(row: Int?) {
            guard dropRow != row else { return }
            if let old = dropRow, old < numberOfRows {
                (rowView(atRow: old, makeIfNecessary: false) as? NeutralSidebarRow)?.isMusicDropTarget = false
            }
            dropRow = row
            if let row, row >= 0, row < numberOfRows {
                (rowView(atRow: row, makeIfNecessary: true) as? NeutralSidebarRow)?.isMusicDropTarget = true
            }
        }
        // The table itself never handles the drag. Its own drop feedback (a rounded shape around the whole
        // row, wider than the row, which no setting turns off in the source-list style) only appears when
        // it validates a drop, so this view answers the drag events directly and draws the one highlight.
        private func device(for sender: any NSDraggingInfo) -> (row: Int, id: String)? {
            let row = self.row(at: convert(sender.draggingLocation, from: nil))
            guard row >= 0, let node = item(atRow: row) as? Sidebar.Node, case .device(let id) = node.item,
                  let payload = TrackDrag.payload, musicDragPayload(in: sender.draggingPasteboard) == payload else { return nil }
            return (row, id)
        }
        private func operation(for sender: any NSDraggingInfo) -> NSDragOperation {
            guard let target = device(for: sender) else { highlightDrop(row: nil); return [] }
            highlightDrop(row: target.row)
            return .copy
        }
        override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { operation(for: sender) }
        override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { operation(for: sender) }
        override func draggingExited(_ sender: (any NSDraggingInfo)?) { highlightDrop(row: nil) }
        override func draggingEnded(_ sender: any NSDraggingInfo) { highlightDrop(row: nil) }
        override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { device(for: sender) != nil }
        override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
            defer { highlightDrop(row: nil) }
            guard let target = device(for: sender) else { return false }
            return TrackDrag.accept(musicDragPayload(in: sender.draggingPasteboard), device: target.id)
        }
        override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) { highlightDrop(row: nil) }
    }

    final class NeutralSidebarRow: NSTableRowView {
        /// Rows of a source-list table render through their layer (`updateLayer`) on recent macOS, which never
        /// calls the `draw…` overrides below. Asking for plain drawing makes the rows draw the selection and
        /// the drop highlight themselves.
        override var wantsUpdateLayer: Bool { false }
        var isMusicDropTarget = false { didSet { refreshFeedback() } }
        private var dropActive: Bool { isMusicDropTarget || isTargetForDropOperation }
        override var isEmphasized: Bool { get { false } set {} }
        override var isTargetForDropOperation: Bool { didSet { refreshFeedback() } }
        private func refreshFeedback() {
            needsDisplay = true
            for cell in subviews.compactMap({ $0 as? Sidebar.SidebarCell }) {
                cell.backgroundStyle = interiorBackgroundStyle
                cell.textField?.textColor = dropActive ? .alternateSelectedControlTextColor : nil
            }
        }
        override func drawBackground(in dirtyRect: NSRect) {
            super.drawBackground(in: dirtyRect)
            if dropActive { drawHighlight(.controlAccentColor) }
            else if isSelected {
                let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                let color = sidebarSelectionRGBA(dark: dark)
                drawHighlight(NSColor(srgbRed: CGFloat(color.r) / 255, green: CGFloat(color.g) / 255,
                                      blue: CGFloat(color.b) / 255, alpha: color.alpha))
            }
        }
        override var interiorBackgroundStyle: NSView.BackgroundStyle {
            dropActive ? .emphasized : .normal
        }
        override func drawSelection(in dirtyRect: NSRect) {
            if dropActive { drawHighlight(.controlAccentColor) }
        }
        override var isSelected: Bool { didSet { if oldValue != isSelected { refreshFeedback() } } }
        override func drawDraggingDestinationFeedback(in dirtyRect: NSRect) {
            if dropActive { drawHighlight(.controlAccentColor) }
        }
        private func drawHighlight(_ color: NSColor) {
            color.setFill()
            // The system's own selection is inset 10 pt on each side of the row: same shape, whatever draws it.
            NSBezierPath(roundedRect: bounds.insetBy(dx: 10, dy: 1), xRadius: 6, yRadius: 6).fill()
        }
    }

    /// The Finder's eject button: `eject.fill`, dim at rest, brighter under the pointer, white while
    /// held down. Ejects on release inside, like a button; the row isn't selected.
    final class EjectButton: NSView {
        var action: () -> Void = {}
        var isBusy = false {
            didSet {
                guard oldValue != isBusy else { return }
                pressed = false
                image.image = isBusy
                    ? systemSymbol("arrow.trianglehead.2.clockwise", description: "Syncing", pointSize: SidebarMetrics.ejectPointSize)
                        ?? systemSymbol("arrow.triangle.2.circlepath", description: "Syncing", pointSize: SidebarMetrics.ejectPointSize)
                    : systemSymbol("eject.fill", description: "Eject", pointSize: SidebarMetrics.ejectPointSize)
                toolTip = isBusy ? "Syncing…" : "Eject"
                image.isHidden = isBusy
                syncGlyph.isHidden = !isBusy
                layoutSyncGlyph()
                if isBusy {
                    let turn = CABasicAnimation(keyPath: "transform.rotation.z")
                    turn.fromValue = 0
                    turn.toValue = -Double.pi * 2
                    turn.duration = 1
                    turn.repeatCount = .infinity
                    syncGlyph.add(turn, forKey: "syncRotation")
                } else {
                    syncGlyph.removeAnimation(forKey: "syncRotation")
                }
                updateTint()
            }
        }
        var onAccent = false { didSet { updateTint() } }
        private let image = NSImageView()
        /// Owned layer, independent of AppKit's backing-layer origin and anchor conventions.
        private let syncGlyph = CALayer()
        private var hovering = false
        private var pressed = false

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            syncGlyph.name = "syncGlyph"
            syncGlyph.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            syncGlyph.isHidden = true
            layer?.addSublayer(syncGlyph)
            image.image = systemSymbol("eject.fill", description: "Eject", pointSize: SidebarMetrics.ejectPointSize)
            image.imageScaling = .scaleNone
            image.translatesAutoresizingMaskIntoConstraints = false
            addSubview(image)
            NSLayoutConstraint.activate([
                image.centerXAnchor.constraint(equalTo: centerXAnchor),
                image.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
            toolTip = "Eject"
            updateTint()
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            layoutSyncGlyph()
        }

        private func layoutSyncGlyph() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            syncGlyph.bounds = CGRect(x: 0, y: 0, width: SidebarMetrics.ejectSize, height: SidebarMetrics.ejectSize)
            syncGlyph.position = CGPoint(x: bounds.midX, y: bounds.midY)
            CATransaction.commit()
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            updateTint()
        }

        /// Rasterize once on an icon/tint change, never on animation frames.
        private func updateSyncGlyph(tint: NSColor) {
            guard isBusy, let symbol = image.image else { return }
            let side = SidebarMetrics.ejectSize
            let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            let pixels = Int(ceil(side * scale))
            guard let bitmap = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            bitmap.scaleBy(x: scale, y: scale)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: bitmap, flipped: false)
            symbol.draw(in: NSRect(x: (side - symbol.size.width) / 2, y: (side - symbol.size.height) / 2,
                width: symbol.size.width, height: symbol.size.height))
            tint.setFill()
            NSRect(x: 0, y: 0, width: side, height: side).fill(using: .sourceIn)
            NSGraphicsContext.restoreGraphicsState()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            syncGlyph.contentsScale = scale
            syncGlyph.contents = bitmap.makeImage()
            CATransaction.commit()
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                           owner: self, userInfo: nil))
        }

        override func mouseEntered(with event: NSEvent) { hovering = true; updateTint() }
        override func mouseExited(with event: NSEvent) { hovering = false; updateTint() }

        /// Tracks the press here, so the outline view doesn't select the row.
        override func mouseDown(with event: NSEvent) {
            guard !isBusy else { return }
            pressed = true
            updateTint()
            while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
                let inside = bounds.contains(convert(next.locationInWindow, from: nil))
                if next.type == .leftMouseUp {
                    pressed = false
                    hovering = inside
                    updateTint()
                    if inside && !isBusy { action() }
                    return
                }
                if pressed != inside {
                    pressed = inside
                    updateTint()
                }
            }
        }

        /// The Finder's own colors: translucent label colors, which take on the sidebar's material
        /// (#494949 at rest and #9FA4B9 under the pointer, measured in dark mode), then the text color.
        private func updateTint() {
            image.contentTintColor =
                onAccent ? (pressed || hovering ? .white : .alternateSelectedControlTextColor.withAlphaComponent(0.85))
                : pressed ? .labelColor
                : hovering ? .secondaryLabelColor
                : .tertiaryLabelColor
            updateSyncGlyph(tint: image.contentTintColor ?? .tertiaryLabelColor)
        }
    }
#endif
