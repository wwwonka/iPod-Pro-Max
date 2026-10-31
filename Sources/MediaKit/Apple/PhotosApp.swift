//
//  PhotosApp.swift
//  iPod Pro Max
//
//  The Photos app as a photo source (macOS only, through PhotoKit): lists its albums and exports the
//  ones the user picked as JPEGs of at most 1024 px. Needs the user's permission, asked on first use;
//  the app's Info.plist carries the text of the question.
//

#if canImport(Photos) && canImport(AppKit)
import Foundation
import Photos
import AppKit
import iPodKit

public struct PhotosAlbumInfo: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let count: Int
    public let isSmart: Bool
}

public enum PhotosApp {
    public enum Access: Sendable { case notDetermined, denied, authorized }

    public static var access: Access {
        if #available(macOS 11, *) {
            switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
            case .authorized, .limited: return .authorized
            case .notDetermined: return .notDetermined
            default: return .denied
            }
        }
        switch PHPhotoLibrary.authorizationStatus() {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    public static func requestAccess() async -> Access {
        await withCheckedContinuation { (cont: CheckedContinuation<Access, Never>) in
            if #available(macOS 11, *) {
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { _ in cont.resume(returning: access) }
            } else {
                PHPhotoLibrary.requestAuthorization { _ in cont.resume(returning: access) }
            }
        }
    }

    private static var imageOptions: PHFetchOptions {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        return options
    }

    public static func allPhotosCount() -> Int { PHAsset.fetchAssets(with: imageOptions).count }

    /// User albums plus a few useful smart albums (Favorites, Recently Added).
    public static func albums() -> [PhotosAlbumInfo] {
        var out: [PhotosAlbumInfo] = []
        PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil).enumerateObjects { c, _, _ in
            out.append(PhotosAlbumInfo(id: c.localIdentifier, title: c.localizedTitle ?? "Untitled",
                                       count: PHAsset.fetchAssets(in: c, options: imageOptions).count, isSmart: false))
        }
        for subtype in [PHAssetCollectionSubtype.smartAlbumFavorites, .smartAlbumRecentlyAdded] {
            PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: subtype, options: nil).enumerateObjects { c, _, _ in
                let n = PHAsset.fetchAssets(in: c, options: imageOptions).count
                if n > 0 { out.append(PhotosAlbumInfo(id: c.localIdentifier, title: c.localizedTitle ?? "Album", count: n, isSmart: true)) }
            }
        }
        return out.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}

public struct PhotosAppLibrary: PhotoLibrarySource {
    public init() {}

    public var isAuthorized: Bool { PhotosApp.access == .authorized }

    public func estimatedCount(selection: PhotoSelection) -> Int {
        var n = 0
        if selection.includeAllPhotos { n += PhotosApp.allPhotosCount() }
        if !selection.albumIDs.isEmpty { for a in PhotosApp.albums() where selection.albumIDs.contains(a.id) { n += a.count } }
        return n
    }

    public func export(selection: PhotoSelection, cacheDir: URL, progress: @escaping (Int, Int) -> Void) throws -> PhotoExport {
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        var photos: [PhotoItem] = []
        var albums: [PhotoExport.Album] = []
        var failed = 0
        var seen: [String: PhotoItem] = [:]
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]

        var groups: [(name: String, assets: PHFetchResult<PHAsset>)] = []
        if selection.includeAllPhotos { groups.append(("All Photos", PHAsset.fetchAssets(with: options))) }
        if !selection.albumIDs.isEmpty {
            PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: selection.albumIDs, options: nil).enumerateObjects { c, _, _ in
                groups.append((c.localizedTitle ?? "Album", PHAsset.fetchAssets(in: c, options: options)))
            }
        }
        let total = groups.reduce(0) { $0 + $1.assets.count }
        var done = 0
        let manager = PHImageManager.default()
        let request = PHImageRequestOptions()
        request.isSynchronous = true
        request.deliveryMode = .highQualityFormat
        request.resizeMode = .exact
        request.isNetworkAccessAllowed = true
        request.version = .current

        for group in groups {
            var keys: [String] = []
            group.assets.enumerateObjects { asset, _, stop in
                if Task.isCancelled { stop.pointee = true; return }
                defer { done += 1; if done % 5 == 0 || done == total { progress(done, total) } }
                let stamp = Int(asset.modificationDate?.timeIntervalSince1970 ?? asset.creationDate?.timeIntervalSince1970 ?? 0)
                let key = asset.localIdentifier.replacingOccurrences(of: "/", with: "_") + "-\(stamp)"
                if let existing = seen[key] { keys.append(existing.key); return }
                let url = cacheDir.appendingPathComponent(key + ".jpg")
                if !FileManager.default.fileExists(atPath: url.path) {
                    var written = false
                    manager.requestImage(for: asset, targetSize: CGSize(width: 1024, height: 1024), contentMode: .aspectFit, options: request) { image, info in
                        guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
                        if let degraded = info?[PHImageResultIsDegradedKey] as? Bool, degraded { return }
                        if let jpeg = ImageLoading.jpegData(from: cg, maxDimension: 1024, quality: 0.9) {
                            written = (try? jpeg.write(to: url, options: .atomic)) != nil
                        }
                    }
                    if !written { failed += 1; return }
                }
                let size = UInt32((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                let item = PhotoItem(key: key, jpegURL: url, creationDate: asset.creationDate, originalSize: size)
                seen[key] = item
                photos.append(item)
                keys.append(key)
            }
            albums.append(PhotoExport.Album(name: group.name, photoKeys: keys))
        }
        return PhotoExport(photos: photos, albums: albums, failed: failed)
    }

    public func pruneCache(_ cacheDir: URL, keep: Set<String>) {
        guard let items = try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil) else { return }
        for url in items where !keep.contains(url.deletingPathExtension().lastPathComponent) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
#endif
