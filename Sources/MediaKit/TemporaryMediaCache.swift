import Foundation
import iPodKit
#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif

public struct MediaCachePolicy: Codable, Equatable, Sendable {
    public var limitBytes: Int64 = 200 * 1024 * 1024
    public var clearSpectrumOnExit = false
    public var clearWaveformsOnExit = false
    public init() {}
}

/// Only derived, disposable data lives here. Methods are called off the main actor.
public final class TemporaryMediaCache: @unchecked Sendable {
    public enum Category: String, CaseIterable, Sendable { case spectrum = "Spectrum", waveforms = "Waveforms", scratch = "Scratch" }
    public static let shared = TemporaryMediaCache()
    public let root: URL
    private let lock = NSRecursiveLock()
    private let scratch: TemporaryScratchSpace
    private var policy = MediaCachePolicy()
    public init(root: URL? = nil) {
        #if os(Linux)
        let base = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
        self.root = root ?? base.appendingPathComponent("iPod Pro Max-\(getuid())", isDirectory: true)
        #else
        self.root = root ?? FileManager.default.temporaryDirectory.appendingPathComponent("iPod Pro Max", isDirectory: true)
        #endif
        scratch = TemporaryScratchSpace(root: self.root.appendingPathComponent(Category.scratch.rawValue, isDirectory: true))
    }
    public static func key(path: String, size: Int64, modified: Date) -> String {
        var hash = SHA1(); hash.update(data: Array("\(path)|\(size)|\(modified.timeIntervalSince1970)".utf8))
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    public static func key(for url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return key(path: url.standardizedFileURL.path, size: Int64(values?.fileSize ?? -1), modified: values?.contentModificationDate ?? .distantPast)
    }
    public func directory(_ category: Category) -> URL { root.appendingPathComponent(category.rawValue, isDirectory: true) }
    public func scratchURL(extension suffix: String = "tmp") -> URL {
        lock.lock(); defer { lock.unlock() }
        return scratch.url(extension: suffix)
    }
    public func read(_ category: Category, key: String, version: Int = 1) -> Data? {
        lock.lock(); defer { lock.unlock() }
        let url = directory(category).appendingPathComponent("v\(version)-\(key).bin")
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return data
    }
    public func touch(_ category: Category, key: String, version: Int = 1) {
        lock.lock(); defer { lock.unlock() }
        let url = directory(category).appendingPathComponent("v\(version)-\(key).bin")
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }
    public func write(_ data: Data, category: Category, key: String, version: Int = 1) {
        lock.lock(); defer { lock.unlock() }
        let folder = directory(category)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: folder.appendingPathComponent("v\(version)-\(key).bin"), options: .atomic)
            trim()
        } catch { /* The memory result remains usable. */ }
    }
    public func commitScratch(_ file: URL, category: Category, key: String) {
        lock.lock(); defer { lock.unlock() }
        let folder = directory(category), fm = FileManager.default
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appendingPathComponent("v1-\(key).bin")
            // Rename within the temporary filesystem; readers see either complete version.
            #if os(Windows)
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.moveItem(at: file, to: destination)
            #else
            guard rename(file.path, destination.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
            #endif
            trim()
        } catch { try? fm.removeItem(at: file) }
    }
    public func configure(_ policy: MediaCachePolicy, launchCleanup: Bool = false) {
        lock.lock(); defer { lock.unlock() }; self.policy = policy
        if launchCleanup {
            let fm = FileManager.default
            scratch.cleanupAbandonedSessions()
            for category in [Category.spectrum, .waveforms] {
                for file in files(category) {
                    if !file.lastPathComponent.hasPrefix("v1-") { try? fm.removeItem(at: file) }
                }
            }
        }
        trim()
    }
    public func sizes() -> [String: Int64] {
        lock.lock(); defer { lock.unlock() }
        return Dictionary(uniqueKeysWithValues: Category.allCases.map { category in
            (category.rawValue, files(category).reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) })
        })
    }
    public func clear(_ category: Category? = nil) {
        lock.lock(); defer { lock.unlock() }
        guard category != .scratch else { return } // Scratch has live owners, not cache entries.
        for item in category.map({ [$0] }) ?? [.spectrum, .waveforms] { for url in files(item) { try? FileManager.default.removeItem(at: url) } }
    }
    public func cleanupOnExit() {
        lock.lock(); defer { lock.unlock() }
        if policy.clearSpectrumOnExit { clear(.spectrum) }
        if policy.clearWaveformsOnExit { clear(.waveforms) }
    }
    private func files(_ category: Category) -> [URL] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        if category == .scratch {
            guard let iterator = FileManager.default.enumerator(at: directory(category), includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
            return iterator.compactMap { $0 as? URL }.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
        }
        return (try? FileManager.default.contentsOfDirectory(at: directory(category), includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
    }
    private func trim() {
        let candidates = ([Category.spectrum, .waveforms].flatMap(files)).map { url -> (URL, Int64, Date) in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return (url, Int64(values?.fileSize ?? 0), values?.contentModificationDate ?? .distantPast)
        }
        var total = candidates.reduce(Int64(0)) { $0 + $1.1 }
        let limit = max(0, policy.limitBytes)
        guard total > limit else { return }
        // Most writes fit under the cap. Sort only when an eviction is needed.
        for (url, size, _) in candidates.sorted(by: { $0.2 < $1.2 }) where total > limit {
            if (try? FileManager.default.removeItem(at: url)) != nil { total -= size }
        }
    }
}
