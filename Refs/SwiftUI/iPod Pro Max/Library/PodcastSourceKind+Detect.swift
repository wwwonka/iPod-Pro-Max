//
//  PodcastSourceKind+Detect.swift
//  iPod Pro Max
//
//  Which feed reader handles a subscription URL. Lives in the app, next to the readers it picks;
//  the kind itself is part of the library model in iPodKit.
//

import Foundation
import iPodKit

extension PodcastSourceKind {
    static func detect(from url: URL) -> PodcastSourceKind {
        if OHdioFeed.isOHdioURL(url) { return .ohdio }
        if YouTubeFeed.isYouTubeURL(url) { return .youtube }
        return .rss
    }
}
