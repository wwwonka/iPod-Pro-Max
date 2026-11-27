import Foundation

/// What the player LCD shows, decided from playback, display mode and activities, with no UI
/// framework. Each backend applies it (visibility, text, symbols) and animates the changes.
/// Built on every refresh (position ticks too), so it stays a handful of fields and strings.
public struct PlayerLCDPresentation: Equatable, Sendable {
    /// The playing track, as the LCD needs it.
    public struct Track: Equatable, Sendable {
        public var id: String
        public var title: String
        public var artist: String
        public var album: String
        public var path: String
        /// Set by sources that know better (podcast episode, web video).
        public var playbackTitle: String?
        public var playbackSubtitle: String?
        public init(id: String, title: String, artist: String = "", album: String = "", path: String = "",
                    playbackTitle: String? = nil, playbackSubtitle: String? = nil) {
            self.id = id; self.title = title; self.artist = artist; self.album = album; self.path = path
            self.playbackTitle = playbackTitle; self.playbackSubtitle = playbackSubtitle
        }
    }

    public struct Input: Sendable {
        public var track: Track?
        public var playing = false
        public var error = ""
        public var position = 0.0
        public var duration = 0.0
        public var rate = 1.0
        /// The mode chosen by the user, and the one shown (lyrics fall back to title).
        public var mode: PlayerLCDMode = .title
        public var effectiveMode: PlayerLCDMode = .title
        public var lyrics: [TimedLyric] = []
        public var lyricIndex: Int?
        public var showsRemaining = true
        public var idleDetail = ""
        public var activity: PlayerActivity?
        public var activityCount = 0
        public var hovered = false
        public init() {}
    }

    /// A track is playing with nothing covering it (no activity, no error).
    public var available: Bool
    /// The mode arrows apply (something to cycle through).
    public var canChangeView: Bool
    public var titleText: String
    public var subtitleText: String
    public var titleHidden: Bool
    public var subtitleHidden: Bool
    public var coverHidden: Bool
    public var moreHidden: Bool
    /// The "more" button's opacity: shown on hover over a track in title mode.
    public var moreVisible: Bool
    public var timeHidden: Bool
    public var elapsedText: String
    public var remainingText: String
    /// Title and subtitle scroll when long (still subject to the window being visible).
    public var textScrolls: Bool
    /// Metadata dims while paused.
    public var metadataOpacity: Double
    // Activities.
    public var activityControlsHidden: Bool
    public var cancelHidden: Bool
    public var cancelEnabled: Bool
    public var cancelSymbol: String
    public var spinning: Bool
    /// One dot per pending activity, up to five.
    public var indicator: String
    // Mode.
    public var modeSymbol: String
    public var modeToolTip: String
    /// Changes when the content (not the clock) changes: the backend crossfades on it.
    public var contentKey: String
    public var accessibilityValue: String

    public static let modeSymbols: [PlayerLCDMode: String] = [
        .title: "text.alignleft", .spectrum: "chart.bar.fill", .waveform: "waveform", .lyrics: "quote.bubble",
    ]

    public init(_ input: Input) {
        let track = input.track
        let activity = input.activity
        let effective = input.effectiveMode
        let showTitle = effective == .title
        let available = track != nil && input.error.isEmpty && activity == nil
        self.available = available
        canChangeView = track != nil || activity != nil || input.activityCount > 0
        coverHidden = !available
        moreHidden = !available || !showTitle
        moreVisible = input.hovered && available && showTitle
        timeHidden = !available || effective == .spectrum || effective == .lyrics

        activityControlsHidden = activity == nil && input.activityCount == 0
        cancelHidden = activity == nil
        cancelEnabled = activity.map { $0.cancellable || $0.state != .running } ?? false
        cancelSymbol = activity?.state == .completed ? "checkmark" : "xmark"
        spinning = activity?.state == .running && activity?.fraction == nil
        indicator = String(repeating: "•", count: min(5, input.activityCount))

        if let activity {
            titleText = activity.title; subtitleText = activity.detail
            titleHidden = false; subtitleHidden = false
        } else if !input.error.isEmpty {
            titleText = "⚠ " + input.error; subtitleText = ""
            titleHidden = false; subtitleHidden = true
        } else if let track {
            titleHidden = !showTitle && effective != .lyrics
            subtitleHidden = titleHidden
            if effective == .lyrics {
                let lyrics = input.lyrics
                let line = input.lyricIndex.flatMap { lyrics.indices.contains($0) ? lyrics[$0].text : nil }
                titleText = (line?.isEmpty ?? true) ? "♪" : line!
                let next = input.lyricIndex.map { $0 + 1 } ?? 0
                subtitleText = next < lyrics.count ? lyrics[next].text : ""
            } else {
                titleText = track.playbackTitle ?? (track.title.isEmpty ? URL(fileURLWithPath: track.path).lastPathComponent : track.title)
                subtitleText = track.playbackSubtitle ?? [track.artist, track.album].filter { !$0.isEmpty }.joined(separator: " — ")
            }
        } else {
            titleText = ""; subtitleText = input.idleDetail
            titleHidden = true; subtitleHidden = input.idleDetail.isEmpty
        }

        textScrolls = input.playing && activity == nil && (effective == .title || effective == .lyrics)
        metadataOpacity = track != nil && !input.playing && activity == nil ? 0.65 : 1
        let hasDuration = input.duration > 0
        elapsedText = (hasDuration ? Self.time(input.position) : "--:--") + (input.rate == 1 ? "" : " · \(input.rate)×")
        remainingText = hasDuration
            ? (input.showsRemaining ? "−" + Self.time(max(0, input.duration - input.position)) : Self.time(input.duration))
            : "--:--"

        modeSymbol = Self.modeSymbols[input.mode] ?? "text.alignleft"
        modeToolTip = "Display: \(input.mode.rawValue.capitalized)"
        contentKey = "\(track?.id ?? "")|\(effective.rawValue)|\(activity?.id ?? "")|\(effective == .lyrics ? (input.lyricIndex ?? -1) : -1)|\(input.error)"
        accessibilityValue = [activity?.title ?? track?.title ?? "", subtitleText, Self.time(input.position), effective.rawValue].joined(separator: ", ")
    }

    /// `m:ss`, or `h:mm:ss` from an hour.
    public static func time(_ seconds: Double) -> String {
        let n = Int(max(0, seconds.isFinite ? seconds : 0))
        return n >= 3600 ? String(format: "%d:%02d:%02d", n / 3600, n / 60 % 60, n % 60) : String(format: "%d:%02d", n / 60, n % 60)
    }
}
