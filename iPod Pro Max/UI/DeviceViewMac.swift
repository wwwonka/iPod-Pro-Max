#if canImport(AppKitBackend)
    import AppKit
    import AppKitBackend
    import SwiftCrossUI
    import iPodKit

    /// The device page is control-heavy.  Keeping it as a native AppKit hierarchy means a sidebar
    /// slide only resizes one scroll view; SwiftCrossUI no longer measures every checkbox, caption
    /// and group box on each divider frame.
    struct MacDevicePage: NSViewRepresentable {
        var device: IPodDevice
        var library: Library
        @Binding var page: DeviceView.PageState
        var isBusy: Bool
        var onEject: () -> Void
        var onRename: (String) -> Void

        func makeCoordinator() -> Coordinator { Coordinator() }

        func makeNSView(context: Context) -> NSScrollView {
            let scroll = NSScrollView()
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.documentView = context.coordinator.content
            return scroll
        }

        func updateNSView(_ scroll: NSScrollView, context: Context) {
            let coordinator = context.coordinator
            coordinator.update(device: device, library: library, page: page, isBusy: isBusy,
                               setPage: { updated in
                                   var updated = updated
                                   let options = DeviceOptions(syncAllMusic: updated.musicChoice != .selectedPlaylists,
                                       selectedPlaylistIDs: updated.selectedPlaylists.sorted(), syncPodcasts: updated.syncPodcasts,
                                       syncVideos: updated.syncVideos, syncAudiobooks: updated.syncAudiobooks, syncPhotos: updated.syncPhotos,
                                       removeUnknownTracks: updated.removeUnknownTracks, useAlbumArtistForGrouping: updated.albumArtistGrouping)
                                   if updated.device == device, let saved = updated.savedOptions, saved != options {
                                       DevicePageCache.shared.stage(options, for: device)
                                       updated.savedOptions = options
                                   }
                                   page = updated
                               }, onEject: onEject, onRename: onRename)
        }

        func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> ViewSize {
            ViewSize(proposal.width ?? 760, proposal.height ?? 500)
        }

        @MainActor
        final class Coordinator: NSObject {
            fileprivate let content = DeviceContentView()
            private var renderKey = ""

            func update(device: IPodDevice, library: Library, page: DeviceView.PageState, isBusy: Bool,
                        setPage: @escaping (DeviceView.PageState) -> Void,
                        onEject: @escaping () -> Void, onRename: @escaping (String) -> Void)
            {
                let key = Self.renderKey(device: device, library: library, page: page, isBusy: isBusy)
                guard key != renderKey else { return }
                renderKey = key
                content.render(device: device, library: library, page: page, isBusy: isBusy,
                               setPage: setPage, onEject: onEject, onRename: onRename)
            }

            private static func renderKey(device: IPodDevice, library: Library, page: DeviceView.PageState, isBusy: Bool) -> String {
                let c = page.contents
                var parts = [device.id, "\(library.playlists.count)", c?.name ?? "", "\(c?.stats.total ?? 0)",
                             "\(c?.stats.free ?? 0)", "\(c?.songs ?? 0)", "\(c?.podcasts ?? 0)",
                             "\(page.isRenaming)", page.newName, page.renamed ?? "", page.musicChoice?.rawValue ?? ""]
                parts.append(page.selectedPlaylists.sorted().joined(separator: ","))
                parts += ["\(page.syncPodcasts)", "\(page.syncVideos)", "\(page.syncAudiobooks)", "\(page.syncPhotos)",
                          "\(page.removeUnknownTracks)", "\(page.albumArtistGrouping)", "\(isBusy)"]
                return parts.joined(separator: "|")
            }
        }
    }

    @MainActor
    fileprivate final class DeviceContentView: NSView {
        private let stack = NSStackView()
        private var setPage: ((DeviceView.PageState) -> Void)?
        private var page: DeviceView.PageState!
        private var library: Library?
        private var device: IPodDevice?
        private var onEject: (() -> Void)?
        private var onRename: ((String) -> Void)?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            translatesAutoresizingMaskIntoConstraints = false
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 20
            stack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
                stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
                stack.topAnchor.constraint(equalTo: topAnchor, constant: 24),
                stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -24),
                stack.widthAnchor.constraint(lessThanOrEqualToConstant: 760),
                widthAnchor.constraint(greaterThanOrEqualToConstant: 1),
            ])
        }

        required init?(coder: NSCoder) { fatalError() }

        func render(device: IPodDevice, library: Library, page: DeviceView.PageState, isBusy: Bool,
                    setPage: @escaping (DeviceView.PageState) -> Void, onEject: @escaping () -> Void,
                    onRename: @escaping (String) -> Void)
        {
            self.device = device; self.library = library; self.page = page; self.setPage = setPage; self.onEject = onEject; self.onRename = onRename
            stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
            stack.addArrangedSubview(header(device: device, page: page, onRename: onRename))
            stack.addArrangedSubview(capacity(page: page))
            stack.addArrangedSubview(syncPanel(library: library, page: page))
            stack.addArrangedSubview(options(library: library, device: device, page: page))
            stack.addArrangedSubview(actions(device: device, busy: isBusy, onEject: onEject))
        }

        private func header(device: IPodDevice, page: DeviceView.PageState, onRename: @escaping (String) -> Void) -> NSView {
            let box = NSStackView(); box.orientation = .horizontal; box.spacing = 16; box.alignment = .centerY
            let icon = MacVolumeIconImageView(frame: .zero)
            icon.configure(volumeRoot: device.mountPoint)
            box.addArrangedSubview(icon)
            let labels = NSStackView(); labels.orientation = .vertical; labels.alignment = .leading; labels.spacing = 4
            let name = page.renamed ?? page.contents?.name ?? device.displayName
            if page.isRenaming {
                let row = NSStackView(); row.orientation = .horizontal; row.spacing = 8
                let field = NSTextField(string: page.newName); field.widthAnchor.constraint(equalToConstant: 260).isActive = true
                let rename = NSButton(title: "Rename", target: nil, action: nil)
                rename.action = #selector(commitRename(_:)); rename.target = self
                let cancel = NSButton(title: "Cancel", target: nil, action: nil); cancel.target = self; cancel.action = #selector(cancelRename)
                row.addArrangedSubview(field); row.addArrangedSubview(rename); row.addArrangedSubview(cancel); labels.addArrangedSubview(row)
            } else {
                let row = NSStackView(); row.orientation = .horizontal; row.spacing = 8
                let title = label(name, size: 26, weight: .bold); let rename = NSButton(title: "Rename", target: self, action: #selector(beginRename))
                rename.isBordered = false; row.addArrangedSubview(title); row.addArrangedSubview(rename); labels.addArrangedSubview(row)
            }
            labels.addArrangedSubview(secondary([device.displayModelName, device.capacityLabel].compactMap { $0 }.joined(separator: " · ")))
            labels.addArrangedSubview(secondary(device.isSimulated ? "Simulated iPod folder · Never synced with iPod Pro Max" : "Never synced with iPod Pro Max", size: 10))
            box.addArrangedSubview(labels); return box
        }

        private func capacity(page: DeviceView.PageState) -> NSView {
            let stats = page.contents?.stats ?? IPodDevice.VolumeStats(total: 0, free: 0)
            let progress = NSProgressIndicator(); progress.isIndeterminate = false; progress.minValue = 0; progress.maxValue = Double(max(stats.total, 1)); progress.doubleValue = Double(stats.used); progress.controlTint = .blueControlTint
            progress.heightAnchor.constraint(equalToConstant: 18).isActive = true; progress.widthAnchor.constraint(equalToConstant: 680).isActive = true
            let songs = page.contents?.songs ?? 0; let episodes = page.contents?.podcasts ?? 0
            return vertical([progress, secondary("\(bytes(stats.used)) used · \(bytes(stats.free)) free · \(songs) songs · \(episodes) episodes", size: 11)], spacing: 7)
        }

        private func syncPanel(library: Library, page: DeviceView.PageState) -> NSView {
            let playlists = page.musicChoice == .selectedPlaylists ? page.selectedPlaylists.count : library.playlists.count
            let summary = "\(library.allRows.count) songs\(playlists > 0 ? ", \(playlists) playlists" : "")"
            return group(title: nil, views: [label("Ready to sync", size: 13, weight: .bold), secondary(summary, size: 12), secondary("Full sync will be available with song checkboxes. Drag songs onto the iPod to add them.", size: 11)])
        }

        private func options(library: Library, device: IPodDevice, page: DeviceView.PageState) -> NSView {
            var rows: [NSView] = []
            let music = NSPopUpButton(); music.addItems(withTitles: DeviceView.MusicChoice.allCases.map(\.rawValue)); music.selectItem(withTitle: page.musicChoice?.rawValue ?? DeviceView.MusicChoice.entireLibrary.rawValue)
            music.target = self; music.action = #selector(musicChoiceChanged(_:)); rows += [row("Music:", music)]
            if page.musicChoice == .selectedPlaylists {
                rows += library.playlists.map { playlist in check(playlist.name, on: page.selectedPlaylists.contains(playlist.id), action: #selector(playlistChanged(_:)), object: playlist.id) }
            }
            rows.append(separator())
            rows += [check("Sync podcasts", on: page.syncPodcasts, action: #selector(toggleOption(_:)), object: "syncPodcasts", enabled: device.supportsPodcasts),
                     check("Sync videos", on: page.syncVideos, action: #selector(toggleOption(_:)), object: "syncVideos"),
                     check("Sync audiobooks", on: page.syncAudiobooks, action: #selector(toggleOption(_:)), object: "syncAudiobooks"),
                     check("Sync photos", on: page.syncPhotos, action: #selector(toggleOption(_:)), object: "syncPhotos", enabled: device.generation.supportsPhotos),
                     check("Remove songs that aren't in this library", on: page.removeUnknownTracks, action: #selector(toggleOption(_:)), object: "removeUnknownTracks"),
                     secondary("When on, songs added by another Mac are removed during a full sync.", size: 10), separator(),
                     check("Use Album Artist for Grouping", on: page.albumArtistGrouping, action: #selector(toggleOption(_:)), object: "albumArtistGrouping"),
                     secondary("Your library files are not modified.", size: 10)]
            return group(title: "Sync Options", views: rows)
        }

        private func actions(device: IPodDevice, busy: Bool, onEject: @escaping () -> Void) -> NSView {
            let row = NSStackView(); row.orientation = .horizontal; row.spacing = 12
            let eject = NSButton(title: device.isSimulated ? "Detach Folder" : "Eject", target: self, action: #selector(ejectPressed)); eject.isEnabled = !busy
            row.addArrangedSubview(eject)
            let importButton = NSButton(title: "Import Songs from iPod…", target: nil, action: nil); importButton.isEnabled = false; row.addArrangedSubview(importButton)
            let reveal = NSButton(title: "Show in \(fileManagerName)", target: self, action: #selector(showDevice)); row.addArrangedSubview(reveal)
            row.addArrangedSubview(NSView())
            let forget = NSButton(title: "Forget iPod", target: nil, action: nil); forget.isEnabled = false; row.addArrangedSubview(forget)
            return row
        }

        @objc private func beginRename() { mutate { $0.newName = $0.renamed ?? $0.contents?.name ?? $0.device.displayName; $0.isRenaming = true } }
        @objc private func cancelRename() { mutate { $0.isRenaming = false } }
        @objc private func commitRename(_ sender: NSButton) {
            guard let row = sender.superview as? NSStackView, let field = row.arrangedSubviews.first as? NSTextField else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespaces); guard !name.isEmpty else { cancelRename(); return }
            mutate { $0.isRenaming = false; $0.renamed = name }; onRename?(name)
        }
        @objc private func musicChoiceChanged(_ sender: NSPopUpButton) { mutate { $0.musicChoice = DeviceView.MusicChoice(rawValue: sender.titleOfSelectedItem ?? "") } }
        @objc private func playlistChanged(_ sender: NSButton) { mutate { if sender.state == .on { $0.selectedPlaylists.insert(sender.identifier!.rawValue) } else { $0.selectedPlaylists.remove(sender.identifier!.rawValue) } } }
        @objc private func toggleOption(_ sender: NSButton) { mutate { page in switch sender.identifier!.rawValue { case "syncPodcasts": page.syncPodcasts = sender.state == .on; case "syncVideos": page.syncVideos = sender.state == .on; case "syncAudiobooks": page.syncAudiobooks = sender.state == .on; case "syncPhotos": page.syncPhotos = sender.state == .on; case "removeUnknownTracks": page.removeUnknownTracks = sender.state == .on; default: page.albumArtistGrouping = sender.state == .on } } }
        @objc private func showDevice() { if let device { showInFileManager(device.mountPoint) } }
        @objc private func ejectPressed() { onEject?() }
        private func mutate(_ change: (inout DeviceView.PageState) -> Void) { var next = page!; change(&next); page = next; setPage?(next) }

        private func group(title: String?, views: [NSView]) -> NSView { let body = vertical(views, spacing: 7); let box = NSBox(); box.boxType = .custom; box.borderType = .lineBorder; box.cornerRadius = 6; box.contentViewMargins = NSSize(width: 12, height: 12); box.contentView = body; body.translatesAutoresizingMaskIntoConstraints = false; if let title { let outer = vertical([label(title, size: 13, weight: .bold), box], spacing: 6); return outer }; return box }
        private func vertical(_ views: [NSView], spacing: CGFloat) -> NSStackView { let stack = NSStackView(views: views); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = spacing; return stack }
        private func row(_ title: String, _ view: NSView) -> NSStackView { let r = NSStackView(views: [label(title, size: 12), view]); r.orientation = .horizontal; r.alignment = .centerY; r.spacing = 8; return r }
        private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSTextField { let field = NSTextField(labelWithString: text); field.font = .systemFont(ofSize: size, weight: weight); field.lineBreakMode = .byTruncatingTail; return field }
        private func secondary(_ text: String, size: CGFloat = 12) -> NSTextField { let field = label(text, size: size); field.textColor = .secondaryLabelColor; return field }
        private func check(_ title: String, on: Bool, action: Selector, object: String, enabled: Bool = true) -> NSButton { let b = NSButton(checkboxWithTitle: title, target: self, action: action); b.state = on ? .on : .off; b.identifier = NSUserInterfaceItemIdentifier(object); b.isEnabled = enabled; return b }
        private func separator() -> NSBox { let box = NSBox(); box.boxType = .separator; return box }
    }

    struct MacStorageBar: NSViewRepresentable {
        var total: Int64
        var values: [Int64]
        func makeNSView(context: Context) -> StorageBarView { StorageBarView(total: total, values: values) }
        func updateNSView(_ view: StorageBarView, context: Context) { view.update(total: total, values: values) }
        func sizeThatFits(_ proposal: ProposedViewSize, nsView: StorageBarView, context: Context) -> ViewSize {
            ViewSize(proposal.width ?? 680, 18)
        }
    }

    /// Inline rename actions with the same native hover language as the rail: quiet outline at
    /// rest, then a white filled symbol under the pointer. AppKit tracking avoids view rebuilds.
    struct MacRenameControls: NSViewRepresentable {
        var editing: Bool
        var onEdit: () -> Void
        var onConfirm: () -> Void
        var onCancel: () -> Void

        func makeCoordinator() -> Coordinator { Coordinator() }
        func makeNSView(context: Context) -> RenameControlsView {
            let view = RenameControlsView()
            view.coordinator = context.coordinator
            return view
        }
        func updateNSView(_ view: RenameControlsView, context: Context) {
            context.coordinator.onEdit = onEdit
            context.coordinator.onConfirm = onConfirm
            context.coordinator.onCancel = onCancel
            view.setEditing(editing)
        }
        func sizeThatFits(_ proposal: ProposedViewSize, nsView: RenameControlsView, context: Context) -> ViewSize {
            ViewSize(editing ? 56 : 24, 34)
        }

        final class Coordinator {
            var onEdit: () -> Void = {}
            var onConfirm: () -> Void = {}
            var onCancel: () -> Void = {}
        }
    }

    final class RenameControlsView: NSView {
        var coordinator: MacRenameControls.Coordinator?
        private lazy var edit = makeButton(outline: "pencil", filled: "pencil",
                                           label: "Rename", action: #selector(editName(_:)))
        private lazy var confirm = makeButton(outline: "checkmark.circle", filled: "checkmark.circle.fill",
                                              label: "Confirm rename", action: #selector(confirmName(_:)))
        private lazy var cancel = makeButton(outline: "xmark.circle", filled: "xmark.circle.fill",
                                             label: "Cancel rename", action: #selector(cancelName(_:)))
        private var currentEditing: Bool?
        private var transitionRevision = 0

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            addSubview(edit); addSubview(confirm); addSubview(cancel)
            setEditing(false)
        }
        required init?(coder: NSCoder) { fatalError() }
        func setEditing(_ editing: Bool) {
            guard currentEditing != editing else { return }
            let initial = currentEditing == nil
            currentEditing = editing
            transitionRevision += 1
            let revision = transitionRevision
            if initial {
                edit.isHidden = editing
                confirm.isHidden = !editing
                cancel.isHidden = !editing
            } else if editing {
                edit.playDisappear { [weak self] in
                    guard let self, self.transitionRevision == revision else { return }
                    self.edit.isHidden = true
                    self.confirm.isHidden = false; self.cancel.isHidden = false
                    self.confirm.playAppear(); self.cancel.playAppear()
                }
            } else {
                confirm.playDisappear { [weak self] in
                    guard let self, self.transitionRevision == revision else { return }
                    self.confirm.isHidden = true; self.cancel.isHidden = true
                    self.edit.isHidden = false; self.edit.playAppear()
                }
            }
            needsLayout = true
        }
        override func layout() {
            super.layout()
            // The pencil glyph is optically top-heavy inside NSButton; lower it slightly so its
            // visual centre matches the 26-point title rather than its bounding box.
            edit.frame = NSRect(x: 0, y: 2, width: 24, height: 24)
            confirm.frame = NSRect(x: 0, y: (bounds.height - 24) / 2, width: 24, height: 24)
            cancel.frame = NSRect(x: 32, y: confirm.frame.minY, width: 24, height: 24)
        }
        private func makeButton(outline: String, filled: String, label: String,
                                action: Selector) -> HoverSymbolButton {
            let button = HoverSymbolButton(outline: outline, filled: filled)
            button.target = self
            button.action = action
            button.setButtonType(.momentaryChange)
            button.toolTip = label
            button.setAccessibilityLabel(label)
            return button
        }
        @objc private func editName(_ sender: Any?) { coordinator?.onEdit() }
        @objc private func confirmName(_ sender: Any?) { coordinator?.onConfirm() }
        @objc private func cancelName(_ sender: Any?) { coordinator?.onCancel() }
    }

    /// One native text control for both display and editing. Switching modes therefore cannot
    /// change the glyph origin, baseline or height; only editability and first responder change.
    struct MacInlineNameEditor: NSViewRepresentable {
        @Binding var text: String
        var displayText: String
        var textWidth: Int
        var editing: Bool
        var onEdit: () -> Void
        var onSubmit: () -> Void
        var onCancel: () -> Void

        func makeCoordinator() -> Coordinator { Coordinator() }
        func makeNSView(context: Context) -> InlineNameEditorView {
            let view = InlineNameEditorView()
            let field = view.field
            field.delegate = context.coordinator
            field.target = context.coordinator
            field.action = #selector(Coordinator.submit)
            context.coordinator.field = field
            view.controls.coordinator = context.coordinator.controls
            return view
        }
        func updateNSView(_ view: InlineNameEditorView, context: Context) {
            let field = view.field
            let coordinator = context.coordinator
            coordinator.setText = { text = $0 }
            coordinator.onSubmit = onSubmit
            coordinator.controls.onEdit = onEdit
            coordinator.controls.onConfirm = onSubmit
            coordinator.controls.onCancel = onCancel
            view.update(textWidth: CGFloat(textWidth), editing: editing)
            let wanted = editing ? text : displayText
            if field.stringValue != wanted { field.stringValue = wanted }
            field.isEditable = editing
            field.isSelectable = editing
            if editing != coordinator.editing {
                coordinator.editing = editing
                if editing {
                    DispatchQueue.main.async { [weak field] in
                        guard let field, field.window != nil else { return }
                        field.window?.makeFirstResponder(field)
                        field.currentEditor()?.selectedRange = NSRange(location: 0, length: field.stringValue.utf16.count)
                    }
                } else if field.currentEditor() != nil {
                    field.window?.makeFirstResponder(nil)
                }
            }
        }
        func sizeThatFits(_ proposal: ProposedViewSize, nsView: InlineNameEditorView, context: Context) -> ViewSize {
            ViewSize(Double(textWidth + (editing ? 59 : 27)), 34)
        }

        final class Coordinator: NSObject, NSTextFieldDelegate {
            weak var field: NSTextField?
            var editing = false
            let controls = MacRenameControls.Coordinator()
            var setText: (String) -> Void = { _ in }
            var onSubmit: () -> Void = {}
            func controlTextDidChange(_ notification: Notification) {
                if let field = notification.object as? NSTextField { setText(field.stringValue) }
            }
            @objc func submit() { onSubmit() }
        }
    }

    final class InlineNameEditorView: NSView {
        let field = NSTextField(frame: .zero)
        let controls = RenameControlsView(frame: .zero)
        private var textWidth: CGFloat = 0
        private var editing = false

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            field.font = .systemFont(ofSize: 26, weight: .bold)
            field.isBordered = false
            field.drawsBackground = false
            field.focusRingType = .none
            field.lineBreakMode = .byClipping
            field.maximumNumberOfLines = 1
            field.cell?.wraps = false
            field.cell?.isScrollable = true
            addSubview(field)
            addSubview(controls, positioned: .above, relativeTo: field)
        }
        required init?(coder: NSCoder) { fatalError() }
        func update(textWidth: CGFloat, editing: Bool) {
            self.textWidth = textWidth
            self.editing = editing
            controls.setEditing(editing)
            needsLayout = true
        }
        override func layout() {
            super.layout()
            field.frame = NSRect(x: 0, y: 0, width: textWidth, height: bounds.height)
            controls.frame = NSRect(x: textWidth + 3, y: 0, width: editing ? 56 : 24, height: bounds.height)
        }
    }

    final class HoverSymbolButton: NSButton {
        private let outline: String
        private let filled: String
        private var tracking: NSTrackingArea?
        private var hovered = false { didSet { if hovered != oldValue { refresh() } } }
        private let glyphView = NSImageView()

        init(outline: String, filled: String) {
            self.outline = outline; self.filled = filled
            super.init(frame: .zero)
            isBordered = false
            imagePosition = .imageOnly
            focusRingType = .none
            addSubview(glyphView)
            refresh()
        }
        required init?(coder: NSCoder) { fatalError() }
        override func layout() { super.layout(); glyphView.frame = bounds }
        // The animated image view must never become the event target. AppKit has already established
        // that the point lies in this subview before asking it to resolve the deepest hit.
        override func hitTest(_ point: NSPoint) -> NSView? { self }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let next = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self)
            addTrackingArea(next); tracking = next
        }
        override func mouseEntered(with event: NSEvent) { hovered = true }
        override func mouseExited(with event: NSEvent) { hovered = false }
        func playAppear() {
            if #available(macOS 14.0, *) {
                glyphView.addSymbolEffect(.disappear, options: .default, animated: false)
                DispatchQueue.main.async { [weak self] in self?.glyphView.addSymbolEffect(.appear) }
            } else {
                alphaValue = 0
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.25; animator().alphaValue = 1
                }
            }
        }
        func playDisappear(completion: @escaping () -> Void) {
            if #available(macOS 14.0, *) {
                glyphView.addSymbolEffect(.disappear)
            } else {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.25; animator().alphaValue = 0
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { completion() }
        }
        private func refresh() {
            if #available(macOS 11.0, *) {
                glyphView.image = NSImage(systemSymbolName: hovered ? filled : outline, accessibilityDescription: nil)
                glyphView.symbolConfiguration = .init(pointSize: 15, weight: .regular)
            }
            glyphView.contentTintColor = hovered ? .white : .secondaryLabelColor
        }
    }

    /// Stable native storage drawing: resizing redraws one view instead of rebuilding a GeometryReader tree.
    final class StorageBarView: NSView {
        private var total: Int64
        private var values: [Int64]
        private let colors: [NSColor] = [.systemBlue, .systemPurple, .systemOrange, .systemPink,
                                         .systemGreen, .systemGray]

        init(total: Int64, values: [Int64]) {
            self.total = total
            self.values = values
            super.init(frame: .zero)
            wantsLayer = true
            layer?.cornerRadius = 6
            layer?.masksToBounds = true
        }
        required init?(coder: NSCoder) { fatalError() }
        func update(total: Int64, values: [Int64]) {
            guard self.total != total || self.values != values else { return }
            self.total = total; self.values = values; needsDisplay = true
        }
        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) {
            NSColor.secondaryLabelColor.withAlphaComponent(0.12).setFill()
            bounds.fill()
            guard total > 0 else { return }
            var x: CGFloat = 0
            for (index, value) in values.enumerated() where value > 0 {
                // A real but proportionally tiny category must still be identifiable. Three points
                // is enough to expose its color without materially falsifying the capacity scale.
                let proportional = bounds.width * CGFloat(Double(value) / Double(total))
                let width = min(bounds.width - x, max(3, proportional))
                guard width > 0 else { continue }
                colors[min(index, colors.count - 1)].setFill()
                NSRect(x: x, y: 0, width: width, height: bounds.height).fill()
                x += width
            }
        }
    }

#endif
