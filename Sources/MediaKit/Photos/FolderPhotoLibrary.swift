//
//  FolderPhotoLibrary.swift
//  iPod Pro Max
//
//  Photos from folders the user picked, the same on every OS. Each folder is an album on the iPod, and
//  so is each of its subfolders that holds pictures. Pictures are exported once as JPEGs of at most
//  1024 px (what the iPod's thumbnails are made from) into the host's photo cache; a picture that did
//  not change is not read again.
//

import Foundation
import iPodKit

public struct FolderPhotoLibrary: PhotoLibrarySource {
    public var folders: [URL]
    public init(folders: [URL]) { self.folders = folders }

    public var isAuthorized: Bool { true }
    public var exportsWithoutSelection: Bool { true }

    #if canImport(ImageIO)
    public static let extensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "bmp", "gif"]
    #else
    public static let extensions: Set<String> = ["jpg", "jpeg", "png", "webp"]
    #endif

    /// Pictures under `folder`, in name order, without hidden files.
    public static func images(in folder: URL) -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        var pending = [folder]
        while let dir = pending.popLast() {
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for name in names where !name.hasPrefix(".") {
                let url = dir.appendingPathComponent(name)
                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
                if isDirectory.boolValue {
                    #if os(macOS)
                    if (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true { continue }
                    #endif
                    pending.append(url)
                } else if extensions.contains(url.pathExtension.lowercased()) {
                    out.append(url)
                }
            }
        }
        return out.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    public func estimatedCount(selection: PhotoSelection) -> Int {
        Set(folders.flatMap { Self.images(in: $0).map(\.path) }).count
    }

    /// The albums a folder makes: itself, then each immediate subfolder with pictures.
    static func albums(of folder: URL, images: [URL]) -> [(name: String, files: [URL])] {
        let base = folder.standardizedFileURL.path + "/"
        var result: [(name: String, files: [URL])] = [(folder.lastPathComponent, images)]
        var bySub: [String: [URL]] = [:]
        for file in images {
            let relative = String(file.standardizedFileURL.path.dropFirst(base.count))
            if let slash = relative.firstIndex(of: "/") { bySub[String(relative[..<slash]), default: []].append(file) }
        }
        for name in bySub.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) where bySub[name]!.count < images.count {
            result.append(("\(folder.lastPathComponent) – \(name)", bySub[name]!))
        }
        return result
    }

    public func export(selection: PhotoSelection, cacheDir: URL, progress: @escaping (Int, Int) -> Void) throws -> PhotoExport {
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let perFolder = folders.map { (folder: $0, images: Self.images(in: $0)) }
        var unique: [URL] = []
        var seen = Set<String>()
        for entry in perFolder { for file in entry.images where seen.insert(file.standardizedFileURL.path).inserted { unique.append(file) } }

        let state = ExportState(count: unique.count)
        let total = unique.count
        // concurrentPerform's workers don't run in this task, so cancellation is checked between chunks, here.
        let chunk = max(ProcessInfo.processInfo.activeProcessorCount, 1) * 16
        for start in stride(from: 0, to: unique.count, by: chunk) {
            try Task.checkCancellation()
            let end = min(start + chunk, unique.count)
            DispatchQueue.concurrentPerform(iterations: end - start) { offset in
                let i = start + offset
                let file = unique[i]
                let attrs = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                let key = Self.key(for: file, size: attrs?.fileSize ?? 0, modified: attrs?.contentModificationDate)
                let jpeg = cacheDir.appendingPathComponent(key + ".jpg")
                var ok = FileManager.default.fileExists(atPath: jpeg.path)
                if !ok, let data = ImageLoading.photoJPEG(from: file, maxDimension: 1024, quality: 0.9) {
                    ok = (try? data.write(to: jpeg, options: .atomic)) != nil
                }
                let size = UInt32((try? jpeg.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                let done = state.finish(i, item: ok ? PhotoItem(key: key, jpegURL: jpeg, creationDate: attrs?.contentModificationDate, originalSize: size) : nil)
                if done % 8 == 0 || done == total { progress(done, total) }
            }
        }
        let byPath = Dictionary(uniqueKeysWithValues: unique.indices.compactMap { i in state.item(i).map { (unique[i].standardizedFileURL.path, $0) } })
        var albums: [PhotoExport.Album] = []
        for entry in perFolder {
            for album in Self.albums(of: entry.folder, images: entry.images) {
                let keys = album.files.compactMap { byPath[$0.standardizedFileURL.path]?.key }
                if !keys.isEmpty { albums.append(PhotoExport.Album(name: album.name, photoKeys: keys)) }
            }
        }
        return PhotoExport(photos: unique.indices.compactMap { state.item($0) }, albums: albums, failed: state.failures)
    }

    public func pruneCache(_ cacheDir: URL, keep: Set<String>) {
        guard let items = try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil) else { return }
        for url in items where !keep.contains(url.deletingPathExtension().lastPathComponent) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Changes with the picture's place, size or date: an edited picture is exported again.
    static func key(for file: URL, size: Int, modified: Date?) -> String {
        let text = "\(file.standardizedFileURL.path)|\(size)|\(Int(modified?.timeIntervalSince1970 ?? 0))"
        return "f" + SHA1.hash(Array(text.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private final class ExportState: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [PhotoItem?]
        private var done = 0
        private(set) var failures = 0
        init(count: Int) { items = Array(repeating: nil, count: count) }
        func finish(_ i: Int, item: PhotoItem?) -> Int {
            lock.lock(); defer { lock.unlock() }
            items[i] = item
            if item == nil { failures += 1 }
            done += 1
            return done
        }
        func item(_ i: Int) -> PhotoItem? { lock.lock(); defer { lock.unlock() }; return items[i] }
    }
}

/// Several photo sources as one: the chosen folders, and on a Mac the Photos app. A source that has no
/// access (Photos without permission) or nothing selected simply adds nothing.
public struct CompositePhotoLibrary: PhotoLibrarySource {
    public var sources: [any PhotoLibrarySource]
    public init(sources: [any PhotoLibrarySource]) { self.sources = sources }

    public var isAuthorized: Bool { true }
    public var exportsWithoutSelection: Bool { sources.contains { $0.exportsWithoutSelection } }

    private func active(_ selection: PhotoSelection) -> [any PhotoLibrarySource] {
        sources.filter { $0.isAuthorized && ($0.exportsWithoutSelection || !selection.isEmpty) }
    }

    public func estimatedCount(selection: PhotoSelection) -> Int {
        active(selection).reduce(0) { $0 + $1.estimatedCount(selection: selection) }
    }

    public func export(selection: PhotoSelection, cacheDir: URL, progress: @escaping (Int, Int) -> Void) throws -> PhotoExport {
        var photos: [PhotoItem] = []
        var albums: [PhotoExport.Album] = []
        var failed = 0
        var keys = Set<String>()
        for source in active(selection) {
            let part = try source.export(selection: selection, cacheDir: cacheDir, progress: progress)
            for photo in part.photos where keys.insert(photo.key).inserted { photos.append(photo) }
            albums += part.albums
            failed += part.failed
        }
        return PhotoExport(photos: photos, albums: albums, failed: failed)
    }

    public func pruneCache(_ cacheDir: URL, keep: Set<String>) {
        // One shared cache: pruning with the union of the keys is the same whichever source does it.
        guard let items = try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil) else { return }
        for url in items where !keep.contains(url.deletingPathExtension().lastPathComponent) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
