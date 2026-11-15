import Foundation

#if canImport(AppKitBackend)
import AppKit
import AVFoundation
import AudioToolbox
import CryptoKit
import UniformTypeIdentifiers
import iPodKit

/// Coordinates opening and saving from the macOS Metadata Editor window (`MUS-21` → `MUS-32`).
@MainActor
final class MetadataEditorController {
    static let shared = MetadataEditorController()

    typealias TrackLookup = @MainActor (UUID) -> LibraryTrack?
    typealias GenreProvider = @MainActor () -> [String]
    typealias SaveHandler = @MainActor (_ track: LibraryTrack, _ customArtworkData: Data?, _ completion: @escaping @MainActor (Result<Void, Error>) -> Void) -> Void

    private var trackLookup: TrackLookup?
    private var genreProvider: GenreProvider?
    private var artworkFolder: URL?
    private var onSaveTrack: SaveHandler?
    private var windowController: MetadataEditorWindowController?

    private init() {}

    func configure(
        artworkFolder: URL?,
        trackLookup: @escaping TrackLookup,
        genreProvider: @escaping GenreProvider,
        onSaveTrack: @escaping SaveHandler
    ) {
        self.artworkFolder = artworkFolder
        self.trackLookup = trackLookup
        self.genreProvider = genreProvider
        self.onSaveTrack = onSaveTrack
    }

    func open(rows: [TrackRow], index: Int) {
        guard rows.indices.contains(index) else { return }
        if windowController == nil {
            windowController = MetadataEditorWindowController()
        }
        windowController?.configure(
            rows: rows,
            index: index,
            artworkFolder: artworkFolder,
            trackLookup: trackLookup,
            genreProvider: genreProvider,
            onSaveTrack: onSaveTrack
        )
        windowController?.showWindow(nil)
        windowController?.window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Draft Model

private struct MetadataDraft {
    var track: LibraryTrack
    var customArtworkData: Data?
    var customArtworkImage: NSImage?
    var resetPlayCount: Bool = false

    // Options helpers
    var hasStartTime: Bool
    var startTimeMs: Int
    var hasStopTime: Bool
    var stopTimeMs: Int

    init(track: LibraryTrack, artworkImage: NSImage?) {
        self.track = track
        self.customArtworkImage = artworkImage
        self.hasStartTime = track.startTimeMs != nil
        self.startTimeMs = track.startTimeMs ?? 0
        self.hasStopTime = track.stopTimeMs != nil
        self.stopTimeMs = track.stopTimeMs ?? max(0, track.durationMs)
    }

    func finalizedTrack() -> LibraryTrack {
        var t = track
        if resetPlayCount {
            t.playCount = 0
            t.lastPlayed = nil
        }
        t.startTimeMs = hasStartTime ? max(0, min(startTimeMs, max(0, t.durationMs))) : nil
        if hasStopTime {
            let minStop = t.startTimeMs ?? 0
            let maxStop = max(minStop, t.durationMs)
            t.stopTimeMs = max(minStop, min(stopTimeMs, maxStop))
        } else {
            t.stopTimeMs = nil
        }
        let trimmedLyrics = t.lyrics?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        t.hasLyrics = (t.customLyrics == true && !trimmedLyrics.isEmpty)
        t.dateModified = Date()
        return t
    }
}

// MARK: - Window Controller

@MainActor
private final class MetadataEditorWindowController: NSWindowController, NSWindowDelegate {
    enum Tab: Int, CaseIterable {
        case details, artwork, lyrics, options, sorting, file

        var title: String {
            switch self {
            case .details: return "Details"
            case .artwork: return "Artwork"
            case .lyrics: return "Lyrics"
            case .options: return "Options"
            case .sorting: return "Sorting"
            case .file: return "File"
            }
        }
    }

    private var rows: [TrackRow] = []
    private var currentIndex: Int = 0
    private var artworkFolder: URL?
    private var trackLookup: MetadataEditorController.TrackLookup?
    private var genreProvider: MetadataEditorController.GenreProvider?
    private var onSaveTrack: MetadataEditorController.SaveHandler?

    private var draft: MetadataDraft?
    private var selectedTab: Tab = .details
    private var isSaving = false

    // Root views
    private let headerEffectView = NSVisualEffectView()
    private let headerOpaqueFallback = NSView()
    private let headerArtworkView = NSImageView()
    private let headerTitleLabel = NSTextField(labelWithString: "")
    private let headerArtistLabel = NSTextField(labelWithString: "")
    private let headerAlbumLabel = NSTextField(labelWithString: "")

    private var tabButtons: [Tab: NSButton] = [:]
    private let contentContainer = NSView()
    private var tabViews: [Tab: NSView] = [:]

    // Bottom bar
    private let prevButton = NSButton()
    private let nextButton = NSButton()
    private let addArtworkButton = NSButton(title: "Add Artwork", target: nil, action: nil)
    private let customLyricsCheckbox = NSButton(checkboxWithTitle: "Custom Lyrics", target: nil, action: nil)
    private let errorLabel = NSTextField(labelWithString: "")
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let okButton = NSButton(title: "OK", target: nil, action: nil)

    // Details controls
    private let songField = NSTextField()
    private let artistField = NSTextField()
    private let albumField = NSTextField()
    private let albumArtistField = NSTextField()
    private let composerField = NSTextField()
    private let showComposerCheckbox = NSButton(checkboxWithTitle: "Show composer in all views", target: nil, action: nil)
    private let groupingField = NSTextField()
    private let genreCombo = NSComboBox()
    private let yearField = NSTextField()
    private let trackNumField = NSTextField()
    private let trackTotalField = NSTextField()
    private let discNumField = NSTextField()
    private let discTotalField = NSTextField()
    private let compilationCheckbox = NSButton(checkboxWithTitle: "Album is a compilation of songs by various artists", target: nil, action: nil)
    private var starButtons: [NSButton] = []
    private let favoriteButton = NSButton()
    private let bpmField = NSTextField()
    private let playCountLabel = NSTextField(labelWithString: "")
    private let resetPlayCountButton = NSButton(title: "Reset", target: nil, action: nil)
    private let commentsTextView = NSTextView()

    // Artwork controls
    private let largeArtworkView = NSImageView()

    // Lyrics controls
    private let lyricsTextView = NSTextView()

    // Options controls
    private let mediaKindPopup = NSPopUpButton()
    private let startCheckbox = NSButton(checkboxWithTitle: "start", target: nil, action: nil)
    private let startTimeField = NSTextField()
    private let stopCheckbox = NSButton(checkboxWithTitle: "stop", target: nil, action: nil)
    private let stopTimeField = NSTextField()
    private let rememberPositionCheckbox = NSButton(checkboxWithTitle: "Remember playback position", target: nil, action: nil)
    private let skipShufflingCheckbox = NSButton(checkboxWithTitle: "Skip when shuffling", target: nil, action: nil)
    private let volumeSlider = NSSlider(value: 0, minValue: -100, maxValue: 100, target: nil, action: nil)
    private let volumeValueLabel = NSTextField(labelWithString: "None")
    private let eqPopup = NSPopUpButton()

    // Sorting controls
    private let sortNameField = NSTextField()
    private let sortNameAsField = NSTextField()
    private let sortAlbumField = NSTextField()
    private let sortAlbumAsField = NSTextField()
    private let sortAlbumArtistField = NSTextField()
    private let sortAlbumArtistAsField = NSTextField()
    private let sortArtistField = NSTextField()
    private let sortArtistAsField = NSTextField()
    private let sortComposerField = NSTextField()
    private let sortComposerAsField = NSTextField()

    // File controls
    private let fileKindLabel = makeMetadataReadOnlyLabel()
    private let fileDurationLabel = makeMetadataReadOnlyLabel()
    private let fileSizeLabel = makeMetadataReadOnlyLabel()
    private let fileBitRateLabel = makeMetadataReadOnlyLabel()
    private let fileSampleRateLabel = makeMetadataReadOnlyLabel()
    private let fileChannelsLabel = makeMetadataReadOnlyLabel()
    private let fileVolumeLabel = makeMetadataReadOnlyLabel()
    private let fileID3Label = makeMetadataReadOnlyLabel()
    private let fileID3RowTitle = NSTextField(labelWithString: "id3 tag")
    private let fileEncodedWithLabel = makeMetadataReadOnlyLabel()
    private let fileFormatLabel = makeMetadataReadOnlyLabel()
    private let fileDateModifiedLabel = makeMetadataReadOnlyLabel()
    private let fileDateAddedLabel = makeMetadataReadOnlyLabel()
    private let fileLocationLabel = makeMetadataReadOnlyLabel(wraps: true)
    private var fileInspectTask: Task<Void, Never>?
    private var artworkLoadTask: Task<Void, Never>?
    private var inspectedTrackID: UUID?
    private var cachedGenres: [String]?
    private var transparencyObserver: NSObjectProtocol?

    private static let mediumDateFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        return fmt
    }()

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = ""
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self

        buildUI()
        observeReduceTransparency()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let transparencyObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(transparencyObserver)
        }
    }

    func configure(
        rows: [TrackRow],
        index: Int,
        artworkFolder: URL?,
        trackLookup: MetadataEditorController.TrackLookup?,
        genreProvider: MetadataEditorController.GenreProvider?,
        onSaveTrack: MetadataEditorController.SaveHandler?
    ) {
        self.rows = rows
        self.currentIndex = index
        self.artworkFolder = artworkFolder
        self.trackLookup = trackLookup
        self.genreProvider = genreProvider
        self.onSaveTrack = onSaveTrack
        self.cachedGenres = nil
        loadCurrentTrack()
    }

    // MARK: - UI Construction

    private func buildUI() {
        guard let root = window?.contentView else { return }

        // Opaque body background underneath the content (header stays translucent)
        let bodyBackground = NSView()
        bodyBackground.wantsLayer = true
        bodyBackground.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        bodyBackground.translatesAutoresizingMaskIntoConstraints = false

        buildHeader()
        let tabBar = buildTabBar()
        let bottomBar = buildBottomBar()

        contentContainer.translatesAutoresizingMaskIntoConstraints = false

        let topSeparator = NSBox()
        topSeparator.boxType = .separator
        topSeparator.translatesAutoresizingMaskIntoConstraints = false

        let bottomSeparator = NSBox()
        bottomSeparator.boxType = .separator
        bottomSeparator.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(headerEffectView)
        root.addSubview(bodyBackground)
        root.addSubview(topSeparator)
        root.addSubview(tabBar)
        root.addSubview(contentContainer)
        root.addSubview(bottomSeparator)
        root.addSubview(bottomBar)

        NSLayoutConstraint.activate([
            headerEffectView.topAnchor.constraint(equalTo: root.topAnchor),
            headerEffectView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            headerEffectView.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            topSeparator.topAnchor.constraint(equalTo: headerEffectView.bottomAnchor),
            topSeparator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            topSeparator.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            bodyBackground.topAnchor.constraint(equalTo: topSeparator.bottomAnchor),
            bodyBackground.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bodyBackground.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bodyBackground.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            tabBar.topAnchor.constraint(equalTo: topSeparator.bottomAnchor, constant: 10),
            tabBar.centerXAnchor.constraint(equalTo: root.centerXAnchor),

            contentContainer.topAnchor.constraint(equalTo: tabBar.bottomAnchor, constant: 12),
            contentContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            contentContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            contentContainer.bottomAnchor.constraint(equalTo: bottomSeparator.topAnchor, constant: -10),

            bottomSeparator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bottomSeparator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bottomSeparator.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),

            bottomBar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            bottomBar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            bottomBar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            bottomBar.heightAnchor.constraint(equalToConstant: 36),
        ])

        tabViews[.details] = buildDetailsTab()
        tabViews[.artwork] = buildArtworkTab()
        tabViews[.lyrics] = buildLyricsTab()
        tabViews[.options] = buildOptionsTab()
        tabViews[.sorting] = buildSortingTab()
        tabViews[.file] = buildFileTab()

        switchTab(to: .details)
    }

    private func buildHeader() {
        headerEffectView.translatesAutoresizingMaskIntoConstraints = false
        headerEffectView.blendingMode = .behindWindow
        headerEffectView.material = .headerView
        headerEffectView.state = .followsWindowActiveState

        headerOpaqueFallback.translatesAutoresizingMaskIntoConstraints = false
        headerOpaqueFallback.wantsLayer = true
        headerOpaqueFallback.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        headerOpaqueFallback.isHidden = !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        headerEffectView.addSubview(headerOpaqueFallback)

        headerArtworkView.translatesAutoresizingMaskIntoConstraints = false
        headerArtworkView.imageScaling = .scaleProportionallyUpOrDown
        headerArtworkView.wantsLayer = true
        headerArtworkView.layer?.cornerRadius = 8
        headerArtworkView.layer?.masksToBounds = true
        headerArtworkView.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor

        headerTitleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        headerTitleLabel.lineBreakMode = .byTruncatingTail
        headerTitleLabel.maximumNumberOfLines = 1
        headerTitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        headerArtistLabel.font = .systemFont(ofSize: 13)
        headerArtistLabel.textColor = .secondaryLabelColor
        headerArtistLabel.lineBreakMode = .byTruncatingTail
        headerArtistLabel.maximumNumberOfLines = 1
        headerArtistLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        headerAlbumLabel.font = .systemFont(ofSize: 13)
        headerAlbumLabel.textColor = .secondaryLabelColor
        headerAlbumLabel.lineBreakMode = .byTruncatingTail
        headerAlbumLabel.maximumNumberOfLines = 1
        headerAlbumLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let textStack = NSStackView(views: [headerTitleLabel, headerArtistLabel, headerAlbumLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false

        headerEffectView.addSubview(headerArtworkView)
        headerEffectView.addSubview(textStack)

        NSLayoutConstraint.activate([
            headerOpaqueFallback.topAnchor.constraint(equalTo: headerEffectView.topAnchor),
            headerOpaqueFallback.bottomAnchor.constraint(equalTo: headerEffectView.bottomAnchor),
            headerOpaqueFallback.leadingAnchor.constraint(equalTo: headerEffectView.leadingAnchor),
            headerOpaqueFallback.trailingAnchor.constraint(equalTo: headerEffectView.trailingAnchor),

            headerArtworkView.topAnchor.constraint(equalTo: headerEffectView.topAnchor, constant: 34),
            headerArtworkView.leadingAnchor.constraint(equalTo: headerEffectView.leadingAnchor, constant: 20),
            headerArtworkView.bottomAnchor.constraint(equalTo: headerEffectView.bottomAnchor, constant: -14),
            headerArtworkView.widthAnchor.constraint(equalToConstant: 64),
            headerArtworkView.heightAnchor.constraint(equalToConstant: 64),

            textStack.centerYAnchor.constraint(equalTo: headerArtworkView.centerYAnchor),
            textStack.leadingAnchor.constraint(equalTo: headerArtworkView.trailingAnchor, constant: 14),
            textStack.trailingAnchor.constraint(equalTo: headerEffectView.trailingAnchor, constant: -20),
        ])
    }

    private func buildTabBar() -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false

        for tab in Tab.allCases {
            let button = NSButton(title: tab.title, target: self, action: #selector(tabButtonClicked(_:)))
            button.tag = tab.rawValue
            button.bezelStyle = .rounded
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.cornerRadius = 6
            button.font = .systemFont(ofSize: 12, weight: .medium)
            button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                button.heightAnchor.constraint(equalToConstant: 24),
                button.widthAnchor.constraint(greaterThanOrEqualToConstant: 66),
            ])
            tabButtons[tab] = button
            stack.addArrangedSubview(button)
        }
        return stack
    }

    private func buildBottomBar() -> NSView {
        let bar = NSView()
        bar.translatesAutoresizingMaskIntoConstraints = false

        if #available(macOS 11, *) {
            prevButton.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Previous")
        } else {
            prevButton.title = "‹"
        }
        prevButton.bezelStyle = .rounded
        prevButton.target = self
        prevButton.action = #selector(previousTrackClicked)
        prevButton.translatesAutoresizingMaskIntoConstraints = false

        if #available(macOS 11, *) {
            nextButton.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Next")
        } else {
            nextButton.title = "›"
        }
        nextButton.bezelStyle = .rounded
        nextButton.target = self
        nextButton.action = #selector(nextTrackClicked)
        nextButton.translatesAutoresizingMaskIntoConstraints = false

        addArtworkButton.bezelStyle = .rounded
        addArtworkButton.target = self
        addArtworkButton.action = #selector(addArtworkClicked)
        addArtworkButton.translatesAutoresizingMaskIntoConstraints = false

        customLyricsCheckbox.target = self
        customLyricsCheckbox.action = #selector(customLyricsToggled)
        customLyricsCheckbox.translatesAutoresizingMaskIntoConstraints = false

        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .systemRed
        errorLabel.lineBreakMode = .byTruncatingTail
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.isHidden = true

        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        cancelButton.translatesAutoresizingMaskIntoConstraints = false

        okButton.bezelStyle = .rounded
        okButton.keyEquivalent = "\r"
        okButton.target = self
        okButton.action = #selector(okClicked)
        okButton.translatesAutoresizingMaskIntoConstraints = false

        bar.addSubview(prevButton)
        bar.addSubview(nextButton)
        bar.addSubview(addArtworkButton)
        bar.addSubview(customLyricsCheckbox)
        bar.addSubview(errorLabel)
        bar.addSubview(cancelButton)
        bar.addSubview(okButton)

        NSLayoutConstraint.activate([
            prevButton.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            prevButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor, constant: 4),
            prevButton.widthAnchor.constraint(equalToConstant: 28),

            nextButton.leadingAnchor.constraint(equalTo: prevButton.trailingAnchor, constant: 4),
            nextButton.centerYAnchor.constraint(equalTo: prevButton.centerYAnchor),
            nextButton.widthAnchor.constraint(equalToConstant: 28),

            addArtworkButton.leadingAnchor.constraint(equalTo: nextButton.trailingAnchor, constant: 12),
            addArtworkButton.centerYAnchor.constraint(equalTo: prevButton.centerYAnchor),

            customLyricsCheckbox.leadingAnchor.constraint(equalTo: nextButton.trailingAnchor, constant: 12),
            customLyricsCheckbox.centerYAnchor.constraint(equalTo: prevButton.centerYAnchor),

            okButton.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            okButton.centerYAnchor.constraint(equalTo: prevButton.centerYAnchor),
            okButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 72),

            cancelButton.trailingAnchor.constraint(equalTo: okButton.leadingAnchor, constant: -8),
            cancelButton.centerYAnchor.constraint(equalTo: prevButton.centerYAnchor),
            cancelButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 72),

            errorLabel.leadingAnchor.constraint(equalTo: nextButton.trailingAnchor, constant: 12),
            errorLabel.trailingAnchor.constraint(lessThanOrEqualTo: cancelButton.leadingAnchor, constant: -8),
            errorLabel.centerYAnchor.constraint(equalTo: prevButton.centerYAnchor),
        ])

        return bar
    }

    // MARK: - Details Tab (MUS-24)

    private func buildDetailsTab() -> NSView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let container = FlippedView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        let digitsFormatter = DigitsOnlyFormatter()

        for field in [songField, artistField, albumField, albumArtistField, composerField, groupingField] {
            field.target = self
            field.action = #selector(detailsFieldChanged(_:))
            NotificationCenter.default.addObserver(self, selector: #selector(textDidChangeNotification(_:)), name: NSControl.textDidChangeNotification, object: field)
        }

        genreCombo.completes = true
        genreCombo.usesDataSource = false
        genreCombo.target = self
        NotificationCenter.default.addObserver(self, selector: #selector(textDidChangeNotification(_:)), name: NSControl.textDidChangeNotification, object: genreCombo)

        for numeric in [yearField, trackNumField, trackTotalField, discNumField, discTotalField, bpmField] {
            numeric.formatter = digitsFormatter
            NotificationCenter.default.addObserver(self, selector: #selector(textDidChangeNotification(_:)), name: NSControl.textDidChangeNotification, object: numeric)
        }

        showComposerCheckbox.target = self
        showComposerCheckbox.action = #selector(detailsCheckboxChanged)
        compilationCheckbox.target = self
        compilationCheckbox.action = #selector(detailsCheckboxChanged)

        stack.addArrangedSubview(formRow("song", field: songField))
        stack.addArrangedSubview(formRow("artist", field: artistField))
        stack.addArrangedSubview(formRow("album", field: albumField))
        stack.addArrangedSubview(formRow("album artist", field: albumArtistField))
        stack.addArrangedSubview(formRow("composer", field: composerField))
        stack.addArrangedSubview(formRow("", field: showComposerCheckbox))
        stack.addArrangedSubview(formRow("grouping", field: groupingField))
        stack.addArrangedSubview(formRow("genre", field: genreCombo))
        stack.addArrangedSubview(formRow("year", field: yearField, width: 80))

        // Track number of total
        let trackPair = makePairRow(left: trackNumField, right: trackTotalField)
        stack.addArrangedSubview(formRow("track", field: trackPair))

        let discPair = makePairRow(left: discNumField, right: discTotalField)
        stack.addArrangedSubview(formRow("disc number", field: discPair))
        stack.addArrangedSubview(formRow("compilation", field: compilationCheckbox))

        // Rating stars + favorite icon
        let ratingRow = NSStackView()
        ratingRow.orientation = .horizontal
        ratingRow.spacing = 4
        ratingRow.alignment = .centerY
        for star in 1...5 {
            let btn = NSButton()
            btn.isBordered = false
            btn.tag = star
            btn.target = self
            btn.action = #selector(starClicked(_:))
            btn.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                btn.widthAnchor.constraint(equalToConstant: 18),
                btn.heightAnchor.constraint(equalToConstant: 18),
            ])
            starButtons.append(btn)
            ratingRow.addArrangedSubview(btn)
        }
        let favSpacer = NSView()
        favSpacer.translatesAutoresizingMaskIntoConstraints = false
        favSpacer.widthAnchor.constraint(equalToConstant: 10).isActive = true
        ratingRow.addArrangedSubview(favSpacer)

        favoriteButton.isBordered = false
        favoriteButton.target = self
        favoriteButton.action = #selector(favoriteClicked)
        favoriteButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            favoriteButton.widthAnchor.constraint(equalToConstant: 20),
            favoriteButton.heightAnchor.constraint(equalToConstant: 20),
        ])
        ratingRow.addArrangedSubview(favoriteButton)
        stack.addArrangedSubview(formRow("rating", field: ratingRow))

        stack.addArrangedSubview(formRow("bpm", field: bpmField, width: 80))

        // Play count + Reset
        playCountLabel.font = .systemFont(ofSize: 12)
        playCountLabel.textColor = .labelColor
        resetPlayCountButton.bezelStyle = .rounded
        resetPlayCountButton.controlSize = .small
        resetPlayCountButton.target = self
        resetPlayCountButton.action = #selector(resetPlayCountClicked)
        let playCountRow = NSStackView(views: [playCountLabel, resetPlayCountButton])
        playCountRow.orientation = .horizontal
        playCountRow.spacing = 10
        playCountRow.alignment = .centerY
        stack.addArrangedSubview(formRow("play count", field: playCountRow))

        // Comments multi-line
        let commentsScroll = NSScrollView()
        commentsScroll.borderType = .bezelBorder
        commentsScroll.hasVerticalScroller = true
        commentsScroll.translatesAutoresizingMaskIntoConstraints = false
        commentsTextView.font = .systemFont(ofSize: 12)
        commentsTextView.isRichText = false
        commentsTextView.isEditable = true
        commentsTextView.isVerticallyResizable = true
        commentsTextView.autoresizingMask = [.width]
        commentsTextView.textContainer?.widthTracksTextView = true
        commentsScroll.documentView = commentsTextView
        NSLayoutConstraint.activate([
            commentsScroll.heightAnchor.constraint(equalToConstant: 66),
        ])
        stack.addArrangedSubview(formRow("comments", field: commentsScroll, alignTop: true))

        container.addSubview(stack)
        scroll.documentView = container

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
            container.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        return scroll
    }

    private func makePairRow(left: NSTextField, right: NSTextField) -> NSView {
        left.translatesAutoresizingMaskIntoConstraints = false
        right.translatesAutoresizingMaskIntoConstraints = false
        let ofLabel = NSTextField(labelWithString: "of")
        ofLabel.font = .systemFont(ofSize: 12)
        ofLabel.textColor = .secondaryLabelColor
        let row = NSStackView(views: [left, ofLabel, right])
        row.orientation = .horizontal
        row.spacing = 6
        row.alignment = .centerY
        NSLayoutConstraint.activate([
            left.widthAnchor.constraint(equalToConstant: 48),
            right.widthAnchor.constraint(equalToConstant: 48),
        ])
        return row
    }

    // MARK: - Artwork Tab (MUS-27)

    private func buildArtworkTab() -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false

        let heading = NSTextField(labelWithString: "Album Artwork")
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        heading.translatesAutoresizingMaskIntoConstraints = false

        largeArtworkView.translatesAutoresizingMaskIntoConstraints = false
        largeArtworkView.imageScaling = .scaleProportionallyUpOrDown
        largeArtworkView.wantsLayer = true
        largeArtworkView.layer?.cornerRadius = 10
        largeArtworkView.layer?.masksToBounds = true
        largeArtworkView.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor

        view.addSubview(heading)
        view.addSubview(largeArtworkView)

        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: view.topAnchor, constant: 4),
            heading.leadingAnchor.constraint(equalTo: view.leadingAnchor),

            largeArtworkView.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 10),
            largeArtworkView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            largeArtworkView.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor),
            largeArtworkView.heightAnchor.constraint(equalTo: largeArtworkView.widthAnchor),
            largeArtworkView.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -8),
        ])
        return view
    }

    // MARK: - Lyrics Tab (MUS-28)

    private func buildLyricsTab() -> NSView {
        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        lyricsTextView.font = .systemFont(ofSize: 13)
        lyricsTextView.isRichText = false
        lyricsTextView.isVerticallyResizable = true
        lyricsTextView.autoresizingMask = [.width]
        lyricsTextView.textContainer?.widthTracksTextView = true
        scroll.documentView = lyricsTextView
        return scroll
    }

    // MARK: - Options Tab (MUS-29)

    private func buildOptionsTab() -> NSView {
        let container = FlippedView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        mediaKindPopup.addItems(withTitles: ["Music", "Audiobook", "Video"])
        mediaKindPopup.target = self
        mediaKindPopup.action = #selector(optionsChanged)
        stack.addArrangedSubview(formRow("media kind", field: mediaKindPopup, width: 160))

        startCheckbox.target = self
        startCheckbox.action = #selector(optionsChanged)
        startTimeField.translatesAutoresizingMaskIntoConstraints = false
        startTimeField.widthAnchor.constraint(equalToConstant: 90).isActive = true
        startTimeField.target = self
        startTimeField.action = #selector(optionsTimeEdited)
        let startRow = NSStackView(views: [startCheckbox, startTimeField])
        startRow.orientation = .horizontal
        startRow.spacing = 8
        stack.addArrangedSubview(formRow("", field: startRow))

        stopCheckbox.target = self
        stopCheckbox.action = #selector(optionsChanged)
        stopTimeField.translatesAutoresizingMaskIntoConstraints = false
        stopTimeField.widthAnchor.constraint(equalToConstant: 90).isActive = true
        stopTimeField.target = self
        stopTimeField.action = #selector(optionsTimeEdited)
        let stopRow = NSStackView(views: [stopCheckbox, stopTimeField])
        stopRow.orientation = .horizontal
        stopRow.spacing = 8
        stack.addArrangedSubview(formRow("", field: stopRow))

        rememberPositionCheckbox.target = self
        rememberPositionCheckbox.action = #selector(optionsChanged)
        skipShufflingCheckbox.target = self
        skipShufflingCheckbox.action = #selector(optionsChanged)
        let playbackStack = NSStackView(views: [rememberPositionCheckbox, skipShufflingCheckbox])
        playbackStack.orientation = .vertical
        playbackStack.alignment = .leading
        playbackStack.spacing = 6
        stack.addArrangedSubview(formRow("playback", field: playbackStack, alignTop: true))

        volumeSlider.isContinuous = true
        volumeSlider.numberOfTickMarks = 3
        volumeSlider.target = self
        volumeSlider.action = #selector(volumeSliderChanged)
        volumeValueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        volumeValueLabel.textColor = .secondaryLabelColor

        let minLabel = NSTextField(labelWithString: "−100%")
        minLabel.font = .systemFont(ofSize: 10)
        minLabel.textColor = .secondaryLabelColor
        let midLabel = NSTextField(labelWithString: "None")
        midLabel.font = .systemFont(ofSize: 10)
        midLabel.textColor = .secondaryLabelColor
        let maxLabel = NSTextField(labelWithString: "+100%")
        maxLabel.font = .systemFont(ofSize: 10)
        maxLabel.textColor = .secondaryLabelColor

        let ticksRow = NSStackView(views: [minLabel, NSView(), midLabel, NSView(), maxLabel])
        ticksRow.orientation = .horizontal
        ticksRow.distribution = .fill

        let sliderRow = NSStackView(views: [volumeSlider, volumeValueLabel])
        sliderRow.orientation = .horizontal
        sliderRow.spacing = 8
        volumeValueLabel.widthAnchor.constraint(equalToConstant: 48).isActive = true

        let volumeStack = NSStackView(views: [sliderRow, ticksRow])
        volumeStack.orientation = .vertical
        volumeStack.alignment = .leading
        volumeStack.spacing = 2
        stack.addArrangedSubview(formRow("volume adjust", field: volumeStack, alignTop: true))

        eqPopup.addItems(withTitles: [
            "None", "Acoustic", "Bass Booster", "Bass Reducer", "Classical", "Dance",
            "Deep", "Electronic", "Flat", "Hip-Hop", "Jazz", "Latin", "Loudness",
            "Lounge", "Piano", "Pop", "R&B", "Rock", "Small Speakers", "Spoken Word",
            "Treble Booster", "Treble Reducer", "Vocal Booster",
        ])
        eqPopup.target = self
        eqPopup.action = #selector(optionsChanged)
        stack.addArrangedSubview(formRow("equalizer", field: eqPopup, width: 180))

        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        return container
    }

    // MARK: - Sorting Tab (MUS-30)

    private func buildSortingTab() -> NSView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let container = FlippedView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        let fields = [
            sortNameField, sortNameAsField,
            sortAlbumField, sortAlbumAsField,
            sortAlbumArtistField, sortAlbumArtistAsField,
            sortArtistField, sortArtistAsField,
            sortComposerField, sortComposerAsField,
        ]
        for field in fields {
            NotificationCenter.default.addObserver(self, selector: #selector(textDidChangeNotification(_:)), name: NSControl.textDidChangeNotification, object: field)
        }

        let pairs: [(String, NSTextField, NSTextField)] = [
            ("name", sortNameField, sortNameAsField),
            ("album", sortAlbumField, sortAlbumAsField),
            ("album artist", sortAlbumArtistField, sortAlbumArtistAsField),
            ("artist", sortArtistField, sortArtistAsField),
            ("composer", sortComposerField, sortComposerAsField),
        ]
        for (index, pair) in pairs.enumerated() {
            stack.addArrangedSubview(formRow(pair.0, field: pair.1))
            stack.addArrangedSubview(formRow("sort as", field: pair.2))
            if index < pairs.count - 1 {
                let sep = NSBox()
                sep.boxType = .separator
                sep.translatesAutoresizingMaskIntoConstraints = false
                stack.addArrangedSubview(sep)
                sep.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
        }

        container.addSubview(stack)
        scroll.documentView = container
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
            container.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        return scroll
    }

    // MARK: - File Tab (MUS-31)

    private func buildFileTab() -> NSView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let container = FlippedView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(formRow("kind", field: fileKindLabel))
        stack.addArrangedSubview(formRow("duration", field: fileDurationLabel))
        stack.addArrangedSubview(formRow("size", field: fileSizeLabel))
        stack.addArrangedSubview(formRow("bit rate", field: fileBitRateLabel))
        stack.addArrangedSubview(formRow("sample rate", field: fileSampleRateLabel))
        stack.addArrangedSubview(formRow("channels", field: fileChannelsLabel))
        stack.addArrangedSubview(formRow("volume", field: fileVolumeLabel))
        stack.addArrangedSubview(formRow(customLabel: fileID3RowTitle, field: fileID3Label))
        stack.addArrangedSubview(formRow("encoded with", field: fileEncodedWithLabel))
        stack.addArrangedSubview(formRow("format", field: fileFormatLabel))
        stack.addArrangedSubview(formRow("date modified", field: fileDateModifiedLabel))
        stack.addArrangedSubview(formRow("date added", field: fileDateAddedLabel))
        stack.addArrangedSubview(formRow("location", field: fileLocationLabel, alignTop: true))

        container.addSubview(stack)
        scroll.documentView = container
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
            container.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        return scroll
    }

    // MARK: - Form Row Helper

    private func formRow(_ title: String, field: NSView, width: CGFloat? = nil, alignTop: Bool = false) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        return formRow(customLabel: label, field: field, width: width, alignTop: alignTop)
    }

    private func formRow(customLabel label: NSTextField, field: NSView, width: CGFloat? = nil, alignTop: Bool = false) -> NSView {
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        field.translatesAutoresizingMaskIntoConstraints = false

        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(label)
        row.addSubview(field)

        var constraints: [NSLayoutConstraint] = [
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            label.widthAnchor.constraint(equalToConstant: 105),
            field.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 10),
            field.topAnchor.constraint(equalTo: row.topAnchor),
            field.bottomAnchor.constraint(equalTo: row.bottomAnchor),
        ]
        if alignTop {
            constraints.append(label.topAnchor.constraint(equalTo: row.topAnchor, constant: 2))
        } else {
            constraints.append(label.centerYAnchor.constraint(equalTo: field.centerYAnchor))
        }
        if let width {
            constraints.append(field.widthAnchor.constraint(equalToConstant: width))
            constraints.append(field.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor))
        } else {
            constraints.append(field.trailingAnchor.constraint(equalTo: row.trailingAnchor))
        }
        NSLayoutConstraint.activate(constraints)
        return row
    }

    private static func makeReadOnlyLabel(wraps: Bool = false) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 12)
        label.textColor = .labelColor
        label.isSelectable = true
        label.isBordered = false
        label.drawsBackground = false
        if wraps {
            label.lineBreakMode = .byCharWrapping
            label.maximumNumberOfLines = 0
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        } else {
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
        }
        return label
    }

    // MARK: - Loading & Populating

    private func loadCurrentTrack() {
        guard rows.indices.contains(currentIndex) else { return }
        let row = rows[currentIndex]
        let track = UUID(uuidString: row.id).flatMap { trackLookup?($0) } ?? fallbackTrack(from: row)
        artworkLoadTask?.cancel()
        fileInspectTask?.cancel()
        inspectedTrackID = nil

        let cachedImage = cachedArtworkImage(for: track.artworkKey)
        draft = MetadataDraft(track: track, artworkImage: cachedImage)
        errorLabel.isHidden = true
        errorLabel.stringValue = ""

        populateGenres()
        populateAllFields()
        updateHeader()
        updateNavButtons()
        loadArtworkAsyncIfNeeded(for: track)
        if selectedTab == .file {
            inspectFileTechnicalDetails(for: track)
        }
    }

    private func cachedArtworkImage(for key: String?) -> NSImage? {
        guard let key, !key.isEmpty, let artworkFolder else { return nil }
        let url = artworkFolder.appendingPathComponent("\(key).jpg")
        return ThumbnailStore.shared.cached(url, pixels: 600) ?? ThumbnailStore.shared.cached(url, pixels: 128)
    }

    private func loadArtworkAsyncIfNeeded(for track: LibraryTrack) {
        guard let key = track.artworkKey, !key.isEmpty, let artworkFolder else { return }
        let url = artworkFolder.appendingPathComponent("\(key).jpg")
        let targetID = track.id
        artworkLoadTask = Task { [weak self] in
            let image = await ThumbnailStore.shared.image(url, pixels: 600)
            guard !Task.isCancelled, let self, let image, self.draft?.track.id == targetID else { return }
            self.draft?.customArtworkImage = image
            self.headerArtworkView.image = image
            self.largeArtworkView.image = image
        }
    }

    private func populateGenres() {
        if cachedGenres == nil {
            let genres = genreProvider?() ?? []
            cachedGenres = genres
            genreCombo.removeAllItems()
            if !genres.isEmpty {
                genreCombo.addItems(withObjectValues: genres)
            }
        }
    }

    private func fallbackTrack(from row: TrackRow) -> LibraryTrack {
        LibraryTrack(
            id: UUID(uuidString: row.id) ?? UUID(),
            path: row.path ?? "",
            title: row.title,
            artist: row.artist.isEmpty ? nil : row.artist,
            album: row.album.isEmpty ? nil : row.album,
            year: Int(row.year) ?? 0,
            trackNumber: Int(row.number) ?? 0,
            fileExtension: URL(fileURLWithPath: row.path ?? "").pathExtension,
            hasLyrics: row.hasLyrics,
            isFavorite: row.isFavorite,
            dateAdded: row.dateAdded ?? Date(),
            artworkKey: row.artworkKey
        )
    }

    private func populateAllFields() {
        guard let draft else { return }
        let t = draft.track

        // Details
        songField.stringValue = t.title
        artistField.stringValue = t.artist ?? ""
        albumField.stringValue = t.album ?? ""
        albumArtistField.stringValue = t.albumArtist ?? ""
        composerField.stringValue = t.composer ?? ""
        showComposerCheckbox.state = (t.showComposerInAllViews ?? false) ? .on : .off
        groupingField.stringValue = t.grouping ?? ""
        genreCombo.stringValue = t.genre ?? ""
        yearField.stringValue = t.year > 0 ? "\(t.year)" : ""
        trackNumField.stringValue = t.trackNumber > 0 ? "\(t.trackNumber)" : ""
        trackTotalField.stringValue = t.trackCount > 0 ? "\(t.trackCount)" : ""
        discNumField.stringValue = t.discNumber > 0 ? "\(t.discNumber)" : ""
        discTotalField.stringValue = t.discCount > 0 ? "\(t.discCount)" : ""
        compilationCheckbox.state = t.compilation ? .on : .off
        bpmField.stringValue = t.bpm > 0 ? "\(t.bpm)" : ""
        commentsTextView.string = t.comment ?? ""
        updateRatingAndFavorite()
        updatePlayCountLabel()

        // Artwork
        let art = draft.customArtworkImage ?? placeholderArtworkImage(size: 260)
        largeArtworkView.image = art

        // Lyrics
        let customLyrics = t.customLyrics ?? (t.lyrics != nil && !t.lyrics!.isEmpty)
        customLyricsCheckbox.state = customLyrics ? .on : .off
        lyricsTextView.string = t.lyrics ?? ""
        lyricsTextView.isEditable = customLyrics

        // Options
        switch t.mediaKind {
        case .song: mediaKindPopup.selectItem(withTitle: "Music")
        case .audiobook: mediaKindPopup.selectItem(withTitle: "Audiobook")
        case .video: mediaKindPopup.selectItem(withTitle: "Video")
        }
        startCheckbox.state = draft.hasStartTime ? .on : .off
        startTimeField.stringValue = Self.formatTimeMs(draft.startTimeMs, thousandths: false)
        startTimeField.isEnabled = draft.hasStartTime

        stopCheckbox.state = draft.hasStopTime ? .on : .off
        stopTimeField.stringValue = Self.formatTimeMs(draft.stopTimeMs, thousandths: true)
        stopTimeField.isEnabled = draft.hasStopTime

        rememberPositionCheckbox.state = (t.rememberPlaybackPosition ?? false) ? .on : .off
        skipShufflingCheckbox.state = (t.skipWhenShuffling ?? false) ? .on : .off

        let vol = t.volumeAdjustment ?? 0
        volumeSlider.integerValue = vol
        volumeValueLabel.stringValue = vol == 0 ? "None" : "\(vol > 0 ? "+" : "")\(vol)%"

        let eq = t.eqPreset ?? "None"
        if eqPopup.item(withTitle: eq) != nil {
            eqPopup.selectItem(withTitle: eq)
        } else {
            eqPopup.selectItem(withTitle: "None")
        }

        // Sorting
        sortNameField.stringValue = t.title
        sortNameAsField.stringValue = t.sortTitle ?? ""
        sortAlbumField.stringValue = t.album ?? ""
        sortAlbumAsField.stringValue = t.sortAlbum ?? ""
        sortAlbumArtistField.stringValue = t.albumArtist ?? ""
        sortAlbumArtistAsField.stringValue = t.sortAlbumArtist ?? ""
        sortArtistField.stringValue = t.artist ?? ""
        sortArtistAsField.stringValue = t.sortArtist ?? ""
        sortComposerField.stringValue = t.composer ?? ""
        sortComposerAsField.stringValue = t.sortComposer ?? ""
        updateSortingPlaceholders()
    }

    private func updateHeader() {
        guard let draft else { return }
        let t = draft.track
        headerTitleLabel.stringValue = t.title.isEmpty ? "Untitled" : t.title
        headerArtistLabel.stringValue = t.artist ?? ""
        headerAlbumLabel.stringValue = t.album ?? ""
        headerArtworkView.image = draft.customArtworkImage ?? placeholderArtworkImage(size: 64)
    }

    private func updateSortingPlaceholders() {
        sortNameAsField.placeholderString = sortNameField.stringValue
        sortAlbumAsField.placeholderString = sortAlbumField.stringValue
        sortAlbumArtistAsField.placeholderString = sortAlbumArtistField.stringValue
        sortArtistAsField.placeholderString = sortArtistField.stringValue
        sortComposerAsField.placeholderString = sortComposerField.stringValue
    }

    private func updateRatingAndFavorite() {
        guard let draft else { return }
        let rating = draft.track.rating
        for btn in starButtons {
            let filled = btn.tag <= rating
            if #available(macOS 11, *) {
                btn.image = NSImage(systemSymbolName: filled ? "star.fill" : "star", accessibilityDescription: "\(btn.tag) stars")
            } else {
                btn.title = filled ? "★" : "☆"
            }
            btn.contentTintColor = filled ? .systemYellow : .secondaryLabelColor
        }
        let isFav = draft.track.isFavorite ?? false
        let iconBase = ListAppearance.shared.favoriteIcon == .star ? "star" : "heart"
        let symbol = isFav ? "\(iconBase).fill" : iconBase
        if #available(macOS 11, *) {
            favoriteButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Favorite")
        } else {
            favoriteButton.title = isFav ? "♥" : "♡"
        }
        favoriteButton.contentTintColor = isFav ? .controlAccentColor : .secondaryLabelColor
    }

    private func updatePlayCountLabel() {
        guard let draft else { return }
        let count = draft.resetPlayCount ? 0 : draft.track.playCount
        if !draft.resetPlayCount, let last = draft.track.lastPlayed {
            playCountLabel.stringValue = "\(count)  (Last played: \(Self.mediumDateFormatter.string(from: last)))"
        } else {
            playCountLabel.stringValue = "\(count)"
        }
    }

    private func updateNavButtons() {
        prevButton.isEnabled = !isSaving && currentIndex > 0
        nextButton.isEnabled = !isSaving && currentIndex + 1 < rows.count
        okButton.isEnabled = !isSaving
        cancelButton.isEnabled = !isSaving
    }

    private func switchTab(to tab: Tab) {
        selectedTab = tab
        for sub in contentContainer.subviews { sub.removeFromSuperview() }
        if let view = tabViews[tab] {
            contentContainer.addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: contentContainer.topAnchor),
                view.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
                view.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            ])
        }

        for (key, btn) in tabButtons {
            let active = key == tab
            btn.layer?.backgroundColor = active ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
            btn.contentTintColor = active ? .white : .labelColor
            let titleColor: NSColor = active ? .white : .labelColor
            btn.attributedTitle = NSAttributedString(
                string: key.title,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: active ? .semibold : .medium),
                    .foregroundColor: titleColor,
                ]
            )
        }

        // Context-sensitive bottom-bar controls (MUS-27, MUS-28)
        addArtworkButton.isHidden = (tab != .artwork)
        customLyricsCheckbox.isHidden = (tab != .lyrics)

        if tab == .file, let track = draft?.track, inspectedTrackID != track.id {
            inspectFileTechnicalDetails(for: track)
        }
    }

    private lazy var placeholder64: NSImage? = makePlaceholderArtworkImage(size: 64)
    private lazy var placeholder260: NSImage? = makePlaceholderArtworkImage(size: 260)

    private func placeholderArtworkImage(size: CGFloat) -> NSImage? {
        size <= 100 ? placeholder64 : placeholder260
    }

    private func makePlaceholderArtworkImage(size: CGFloat) -> NSImage? {
        guard #available(macOS 11, *) else { return nil }
        let cfg = NSImage.SymbolConfiguration(pointSize: size * 0.42, weight: .regular)
        return NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
    }

    // MARK: - Actions & Syncing

    @objc private func tabButtonClicked(_ sender: NSButton) {
        guard let tab = Tab(rawValue: sender.tag) else { return }
        switchTab(to: tab)
    }

    @objc private func previousTrackClicked() {
        guard currentIndex > 0 else { return }
        currentIndex -= 1
        loadCurrentTrack()
    }

    @objc private func nextTrackClicked() {
        guard currentIndex + 1 < rows.count else { return }
        currentIndex += 1
        loadCurrentTrack()
    }

    @objc private func cancelClicked() {
        fileInspectTask?.cancel()
        window?.close()
    }

    @objc private func okClicked() {
        commitTextViewsToDraft()
        guard let draft else {
            window?.close()
            return
        }
        let finalTrack = draft.finalizedTrack()
        let artworkData = draft.customArtworkData
        guard let onSaveTrack else {
            window?.close()
            return
        }

        isSaving = true
        errorLabel.isHidden = true
        updateNavButtons()

        onSaveTrack(finalTrack, artworkData) { [weak self] result in
            guard let self else { return }
            self.isSaving = false
            self.updateNavButtons()
            switch result {
            case .success:
                self.fileInspectTask?.cancel()
                self.window?.close()
            case .failure(let error):
                self.errorLabel.stringValue = error.localizedDescription
                self.errorLabel.isHidden = false
            }
        }
    }

    @objc private func addArtworkClicked() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if #available(macOS 11, *) {
            panel.allowedContentTypes = [.image]
        } else {
            panel.allowedFileTypes = ["png", "jpg", "jpeg", "tiff", "heic", "webp"]
        }
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor [weak self] in
                let loaded = await Task.detached(priority: .userInitiated) { () -> (Data, CGImage)? in
                    guard let data = try? Data(contentsOf: url),
                          let source = CGImageSourceCreateWithData(data as CFData, nil),
                          let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceThumbnailMaxPixelSize: 600,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                          ] as CFDictionary) else { return nil }
                    return (data, cgImage)
                }.value
                guard let self, let (data, cgImage) = loaded else { return }
                let image = NSImage(cgImage: cgImage, size: .zero)
                self.draft?.customArtworkData = data
                self.draft?.customArtworkImage = image
                self.largeArtworkView.image = image
                self.headerArtworkView.image = image
            }
        }
    }

    @objc private func customLyricsToggled() {
        let enabled = customLyricsCheckbox.state == .on
        draft?.track.customLyrics = enabled
        lyricsTextView.isEditable = enabled
        if enabled {
            window?.makeFirstResponder(lyricsTextView)
        }
    }

    @objc private func starClicked(_ sender: NSButton) {
        guard var d = draft else { return }
        d.track.rating = (d.track.rating == sender.tag) ? 0 : sender.tag
        draft = d
        updateRatingAndFavorite()
    }

    @objc private func favoriteClicked() {
        guard var d = draft else { return }
        d.track.isFavorite = !(d.track.isFavorite ?? false)
        draft = d
        updateRatingAndFavorite()
    }

    @objc private func resetPlayCountClicked() {
        draft?.resetPlayCount = true
        updatePlayCountLabel()
    }

    @objc private func detailsFieldChanged(_ sender: NSTextField) {
        syncFieldToDraft(sender)
    }

    @objc private func detailsCheckboxChanged() {
        draft?.track.showComposerInAllViews = showComposerCheckbox.state == .on
        draft?.track.compilation = compilationCheckbox.state == .on
    }

    @objc private func optionsChanged() {
        guard var d = draft else { return }
        switch mediaKindPopup.titleOfSelectedItem {
        case "Audiobook": d.track.kind = .audiobook
        case "Video": d.track.kind = .video
        default: d.track.kind = .song
        }
        d.hasStartTime = startCheckbox.state == .on
        startTimeField.isEnabled = d.hasStartTime
        d.hasStopTime = stopCheckbox.state == .on
        stopTimeField.isEnabled = d.hasStopTime
        d.track.rememberPlaybackPosition = rememberPositionCheckbox.state == .on
        d.track.skipWhenShuffling = skipShufflingCheckbox.state == .on
        let eq = eqPopup.titleOfSelectedItem ?? "None"
        d.track.eqPreset = (eq == "None") ? nil : eq
        draft = d
    }

    @objc private func optionsTimeEdited() {
        guard var d = draft else { return }
        let duration = max(0, d.track.durationMs)
        let parsedStart = Self.parseTimeMs(startTimeField.stringValue) ?? d.startTimeMs
        d.startTimeMs = max(0, min(parsedStart, duration))
        let parsedStop = Self.parseTimeMs(stopTimeField.stringValue) ?? d.stopTimeMs
        d.stopTimeMs = max(d.startTimeMs, min(parsedStop, duration))
        draft = d
        startTimeField.stringValue = Self.formatTimeMs(d.startTimeMs, thousandths: false)
        stopTimeField.stringValue = Self.formatTimeMs(d.stopTimeMs, thousandths: true)
    }

    @objc private func volumeSliderChanged() {
        let vol = volumeSlider.integerValue
        draft?.track.volumeAdjustment = (vol == 0) ? nil : vol
        volumeValueLabel.stringValue = vol == 0 ? "None" : "\(vol > 0 ? "+" : "")\(vol)%"
    }

    @objc private func textDidChangeNotification(_ notification: Notification) {
        guard let obj = notification.object as? NSControl else { return }
        syncFieldToDraft(obj)
    }

    private func syncFieldToDraft(_ control: NSControl) {
        guard var d = draft else { return }
        switch control {
        case songField:
            d.track.title = songField.stringValue
            sortNameField.stringValue = songField.stringValue
        case sortNameField:
            d.track.title = sortNameField.stringValue
            songField.stringValue = sortNameField.stringValue
        case artistField:
            d.track.artist = artistField.stringValue.isEmpty ? nil : artistField.stringValue
            sortArtistField.stringValue = artistField.stringValue
        case sortArtistField:
            d.track.artist = sortArtistField.stringValue.isEmpty ? nil : sortArtistField.stringValue
            artistField.stringValue = sortArtistField.stringValue
        case albumField:
            d.track.album = albumField.stringValue.isEmpty ? nil : albumField.stringValue
            sortAlbumField.stringValue = albumField.stringValue
        case sortAlbumField:
            d.track.album = sortAlbumField.stringValue.isEmpty ? nil : sortAlbumField.stringValue
            albumField.stringValue = sortAlbumField.stringValue
        case albumArtistField:
            d.track.albumArtist = albumArtistField.stringValue.isEmpty ? nil : albumArtistField.stringValue
            sortAlbumArtistField.stringValue = albumArtistField.stringValue
        case sortAlbumArtistField:
            d.track.albumArtist = sortAlbumArtistField.stringValue.isEmpty ? nil : sortAlbumArtistField.stringValue
            albumArtistField.stringValue = sortAlbumArtistField.stringValue
        case composerField:
            d.track.composer = composerField.stringValue.isEmpty ? nil : composerField.stringValue
            sortComposerField.stringValue = composerField.stringValue
        case sortComposerField:
            d.track.composer = sortComposerField.stringValue.isEmpty ? nil : sortComposerField.stringValue
            composerField.stringValue = sortComposerField.stringValue
        case groupingField:
            d.track.grouping = groupingField.stringValue.isEmpty ? nil : groupingField.stringValue
        case genreCombo:
            d.track.genre = genreCombo.stringValue.isEmpty ? nil : genreCombo.stringValue
        case yearField:
            d.track.year = Int(yearField.stringValue) ?? 0
        case trackNumField:
            d.track.trackNumber = Int(trackNumField.stringValue) ?? 0
        case trackTotalField:
            d.track.trackCount = Int(trackTotalField.stringValue) ?? 0
        case discNumField:
            d.track.discNumber = Int(discNumField.stringValue) ?? 0
        case discTotalField:
            d.track.discCount = Int(discTotalField.stringValue) ?? 0
        case bpmField:
            d.track.bpm = Int(bpmField.stringValue) ?? 0
        case sortNameAsField:
            d.track.sortTitle = sortNameAsField.stringValue.isEmpty ? nil : sortNameAsField.stringValue
        case sortAlbumAsField:
            d.track.sortAlbum = sortAlbumAsField.stringValue.isEmpty ? nil : sortAlbumAsField.stringValue
        case sortAlbumArtistAsField:
            d.track.sortAlbumArtist = sortAlbumArtistAsField.stringValue.isEmpty ? nil : sortAlbumArtistAsField.stringValue
        case sortArtistAsField:
            d.track.sortArtist = sortArtistAsField.stringValue.isEmpty ? nil : sortArtistAsField.stringValue
        case sortComposerAsField:
            d.track.sortComposer = sortComposerAsField.stringValue.isEmpty ? nil : sortComposerAsField.stringValue
        default:
            break
        }
        draft = d
        updateHeader()
        updateSortingPlaceholders()
    }

    private func commitTextViewsToDraft() {
        guard var d = draft else { return }
        let comment = commentsTextView.string
        d.track.comment = comment.isEmpty ? nil : comment
        let lyrics = lyricsTextView.string
        d.track.lyrics = lyrics.isEmpty ? nil : lyrics
        d.track.customLyrics = customLyricsCheckbox.state == .on
        draft = d
        optionsTimeEdited()
    }

    // MARK: - File Technical Info (MUS-31, off main thread)

    private func inspectFileTechnicalDetails(for track: LibraryTrack) {
        fileInspectTask?.cancel()
        inspectedTrackID = track.id
        fileKindLabel.stringValue = Self.kindDescription(for: track.fileExtension)
        fileDurationLabel.stringValue = Self.formatTimeMs(track.durationMs, thousandths: false)
        fileSizeLabel.stringValue = track.fileSize > 0 ? ByteCountFormatter.string(fromByteCount: track.fileSize, countStyle: .file) : ""
        fileBitRateLabel.stringValue = track.bitrate > 0 ? "\(track.bitrate) kbps" : ""
        fileSampleRateLabel.stringValue = track.sampleRate > 0 ? String(format: "%.3f kHz", Double(track.sampleRate) / 1000.0) : ""
        fileChannelsLabel.stringValue = ""
        let vol = track.volumeAdjustment ?? 0
        fileVolumeLabel.stringValue = vol == 0 ? "" : "\(vol > 0 ? "+" : "")\(vol)%"
        fileID3Label.stringValue = ""
        fileID3Label.isHidden = true
        fileID3RowTitle.isHidden = true
        fileEncodedWithLabel.stringValue = ""
        fileFormatLabel.stringValue = ""

        fileDateModifiedLabel.stringValue = track.dateModified.map { Self.mediumDateFormatter.string(from: $0) } ?? ""
        fileDateAddedLabel.stringValue = Self.mediumDateFormatter.string(from: track.dateAdded)
        fileLocationLabel.stringValue = track.path

        let path = track.path
        guard !path.isEmpty else { return }
        fileInspectTask = Task { [weak self] in
            let info = await Task.detached(priority: .utility) {
                await Self.readAudioFileInfo(at: path)
            }.value
            guard !Task.isCancelled, let self else { return }
            if let channels = info.channels { self.fileChannelsLabel.stringValue = channels }
            if let format = info.format { self.fileFormatLabel.stringValue = format }
            if let id3 = info.id3Tag {
                self.fileID3Label.stringValue = id3
                self.fileID3Label.isHidden = false
                self.fileID3RowTitle.isHidden = false
            }
            if let encoder = info.encodedWith { self.fileEncodedWithLabel.stringValue = encoder }
            if let modified = info.dateModified { self.fileDateModifiedLabel.stringValue = Self.mediumDateFormatter.string(from: modified) }
            if let size = info.fileSize, size > 0 {
                self.fileSizeLabel.stringValue = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
            }
        }
    }

    private struct FileInfo {
        var channels: String?
        var format: String?
        var id3Tag: String?
        var encodedWith: String?
        var dateModified: Date?
        var fileSize: Int64?
    }

    private static func readAudioFileInfo(at path: String) async -> FileInfo {
        var info = FileInfo()
        let url = URL(fileURLWithPath: path)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path) {
            info.dateModified = attrs[.modificationDate] as? Date
            if let num = attrs[.size] as? NSNumber { info.fileSize = num.int64Value }
        }
        // Check ID3v2 header
        if let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            if let header = try? handle.read(upToCount: 5),
               header.count >= 4,
               header[0] == 0x49, header[1] == 0x44, header[2] == 0x33 {
                info.id3Tag = "v2.\(header[3])"
            }
        }

        let asset = AVURLAsset(url: url)
        if #available(macOS 12, *) {
            if let tracks = try? await asset.loadTracks(withMediaType: .audio), let first = tracks.first,
               let descs = try? await first.load(.formatDescriptions), let desc = descs.first {
                if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee {
                    switch asbd.mChannelsPerFrame {
                    case 1: info.channels = "Mono"
                    case 2: info.channels = "Stereo"
                    case let n where n > 2: info.channels = "\(n) channels"
                    default: break
                    }
                    var asbdCopy = asbd
                    var nameSize: UInt32 = 0
                    var cfName: Unmanaged<CFString>?
                    let propSize = UInt32(MemoryLayout<CFString?>.size)
                    if AudioFormatGetPropertyInfo(kAudioFormatProperty_FormatName, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &asbdCopy, &nameSize) == noErr {
                        var mutablePropSize = propSize
                        if AudioFormatGetProperty(kAudioFormatProperty_FormatName, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &asbdCopy, &mutablePropSize, &cfName) == noErr,
                           let str = cfName?.takeRetainedValue() as String? {
                            info.format = str
                        }
                    }
                }
            }

            if let metadata = try? await asset.load(.metadata) {
                for item in metadata {
                    let keyStr = (item.commonKey?.rawValue ?? "") + " " + (item.identifier?.rawValue ?? "")
                    if keyStr.localizedCaseInsensitiveContains("encoder") || keyStr.contains("TSSE") || keyStr.contains("too") {
                        if let val = try? await item.load(.stringValue), !val.isEmpty {
                            info.encodedWith = val
                            break
                        }
                    }
                }
            }
        }
        return info
    }

    private static func kindDescription(for ext: String) -> String {
        let lower = ext.lowercased()
        switch lower {
        case "mp3": return "MPEG audio file"
        case "m4a", "aac": return "Apple MPEG-4 audio"
        case "flac": return "FLAC audio file"
        case "wav": return "Waveform audio"
        case "aiff", "aif": return "AIFF audio"
        case "alac": return "Apple Lossless audio"
        default:
            if #available(macOS 11, *), let type = UTType(filenameExtension: lower), let desc = type.localizedDescription {
                return desc
            }
            return lower.isEmpty ? "Audio file" : "\(lower.uppercased()) audio file"
        }
    }

    // MARK: - Transparency & Window Delegate

    private func observeReduceTransparency() {
        transparencyObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.headerOpaqueFallback.isHidden = !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        artworkLoadTask?.cancel()
        fileInspectTask?.cancel()
    }

    // MARK: - Formatting Helpers

    static func formatTimeMs(_ ms: Int, thousandths: Bool) -> String {
        let clamped = max(0, ms)
        let totalSeconds = clamped / 1000
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        let remMs = clamped % 1000
        if thousandths {
            return String(format: "%d:%02d.%03d", minutes, seconds, remMs)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    static func parseTimeMs(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ":")
        if parts.count == 2, let mins = Int(parts[0]), let secs = Double(parts[1]) {
            return max(0, Int((Double(mins * 60) + secs) * 1000.0))
        }
        if let secs = Double(trimmed) {
            return max(0, Int(secs * 1000.0))
        }
        return nil
    }
}

// MARK: - Helpers

@MainActor
private func makeMetadataReadOnlyLabel(wraps: Bool = false) -> NSTextField {
    let label = NSTextField(labelWithString: "")
    label.font = .systemFont(ofSize: 12)
    label.textColor = .labelColor
    label.isSelectable = true
    label.isBordered = false
    label.drawsBackground = false
    if wraps {
        label.lineBreakMode = .byCharWrapping
        label.maximumNumberOfLines = 0
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    } else {
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
    }
    return label
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class DigitsOnlyFormatter: Formatter {
    override func string(for obj: Any?) -> String? {
        obj as? String
    }

    override func getObjectValue(_ obj: AutoreleasingUnsafeMutablePointer<AnyObject?>?, for string: String, errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool {
        obj?.pointee = string as NSString
        return true
    }

    override func isPartialStringValid(_ partialString: String, newEditingString newString: AutoreleasingUnsafeMutablePointer<NSString?>?, errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool {
        partialString.allSatisfy(\.isASCII) && partialString.allSatisfy { $0.isNumber }
    }
}

/// Encodes an image to JPEG (max 600 px) and stores it in `artworkFolder` under its SHA-1 key, returning the key.
enum MetadataArtworkSaver {
    static func saveCustomArtwork(_ data: Data, into artworkFolder: URL) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 600,
                kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary) else { return nil }

        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }

        let jpegData = out as Data
        let digest = Insecure.SHA1.hash(data: jpegData)
        let key = digest.prefix(12).map { String(format: "%02x", $0) }.joined()
        try? FileManager.default.createDirectory(at: artworkFolder, withIntermediateDirectories: true)
        let fileURL = artworkFolder.appendingPathComponent("\(key).jpg")
        do {
            try jpegData.write(to: fileURL, options: .atomic)
            return key
        } catch {
            return nil
        }
    }
}
#endif
