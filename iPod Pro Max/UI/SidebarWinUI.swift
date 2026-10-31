#if canImport(WinUIBackend)
    import Foundation
    import SwiftCrossUI
    import UWP
    import WinUI
    import UWP
    import WinUIBackend
    import WindowsFoundation

    /// On WinUI the sidebar is drawn like macOS's source list, to `SidebarMetrics`: one ListView per
    /// section (native selection and keyboard handling) under a header whose chevron fades in on
    /// hover and collapses the section, its rows sliding up under the header. The selection is the
    /// Mac's (accent while the sidebar has focus, gray otherwise), not WinUI's. None of its labels
    /// go through SwiftCrossUI's layout, which the chrome reruns on every frame of the slide.
    ///
    /// It takes whatever width the split view gives it (zero once hidden); during a slide the chrome
    /// gives the sections the open width, right-aligned and clipped, so the rows slide with the
    /// pane's edge instead of squeezing. Transparent: the window's acrylic shows through.
    struct Sidebar: WinUIElementRepresentable {
        // Bindings, not values: SwiftCrossUI used to hand a native view's updates the values it
        // was created with (see scripts/patches/representables.patch). WinUI has its own Binding.
        @SwiftCrossUI.Binding var devices: [String]
        @SwiftCrossUI.Binding var library: Library?
        @SwiftCrossUI.Binding var selection: SidebarItem
        @SwiftCrossUI.Binding var busyDevices: Set<String>
        var onEject: (SidebarItem) -> Void = { _ in }

        private var playlists: [Playlist] { library?.playlists ?? [] }

        func makeCoordinator() -> Coordinator { Coordinator() }

        func makeWinUIElement(context: Context) -> WinUI.Grid {
            let content = StackPanel()
            // Below the title area, where dragging moves the window.
            content.margin = Thickness(left: 0, top: titleBarHeight, right: 0, bottom: 0)
            context.coordinator.content = content
            let scroll = ScrollViewer()
            scroll.content = content
            let root = WinUI.Grid()
            root.children.append(scroll)
            // The chrome owns the split view (width, slide): it finds it from here once it's on screen.
            root.loaded.addHandler { _, _ in WinUIChrome.shared.attach(sidebar: root) }
            return root
        }

        func updateWinUIElement(_ root: WinUI.Grid, context: Context) {
            let coordinator = context.coordinator
            coordinator.onSelect = { selection = $0 }
            coordinator.onEject = onEject
            let dark = context.environment.colorScheme == .dark
            let key = devices.map { $0 + (ConnectedDeviceTitles.names[$0] ?? "") } + ["|"] + playlists.map { $0.id + $0.name } + [dark ? "dark" : "light"]
            if key != coordinator.key {
                coordinator.key = key
                coordinator.rebuild(sidebarSections(devices: devices, playlists: playlists), dark: dark)
            }
            coordinator.select(selection)
            coordinator.updateActivity(busyDevices)
        }

        func sizeThatFits(_ proposal: ProposedViewSize, winUIElement: WinUI.Grid, context: Context) -> ViewSize {
            ViewSize(proposal.width ?? sidebarWidth, proposal.height ?? 400)
        }

        @MainActor
        final class Coordinator {
            var content: StackPanel?
            var key: [String] = []
            var onSelect: (SidebarItem) -> Void = { _ in }
            var onEject: (SidebarItem) -> Void = { _ in }

            fileprivate typealias Cell = (cell: WinUI.Grid, glyph: TextBlock, label: TextBlock, eject: EjectButton?, row: SidebarSection.Row)

            fileprivate final class Section {
                let title: String
                let rows: WinUI.Grid
                let list: ListView
                let chevron: TextBlock
                let cells: [Cell]
                var open: Bool
                /// Expand or collapse in progress: when it started and the heights it goes between.
                var slide: (start: Date?, from: Double, to: Double)?

                init(title: String, rows: WinUI.Grid, list: ListView, chevron: TextBlock, cells: [Cell], open: Bool) {
                    self.title = title
                    self.rows = rows
                    self.list = list
                    self.chevron = chevron
                    self.cells = cells
                    self.open = open
                }

                var fullHeight: Double { Double(cells.count) * SidebarMetrics.rowHeight }
                var items: [SidebarItem?] { cells.map(\.row.item) }
            }

            private var sections: [Section] = []
            /// Kept across rebuilds (a playlist added doesn't reopen a closed section).
            private var collapsed: Set<String> = []
            private var dropTarget: SidebarItem?
            private var dark = false
            private weak var focusedList: ListView?
            private var isSyncingSelection = false
            private var rendering: EventCleanup?

            func rebuild(_ model: [SidebarSection], dark: Bool) {
                guard let content else { return }
                self.dark = dark
                isSyncingSelection = true
                defer { isSyncingSelection = false }
                content.children.clear()
                sections = model.enumerated().map { index, section in
                    makeSection(section, first: index == 0, into: content)
                }
                paintSelection()
            }

            // MARK: Building

            private func makeSection(_ model: SidebarSection, first: Bool, into content: StackPanel) -> Section {
                typealias M = SidebarMetrics
                let open = !collapsed.contains(model.title)

                let header = WinUI.Grid()
                header.height = M.headerHeight
                header.margin = Thickness(left: M.headerTextX, top: first ? M.topGap : M.sectionGap,
                                          right: M.chevronTrailing, bottom: 0)
                // Transparent rather than none: the whole header reports the pointer.
                header.background = brush(0, 0, 0, alpha: 0)
                for width in [GridLength(value: 1, gridUnitType: .star), GridLength(value: M.chevronWidth, gridUnitType: .pixel)] {
                    let column = ColumnDefinition()
                    column.width = width
                    header.columnDefinitions.append(column)
                }
                let title = TextBlock()
                title.text = model.title
                title.fontSize = M.headerFontSize
                title.fontWeight.weight = 700
                title.foreground = textBrush(secondary: true)
                title.verticalAlignment = .center
                header.children.append(title)

                let chevron = TextBlock()
                showSymbol("chevron.right", in: chevron, pointSize: 9, tint: .secondary, dark: dark)
                chevron.horizontalAlignment = .center
                chevron.verticalAlignment = .center
                chevron.opacity = 0
                chevron.opacityTransition = transition(0.15)
                chevron.rotation = open ? 90 : 0
                chevron.rotationTransition = transition(M.collapseDuration)
                chevron.centerPoint = Vector3(x: 4, y: 6, z: 0)
                let chevronTarget = WinUI.Grid()
                chevronTarget.background = brush(0, 0, 0, alpha: 0)
                chevronTarget.children.append(chevron)
                WinUI.Grid.setColumn(chevronTarget, 1)
                header.children.append(chevronTarget)
                header.pointerEntered.addHandler { _, _ in chevron.opacity = 1 }
                header.pointerExited.addHandler { _, _ in chevron.opacity = 0 }
                content.children.append(header)

                let list = ListView()
                list.selectionMode = .single
                list.verticalAlignment = .bottom
                WinUI.ScrollViewer.setVerticalScrollBarVisibility(list, .hidden)
                WinUI.ScrollViewer.setVerticalScrollMode(list, .disabled)
                hideWinUISelection(list)
                var cells: [Cell] = []
                for row in model.rows {
                    let (item, cell, glyph, label, eject) = makeRow(row)
                    list.items.append(item)
                    cells.append((cell, glyph, label, eject, row))
                }
                list.height = Double(model.rows.count) * M.rowHeight

                // The rows' box: its height animates and clips the list, held to its bottom, so the
                // rows slide up under the header.
                let rows = WinUI.Grid()
                rows.height = open ? list.height : 0
                rows.visibility = open ? .visible : .collapsed
                rows.children.append(list)
                content.children.append(rows)

                let section = Section(title: model.title, rows: rows, list: list, chevron: chevron, cells: cells, open: open)
                chevronTarget.tapped.addHandler { [weak self, weak section] _, _ in
                    guard let section else { return }
                    MainActor.assumeIsolated { self?.toggle(section) }
                }
                list.selectionChanged.addHandler { [weak self, weak section] _, _ in
                    guard let section else { return }
                    MainActor.assumeIsolated { self?.selectionChanged(in: section) }
                }
                list.gotFocus.addHandler { [weak self, weak list] _, _ in
                    MainActor.assumeIsolated {
                        self?.focusedList = list
                        self?.paintSelection()
                    }
                }
                list.lostFocus.addHandler { [weak self, weak list] _, _ in
                    MainActor.assumeIsolated {
                        if self?.focusedList === list { self?.focusedList = nil }
                        self?.paintSelection()
                    }
                }
                list.previewKeyDown.addHandler { [weak self, weak section] _, args in
                    guard let section, let args, args.key == .down || args.key == .up else { return }
                    MainActor.assumeIsolated {
                        if self?.leave(section, down: args.key == .down) == true { args.handled = true }
                    }
                }
                return section
            }

            /// Icon and title in a cell inset like the source list's selection.
            private func makeRow(_ row: SidebarSection.Row) -> (ListViewItem, WinUI.Grid, TextBlock, TextBlock, EjectButton?) {
                typealias M = SidebarMetrics
                let cell = WinUI.Grid()
                cell.margin = Thickness(left: M.selectionInset, top: 0, right: M.selectionInset, bottom: 0)
                cell.padding = Thickness(left: M.iconX - M.selectionInset, top: 0, right: 4, bottom: 0)
                cell.cornerRadius = CornerRadius(topLeft: M.selectionRadius, topRight: M.selectionRadius,
                                                 bottomRight: M.selectionRadius, bottomLeft: M.selectionRadius)
                for width in [GridLength(value: M.textX - M.iconX, gridUnitType: .pixel), GridLength(value: 1, gridUnitType: .star),
                              GridLength(value: 1, gridUnitType: .auto)] {
                    let column = ColumnDefinition()
                    column.width = width
                    cell.columnDefinitions.append(column)
                }
                let glyph = TextBlock()
                glyph.width = M.iconWidth
                glyph.textAlignment = .center
                glyph.horizontalAlignment = .left
                glyph.verticalAlignment = .center
                let label = TextBlock()
                label.text = row.title
                label.fontSize = M.rowFontSize
                label.textTrimming = .characterEllipsis
                label.verticalAlignment = .center
                WinUI.Grid.setColumn(label, 1)
                cell.children.append(glyph)
                cell.children.append(label)
                var eject: EjectButton?
                if row.ejectable, let sidebarItem = row.item {
                    let button = EjectButton(dark: dark) { [weak self] in self?.onEject(sidebarItem) }
                    WinUI.Grid.setColumn(button, 2)
                    cell.children.append(button)
                    eject = button
                }

                let item = ListViewItem()
                if case .device(let name) = row.item {
                    item.allowDrop = true
                    item.dragOver.addHandler { [weak self] _, args in
                        MainActor.assumeIsolated {
                            guard let args, TrackDrag.payload != nil else { return }
                            self?.dropTarget = row.item
                            self?.paintSelection()
                            args.acceptedOperation = .copy
                            args.handled = true
                        }
                    }
                    item.dragLeave.addHandler { [weak self] _, _ in
                        MainActor.assumeIsolated { self?.dropTarget = nil; self?.paintSelection() }
                    }
                    item.drop.addHandler { [weak self] _, args in
                        MainActor.assumeIsolated {
                            guard let args, TrackDrag.payload != nil else { return }
                            args.handled = true
                            do {
                                let deferral = try args.getDeferral()
                                do {
                                    guard var operation = try args.dataView.getTextAsync() else { try? deferral?.complete(); return }
                                    operation.completed = { operation, _ in
                                        let text = try? operation?.getResults()
                                        Task { @MainActor in
                                            defer { try? deferral?.complete(); self?.dropTarget = nil; self?.paintSelection() }
                                            if TrackDrag.accept(text, device: name) { args.acceptedOperation = .copy }
                                        }
                                    }
                                } catch {
                                    try? deferral?.complete()
                                    throw error
                                }
                            } catch { self?.dropTarget = nil; self?.paintSelection() }
                        }
                    }
                }
                item.content = cell
                item.height = M.rowHeight
                item.minHeight = 0
                item.padding = Thickness(left: 0, top: 0, right: 0, bottom: 0)
                item.margin = Thickness(left: 0, top: 0, right: 0, bottom: 0)
                item.horizontalContentAlignment = .stretch
                item.verticalContentAlignment = .stretch
                item.useSystemFocusVisuals = false
                if row.item == nil { item.isEnabled = false }
                return (item, cell, glyph, label, eject)
            }

            /// WinUI's own row backgrounds and selection pill, made transparent: the cells draw the
            /// Mac's selection instead.
            private func hideWinUISelection(_ list: ListView) {
                let resources = ResourceDictionary()
                for key in ["ListViewItemBackgroundPointerOver", "ListViewItemBackgroundPressed",
                            "ListViewItemBackgroundSelected", "ListViewItemBackgroundSelectedPointerOver",
                            "ListViewItemBackgroundSelectedPressed", "ListViewItemSelectionIndicatorBrush",
                            "ListViewItemSelectionIndicatorPointerOverBrush", "ListViewItemSelectionIndicatorPressedBrush"]
                {
                    _ = resources.insert(key, brush(0, 0, 0, alpha: 0))
                }
                list.resources = resources
            }

            // MARK: Selection

            func select(_ selection: SidebarItem) {
                for section in sections {
                    guard let index = section.items.firstIndex(of: selection) else { continue }
                    guard section.list.selectedIndex != Int32(index) else { return }
                    isSyncingSelection = true
                    for other in sections where other !== section { other.list.selectedIndex = -1 }
                    section.list.selectedIndex = Int32(index)
                    isSyncingSelection = false
                    paintSelection()
                    return
                }
            }

            /// One selection across the sections' lists.
            private func selectionChanged(in section: Section) {
                defer { paintSelection() }
                guard !isSyncingSelection else { return }
                let index = Int(section.list.selectedIndex)
                guard index >= 0, index < section.cells.count, let item = section.cells[index].row.item else { return }
                isSyncingSelection = true
                for other in sections where other !== section { other.list.selectedIndex = -1 }
                isSyncingSelection = false
                onSelect(item)
            }

            func updateActivity(_ busy: Set<String>) {
                for entry in sections.flatMap(\.cells) {
                    if case .device(let id) = entry.row.item { entry.eject?.isBusy = busy.contains(id) }
                }
            }

            /// The Mac's selection: accent with white text while the sidebar has focus, gray otherwise.
            private func paintSelection() {
                let focused = focusedList != nil
                let selectionRGB = sidebarSelectionRGB(focused: focused, dark: dark)
                for section in sections {
                    let selected = Int(section.list.selectedIndex)
                    for (index, entry) in section.cells.enumerated() {
                        let isSelected = index == selected
                        let emphasized = dropTarget != nil && entry.row.item == dropTarget
                        entry.cell.background = emphasized ? brush(0x00, 0x7A, 0xFF) : isSelected ? brush(selectionRGB.r, selectionRGB.g, selectionRGB.b) : nil
                        entry.label.foreground = emphasized ? brush(255, 255, 255) : textBrush(secondary: entry.row.item == nil)
                        // White glyph on the accent: the primary tint in dark mode is white.
                        showSymbol(entry.row.icon, in: entry.glyph, pointSize: 13,
                                   tint: emphasized ? .primary : entry.row.item == nil ? .secondary : .accent,
                                   dark: emphasized || dark)
                        entry.eject?.behind = emphasized ? .accent : isSelected ? .selected : .plain
                    }
                }
            }

            /// The arrow keys go on to the next open section, as in a single source list.
            private func leave(_ section: Section, down: Bool) -> Bool {
                guard let index = sections.firstIndex(where: { $0 === section }) else { return false }
                let selectable = section.items.indices.filter { section.items[$0] != nil }
                guard Int(section.list.selectedIndex) == (down ? selectable.last : selectable.first) else { return false }
                let order = down ? Array(sections[(index + 1)...]) : sections[..<index].reversed()
                for next in order where next.open {
                    let targets = next.items.indices.filter { next.items[$0] != nil }
                    guard let target = down ? targets.first : targets.last else { continue }
                    next.list.selectedIndex = Int32(target)
                    _ = try? next.list.focus(.keyboard)
                    return true
                }
                return false
            }

            // MARK: Collapse

            /// Slides the section's rows up under its header (or back down): the rows' box changes
            /// height every frame; the chevron turns with WinUI's own transition.
            private func toggle(_ section: Section) {
                section.open.toggle()
                if section.open { collapsed.remove(section.title) } else { collapsed.insert(section.title) }
                section.chevron.rotation = section.open ? 90 : 0
                section.rows.visibility = .visible
                section.slide = (nil, section.rows.actualHeight, section.open ? section.fullHeight : 0)
                if rendering == nil {
                    rendering = CompositionTarget.rendering.addHandler { [weak self] _, _ in
                        MainActor.assumeIsolated { self?.tick() }
                    }
                }
            }

            /// One frame of every expand or collapse in progress. The frame callback exists only
            /// while one is.
            private func tick() {
                let now = Date()
                var sliding = false
                for section in sections {
                    guard var slide = section.slide else { continue }
                    let start = slide.start ?? now
                    slide.start = start
                    let t = min(1, now.timeIntervalSince(start) / SidebarMetrics.collapseDuration)
                    let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
                    section.rows.height = slide.from + (slide.to - slide.from) * eased
                    if t < 1 {
                        section.slide = slide
                        sliding = true
                    } else {
                        section.slide = nil
                        // Closed rows leave the keyboard's path.
                        if !section.open { section.rows.visibility = .collapsed }
                    }
                }
                guard !sliding else { return }
                rendering?.dispose()
                rendering = nil
            }

            // MARK: Colors

            private func textBrush(secondary: Bool) -> SolidColorBrush {
                let value: UInt8 = dark ? 255 : 0
                return brush(value, value, value, alpha: secondary ? 0.5 : 0.85)
            }

            private func brush(_ r: UInt8, _ g: UInt8, _ b: UInt8, alpha: Double = 1) -> SolidColorBrush {
                let brush = SolidColorBrush()
                brush.color = UWP.Color(a: UInt8(alpha * 255), r: r, g: g, b: b)
                return brush
            }

            private func transition(_ seconds: Double) -> ScalarTransition {
                let transition = ScalarTransition()
                transition.duration = TimeSpan(duration: Int64(seconds * 10_000_000))
                return transition
            }
        }
    }

    /// The Finder's eject button: `eject.fill`, dim at rest, brighter under the pointer, white while
    /// held down (`ejectButtonRGB`). Ejects when released over it; the press never reaches the row,
    /// so it isn't selected.
    final class EjectButton: WinUI.Grid {
        private var rendering: EventCleanup?
        private var turnStarted = Date()
        var isBusy = false {
            didSet {
                guard oldValue != isBusy else { return }
                state = .normal
                ToolTipService.setToolTip(self, isBusy ? "Syncing…" : "Eject")
                rendering?.dispose()
                rendering = nil
                if isBusy { startRotation() } else { glyph.rotation = 0 }
                paint()
            }
        }
        var behind = EjectButtonBackground.plain { didSet { if behind != oldValue { paint() } } }
        private let glyph = TextBlock()
        private let dark: Bool
        private let action: () -> Void
        private var state = EjectButtonState.normal

        init(dark: Bool, action: @escaping () -> Void) {
            self.dark = dark
            self.action = action
            super.init()
            width = SidebarMetrics.ejectSize
            height = SidebarMetrics.ejectSize
            margin = Thickness(left: 2, top: 0, right: SidebarMetrics.ejectTrailing - 4, bottom: 0)
            verticalAlignment = .center
            // Transparent rather than none, so the whole square gets the pointer.
            let clear = SolidColorBrush()
            clear.color = UWP.Color(a: 0, r: 0, g: 0, b: 0)
            background = clear
            glyph.horizontalAlignment = .center
            glyph.verticalAlignment = .center
            children.append(glyph)
            ToolTipService.setToolTip(self, "Eject")
            paint()
            pointerEntered.addHandler { [weak self] _, _ in self?.set(.hover) }
            pointerExited.addHandler { [weak self] _, _ in
                guard let self, self.state != .pressed else { return }
                self.set(.normal)
            }
            pointerPressed.addHandler { [weak self] _, args in
                guard let self, let args else { return }
                guard !self.isBusy else { args.handled = true; return }
                _ = try? self.capturePointer(args.pointer)
                self.set(.pressed)
                args.handled = true
            }
            pointerReleased.addHandler { [weak self] _, args in
                guard let self, let args else { return }
                guard !self.isBusy else { args.handled = true; return }
                let wasPressed = self.state == .pressed
                var inside = false
                if let point = try? args.getCurrentPoint(self) {
                    inside = point.position.x >= 0 && point.position.y >= 0
                        && Double(point.position.x) <= self.actualWidth && Double(point.position.y) <= self.actualHeight
                }
                try? self.releasePointerCaptures()
                self.set(inside ? .hover : .normal)
                args.handled = true
                if wasPressed && inside { self.action() }
            }
            pointerCaptureLost.addHandler { [weak self] _, _ in
                guard let self, self.state == .pressed else { return }
                self.set(.normal)
            }
            tapped.addHandler { _, args in args?.handled = true }
            loaded.addHandler { [weak self] _, _ in
                if let self, self.isBusy { self.startRotation() }
            }
            unloaded.addHandler { [weak self] _, _ in
                self?.rendering?.dispose()
                self?.rendering = nil
            }
        }

        private func startRotation() {
            guard rendering == nil else { return }
            turnStarted = Date()
            rendering = CompositionTarget.rendering.addHandler { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.glyph.centerPoint = .init(x: Float(self.glyph.actualWidth / 2), y: Float(self.glyph.actualHeight / 2), z: 0)
                    self.glyph.rotation = Float(Date().timeIntervalSince(self.turnStarted).truncatingRemainder(dividingBy: 1) * 360)
                }
            }
        }

        private func set(_ newState: EjectButtonState) {
            guard newState != state else { return }
            state = newState
            paint()
        }

        private func paint() {
            let symbol = symbolCodepoints[isBusy ? "arrow.triangle.2.circlepath" : "eject.fill"].flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? ""
            if glyph.text != symbol {
                glyph.fontFamily = FontFamily("SF-Symbols")
                glyph.text = symbol
                glyph.fontSize = SidebarMetrics.ejectPointSize
            }
            let rgb = ejectButtonRGB(state, dark: dark, on: behind)
            let brush = SolidColorBrush()
            brush.color = UWP.Color(a: 255, r: rgb.r, g: rgb.g, b: rgb.b)
            glyph.foreground = brush
        }
    }
#endif
