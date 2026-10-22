//
//  Formatters.swift
//  iPod Pro Max
//

import SwiftUI
import AppKit

enum Format {
    static func duration(ms: Int) -> String {
        let total = max(ms / 1000, 0)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    static func bytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }

    static func shortDate(_ d: Date?) -> String {
        guard let d else { return "" }
        return d.formatted(date: .abbreviated, time: .omitted)
    }

    static func relative(_ d: Date?) -> String {
        guard let d else { return "never" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: Date())
    }
}

extension LibraryTrack {
    var artistForSort: String { artist ?? albumArtist ?? "" }
    var albumForSort: String { album ?? "" }
    var genreForSort: String { genre ?? "" }
    var formatLabel: String {
        let ext = fileExtension.uppercased()
        if needsTranscode { return "\(ext) → AAC" }
        if isLossless && (ext == "M4A") { return "ALAC" }
        return ext
    }
}

/// Decoded, display-sized thumbnails kept in memory, so revisiting an artist or scrolling back shows
/// artwork instantly instead of re-reading and re-decoding it from disk every time. NSCache evicts on
/// its own under memory pressure; the cost limit keeps it to a few tens of MB.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.totalCostLimit = 64 * 1024 * 1024
        return c
    }()

    private func key(_ url: URL, _ pixels: Int) -> NSString { "\(pixels)|\(url.path)" as NSString }

    func image(for url: URL, pixels: Int) -> NSImage? { cache.object(forKey: key(url, pixels)) }

    func insert(_ image: NSImage, for url: URL, pixels: Int) {
        cache.setObject(image, forKey: key(url, pixels), cost: pixels * pixels * 4)
    }

    func remove(_ url: URL) {
        // Sizes vary per call site; a replaced file (e.g. a new artist photo) just needs its common sizes gone.
        for px in [16, 48, 56, 68, 80, 192, 300] { cache.removeObject(forKey: key(url, px)) }
    }

    /// Loads `url` downsampled so its longest side is `pixels`, from the cache or off the main thread.
    /// ImageIO's thumbnail path decodes at the reduced size directly, far cheaper than a full decode.
    func load(_ url: URL, pixels: Int) async -> NSImage? {
        if let hit = image(for: url, pixels: pixels) { return hit }
        let cg: CGImage? = await Task.detached(priority: .userInitiated) {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: pixels,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        }.value
        guard let cg else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        insert(image, for: url, pixels: pixels)
        return image
    }
}

/// Small artwork thumbnail loaded off the main thread. Takes the file URL directly so it never depends on
/// environment objects — table cells on macOS can be hosted outside the main view tree.
struct ArtworkThumb: View {
    let url: URL?
    var size: CGFloat = 40
    var cornerRadius: CGFloat = 4
    var placeholder: String = "music.note"
    @State private var image: NSImage?

    init(url: URL?, size: CGFloat = 40, cornerRadius: CGFloat = 4, placeholder: String = "music.note") {
        self.url = url
        self.size = size
        self.cornerRadius = cornerRadius
        self.placeholder = placeholder
        // A cached image is shown on the very first frame — no placeholder flash, no async hop.
        _image = State(initialValue: url.flatMap { ThumbnailCache.shared.image(for: $0, pixels: Self.pixels(for: size)) })
    }

    /// Pixel size to decode at for a point size (Retina 2×), bucketed so nearby sizes share cache entries.
    static func pixels(for size: CGFloat) -> Int {
        let px = Int(size * 2)
        return [16, 48, 56, 68, 80, 192, 300].first { $0 >= px } ?? px
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(Color.secondary.opacity(0.15))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            } else {
                Image(systemName: placeholder)
                    .foregroundStyle(.secondary)
                    .font(.system(size: size * 0.4))
            }
        }
        .frame(width: size, height: size)
        .task(id: url) {
            guard let url else { image = nil; return }
            let loaded = await ThumbnailCache.shared.load(url, pixels: Self.pixels(for: size))
            if !Task.isCancelled { image = loaded }
        }
    }
}

/// A soft, blurred wash of an image for header backgrounds. Decodes a 16-px version and lets the GPU
/// upscale it with smooth interpolation — it looks like a heavy blur, without paying for one over a
/// large layer.
struct BlurredArtwork: View {
    let url: URL?
    @State private var image: NSImage?

    init(url: URL?) {
        self.url = url
        _image = State(initialValue: url.flatMap { ThumbnailCache.shared.image(for: $0, pixels: 16) })
    }

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: url) {
            guard let url else { image = nil; return }
            let loaded = await ThumbnailCache.shared.load(url, pixels: 16)
            if !Task.isCancelled { image = loaded }
        }
    }
}

struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String
    var actions: () -> AnyView = { AnyView(EmptyView()) }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 48, weight: .thin)).foregroundStyle(.secondary)
            Text(title).font(.title2.bold())
            Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            actions().padding(.top, 6)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Lays children out left to right and wraps to a new line when a child doesn't fit, keeping each child whole.
struct FlowLayout: Layout {
    var hSpacing: CGFloat = 8
    var vSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews: subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + vSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + hSpacing
            }
            y += row.height + vSpacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].indices.isEmpty ? size.width : rows[rows.count - 1].width + hSpacing + size.width
            if needed > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width = row.indices.isEmpty ? size.width : row.width + hSpacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}
