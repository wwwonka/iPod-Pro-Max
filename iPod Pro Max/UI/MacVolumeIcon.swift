#if canImport(AppKitBackend)
    import AppKit
    import AppKitBackend
    import CoreGraphics
    import Foundation
    import ImageIO
    import SwiftCrossUI

    /// The custom icon Finder reads from the root of a volume. Reads and ImageIO decoding happen
    /// once, off the main actor; the cached failure is just as important as a cached image because
    /// most real iPods do not have this file.
    @MainActor
    final class MacVolumeIconLoader {
        static let shared = MacVolumeIconLoader()

        private struct Fingerprint: Equatable {
            var path: String
            var size: Int64
            var modified: Date
        }

        private struct Entry {
            var fingerprint: Fingerprint?
            var image: CGImage?
        }

        private var entries: [String: Entry] = [:]
        private var loads: [String: Task<Entry, Never>] = [:]
        private(set) var readCount = 0

        func image(for volumeRoot: URL) async -> CGImage? {
            let path = volumeRoot.standardizedFileURL.path
            if let entry = entries[path] { return entry.image }
            if let load = loads[path] { return await load.value.image }

            let iconURL = volumeRoot.appendingPathComponent(".VolumeIcon.icns", isDirectory: false)
            readCount += 1
            let load = Task.detached(priority: .utility) { Self.read(iconURL) }
            loads[path] = load
            let entry = await load.value
            loads[path] = nil
            entries[path] = entry
            return entry.image
        }

        /// A reconnect, explicit cache invalidation or changed device snapshot is the boundary at
        /// which the icon's size/date are inspected again. Ordinary renders and resizes never stat it.
        func remove(_ volumeRoot: URL) {
            let path = volumeRoot.standardizedFileURL.path
            loads[path]?.cancel()
            loads[path] = nil
            entries[path] = nil
        }

        nonisolated private static func read(_ iconURL: URL) -> Entry {
            guard !Task.isCancelled,
                  let values = try? iconURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize,
                  let modified = values.contentModificationDate,
                  let source = CGImageSourceCreateWithURL(iconURL as CFURL, nil)
            else { return Entry(fingerprint: nil, image: nil) }

            let fingerprint = Fingerprint(path: iconURL.standardizedFileURL.path,
                                          size: Int64(size), modified: modified)
            let count = CGImageSourceGetCount(source)
            guard count > 0 else { return Entry(fingerprint: fingerprint, image: nil) }

            // Prefer the smallest representation that covers a 2x 128-point view (the launch panel's
            // icon, which then travels down to the 80-point header). If none does, take the largest
            // one. This avoids decoding an unnecessarily large ICNS member.
            let targetPixels = 256
            var bestIndex = 0
            var bestPixels = 0
            var bestCoverPixels = Int.max
            for index in 0..<count {
                guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? Int,
                      let height = properties[kCGImagePropertyPixelHeight] as? Int
                else { continue }
                let pixels = min(width, height)
                if pixels >= targetPixels, pixels < bestCoverPixels {
                    bestIndex = index
                    bestCoverPixels = pixels
                } else if bestCoverPixels == Int.max, pixels > bestPixels {
                    bestIndex = index
                    bestPixels = pixels
                }
            }

            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: targetPixels,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            let image = CGImageSourceCreateThumbnailAtIndex(source, bestIndex, options as CFDictionary)
            return Entry(fingerprint: fingerprint, image: image)
        }
    }

    /// Shared native image view used by both the current SwiftCrossUI page and MacDevicePage.
    @MainActor
    final class MacVolumeIconImageView: NSImageView {
        private var representedRoot: String?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            imageScaling = .scaleProportionallyUpOrDown
            imageAlignment = .alignCenter
            translatesAutoresizingMaskIntoConstraints = false
            widthAnchor.constraint(equalToConstant: 80).isActive = true
            heightAnchor.constraint(equalToConstant: 80).isActive = true
            showFallback()
        }

        required init?(coder: NSCoder) { fatalError() }

        func configure(volumeRoot: URL) {
            let root = volumeRoot.standardizedFileURL.path
            guard representedRoot != root else { return }
            representedRoot = root
            showFallback()
            Task { [weak self] in
                let cgImage = await MacVolumeIconLoader.shared.image(for: volumeRoot)
                guard let self, self.representedRoot == root, let cgImage else { return }
                let image = NSImage(cgImage: cgImage, size: NSSize(width: 80, height: 80))
                image.isTemplate = false
                self.contentTintColor = nil
                self.image = image
            }
        }

        private func showFallback() {
            guard #available(macOS 11, *) else { image = nil; return }
            image = NSImage(systemSymbolName: "ipod", accessibilityDescription: "iPod")
            symbolConfiguration = .init(pointSize: 48, weight: .regular)
            contentTintColor = .controlAccentColor
        }
    }

    struct MacVolumeIcon: NSViewRepresentable {
        var volumeRoot: URL

        func makeNSView(context: Context) -> MacVolumeIconImageView {
            let view = MacVolumeIconImageView(frame: .zero)
            view.configure(volumeRoot: volumeRoot)
            return view
        }

        func updateNSView(_ view: MacVolumeIconImageView, context: Context) {
            view.configure(volumeRoot: volumeRoot)
        }

        func sizeThatFits(_ proposal: ProposedViewSize, nsView: MacVolumeIconImageView, context: Context) -> ViewSize {
            ViewSize(80, 80)
        }
    }
#endif
