import Foundation
import iPodKit
import PluginKit

/// Builds the Soulseek upload share index from local Music folders or connected iPod storage (`SUB-17`).
public enum ShareIndexBuilder {
    public struct BuiltIndex: Sendable {
        public var entries: [ShareIndexEntry]
        public var uploadSlots: Int
        public var summary: String
        public var sourceKind: SourceKind

        public enum SourceKind: Equatable, Sendable {
            case hostFolders(folderCount: Int)
            case ipodFallback
            case none
        }
    }

    public static func build(
        store: PortableLibraryStore,
        tracks: [LibraryTrack],
        connectedDevice: IPodDevice? = nil
    ) -> BuiltIndex {
        let hostSources = store.currentHost()?.sources.filter { $0.kind == .music } ?? []

        // 1. Prefer local Music folders on the host computer (`<FolderName>\<RelativePath>`), 2 upload slots.
        if !hostSources.isEmpty {
            let normalizedRoots = hostSources.compactMap { src -> (name: String, prefix: String)? in
                let std = URL(fileURLWithPath: src.path).standardizedFileURL
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: std.path, isDirectory: &isDir), isDir.boolValue else {
                    return nil
                }
                let folderName = std.lastPathComponent.isEmpty ? "Music" : std.lastPathComponent
                let prefix = std.path.hasSuffix("/") ? std.path : std.path + "/"
                return (folderName, prefix)
            }
            .sorted { $0.prefix.count > $1.prefix.count }

            if !normalizedRoots.isEmpty {
                var entries: [ShareIndexEntry] = []
                entries.reserveCapacity(tracks.count)
                var representedFolders = Set<String>()

                for track in tracks where track.mediaKind == .song && FileManager.default.fileExists(atPath: track.path) {
                    let stdPath = URL(fileURLWithPath: track.path).standardizedFileURL.path
                    guard let root = normalizedRoots.first(where: { stdPath.hasPrefix($0.prefix) }) else { continue }
                    let rel = String(stdPath.dropFirst(root.prefix.count))
                    guard !rel.isEmpty else { continue }
                    let virtual = "\(root.name)\\\(rel.replacingOccurrences(of: "/", with: "\\"))"
                    representedFolders.insert(root.prefix)
                    entries.append(ShareIndexEntry(
                        virtualPath: virtual,
                        realPath: stdPath,
                        size: max(0, track.fileSize),
                        bitrateKbps: track.bitrate > 0 ? track.bitrate : nil,
                        durationMs: track.durationMs > 0 ? track.durationMs : nil
                    ))
                }

                let folderCount = max(representedFolders.count, normalizedRoots.count)
                let summary = entries.isEmpty
                    ? "Not sharing"
                    : "Sharing \(entries.count) file\(entries.count == 1 ? "" : "s") in \(folderCount) folder\(folderCount == 1 ? "" : "s")"
                return BuiltIndex(
                    entries: entries,
                    uploadSlots: 2,
                    summary: summary,
                    sourceKind: .hostFolders(folderCount: folderCount)
                )
            }
        }

        // 2. Fallback: share audio tracks on the connected iPod under virtual paths `iPod\<Artist>\<Album>\<NN> <Title>.<ext>`, 1 upload slot.
        if let device = connectedDevice, let db = try? device.readDatabase() {
            var entries: [ShareIndexEntry] = []
            for item in db.tracks where item.mediaType == 0x0001 || item.mediaType == 0 {
                guard let url = item.fileURL(mountPoint: device.mountPoint),
                      FileManager.default.fileExists(atPath: url.path) else {
                    continue
                }
                let artist = DownloadPlacement.sanitizeComponent(item.albumArtist ?? item.artist, fallback: "Unknown Artist")
                let album = DownloadPlacement.sanitizeComponent(item.album, fallback: "Unknown Album")
                let numStr = item.trackNumber > 0 ? String(format: "%02d ", item.trackNumber) : ""
                let title = DownloadPlacement.sanitizeComponent(item.title, fallback: url.deletingPathExtension().lastPathComponent)
                let ext = url.pathExtension.isEmpty ? "m4a" : url.pathExtension.lowercased()
                let virtual = "iPod\\\(artist)\\\(album)\\\(numStr)\(title).\(ext)"
                entries.append(ShareIndexEntry(
                    virtualPath: virtual,
                    realPath: url.path,
                    size: Int64(item.fileSize),
                    bitrateKbps: item.bitrate > 0 ? Int(item.bitrate) : nil,
                    durationMs: item.durationMs > 0 ? Int(item.durationMs) : nil
                ))
            }
            let summary = entries.isEmpty
                ? "Not sharing"
                : "Sharing your iPod: \(entries.count) file\(entries.count == 1 ? "" : "s")"
            return BuiltIndex(
                entries: entries,
                uploadSlots: 1,
                summary: summary,
                sourceKind: .ipodFallback
            )
        }

        return BuiltIndex(entries: [], uploadSlots: 1, summary: "Not sharing", sourceKind: .none)
    }
}
