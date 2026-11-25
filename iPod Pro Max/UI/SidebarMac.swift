#if canImport(AppKitBackend)
    import AppKit
    import AppKitBackend
    import MediaKit
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
        var sidebarOrder: [String: [String]] = [:]
        var editingPlaylistID: String? = nil
        var subscriptionRevision: Int = 0
        var onEject: (SidebarItem) -> Void = { _ in }
        /// The "+" at the main section's header: adds to that library (a folder, a podcast…).
        var onAdd: (SidebarItem) -> Void = { _ in }
        var onReorder: (String, [SidebarItem]) -> Void = { _, _ in }
        var onAddMusicFolder: () -> Void = {}
        var onCreatePlaylist: (Bool) -> Void = { _ in }
        var onNewSubscription: () -> Void = {}
        var onImportRemotePlaylists: () -> Void = {}
        var onNewSpotifyPlaylist: () -> Void = {}
        var onNewYouTubeMusicPlaylist: () -> Void = {}
        var onRenamePlaylist: (String, String) -> Void = { _, _ in }
        var onDeletePlaylist: (String) -> Void = { _ in }
        var onRefreshSubscription: (String) -> Void = { _ in }
        var onStopSubscription: (String) -> Void = { _ in }
        var onAddTracksToPlaylist: ([String], String) -> Void = { _, _ in }
        var onUnsubscribePlaylist: (String) -> Void = { _ in }
        var onMovePlaylistToFolder: (String, String?, Int?) -> Void = { _, _, _ in }
        var onSendPlaylistToDevice: (String, String) -> Void = { _, _ in }
        var onClearEditing: () -> Void = {}

        private var playlists: [Playlist] { library?.playlists ?? [] }
        private var videoPlaylists: [Playlist] { library?.videoPlaylists ?? [] }

        func makeCoordinator() -> Coordinator { Coordinator() }

        func makeNSView(context: Context) -> NSView {
            let outline = MusicDropOutlineView()
            outline.coordinator = context.coordinator
            context.coordinator.outline = outline
            ListAppearance.shared.observe(context.coordinator) { [weak coordinator = context.coordinator] in
                coordinator?.refreshFavoriteIcon()
            }
            if #available(macOS 11, *) { outline.style = .sourceList }
            outline.headerView = nil
            // The outline view's own drop frame (a rounded rectangle around the whole row, larger than
            // the highlight) would show underneath: the row draws the one and only feedback, in the accent color.
            outline.draggingDestinationFeedbackStyle = .none
            // The system draws a source list's selection itself and never calls the rows' `drawSelection`: the
            // rows draw it (neutral gray, or the accent color under a drag) so one shape is ever on screen.
            outline.selectionHighlightStyle = .none
            outline.pressureConfiguration = NSPressureConfiguration(pressureBehavior: .primaryDeepDrag)
            outline.floatsGroupRows = false
            outline.rowSizeStyle = .default
            outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
            column.resizingMask = .autoresizingMask
            outline.addTableColumn(column)
            outline.outlineTableColumn = column
            outline.dataSource = context.coordinator
            outline.delegate = context.coordinator
            outline.registerForDraggedTypes([.string])

            let scroll = PinnedScrollView()
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
            coordinator.onReorder = onReorder
            coordinator.onAddMusicFolder = onAddMusicFolder
            coordinator.onCreatePlaylist = onCreatePlaylist
            coordinator.onNewSubscription = onNewSubscription
            coordinator.onImportRemotePlaylists = onImportRemotePlaylists
            coordinator.onNewSpotifyPlaylist = onNewSpotifyPlaylist
            coordinator.onNewYouTubeMusicPlaylist = onNewYouTubeMusicPlaylist
            coordinator.onRenamePlaylist = onRenamePlaylist
            coordinator.onDeletePlaylist = onDeletePlaylist
            coordinator.onRefreshSubscription = onRefreshSubscription
            coordinator.onStopSubscription = onStopSubscription
            coordinator.onAddTracksToPlaylist = onAddTracksToPlaylist
            coordinator.onUnsubscribePlaylist = onUnsubscribePlaylist
            coordinator.onMovePlaylistToFolder = onMovePlaylistToFolder
            coordinator.onSendPlaylistToDevice = onSendPlaylistToDevice
            // An iPod's page keeps the list of the section the user came from.
            if let media = selection.media { coordinator.media = media }
            let deviceKey: [String] = devices.map { $0 + (ConnectedDeviceTitles.names[$0] ?? "") }
            let playlistKey: [String] = (playlists + videoPlaylists).map {
                let isSubSync = $0.subscriptionID != nil && SubscriptionController.shared.isSyncing(playlistID: $0.id)
                let hasErr = ($0.subscriptionID != nil && !(SubscriptionController.shared.subscription(forPlaylistID: $0.id)?.lastError ?? "").isEmpty)
                return $0.id + $0.name + ($0.isFolder ? "F" : "P") + ($0.parentID ?? "") + ($0.subscriptionID ?? "") + (isSubSync ? "S" : "") + (hasErr ? "E" : "")
            }
            let orderKey: [String] = sidebarOrder.keys.sorted().flatMap { ["#", $0] + (sidebarOrder[$0] ?? []) }
            let key: [String] = deviceKey + ["|"] + playlistKey + ["|", coordinator.media.title] + orderKey
            if key != coordinator.key && !coordinator.isReordering {
                coordinator.key = key
                if coordinator.skipNextReload {
                    coordinator.skipNextReload = false
                } else {
                    coordinator.sections = Self.sections(devices: devices, playlists: playlists, videoPlaylists: videoPlaylists, media: coordinator.media, sidebarOrder: sidebarOrder)
                    outline.reloadData()
                    outline.expandItem(nil, expandChildren: true)
                }
            }
            coordinator.select(selection, in: outline)
            coordinator.updateActivity(busyDevices, in: outline)
            if let editID = editingPlaylistID,
               let node = coordinator.findNode(for: .playlist(editID)) {
                onClearEditing()
                DispatchQueue.main.async { [weak outline] in
                    guard let outline else { return }
                    let row = outline.row(forItem: node)
                    guard row >= 0 else { return }
                    outline.scrollRowToVisible(row)
                    if let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarCell {
                        cell.beginInlineEdit()
                    }
                }
            }
        }

        func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> ViewSize {
            ViewSize(proposal.width ?? sidebarWidth, proposal.height ?? 400)
        }

        /// Group rows are what NSOutlineView collapses: on hover they show a chevron at the right,
        /// and the section slides closed or open.
        private static func makeNode(_ row: SidebarSection.Row) -> Node {
            Node(
                title: row.title,
                icon: row.icon,
                item: row.item,
                ejectable: row.ejectable,
                isFolder: row.isFolder,
                children: row.children.map(makeNode),
                subscriptionID: row.subscriptionID,
                sourcePluginID: row.sourcePluginID,
                isSyncing: row.isSyncing,
                hasError: row.hasError,
                errorTooltip: row.errorTooltip
            )
        }
        private static func sections(devices: [String], playlists: [Playlist], videoPlaylists: [Playlist], media: SidebarItem, sidebarOrder: [String: [String]]) -> [Node] {
            // The iPods live at the rail's bottom, not in this list.
            let nodes = sidebarSections(devices: devices, playlists: playlists, videoPlaylists: videoPlaylists, media: media, sidebarOrder: sidebarOrder).filter { $0.title != "iPods" }.map { section in
                Node(title: section.title, children: section.rows.map(makeNode))
            }
            nodes.first?.isMain = true
            return nodes
        }

        /// Scroll view that keeps its pinned width during sidebar open/close animations so
        /// `NSSplitViewResizingDelegate.carry` cannot stretch it when the pane nears full width.
        final class PinnedScrollView: NSScrollView {
            var allowsFrameWidthMutation = false

            override func setFrameSize(_ newSize: NSSize) {
                guard allowsFrameWidthMutation || !MacChrome.shared.isAnimatingSidebar else {
                    super.setFrameSize(NSSize(width: frame.width, height: newSize.height))
                    return
                }
                super.setFrameSize(newSize)
            }
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

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                if window != nil { MainActor.assumeIsolated { MacChrome.shared.sidebarHierarchyDidChange() } }
            }

            override func resizeSubviews(withOldSize oldSize: NSSize) {
                let width = max(bounds.width, MacChrome.shared.pinnedSidebarContentWidth ?? 0)
                guard let scroll = subviews.first else { return }
                let target = NSRect(x: 0, y: 0, width: width, height: bounds.height)
                if scroll.frame != target {
                    let pinned = scroll as? PinnedScrollView
                    pinned?.allowsFrameWidthMutation = true
                    scroll.frame = target
                    pinned?.allowsFrameWidthMutation = false
                    scroll.layoutSubtreeIfNeeded()
                    if let outline = (scroll as? NSScrollView)?.documentView as? NSOutlineView {
                        outline.sizeLastColumnToFit()
                        outline.tile()
                        outline.layoutSubtreeIfNeeded()
                        outline.enumerateAvailableRowViews { rowView, _ in
                            rowView.needsDisplay = true
                        }
                    }
                }
            }
        }

        final class Node: NSObject {
            let title: String
            var icon: String?
            let item: SidebarItem?
            let ejectable: Bool
            let isFolder: Bool
            var children: [Node]
            var subscriptionID: String?
            var sourcePluginID: String?
            var isSyncing: Bool
            var hasError: Bool
            var errorTooltip: String?
            /// The library's own section, at the top: it can't be collapsed, and has a "+" instead.
            var isMain = false

            init(
                title: String,
                icon: String? = nil,
                item: SidebarItem? = nil,
                ejectable: Bool = false,
                isFolder: Bool = false,
                children: [Node] = [],
                subscriptionID: String? = nil,
                sourcePluginID: String? = nil,
                isSyncing: Bool = false,
                hasError: Bool = false,
                errorTooltip: String? = nil
            ) {
                self.title = title
                self.icon = icon
                self.item = item
                self.ejectable = ejectable
                self.isFolder = isFolder
                self.children = children
                self.subscriptionID = subscriptionID
                self.sourcePluginID = sourcePluginID
                self.isSyncing = isSyncing
                self.hasError = hasError
                self.errorTooltip = errorTooltip
            }

            var isGroup: Bool { icon == nil }
        }

        /// An icon the sidebar's vibrancy leaves alone, so its accent color isn't washed out.
        final class FlatImageView: NSImageView {
            override var allowsVibrancy: Bool { false }
        }

        /// Icons in the accent color, white on the selected row, gray when dimmed: what SwiftUI's
        /// sidebar `Label` does.
        private final class PassthroughView: NSView {
            override func hitTest(_ point: NSPoint) -> NSView? { nil }
        }

        private final class RenameTextView: NSTextView {
            private let localUndoManager = UndoManager()
            override var undoManager: UndoManager? { localUndoManager }

            override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting stillSelectingFlag: Bool) {
                super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelectingFlag)
                needsDisplay = true
                alignInsertionIndicator()
            }

            override func layout() {
                super.layout()
                alignInsertionIndicator()
            }

            override func updateInsertionPointStateAndRestartTimer(_ restartFlag: Bool) {
                super.updateInsertionPointStateAndRestartTimer(restartFlag)
                alignInsertionIndicator()
            }

            private func alignInsertionIndicator() {
                for subview in subviews where NSStringFromClass(type(of: subview)).contains("InsertionIndicator") {
                    var f = subview.frame
                    let pad = max(0, (f.width - 2.0) / 2.0)
                    if f.minX <= textContainerInset.width + 0.5 {
                        f.origin.x = 0.5 - pad
                    } else if f.maxX >= bounds.maxX - textContainerInset.width - 0.5 {
                        f.origin.x = max(0.5 - pad, bounds.maxX - 2.5 - pad)
                    }
                    if f != subview.frame {
                        subview.frame = f
                    }
                }
            }

            override func drawBackground(in rect: NSRect) {
                super.drawBackground(in: rect)
                let sel = selectedRange()
                let len = (string as NSString).length
                guard len > 0, sel.length > 0 else { return }

                NSColor.selectedTextBackgroundColor.setFill()
                if sel.length == len {
                    bounds.fill()
                    return
                }

                guard let lm = layoutManager, let tc = textContainer else { return }
                let glyphRange = lm.glyphRange(forCharacterRange: sel, actualCharacterRange: nil)
                let origin = textContainerOrigin
                let insetX = textContainerInset.width
                lm.enumerateEnclosingRects(
                    forGlyphRange: glyphRange,
                    withinSelectedGlyphRange: glyphRange,
                    in: tc
                ) { enclosingRect, _ in
                    var r = enclosingRect.offsetBy(dx: origin.x, dy: origin.y)
                    if r.minX <= origin.x + 0.5 {
                        let delta = r.minX
                        r.origin.x = 0
                        r.size.width += delta
                    }
                    if r.maxX >= self.bounds.maxX - insetX - 0.5 {
                        r.size.width = self.bounds.maxX - r.minX
                    }
                    r.fill()
                }
            }
        }

        final class SidebarCell: NSTableCellView, NSTextViewDelegate {
            private var emphasisObservers: [NSObjectProtocol] = []
            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                emphasisObservers.forEach(NotificationCenter.default.removeObserver); emphasisObservers.removeAll()
                if let window {
                    for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, MacWindowLifecycle.visualActivationDidChange] {
                        emphasisObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                            MainActor.assumeIsolated { self?.updateTextEmphasis() }
                        })
                    }
                }
                updateTextEmphasis()
            }
            private func updateTextEmphasis() {
                let opacity: CGFloat = MacWindowLifecycle.shared.isWindowVisuallyActive(window) ? 1 : 0.45
                textField?.alphaValue = opacity; headerLabel?.alphaValue = opacity
            }
            deinit { emphasisObservers.forEach(NotificationCenter.default.removeObserver) }

            var dimmed = false { didSet { updateTint() } }
            var forceBlackIcon = false { didSet { updateTint() } }
            var customIcon: NSImage? { didSet { updateTint() } }
            /// iPod rows only.
            var ejectButton: EjectButton?
            /// Subscribed playlist activity/error indicators.
            var syncSpinner: NSProgressIndicator?
            var errorIndicator: NSImageView?
            /// A section's name: big and white, in a label of its own. The source list restyles the
            /// text field of a group row as a small gray caption, whatever is set on it.
            var headerLabel: NSTextField?
            /// The main section's "+".
            var plusButton: NSButton?
            var keepPlusVisible = false
            var onPlus: () -> Void = {}
            var onRenameCommit: ((String) -> Void)?
            private var preEditTitle = ""
            private var renameBox: NSView?
            private var renameScrollView: NSScrollView?
            private var renameTextView: NSTextView?
            @objc func plusClicked(_ sender: NSButton) { onPlus() }

            func beginInlineEdit() {
                guard let textField, let outline = enclosingOutlineView, renameBox == nil else { return }
                preEditTitle = textField.stringValue
                let font = textField.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)

                let box = NSView(frame: .zero)
                box.wantsLayer = true
                box.layer?.cornerRadius = 5
                box.layer?.borderWidth = 0
                box.layer?.backgroundColor = NSColor.keyboardFocusIndicatorColor.withAlphaComponent(0.5).cgColor

                let innerBox = NSView(frame: .zero)
                innerBox.wantsLayer = true
                innerBox.layer?.cornerRadius = 0
                let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                innerBox.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
                innerBox.autoresizingMask = [.width, .height]

                let borderOverlay = PassthroughView(frame: .zero)
                borderOverlay.wantsLayer = true
                borderOverlay.layer?.cornerRadius = 0
                borderOverlay.layer?.borderWidth = 1.0 / max(1.0, outline.window?.backingScaleFactor ?? 2.0)
                borderOverlay.layer?.borderColor = (dark ? NSColor.white.withAlphaComponent(0.22) : NSColor.black.withAlphaComponent(0.15)).cgColor
                borderOverlay.layer?.backgroundColor = NSColor.clear.cgColor
                borderOverlay.autoresizingMask = [.width, .height]

                let scroll = NSScrollView(frame: .zero)
                scroll.drawsBackground = false
                scroll.borderType = .noBorder
                scroll.hasVerticalScroller = false
                scroll.hasHorizontalScroller = false
                scroll.autohidesScrollers = true
                scroll.scrollerStyle = .overlay
                scroll.verticalScroller?.controlSize = .small
                scroll.autoresizingMask = [.width, .height]

                let textView = RenameTextView(frame: .zero)
                textView.string = preEditTitle
                textView.font = font
                textView.drawsBackground = false
                textView.textColor = .labelColor
                textView.insertionPointColor = .controlAccentColor
                textView.selectedTextAttributes = [
                    .backgroundColor: NSColor.clear,
                    .foregroundColor: NSColor.labelColor,
                ]
                textView.isRichText = false
                textView.importsGraphics = false
                textView.allowsUndo = true
                textView.isEditable = true
                textView.isSelectable = true
                textView.isVerticallyResizable = true
                textView.isHorizontallyResizable = false
                textView.textContainerInset = NSSize(width: 2, height: 0)
                textView.textContainer?.lineFragmentPadding = 0
                textView.textContainer?.widthTracksTextView = false
                textView.delegate = self

                scroll.documentView = textView
                innerBox.addSubview(scroll)
                innerBox.addSubview(borderOverlay, positioned: .below, relativeTo: scroll)
                box.addSubview(innerBox)

                renameBox = box
                renameScrollView = scroll
                renameTextView = textView

                textField.isHidden = true
                outline.addSubview(box, positioned: .above, relativeTo: nil)
                resizeRenameBox(scrollToSelection: false)
                outline.window?.makeKey()
                outline.window?.makeFirstResponder(textView)
                textView.selectAll(nil)
                textView.scroll(.zero)
            }

            private func resizeRenameBox(scrollToSelection: Bool = true) {
                guard let box = renameBox,
                      let scroll = renameScrollView,
                      let textView = renameTextView,
                      let textField,
                      let outline = enclosingOutlineView,
                      let layoutManager = textView.layoutManager,
                      let textContainer = textView.textContainer else { return }

                let labelTitleRect = textField.cell?.titleRect(forBounds: textField.bounds) ?? textField.bounds
                let labelTextInOutline = outline.convert(textField.convert(labelTitleRect, to: self), from: self)
                let maxScrollWidth = max(44, outline.bounds.maxX - labelTextInOutline.minX - 20)

                textContainer.containerSize = NSSize(width: max(10, maxScrollWidth - 4), height: .greatestFiniteMagnitude)
                layoutManager.ensureLayout(for: textContainer)
                let glyphCount = layoutManager.numberOfGlyphs
                let used = glyphCount > 0
                    ? layoutManager.boundingRect(forGlyphRange: NSRange(location: 0, length: glyphCount), in: textContainer)
                    : .zero
                let font = textView.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
                let lineHeight = ceil(layoutManager.defaultLineHeight(for: font))
                let maxScrollHeight = lineHeight * 3

                let scrollW = min(maxScrollWidth, max(6, ceil(used.width) + 4))
                let contentH = max(lineHeight, ceil(used.height))
                let scrollH = min(maxScrollHeight, contentH)
                scroll.hasVerticalScroller = contentH > maxScrollHeight
                scroll.scrollerStyle = .overlay
                scroll.verticalScroller?.controlSize = .mini

                let originX = labelTextInOutline.minX - 3
                let originY = labelTextInOutline.minY - 3
                box.frame = NSRect(x: originX, y: originY, width: scrollW + 6, height: scrollH + 6)
                if let inner = box.subviews.first {
                    inner.frame = box.bounds.insetBy(dx: 3, dy: 3)
                    scroll.frame = inner.bounds
                    inner.subviews.last?.frame = inner.bounds
                }
                textView.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: max(scrollH, contentH))
                if scrollToSelection {
                    textView.scrollRangeToVisible(textView.selectedRange())
                }
            }

            func textDidChange(_ notification: Notification) {
                resizeRenameBox()
            }

            func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
                if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                    let outline = enclosingOutlineView
                    finishInlineEdit(commit: true)
                    if let outline { outline.window?.makeFirstResponder(outline) }
                    return true
                }
                if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                    let outline = enclosingOutlineView
                    finishInlineEdit(commit: false)
                    if let outline { outline.window?.makeFirstResponder(outline) }
                    return true
                }
                return false
            }

            private var enclosingOutlineView: NSOutlineView? {
                var v: NSView? = superview
                while let current = v {
                    if let outline = current as? NSOutlineView { return outline }
                    v = current.superview
                }
                return nil
            }

            func textDidEndEditing(_ notification: Notification) {
                finishInlineEdit(commit: true)
            }

            var isEditingInline: Bool { renameBox != nil }

            func ensureSyncIndicators() {
                if syncSpinner == nil {
                    let spinner = NSProgressIndicator()
                    spinner.style = .spinning
                    spinner.controlSize = .small
                    spinner.isDisplayedWhenStopped = false
                    spinner.isHidden = true
                    spinner.translatesAutoresizingMaskIntoConstraints = false
                    addSubview(spinner)
                    NSLayoutConstraint.activate([
                        spinner.widthAnchor.constraint(equalToConstant: 14),
                        spinner.heightAnchor.constraint(equalToConstant: 14),
                        spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
                        spinner.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
                    ])
                    syncSpinner = spinner
                }
                if errorIndicator == nil {
                    let img = NSImageView()
                    img.image = systemSymbol("exclamationmark.triangle.fill", description: "Subscription Error", pointSize: 12)
                    img.contentTintColor = .systemYellow
                    img.isHidden = true
                    img.translatesAutoresizingMaskIntoConstraints = false
                    addSubview(img)
                    NSLayoutConstraint.activate([
                        img.widthAnchor.constraint(equalToConstant: 14),
                        img.heightAnchor.constraint(equalToConstant: 14),
                        img.centerYAnchor.constraint(equalTo: centerYAnchor),
                        img.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
                    ])
                    errorIndicator = img
                }
            }

            func finishInlineEdit(commit: Bool) {
                guard let box = renameBox, let textView = renameTextView, let textField else { return }
                let edited = textView.string
                renameBox = nil
                renameScrollView = nil
                renameTextView = nil
                box.removeFromSuperview()
                textField.isHidden = false
                let trimmed = edited.trimmingCharacters(in: .whitespacesAndNewlines)
                if commit && !trimmed.isEmpty {
                    textField.stringValue = trimmed
                    onRenameCommit?(trimmed)
                } else {
                    textField.stringValue = preEditTitle
                }
            }

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
            override func mouseEntered(with event: NSEvent) {
                guard !MacChrome.shared.isAnimatingSidebar else { return }
                fadePlus(to: 1)
            }
            override func mouseExited(with event: NSEvent) {
                guard !keepPlusVisible else { return }
                fadePlus(to: 0)
            }
            func fadePlus(to alpha: CGFloat, duration: TimeInterval? = nil) {
                guard let plus = plusButton, !plus.isHidden else { return }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = duration ?? (alpha == 0 ? 0.3 : 0.2)
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
                    forceBlackIcon ? .black
                    : dimmed ? .secondaryLabelColor
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
            var onReorder: (String, [SidebarItem]) -> Void = { _, _ in }
            var onAddMusicFolder: () -> Void = {}
            var onCreatePlaylist: (Bool) -> Void = { _ in }
            var onNewSubscription: () -> Void = {}
            var onImportRemotePlaylists: () -> Void = {}
            var onNewSpotifyPlaylist: () -> Void = {}
            var onNewYouTubeMusicPlaylist: () -> Void = {}
            var onRenamePlaylist: (String, String) -> Void = { _, _ in }
            var onDeletePlaylist: (String) -> Void = { _ in }
            var onRefreshSubscription: (String) -> Void = { _ in }
            var onStopSubscription: (String) -> Void = { _ in }
            var onAddTracksToPlaylist: ([String], String) -> Void = { _, _ in }
            var onUnsubscribePlaylist: (String) -> Void = { _ in }
            var onMovePlaylistToFolder: (String, String?, Int?) -> Void = { _, _, _ in }
        var onSendPlaylistToDevice: (String, String) -> Void = { _, _ in }
            var isReordering = false
            var skipNextReload = false
            weak var outline: NSOutlineView?
            /// Libraries that have something to add.
            private static let addable: Set<SidebarItem> = [.music, .podcasts, .audiobooks, .videos]
            var isSyncingSelection = false

            func findNode(for target: SidebarItem) -> Node? {
                func search(_ nodes: [Node]) -> Node? {
                    for n in nodes {
                        if n.item == target { return n }
                        if let found = search(n.children) { return found }
                    }
                    return nil
                }
                return search(sections)
            }

            @MainActor func showPlaylistsMenu(from button: NSButton, in cell: SidebarCell, includeAddMusicFolder: Bool) {
                cell.keepPlusVisible = true
                let menu = NSMenu()
                if includeAddMusicFolder {
                    let addFolder = NSMenuItem(title: "Add New Music local folder", action: #selector(menuAddMusicFolder), keyEquivalent: "")
                    addFolder.target = self
                    menu.addItem(addFolder)
                    menu.addItem(.separator())
                }
                let newPlaylist = NSMenuItem(title: "New Playlist", action: #selector(menuNewPlaylist), keyEquivalent: "")
                newPlaylist.target = self
                let newFolder = NSMenuItem(title: "New Playlist Folder", action: #selector(menuNewPlaylistFolder), keyEquivalent: "")
                newFolder.target = self
                let newSub = NSMenuItem(title: "New Subscription…", action: #selector(menuNewSubscription), keyEquivalent: "")
                newSub.target = self
                let importPlaylists = NSMenuItem(title: "Import Playlists from Account…", action: #selector(menuImportRemotePlaylists), keyEquivalent: "")
                importPlaylists.target = self
                let newSpotify = NSMenuItem(title: "New Spotify Playlist…", action: #selector(menuNewSpotifyPlaylist), keyEquivalent: "")
                newSpotify.target = self
                let newYTMusic = NSMenuItem(title: "New YouTube Music Playlist…", action: #selector(menuNewYouTubeMusicPlaylist), keyEquivalent: "")
                newYTMusic.target = self
                menu.addItem(newPlaylist)
                menu.addItem(newFolder)
                menu.addItem(newSub)
                menu.addItem(importPlaylists)
                menu.addItem(newSpotify)
                menu.addItem(newYTMusic)
                menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 2), in: button)
                cell.keepPlusVisible = false
                if let window = cell.window {
                    let pt = cell.convert(window.mouseLocationOutsideOfEventStream, from: nil)
                    if !cell.bounds.contains(pt) {
                        cell.fadePlus(to: 0)
                    }
                } else {
                    cell.fadePlus(to: 0)
                }
            }
            @objc private func menuAddMusicFolder() { onAddMusicFolder() }
            @objc private func menuNewPlaylist() { onCreatePlaylist(false) }
            @objc private func menuNewPlaylistFolder() { onCreatePlaylist(true) }
            @objc private func menuNewSubscription() { onNewSubscription() }
            @objc private func menuImportRemotePlaylists() { onImportRemotePlaylists() }
            @objc private func menuNewSpotifyPlaylist() { onNewSpotifyPlaylist() }
            @objc private func menuNewYouTubeMusicPlaylist() { onNewYouTubeMusicPlaylist() }

            @MainActor func refreshFavoriteIcon() {
                let iconName = ListAppearance.shared.favoriteIcon == .heart ? "heart" : "star"
                for section in sections {
                    for child in section.children where child.item == .favorites {
                        child.icon = iconName
                    }
                }
                guard let outline else { return }
                for row in 0..<outline.numberOfRows {
                    guard let node = outline.item(atRow: row) as? Node, node.item == .favorites,
                          let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarCell else { continue }
                    let image = systemSymbol(iconName)
                    cell.customIcon = nil
                    cell.imageView?.image = image
                    cell.updateTint()
                    cell.needsDisplay = true
                }
                outline.needsDisplay = true
            }

            func commitReorder(group: Node, in outline: NSOutlineView) {
                let items = group.children.compactMap(\.item)
                let selected = outline.selectedRow >= 0 ? (outline.item(atRow: outline.selectedRow) as? Node)?.item : nil
                outline.reloadData()
                outline.expandItem(nil, expandChildren: true)
                if let selected { select(selected, in: outline) }
                onReorder(group.isFolder ? "Playlists" : group.title, items)
            }

            /// Updates `sections` and reloads `outline` synchronously on drop so folder moves feel instant.
            func applyLocalFolderMove(playlistID: String, toFolder folderID: String?, atIndex insertIndex: Int?, in outline: NSOutlineView) {
                guard let playlistsSection = sections.first(where: { $0.title == "Playlists" }) else { return }
                let prevSelected = outline.selectedRow >= 0 ? (outline.item(atRow: outline.selectedRow) as? Node)?.item : nil
                var movedNode: Node?
                if let topIdx = playlistsSection.children.firstIndex(where: {
                    if case .playlist(let id) = $0.item { return id == playlistID }
                    return false
                }) {
                    movedNode = playlistsSection.children.remove(at: topIdx)
                } else {
                    for folder in playlistsSection.children where folder.isFolder {
                        if let subIdx = folder.children.firstIndex(where: {
                            if case .playlist(let id) = $0.item { return id == playlistID }
                            return false
                        }) {
                            movedNode = folder.children.remove(at: subIdx)
                            break
                        }
                    }
                }
                guard let movedNode else { return }
                NSAnimationContext.beginGrouping()
                NSAnimationContext.current.duration = 0
                if let folderID, let targetFolder = playlistsSection.children.first(where: {
                    if case .playlist(let id) = $0.item, $0.isFolder { return id == folderID }
                    return false
                }) {
                    let idx = insertIndex.map { max(0, min(targetFolder.children.count, $0)) } ?? targetFolder.children.count
                    targetFolder.children.insert(movedNode, at: idx)
                    outline.reloadData()
                    outline.expandItem(targetFolder)
                } else {
                    let idx = insertIndex.map { max(0, min(playlistsSection.children.count, $0)) } ?? playlistsSection.children.count
                    playlistsSection.children.insert(movedNode, at: idx)
                    outline.reloadData()
                }
                if let prevSelected {
                    select(prevSelected, in: outline)
                }
                NSAnimationContext.endGrouping()
                skipNextReload = true
            }

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
                guard let node = item as? Node else { return false }
                return node.isGroup || node.isFolder
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

            func outlineViewItemWillCollapse(_ notification: Notification) {
                endInlineEditAndDeselect(in: notification.object as? NSOutlineView)
            }

            func outlineViewItemWillExpand(_ notification: Notification) {
                endInlineEditAndDeselect(in: notification.object as? NSOutlineView)
            }

            private func endInlineEditAndDeselect(in outline: NSOutlineView?) {
                guard let outline else { return }
                var ended = false
                outline.enumerateAvailableRowViews { rowView, _ in
                    if let cell = rowView.view(atColumn: 0) as? SidebarCell, cell.isEditingInline {
                        cell.finishInlineEdit(commit: true)
                        ended = true
                    }
                }
                if ended {
                    outline.window?.makeFirstResponder(outline)
                }
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
                if let plus = (cell as? SidebarCell)?.plusButton, let sidebarCell = cell as? SidebarCell {
                    let showMainPlus = node.isMain && Self.addable.contains(media)
                    let showPlaylistsPlus = node.isGroup && !node.isMain && node.title == "Playlists"
                    plus.isHidden = !(showMainPlus || showPlaylistsPlus)
                    sidebarCell.resetPlus()
                    if showPlaylistsPlus {
                        sidebarCell.onPlus = { [weak self, weak plus, weak sidebarCell] in
                            guard let self, let plus, let sidebarCell else { return }
                            self.showPlaylistsMenu(from: plus, in: sidebarCell, includeAddMusicFolder: false)
                        }
                    } else if node.isMain && media == .music {
                        sidebarCell.onPlus = { [weak self, weak plus, weak sidebarCell] in
                            guard let self, let plus, let sidebarCell else { return }
                            self.showPlaylistsMenu(from: plus, in: sidebarCell, includeAddMusicFolder: true)
                        }
                    } else {
                        let target = media
                        sidebarCell.onPlus = { [weak self] in self?.onAdd(target) }
                    }
                }
                if case .playlist(let id) = node.item {
                    (cell as? SidebarCell)?.onRenameCommit = { [weak self] name in
                        self?.onRenamePlaylist(id, name)
                    }
                } else {
                    (cell as? SidebarCell)?.onRenameCommit = nil
                }
                if node.subscriptionID != nil {
                    let badge = node.sourcePluginID.flatMap { pid in
                        PluginController.shared.plugins.first(where: { $0.id == pid })?.badgeSVG
                    }
                    let composite = subscriptionSidebarSymbol(
                        pluginID: node.sourcePluginID,
                        parsedBadge: badge,
                        description: node.title
                    )
                    (cell as? SidebarCell)?.customIcon = composite
                    cell.imageView?.image = composite
                } else if let icon = node.icon {
                    let image = systemSymbol(icon)
                    // AppKit automatically substitutes filled variants in source lists. Keep the
                    // TV Shows glyph on the explicitly requested outline `tv`, selected or not.
                    (cell as? SidebarCell)?.customIcon = customSymbols[icon] != nil || icon == "tv" || icon == "microphone.dynamic.on.stand" ? image : nil
                    cell.imageView?.image = image
                }
                if let sidebarCell = cell as? SidebarCell {
                    if node.isSyncing {
                        sidebarCell.ensureSyncIndicators()
                        sidebarCell.syncSpinner?.isHidden = false
                        sidebarCell.syncSpinner?.startAnimation(nil)
                        sidebarCell.errorIndicator?.isHidden = true
                    } else if node.hasError {
                        sidebarCell.ensureSyncIndicators()
                        sidebarCell.syncSpinner?.stopAnimation(nil)
                        sidebarCell.syncSpinner?.isHidden = true
                        sidebarCell.errorIndicator?.isHidden = false
                        sidebarCell.errorIndicator?.toolTip = node.errorTooltip ?? "Sync failed"
                    } else {
                        sidebarCell.syncSpinner?.stopAnimation(nil)
                        sidebarCell.syncSpinner?.isHidden = true
                        sidebarCell.errorIndicator?.isHidden = true
                    }
                }
                // Placeholder rows ("No iPod connected", "New Playlist…") are dimmed, as in SwiftUI.
                let dimmed = !node.isGroup && node.item == nil
                if !node.isGroup {
                    cell.textField?.textColor = dimmed ? .secondaryLabelColor : nil
                    cell.textField?.lineBreakMode = MacChrome.shared.isAnimatingSidebar ? .byClipping : .byTruncatingTail
                }
                (cell as? SidebarCell)?.dimmed = dimmed
                (cell as? SidebarCell)?.updateTint()
                return cell
            }

            func outlineViewSelectionDidChange(_ notification: Notification) {
                if let outline = notification.object as? NSOutlineView {
                    outline.window?.invalidateCursorRects(for: outline)
                }
                guard !isSyncingSelection, let outline = notification.object as? NSOutlineView,
                      let item = (outline.item(atRow: outline.selectedRow) as? Node)?.item
                else { return }
                onSelect(item)
            }

            var suppressedSelectionItem: SidebarItem?

            func select(_ selection: SidebarItem, in outline: NSOutlineView) {
                if let suppressed = suppressedSelectionItem {
                    if selection == suppressed { return }
                    suppressedSelectionItem = nil
                }
                let row = findNode(for: selection).map { outline.row(forItem: $0) } ?? -1
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
                text.lineBreakMode = group ? .byClipping : .byTruncatingTail
                text.usesSingleLineMode = true
                text.maximumNumberOfLines = 1
                text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                text.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(text)
                cell.textField = text
                // Whatever ties a title to the row's right edge gives way first. While the sidebar slides open
                // or shut the row gets narrower than its icon and title together: with every constraint
                // required, Auto Layout broke the icon's width instead (22 pt down to 3), and the glyph,
                // centered in that frame, drifted left. The title is what shrinks; the icon never moves.
                func yielding(_ constraint: NSLayoutConstraint) -> NSLayoutConstraint {
                    constraint.priority = NSLayoutConstraint.Priority(999)
                    return constraint
                }
                var constraints: [NSLayoutConstraint] = group && !main
                    ? [text.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -2)]
                    : [text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)]
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
                        yielding(text.trailingAnchor.constraint(lessThanOrEqualTo: eject.leadingAnchor, constant: -2)),
                    ]
                } else if !group {
                    constraints.append(yielding(text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2)))
                } else {
                    constraints.append(yielding(text.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4)))
                }
                if group && !main {
                    // A sub-section's caption lines up with the rows' icons, as in the Finder.
                    constraints.append(text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: SidebarMetrics.subHeaderTextX))
                    let plus = NSButton(image: systemSymbol("plus.circle", description: "Add Playlist", pointSize: 14) ?? NSImage(), target: nil, action: nil)
                    plus.isBordered = false
                    plus.contentTintColor = .secondaryLabelColor
                    plus.toolTip = "Add Playlist or Music Folder"
                    plus.isHidden = true
                    plus.target = cell
                    plus.action = #selector(SidebarCell.plusClicked(_:))
                    plus.translatesAutoresizingMaskIntoConstraints = false
                    cell.addSubview(plus)
                    cell.plusButton = plus
                    constraints += [
                        plus.widthAnchor.constraint(equalToConstant: 22),
                        plus.heightAnchor.constraint(equalToConstant: 22),
                        plus.centerYAnchor.constraint(equalTo: text.centerYAnchor),
                        plus.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                    ]
                } else if group {
                    constraints.append(text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2))
                    let label = NSTextField(labelWithString: "")
                    label.font = .systemFont(ofSize: SidebarMetrics.titleFontSize, weight: .bold)
                    label.textColor = .white
                    label.lineBreakMode = .byClipping
                    label.usesSingleLineMode = true
                    label.maximumNumberOfLines = 1
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
                        yielding(label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -24)),
                    ]
                } else {
                    let image = FlatImageView()
                    image.translatesAutoresizingMaskIntoConstraints = false
                    image.setContentCompressionResistancePriority(.required, for: .horizontal)
                    image.setContentHuggingPriority(.required, for: .horizontal)
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

    private final class DropInsertionLineView: NSView {
        var circleX: CGFloat = 10 { didSet { if oldValue != circleX { needsDisplay = true } } }
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
        }
        required init?(coder: NSCoder) { fatalError() }
        override func draw(_ dirtyRect: NSRect) {
            let accent = NSColor.controlAccentColor
            let circleDiameter: CGFloat = 7
            let midY = bounds.midY
            let circleRect = NSRect(x: circleX, y: midY - circleDiameter / 2, width: circleDiameter, height: circleDiameter)
            let linePath = NSBezierPath()
            linePath.lineWidth = 2
            linePath.move(to: NSPoint(x: circleRect.maxX, y: midY))
            linePath.line(to: NSPoint(x: bounds.maxX - 8, y: midY))
            accent.setStroke()
            linePath.stroke()

            let circlePath = NSBezierPath(ovalIn: circleRect)
            circlePath.lineWidth = 1.8
            NSColor.windowBackgroundColor.setFill()
            circlePath.fill()
            accent.setStroke()
            circlePath.stroke()
        }
    }

    /// Own the visual target explicitly: source-list AppKit feedback does not reliably set
    /// NSTableRowView.isTargetForDropOperation when custom rows draw a neutral selection.
    final class MusicDropOutlineView: NSOutlineView {
        weak var coordinator: Sidebar.Coordinator?
        private var dropRow: Int?
        private var contextTargetID: String?
        private var contextTargetRow: Int?
        private var pendingEditWork: DispatchWorkItem?
        private lazy var insertionLine: DropInsertionLineView = {
            let view = DropInsertionLineView(frame: .zero)
            view.isHidden = true
            addSubview(view, positioned: .above, relativeTo: nil)
            return view
        }()

        override func menu(for event: NSEvent) -> NSMenu? {
            let point = convert(event.locationInWindow, from: nil)
            let clickedRow = row(at: point)
            guard clickedRow >= 0,
                  let node = item(atRow: clickedRow) as? Sidebar.Node,
                  case .playlist(let id) = node.item else {
                return super.menu(for: event)
            }
            contextTargetID = id
            contextTargetRow = clickedRow
            let menu = NSMenu()
            if node.subscriptionID != nil {
                if node.isSyncing {
                    let stop = NSMenuItem(title: "Stop", action: #selector(contextStopSubscription), keyEquivalent: "")
                    stop.target = self
                    menu.addItem(stop)
                } else {
                    let refresh = NSMenuItem(title: "Refresh", action: #selector(contextRefreshSubscription), keyEquivalent: "")
                    refresh.target = self
                    menu.addItem(refresh)
                }
                if let sub = SubscriptionController.shared.subscription(forPlaylistID: id) {
                    let open = NSMenuItem(title: "Open in \(sub.sourceName)", action: #selector(contextOpenSubscriptionURL), keyEquivalent: "")
                    open.target = self
                    menu.addItem(open)
                }
                let rename = NSMenuItem(title: "Rename", action: #selector(contextRenamePlaylist), keyEquivalent: "")
                rename.target = self
                menu.addItem(rename)
                menu.addItem(.separator())
                let unsub = NSMenuItem(title: "Unsubscribe…", action: #selector(contextUnsubscribePlaylist), keyEquivalent: "")
                unsub.target = self
                menu.addItem(unsub)
                return menu
            }
            let rename = NSMenuItem(title: "Rename", action: #selector(contextRenamePlaylist), keyEquivalent: "")
            rename.target = self
            let delete = NSMenuItem(title: "Delete", action: #selector(contextDeletePlaylist), keyEquivalent: "")
            delete.target = self
            menu.addItem(rename)
            menu.addItem(delete)
            return menu
        }

        @objc private func contextRenamePlaylist() {
            guard let row = contextTargetRow else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      let cell = self.view(atColumn: 0, row: row, makeIfNecessary: true) as? Sidebar.SidebarCell else { return }
                cell.beginInlineEdit()
            }
        }

        @objc private func contextDeletePlaylist() {
            guard let id = contextTargetID else { return }
            coordinator?.onDeletePlaylist(id)
        }

        @objc private func contextRefreshSubscription() {
            guard let id = contextTargetID else { return }
            coordinator?.onRefreshSubscription(id)
        }

        @objc private func contextStopSubscription() {
            guard let id = contextTargetID else { return }
            coordinator?.onStopSubscription(id)
        }

        @objc private func contextOpenSubscriptionURL() {
            guard let id = contextTargetID,
                  let sub = SubscriptionController.shared.subscription(forPlaylistID: id),
                  let url = URL(string: sub.sourceURL) else { return }
            NSWorkspace.shared.open(url)
        }

        @objc private func contextUnsubscribePlaylist() {
            guard let id = contextTargetID else { return }
            coordinator?.onUnsubscribePlaylist(id)
        }

        override func mouseDown(with event: NSEvent) {
            pendingEditWork?.cancel()
            pendingEditWork = nil
            let startPoint = convert(event.locationInWindow, from: nil)
            var clickedRow = row(at: startPoint)
            if clickedRow >= 0,
               let responder = window?.firstResponder as? NSTextView,
               let clickedRowView = rowView(atRow: clickedRow, makeIfNecessary: false),
               responder.isDescendant(of: clickedRowView) {
                super.mouseDown(with: event)
                return
            }
            guard clickedRow >= 0,
                  let node = item(atRow: clickedRow) as? Sidebar.Node,
                  !node.isGroup,
                  node.item != nil,
                  let groupNode = parent(forItem: node) as? Sidebar.Node,
                  let window else {
                super.mouseDown(with: event)
                return
            }

            let canDrag = groupNode.children.count > 1 || groupNode.isFolder || {
                if case .playlist = node.item { return true }
                return false
            }()
            window.makeFirstResponder(self)

            let wasAlreadySelected = (clickedRow == selectedRow)
            let prevSelectedRow = (!wasAlreadySelected && selectedRow >= 0) ? (rowView(atRow: selectedRow, makeIfNecessary: false) as? NeutralSidebarRow) : nil
            let pressedRow = !wasAlreadySelected ? (rowView(atRow: clickedRow, makeIfNecessary: false) as? NeutralSidebarRow) : nil

            // Wait for either a click release, force-click pressure, or a drag past the movement threshold.
            var dragStarted = false
            var didForceClick = false
            while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .pressure]) {
                if next.type == .pressure {
                    if !wasAlreadySelected && !didForceClick && next.stage >= 2 {
                        didForceClick = true
                        pressedRow?.isPressed = true
                        prevSelectedRow?.suppressSelection = true
                    }
                    continue
                }
                let currentPoint = convert(next.locationInWindow, from: nil)
                if next.type == .leftMouseUp {
                    if wasAlreadySelected,
                       next.clickCount == 1,
                       case .playlist = node.item,
                       let cell = view(atColumn: 0, row: clickedRow, makeIfNecessary: false) as? Sidebar.SidebarCell,
                       let textField = cell.textField {
                        let textPt = cell.convert(currentPoint, from: self)
                        if textField.frame.insetBy(dx: -2, dy: -4).contains(textPt) {
                            pressedRow?.isPressed = false
                            prevSelectedRow?.suppressSelection = false
                            let work = DispatchWorkItem { [weak cell] in
                                cell?.beginInlineEdit()
                            }
                            pendingEditWork = work
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
                            window.makeFirstResponder(self)
                            return
                        }
                    }
                    if let coordinator, coordinator.outlineView(self, shouldSelectItem: node) {
                        coordinator.suppressedSelectionItem = nil
                        selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
                    }
                    pressedRow?.isPressed = false
                    prevSelectedRow?.suppressSelection = false
                    window.makeFirstResponder(self)
                    return
                }
                if !didForceClick && hypot(currentPoint.x - startPoint.x, currentPoint.y - startPoint.y) >= 4 {
                    dragStarted = true
                    break
                }
            }
            pressedRow?.isPressed = false
            prevSelectedRow?.suppressSelection = false
            guard dragStarted, canDrag else { return }

            if wasAlreadySelected, let item = node.item {
                coordinator?.suppressedSelectionItem = item
                coordinator?.isSyncingSelection = true
                deselectAll(nil)
                coordinator?.isSyncingSelection = false
            }

            let wasExpandedFolder = node.isFolder && isItemExpanded(node)
            if wasExpandedFolder {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.18
                    context.allowsImplicitAnimation = true
                    self.animator().collapseItem(node)
                }
                let refreshed = row(forItem: node)
                if refreshed >= 0 { clickedRow = refreshed }
            }

            let siblingRows = groupNode.children.compactMap { child -> Int? in
                let r = row(forItem: child)
                return r >= 0 ? r : nil
            }
            guard siblingRows.count == groupNode.children.count,
                  let startIndex = siblingRows.firstIndex(of: clickedRow) else { return }

            let slotRects = siblingRows.map { rect(ofRow: $0) }
            let rowViews = siblingRows.map { rowView(atRow: $0, makeIfNecessary: true) }
            let blockRowViews: [[NSTableRowView]] = groupNode.children.map { child in
                var rows: [Int] = []
                let r = row(forItem: child)
                if r >= 0 { rows.append(r) }
                if child.isFolder && isItemExpanded(child) {
                    for sub in child.children {
                        let sr = row(forItem: sub)
                        if sr >= 0 { rows.append(sr) }
                    }
                }
                return rows.compactMap { rowView(atRow: $0, makeIfNecessary: true) }
            }
            let blockHeights: [CGFloat] = groupNode.children.map { child in
                var h: CGFloat = 0
                let r = row(forItem: child)
                if r >= 0 { h += rect(ofRow: r).height }
                if child.isFolder && isItemExpanded(child) {
                    for sub in child.children {
                        let sr = row(forItem: sub)
                        if sr >= 0 { h += rect(ofRow: sr).height }
                    }
                }
                return h
            }
            let startRect = slotRects[startIndex]
            guard let draggedRowView = rowViews[startIndex] else { return }

            let neutralRow = draggedRowView as? NeutralSidebarRow
            let draggedCell = draggedRowView.view(atColumn: 0) as? Sidebar.SidebarCell
            neutralRow?.suppressSelection = true
            draggedCell?.forceBlackIcon = true
            draggedRowView.layoutSubtreeIfNeeded()
            draggedRowView.displayIfNeeded()

            guard let snapshot = rowSnapshot(draggedRowView, rect: startRect) else {
                draggedCell?.forceBlackIcon = false
                neutralRow?.suppressSelection = false
                return
            }

            let hostView = window.contentView ?? self
            let startInHost = convert(startRect, to: hostView)
            let startPointInHost = hostView.convert(event.locationInWindow, from: nil)
            let floating = NSImageView(frame: startInHost)
            floating.image = snapshot
            floating.alphaValue = 0.85
            floating.wantsLayer = true
            floating.layer?.shadowColor = NSColor.black.cgColor
            floating.layer?.shadowOpacity = 0.25
            floating.layer?.shadowRadius = 6
            floating.layer?.shadowOffset = CGSize(width: 0, height: -2)
            hostView.addSubview(floating, positioned: .above, relativeTo: nil)
            draggedRowView.alphaValue = 0

            coordinator?.isReordering = true
            let grabOffsetX = startPointInHost.x - startInHost.minX
            let grabOffsetY = startPointInHost.y - startInHost.minY
            var slots = Array(0..<siblingRows.count)
            var currentIndex = startIndex
            var isValidTarget = true
            var cancelled = false
            let groupTop = slotRects.first!.minY
            let groupBottom = groupTop + blockHeights.reduce(0, +)
            let rowH = startRect.height

            let draggedPlaylistID: String? = {
                if case .playlist(let id) = node.item, !node.isFolder { return id }
                return nil
            }()
            let draggedAnyPlaylistID: String? = {
                if case .playlist(let id) = node.item { return id }
                return nil
            }()
            var hoveredFolderID: String?
            var hoveredFolderRow: NeutralSidebarRow?
            var targetFolderInsert: (folderID: String, index: Int)?
            var moveToTopLevelIndex: Int?
            var hoveredDeviceID: String?

            while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .keyDown, .pressure]) {
                if next.type == .pressure { continue }
                if next.type == .keyDown {
                    if next.keyCode == 53 { // Escape
                        cancelled = true
                        break
                    }
                    continue
                }
                if next.type == .leftMouseDragged {
                    autoscroll(with: next)
                    let pointer = convert(next.locationInWindow, from: nil)
                    let pointerInHost = hostView.convert(next.locationInWindow, from: nil)
                    floating.frame.origin = NSPoint(x: pointerInHost.x - grabOffsetX, y: pointerInHost.y - grabOffsetY)

                    if draggedAnyPlaylistID != nil,
                       let hitDevice = MediaRailDropBridge.shared.deviceAt(windowPoint: next.locationInWindow) {
                        hoveredDeviceID = hitDevice
                        NSCursor.dragCopy.set()
                        MediaRailDropBridge.shared.setHighlighted(true)
                        hoveredFolderRow?.isMusicDropTarget = false
                        hoveredFolderRow = nil
                        hoveredFolderID = nil
                        targetFolderInsert = nil
                        moveToTopLevelIndex = nil
                        isValidTarget = false
                        insertionLine.isHidden = true
                        if currentIndex != startIndex {
                            slots = Array(0..<siblingRows.count)
                            currentIndex = startIndex
                            animateSiblingRows(slots: slots, draggedSlotValue: startIndex, blockRowViews: blockRowViews, blockHeights: blockHeights, groupTop: groupTop)
                        }
                        continue
                    } else if hoveredDeviceID != nil {
                        hoveredDeviceID = nil
                        NSCursor.arrow.set()
                        MediaRailDropBridge.shared.setHighlighted(false)
                    }

                    let dx = abs(pointer.x - startPoint.x)
                    let dy = abs(pointer.y - startPoint.y)
                    let horizontalIntent = dx > 28 && dx > dy * 1.5
                    let insideX = !horizontalIntent && pointer.x >= bounds.minX && pointer.x <= bounds.maxX

                    var newFolderID: String?
                    var newFolderRow: NeutralSidebarRow?
                    var newFolderInsert: (folderID: String, index: Int, y: CGFloat, circleX: CGFloat)?
                    if insideX, draggedPlaylistID != nil {
                        let hitRow = row(at: NSPoint(x: bounds.midX, y: pointer.y))
                        if hitRow >= 0, let targetNode = item(atRow: hitRow) as? Sidebar.Node {
                            if targetNode !== node,
                               targetNode.isFolder,
                               case .playlist(let fID) = targetNode.item {
                                newFolderID = fID
                                newFolderRow = rowView(atRow: hitRow, makeIfNecessary: false) as? NeutralSidebarRow
                            } else if let folderParent = parent(forItem: targetNode) as? Sidebar.Node,
                                      folderParent.isFolder,
                                      folderParent !== groupNode,
                                      case .playlist(let fID) = folderParent.item {
                                var boundaries: [(index: Int, y: CGFloat)] = []
                                var childCircleX: CGFloat = 10 + indentationPerLevel
                                for (idx, sub) in folderParent.children.enumerated() {
                                    let sr = row(forItem: sub)
                                    if sr >= 0 {
                                        let rc = rect(ofRow: sr)
                                        if boundaries.isEmpty {
                                            boundaries.append((0, rc.minY))
                                            if let childCell = view(atColumn: 0, row: sr, makeIfNecessary: false) as? Sidebar.SidebarCell,
                                               let iv = childCell.imageView {
                                                childCircleX = convert(iv.bounds, from: iv).minX - 2
                                            }
                                        }
                                        boundaries.append((idx + 1, rc.maxY))
                                    }
                                }
                                if let best = boundaries.min(by: { abs($0.y - pointer.y) < abs($1.y - pointer.y) }) {
                                    newFolderInsert = (fID, best.index, best.y, childCircleX)
                                }
                            }
                        }
                    }
                    if hoveredFolderRow !== newFolderRow {
                        hoveredFolderRow?.isMusicDropTarget = false
                        newFolderRow?.isMusicDropTarget = true
                        hoveredFolderRow = newFolderRow
                    }
                    hoveredFolderID = newFolderID

                    if newFolderID != nil {
                        targetFolderInsert = nil
                        isValidTarget = false
                        moveToTopLevelIndex = nil
                        insertionLine.isHidden = true
                        if currentIndex != startIndex {
                            slots = Array(0..<siblingRows.count)
                            currentIndex = startIndex
                            animateSiblingRows(slots: slots, draggedSlotValue: startIndex, blockRowViews: blockRowViews, blockHeights: blockHeights, groupTop: groupTop)
                        }
                        continue
                    }

                    if let insert = newFolderInsert {
                        targetFolderInsert = (insert.folderID, insert.index)
                        isValidTarget = false
                        moveToTopLevelIndex = nil
                        insertionLine.circleX = insert.circleX
                        insertionLine.frame = NSRect(x: 0, y: insert.y - 4, width: bounds.width, height: 8)
                        insertionLine.isHidden = false
                        addSubview(insertionLine, positioned: .above, relativeTo: nil)
                        if currentIndex != startIndex {
                            slots = Array(0..<siblingRows.count)
                            currentIndex = startIndex
                            animateSiblingRows(slots: slots, draggedSlotValue: startIndex, blockRowViews: blockRowViews, blockHeights: blockHeights, groupTop: groupTop)
                        }
                        continue
                    }
                    targetFolderInsert = nil

                    let insideGroupY = !groupNode.isFolder
                        ? pointer.y >= groupTop - rowH * 0.5
                        : (pointer.y >= groupTop - rowH * 0.5 && pointer.y <= groupBottom + rowH * 0.5)
                    if insideX && insideGroupY {
                        isValidTarget = true
                        moveToTopLevelIndex = nil
                        insertionLine.isHidden = true
                        let midY = pointer.y - grabOffsetY + rowH * 0.5
                        var slotMids: [CGFloat] = []
                        slotMids.reserveCapacity(slots.count)
                        var sy = groupTop
                        for originalIndex in slots {
                            let h = blockHeights[originalIndex]
                            slotMids.append(sy + h * 0.5)
                            sy += h
                        }
                        let targetIndex = slots.indices.min {
                            abs(midY - slotMids[$0]) < abs(midY - slotMids[$1])
                        } ?? currentIndex
                        let targetIsFolder = draggedPlaylistID != nil && groupNode.children[slots[targetIndex]].isFolder
                        if targetIndex != currentIndex, !targetIsFolder {
                            let moved = slots.remove(at: currentIndex)
                            slots.insert(moved, at: targetIndex)
                            currentIndex = targetIndex
                            animateSiblingRows(slots: slots, draggedSlotValue: startIndex, blockRowViews: blockRowViews, blockHeights: blockHeights, groupTop: groupTop)
                        }
                    } else {
                        isValidTarget = false
                        if insideX && groupNode.isFolder && draggedPlaylistID != nil,
                           let playlistsSection = coordinator?.sections.first(where: { $0.title == "Playlists" }) {
                            let sectionRow = row(forItem: playlistsSection)
                            let sectionMinY = sectionRow >= 0 ? rect(ofRow: sectionRow).minY : 0
                            if pointer.y >= sectionMinY {
                                let topNodes = playlistsSection.children
                                var boundaries: [(index: Int, y: CGFloat)] = []
                                for (idx, child) in topNodes.enumerated() {
                                    let r = row(forItem: child)
                                    if r >= 0 {
                                        let rc = rect(ofRow: r)
                                        if boundaries.isEmpty { boundaries.append((0, rc.minY)) }
                                        var maxY = rc.maxY
                                        if child.isFolder {
                                            for sub in child.children {
                                                let sr = row(forItem: sub)
                                                if sr >= 0 { maxY = max(maxY, rect(ofRow: sr).maxY) }
                                            }
                                        }
                                        boundaries.append((idx + 1, maxY))
                                    }
                                }
                                let best = boundaries.min(by: { abs($0.y - pointer.y) < abs($1.y - pointer.y) })
                                let insertY = best?.y ?? groupBottom
                                moveToTopLevelIndex = best?.index ?? topNodes.count
                                insertionLine.circleX = 10
                                insertionLine.frame = NSRect(x: 0, y: insertY - 4, width: bounds.width, height: 8)
                                insertionLine.isHidden = false
                                addSubview(insertionLine, positioned: .above, relativeTo: nil)
                            } else {
                                moveToTopLevelIndex = nil
                                insertionLine.isHidden = true
                            }
                        } else {
                            moveToTopLevelIndex = nil
                            insertionLine.isHidden = true
                        }
                        if currentIndex != startIndex {
                            slots = Array(0..<siblingRows.count)
                            currentIndex = startIndex
                            animateSiblingRows(slots: slots, draggedSlotValue: startIndex, blockRowViews: blockRowViews, blockHeights: blockHeights, groupTop: groupTop)
                        }
                    }
                } else if next.type == .leftMouseUp {
                    break
                }
            }

            insertionLine.isHidden = true
            hoveredFolderRow?.isMusicDropTarget = false
            NSCursor.arrow.set()
            MediaRailDropBridge.shared.setHighlighted(false)
            if (cancelled || !isValidTarget) && currentIndex != startIndex {
                slots = Array(0..<siblingRows.count)
                currentIndex = startIndex
                var y = groupTop
                for originalIndex in slots {
                    if originalIndex == startIndex {
                        y += blockHeights[originalIndex]
                        continue
                    }
                    for rv in blockRowViews[originalIndex] {
                        rv.frame.origin.y = y
                        y += rv.frame.height
                    }
                }
            }

            let finalIndex = (!cancelled && isValidTarget) ? currentIndex : startIndex
            let didFolderMove = !cancelled && draggedPlaylistID != nil && (hoveredFolderID != nil || targetFolderInsert != nil || moveToTopLevelIndex != nil)
            floating.removeFromSuperview()
            draggedCell?.forceBlackIcon = false
            neutralRow?.suppressSelection = false
            if !didFolderMove {
                draggedRowView.alphaValue = 1
            }
            coordinator?.isReordering = false
            if let draggedAnyPlaylistID, let hoveredDeviceID, !cancelled {
                coordinator?.onSendPlaylistToDevice(draggedAnyPlaylistID, hoveredDeviceID)
            } else if !cancelled, let draggedPlaylistID, let hoveredFolderID {
                coordinator?.applyLocalFolderMove(playlistID: draggedPlaylistID, toFolder: hoveredFolderID, atIndex: nil, in: self)
                coordinator?.onMovePlaylistToFolder(draggedPlaylistID, hoveredFolderID, nil)
            } else if !cancelled, let draggedPlaylistID, let insert = targetFolderInsert {
                coordinator?.applyLocalFolderMove(playlistID: draggedPlaylistID, toFolder: insert.folderID, atIndex: insert.index, in: self)
                coordinator?.onMovePlaylistToFolder(draggedPlaylistID, insert.folderID, insert.index)
            } else if !cancelled, let draggedPlaylistID, let topIdx = moveToTopLevelIndex {
                coordinator?.applyLocalFolderMove(playlistID: draggedPlaylistID, toFolder: nil, atIndex: topIdx, in: self)
                coordinator?.onMovePlaylistToFolder(draggedPlaylistID, nil, topIdx)
            } else if finalIndex != startIndex {
                let movedNode = groupNode.children.remove(at: startIndex)
                groupNode.children.insert(movedNode, at: finalIndex)
                coordinator?.commitReorder(group: groupNode, in: self)
            }
            if wasExpandedFolder {
                NSAnimationContext.beginGrouping()
                NSAnimationContext.current.duration = 0
                expandItem(node)
                NSAnimationContext.endGrouping()
            }
        }

        override func keyDown(with event: NSEvent) {
            if (event.keyCode == 36 || event.keyCode == 76), selectedRow >= 0,
               let node = item(atRow: selectedRow) as? Sidebar.Node,
               case .playlist = node.item,
               let cell = view(atColumn: 0, row: selectedRow, makeIfNecessary: false) as? Sidebar.SidebarCell {
                cell.beginInlineEdit()
                return
            }
            if (event.keyCode == 51 || event.keyCode == 117), selectedRow >= 0,
               let node = item(atRow: selectedRow) as? Sidebar.Node,
               case .playlist(let id) = node.item,
               node.subscriptionID != nil {
                coordinator?.onUnsubscribePlaylist(id)
                return
            }
            super.keyDown(with: event)
        }

        private func animateSiblingRows(slots: [Int], draggedSlotValue: Int, blockRowViews: [[NSTableRowView]], blockHeights: [CGFloat], groupTop: CGFloat) {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                var y = groupTop
                for originalIndex in slots {
                    if originalIndex == draggedSlotValue {
                        y += blockHeights[originalIndex]
                        continue
                    }
                    for rv in blockRowViews[originalIndex] {
                        rv.animator().frame.origin.y = y
                        y += rv.frame.height
                    }
                }
            }
        }

        private func rowSnapshot(_ rowView: NSTableRowView, rect: NSRect) -> NSImage? {
            guard let rep = rowView.bitmapImageRepForCachingDisplay(in: rowView.bounds) else { return nil }
            rowView.cacheDisplay(in: rowView.bounds, to: rep)
            let image = NSImage(size: rect.size)
            image.addRepresentation(rep)
            return image
        }
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
        private enum DropTarget {
            case device(String)
            case playlist(String)
        }

        private func dropTarget(for sender: any NSDraggingInfo) -> (row: Int, target: DropTarget)? {
            let row = self.row(at: convert(sender.draggingLocation, from: nil))
            guard row >= 0, let node = item(atRow: row) as? Sidebar.Node,
                  let payload = TrackDrag.payload, musicDragPayload(in: sender.draggingPasteboard) == payload,
                  !TrackDrag.ids.isEmpty else { return nil }
            switch node.item {
            case .device(let id):
                return (row, .device(id))
            case .playlist(let id) where !node.isFolder:
                return (row, .playlist(id))
            default:
                return nil
            }
        }
        private func operation(for sender: any NSDraggingInfo) -> NSDragOperation {
            guard let hit = dropTarget(for: sender) else { highlightDrop(row: nil); return [] }
            highlightDrop(row: hit.row)
            return .copy
        }
        override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { operation(for: sender) }
        override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { operation(for: sender) }
        override func draggingExited(_ sender: (any NSDraggingInfo)?) { highlightDrop(row: nil) }
        override func draggingEnded(_ sender: any NSDraggingInfo) { highlightDrop(row: nil) }
        override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { dropTarget(for: sender) != nil }
        override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
            defer { highlightDrop(row: nil) }
            guard let hit = dropTarget(for: sender) else { return false }
            let pasteboardPayload = musicDragPayload(in: sender.draggingPasteboard)
            switch hit.target {
            case .device(let id):
                return TrackDrag.accept(pasteboardPayload, device: id)
            case .playlist(let id):
                guard let pasteboardPayload, pasteboardPayload == TrackDrag.payload, !TrackDrag.ids.isEmpty else { return false }
                coordinator?.onAddTracksToPlaylist(TrackDrag.ids, id)
                return true
            }
        }
        override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) { highlightDrop(row: nil) }
    }

    final class NeutralSidebarRow: NSTableRowView {
        /// Rows of a source-list table render through their layer (`updateLayer`) on recent macOS, which never
        /// calls the `draw…` overrides below. Asking for plain drawing makes the rows draw the selection and
        /// the drop highlight themselves.
        override var wantsUpdateLayer: Bool { false }
        var isMusicDropTarget = false { didSet { refreshFeedback() } }
        var isPressed = false { didSet { if oldValue != isPressed { refreshFeedback() } } }
        var suppressSelection = false { didSet { refreshFeedback() } }
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
            else if isPressed || (isSelected && !suppressSelection) {
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
            addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
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
