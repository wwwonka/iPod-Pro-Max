#if canImport(WinUIBackend)
    import SwiftCrossUI
    import WinUI
    import WinUIBackend

    /// On WinUI the sidebar is a ListView: native rows, selection and keyboard handling, and none of
    /// its labels go through SwiftCrossUI's layout, which the chrome reruns on every frame of the
    /// slide. It takes whatever width the split view gives it (zero once hidden); during a slide the
    /// chrome gives the list the open width, right-aligned and clipped, so the rows slide with the
    /// pane's edge instead of squeezing.
    struct Sidebar: WinUIElementRepresentable {
        // Bindings, not values: SwiftCrossUI hands a native view's updates the values it was
        // created with, so the playlists loaded later never showed. (WinUI has its own Binding.)
        @SwiftCrossUI.Binding var devices: [String]
        @SwiftCrossUI.Binding var library: Library?
        @SwiftCrossUI.Binding var selection: SidebarItem

        private var playlists: [Playlist] { library?.playlists ?? [] }

        func makeCoordinator() -> Coordinator { Coordinator() }

        func makeWinUIElement(context: Context) -> WinUI.Grid {
            let coordinator = context.coordinator
            let list = ListView()
            // Room for the traffic lights and the toggle drawn over the window's corner. A margin,
            // not padding: that strip stays outside the list, where dragging moves the window.
            list.margin = Thickness(left: 0, top: 52, right: 0, bottom: 0)
            list.selectionChanged.addHandler { [weak coordinator] _, _ in coordinator?.selectionChanged() }
            coordinator.list = list
            let root = WinUI.Grid()
            root.children.append(list)
            // The chrome owns the split view (width, slide): it finds it from here once it's on screen.
            root.loaded.addHandler { _, _ in WinUIChrome.shared.attach(sidebar: root) }
            return root
        }

        func updateWinUIElement(_ root: WinUI.Grid, context: Context) {
            let coordinator = context.coordinator
            coordinator.onSelect = { selection = $0 }
            let dark = context.environment.colorScheme == .dark
            let key = devices + ["|"] + playlists.map { $0.id + $0.name } + [dark ? "dark" : "light"]
            if key != coordinator.key {
                coordinator.key = key
                coordinator.rebuild(devices: devices, playlists: playlists, dark: dark)
            }
            coordinator.select(selection)
        }

        func sizeThatFits(_ proposal: ProposedViewSize, winUIElement: WinUI.Grid, context: Context) -> ViewSize {
            ViewSize(proposal.width ?? sidebarWidth, proposal.height ?? 400)
        }

        @MainActor
        final class Coordinator {
            var list: ListView?
            var key: [String] = []
            var onSelect: (SidebarItem) -> Void = { _ in }
            /// Item of each row by index; nil for headers and placeholders.
            private var items: [SidebarItem?] = []
            private var isSyncingSelection = false

            func rebuild(devices: [String], playlists: [Playlist], dark: Bool) {
                guard let rows = list?.items else { return }
                isSyncingSelection = true
                rows.clear()
                items = []
                header("iPods")
                if devices.isEmpty {
                    row("No iPod connected", icon: "ipod", item: nil, dark: dark)
                } else {
                    devices.forEach { row($0, icon: "ipod", item: .device($0), dark: dark) }
                }
                header("Library")
                SidebarItem.library.forEach { row($0.title, icon: $0.icon, item: $0, dark: dark) }
                header("Playlists")
                playlists.forEach { row($0.name, icon: "music.note.list", item: .playlist($0.id), dark: dark) }
                row("New Playlist…", icon: "plus", item: nil, dark: dark)
                isSyncingSelection = false
            }

            func select(_ selection: SidebarItem) {
                guard let list, let index = items.firstIndex(of: selection), list.selectedIndex != Int32(index)
                else { return }
                isSyncingSelection = true
                list.selectedIndex = Int32(index)
                isSyncingSelection = false
            }

            fileprivate func selectionChanged() {
                guard !isSyncingSelection, let list else { return }
                let index = Int(list.selectedIndex)
                guard index >= 0, index < items.count, let item = items[index] else { return }
                onSelect(item)
            }

            private func header(_ title: String) {
                let text = TextBlock()
                text.text = title
                text.fontSize = 11
                text.fontWeight.weight = 600
                text.opacity = 0.6
                let row = append(text, item: nil)
                row.isEnabled = false
                row.isHitTestVisible = false
                row.verticalContentAlignment = .bottom
                row.height = items.count == 1 ? 24 : 34
            }

            private func row(_ title: String, icon: String, item: SidebarItem?, dark: Bool) {
                let glyph = TextBlock()
                glyph.width = 20
                glyph.textAlignment = .center
                glyph.verticalAlignment = .center
                showSymbol(icon, in: glyph, pointSize: 14, tint: item == nil ? .secondary : .accent, dark: dark)
                let label = TextBlock()
                label.text = title
                label.fontSize = 13
                label.textTrimming = .characterEllipsis
                label.verticalAlignment = .center
                if item == nil { label.opacity = 0.5 }
                let stack = StackPanel()
                stack.orientation = .horizontal
                stack.spacing = 8
                stack.children.append(glyph)
                stack.children.append(label)
                let row = append(stack, item: item)
                row.height = 28
                if item == nil { row.isEnabled = false }
            }

            @discardableResult
            private func append(_ content: UIElement, item: SidebarItem?) -> ListViewItem {
                let row = ListViewItem()
                row.content = content
                row.minHeight = 0
                list?.items.append(row)
                items.append(item)
                return row
            }
        }
    }
#endif
