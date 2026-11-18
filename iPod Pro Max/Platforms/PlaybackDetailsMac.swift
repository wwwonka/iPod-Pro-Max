#if os(macOS)
import Foundation
import AVFoundation
import MediaKit

/// Local tags only, invoked on a utility task. No artwork decoding or network lookup.
enum PlaybackDetails {
    static func read(_ url: URL, needsLyrics: Bool) -> (lyrics: String?, chapters: [PlaybackChapter]) {
        guard !Task.isCancelled else { return (nil, []) }
        let asset = AVURLAsset(url: url)
        var lyrics: String?
        if needsLyrics {
            for format in asset.availableMetadataFormats {
                for item in asset.metadata(forFormat: format) {
                    if Task.isCancelled { return (nil, []) }
                    let key = item.identifier?.rawValue.lowercased() ?? ""
                    if key.contains("lyrics") || key.contains("uslt") || key.contains("sylt") { lyrics = item.stringValue ?? lyrics }
                }
            }
        }
        let chapters = asset.chapterMetadataGroups(bestMatchingPreferredLanguages: Locale.preferredLanguages).compactMap { group -> PlaybackChapter? in
            let time = group.timeRange.start.seconds
            guard time.isFinite, time >= 0 else { return nil }
            let title = group.items.first(where: { $0.commonKey == .commonKeyTitle })?.stringValue ?? "Chapter"
            return PlaybackChapter(time: time, title: title)
        }.sorted { $0.time < $1.time }
        return (lyrics, chapters)
    }
}
#endif
