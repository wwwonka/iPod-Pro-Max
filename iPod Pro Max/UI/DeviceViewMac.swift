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
            let icon = NSImageView(image: NSImage())
            if #available(macOS 11, *) {
                icon.image = NSImage(systemSymbolName: "ipod", accessibilityDescription: nil)
                icon.symbolConfiguration = .init(pointSize: 48, weight: .regular)
                icon.contentTintColor = .controlAccentColor
            }
            icon.setFrameSize(NSSize(width: 80, height: 80)); box.addArrangedSubview(icon)
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

#endif
