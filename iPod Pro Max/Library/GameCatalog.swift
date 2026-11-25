import Foundation
import iPodKit
import PluginKit

/// The click-wheel games (`.ipg`) of this computer's game folders, shown like albums: each archive
/// holds a JPEG cover (`iTunesArtwork`) and MP4-style tags (`iTunesMetaData`). Only those two small
/// entries are read; the cover is copied once to a cache keyed by the archive's size and date.
/// Nothing runs until the Games page opens or a folder changes.
@MainActor final class GameCatalog {
    static let shared = GameCatalog()
    struct Snapshot {
        var folders: [KnownSource] = []
        var games: [AlbumInfo] = []
        var artworkFolder: URL?
    }
    private var snapshots: [URL: Snapshot] = [:]
    private var pending: [URL: Task<Snapshot, Never>] = [:]

    func load(_ store: PortableLibraryStore, refresh: Bool = false) async -> Snapshot {
        let key = store.hostFolder.url
        if refresh { snapshots[key] = nil; pending[key] = nil }
        if let cached = snapshots[key] { return cached }
        if let task = pending[key] { return await task.value }
        let cache = Self.artworkCache
        let task = Task.detached(priority: .utility) { () -> Snapshot in
            let folders = store.sources(of: .games)
            let files = folders.flatMap { Self.archives(in: URL(fileURLWithPath: $0.path)) }
            try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            // One reader per core: each archive costs a few small reads and one inflate.
            let games = await withTaskGroup(of: AlbumInfo?.self) { group in
                var iterator = files.makeIterator()
                var result: [AlbumInfo] = []
                for _ in 0..<max(1, ProcessInfo.processInfo.activeProcessorCount) {
                    guard let file = iterator.next() else { break }
                    group.addTask { Self.read(file, cache: cache) }
                }
                for await game in group {
                    if let game { result.append(game) }
                    if let file = iterator.next() { group.addTask { Self.read(file, cache: cache) } }
                }
                return result
            }
            let sorted = games.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            return Snapshot(folders: folders, games: sorted, artworkFolder: cache)
        }
        pending[key] = task
        let snapshot = await task.value
        pending[key] = nil
        snapshots[key] = snapshot
        return snapshot
    }

    nonisolated static var artworkCache: URL {
        if let root = PortableRoot.url {
            return root.appendingPathComponent("iPod Pro Max/Persistent Data/UI Cache/Game Artwork", isDirectory: true)
        }
        return FileManager.default.temporaryDirectory.appendingPathComponent("iPod Pro Max Game Artwork", isDirectory: true)
    }

    nonisolated static func archives(in folder: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.lowercased().hasSuffix(".ipg") && !$0.hasPrefix(".") }
            .map { folder.appendingPathComponent($0) }
    }

    nonisolated static func read(_ file: URL, cache: URL) -> AlbumInfo? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let date = Int64((attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
        let fallback = file.deletingPathExtension().lastPathComponent
        let key = "game-" + stableHash("\(fallback)|\(size)|\(date)")
        let cover = cache.appendingPathComponent(key + ".jpg")
        let hasCover = FileManager.default.fileExists(atPath: cover.path)
        let wanted: Set<String> = hasCover ? ["iTunesMetaData"] : ["iTunesMetaData", "iTunesArtwork"]
        guard let entries = try? ZipArchive.read(from: file, only: wanted) else { return nil }
        var tags: [String: String] = [:]
        for entry in entries {
            switch entry.path {
            case "iTunesArtwork": try? entry.data.write(to: cover, options: .atomic)
            case "iTunesMetaData": tags = Self.tags(entry.data)
            default: break
            }
        }
        let artwork = FileManager.default.fileExists(atPath: cover.path) ? key : nil
        let year = tags["©day"].map { String($0.prefix(4)) } ?? ""
        return AlbumInfo(id: file.path, title: tags["©nam"] ?? fallback, year: year, genre: tags["©gen"],
                         artworkKey: artwork, rows: [], durationMs: 0, artist: tags["aART"] ?? tags["©ART"] ?? "")
    }

    /// The game's instruction page (a tall JPEG under `Resources/<lang>/`, named by that folder's
    /// `Description.xml`), copied to the cache on first use. Prefers the system languages, then English.
    nonisolated static func instructions(_ file: URL) async -> URL? {
        await Task.detached(priority: .userInitiated) { () -> URL? in
            let cache = artworkCache.appendingPathComponent("Instructions", isDirectory: true)
            let key = file.deletingPathExtension().lastPathComponent
            guard let entries = try? ZipArchive.read(from: file, where: { name in
                let lower = name.lowercased()
                return lower.hasPrefix("resources/") && (lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") || lower.hasSuffix(".png") || lower.hasSuffix("description.xml"))
            }) else { return nil }
            var byLanguage: [String: [ZipEntry]] = [:]
            for entry in entries {
                let parts = entry.path.split(separator: "/")
                guard parts.count == 3 else { continue }
                byLanguage[parts[1].lowercased(), default: []].append(entry)
            }
            let preferred = Locale.preferredLanguages.map { String($0.prefix(2)).lowercased() } + ["en"]
            guard let language = preferred.first(where: { byLanguage[$0] != nil }) ?? byLanguage.keys.sorted().first,
                  let files = byLanguage[language] else { return nil }
            let images = files.filter { !$0.path.lowercased().hasSuffix(".xml") }
            var chosen = images.first
            if let xml = files.first(where: { $0.path.lowercased().hasSuffix("description.xml") }),
               let text = String(data: xml.data, encoding: .utf8),
               let range = text.range(of: #"url="([^"]+)""#, options: .regularExpression) {
                let name = text[range].dropFirst(5).dropLast()
                chosen = images.first { $0.path.split(separator: "/").last.map(String.init)?.caseInsensitiveCompare(String(name)) == .orderedSame } ?? chosen
            }
            guard let chosen else { return nil }
            let ext = (chosen.path as NSString).pathExtension.lowercased()
            let out = cache.appendingPathComponent("\(key) (\(language)).\(ext)")
            if !FileManager.default.fileExists(atPath: out.path) {
                try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
                guard (try? chosen.data.write(to: out, options: .atomic)) != nil else { return nil }
            }
            return out
        }.value
    }

    /// Text values of the `ilst` atoms we show: each `<tag>` atom holds a `data` atom whose value
    /// starts after its 8-byte type and locale fields.
    nonisolated static func tags(_ data: Data) -> [String: String] {
        let bytes = [UInt8](data)
        var result: [String: String] = [:]
        for tag in ["©nam", "aART", "©ART", "©day", "©gen"] {
            let name = Array(tag.data(using: .isoLatin1)!)
            guard let at = find(name, in: bytes), at >= 4, at + 16 <= bytes.count,
                  Array(bytes[(at + 8)..<(at + 12)]) == Array("data".utf8) else { continue }
            let dataSize = Int(bytes[at + 4]) << 24 | Int(bytes[at + 5]) << 16 | Int(bytes[at + 6]) << 8 | Int(bytes[at + 7])
            let start = at + 20, end = at + 4 + dataSize
            guard dataSize >= 16, end <= bytes.count, start <= end,
                  let value = String(bytes: bytes[start..<end], encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { continue }
            result[tag] = value
        }
        return result
    }

    nonisolated private static func find(_ needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard haystack.count >= needle.count else { return nil }
        for i in 0...(haystack.count - needle.count) where haystack[i] == needle[0] {
            if Array(haystack[i..<(i + needle.count)]) == needle { return i }
        }
        return nil
    }

    /// FNV-1a: stable across launches and platforms, unlike `hashValue`.
    nonisolated private static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return String(hash, radix: 16)
    }
}
