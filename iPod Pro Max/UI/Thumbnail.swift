import Foundation
import SwiftCrossUI

#if canImport(AppKitBackend)
import AppKit
import AppKitBackend
import ImageIO

/// Shared, bounded decoding for artist photos, album art and podcast covers. There is no
/// timer and no file probing on render. Concurrent requests for one thumbnail share a task.
@MainActor final class ThumbnailStore {
    static let shared = ThumbnailStore()
    private let cache = NSCache<NSString, NSImage>()
    private var pending: [String: Task<CGImage?, Never>] = [:]
    private var failed: Set<String> = []
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "iPodProMax.thumbnails"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = max(1, ProcessInfo.processInfo.activeProcessorCount / 2)
        return queue
    }()
    init() { cache.totalCostLimit = 32 * 1024 * 1024 }
    private func key(_ url: URL, _ pixels: Int) -> String { "\(pixels):\(url.absoluteString)" }
    func cached(_ url: URL, pixels: Int) -> NSImage? { cache.object(forKey: key(url, pixels) as NSString) }
    func image(_ url: URL, pixels: Int) async -> NSImage? {
        let key = key(url, pixels)
        if let image = cache.object(forKey: key as NSString) { return image }
        if failed.contains(key) { return nil }
        if let task = pending[key] {
            guard let decoded = await task.value else { return nil }
            return store(decoded, key: key)
        }
        let queue = queue
        let task = Task { () -> CGImage? in
            await withCheckedContinuation { continuation in
                queue.addOperation {
                    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                        continuation.resume(returning: nil); return
                    }
                    continuation.resume(returning: CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: pixels,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceShouldCacheImmediately: true
                    ] as CFDictionary))
                }
            }
        }
        pending[key] = task
        let result = await task.value
        pending[key] = nil
        guard let result else { failed.insert(key); return nil }
        return store(result, key: key)
    }
    private func store(_ decoded: CGImage, key: String) -> NSImage {
        if let image = cache.object(forKey: key as NSString) { return image }
        let image = NSImage(cgImage: decoded, size: .zero)
        cache.setObject(image, forKey: key as NSString, cost: decoded.bytesPerRow * decoded.height)
        return image
    }
}

struct Thumbnail: NSViewRepresentable {
    var url: URL
    var pixels: Int
    func makeNSView(context: Context) -> ThumbnailImageView { ThumbnailImageView() }
    func updateNSView(_ image: ThumbnailImageView, context: Context) { image.show(url, pixels: pixels) }
}

final class ThumbnailImageView: NSImageView {
    private var key: String?
    private var load: Task<Void, Never>?
    func show(_ url: URL, pixels: Int) {
        let key = "\(pixels):\(url.absoluteString)"
        guard self.key != key else { return }
        self.key = key
        load?.cancel()
        imageScaling = .scaleProportionallyUpOrDown
        image = ThumbnailStore.shared.cached(url, pixels: pixels)
        guard image == nil else { return }
        load = Task { [weak self] in
            let image = await ThumbnailStore.shared.image(url, pixels: pixels)
            guard !Task.isCancelled, self?.key == key else { return }
            self?.image = image
        }
    }
}
#elseif canImport(GtkBackend)
import CGtk
import Gtk
import GtkBackend

/// GdkTexture is immutable/thread-safe; decoding and resizing happen on a bounded utility queue.
final class GtkThumbnailTexture: NSObject, @unchecked Sendable {
    let pointer: OpaquePointer
    init(_ pointer: OpaquePointer) { self.pointer = pointer }
    deinit { g_object_unref(cast(pointer)) }
}
@MainActor final class GtkThumbnailStore {
    static let shared = GtkThumbnailStore()
    private let cache = NSCache<NSString, GtkThumbnailTexture>()
    private var pending: [String: Task<GtkThumbnailTexture?, Never>] = [:]
    private var failed: Set<String> = []
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = max(1, ProcessInfo.processInfo.activeProcessorCount / 2)
        return queue
    }()
    init() { cache.totalCostLimit = 32 * 1024 * 1024 }
    private func key(_ url: URL, _ pixels: Int) -> String { "\(pixels):\(url.absoluteString)" }
    func cached(_ url: URL, pixels: Int) -> GtkThumbnailTexture? { cache.object(forKey: key(url, pixels) as NSString) }
    func image(_ url: URL, pixels: Int) async -> GtkThumbnailTexture? {
        let key = key(url, pixels)
        if let image = cache.object(forKey: key as NSString) { return image }
        if failed.contains(key) { return nil }
        if let task = pending[key] { return await task.value }
        let queue = queue
        let task = Task { () -> GtkThumbnailTexture? in
            await withCheckedContinuation { continuation in
                queue.addOperation {
                    guard let pixbuf = gdk_pixbuf_new_from_file_at_scale(url.path, Int32(pixels), Int32(pixels), 1, nil) else {
                        continuation.resume(returning: nil); return
                    }
                    defer { g_object_unref(cast(pixbuf)) }
                    continuation.resume(returning: gdk_texture_new_for_pixbuf(pixbuf).map(GtkThumbnailTexture.init))
                }
            }
        }
        pending[key] = task
        let result = await task.value
        pending[key] = nil
        if let result { cache.setObject(result, forKey: key as NSString, cost: pixels * pixels * 4) }
        else { failed.insert(key) }
        return result
    }
}

@MainActor private final class GtkThumbnailBinding {
    var widget: UnsafeMutablePointer<GtkWidget>?
    var key: String?
    var task: Task<Void, Never>?
    func show(_ url: URL?, pixels: Int) {
        let key = url.map { "\(pixels):\($0.absoluteString)" }
        guard self.key != key else { return }
        self.key = key
        task?.cancel()
        guard let widget else { return }
        gtk_image_clear(cast(widget))
        guard let url else { return }
        if let cached = GtkThumbnailStore.shared.cached(url, pixels: pixels) {
            gtk_image_set_from_paintable(cast(widget), cached.pointer)
            return
        }
        task = Task { [weak self] in
            let image = await GtkThumbnailStore.shared.image(url, pixels: pixels)
            guard !Task.isCancelled, let self, self.key == key, let widget = self.widget else { return }
            gtk_image_set_from_paintable(cast(widget), image?.pointer)
        }
    }
}
private let releaseGtkThumbnail: @convention(c) (gpointer?) -> Void = { data in
    guard let data else { return }
    MainActor.assumeIsolated {
        let binding = Unmanaged<GtkThumbnailBinding>.fromOpaque(data).takeRetainedValue()
        binding.widget = nil
        binding.task?.cancel()
    }
}
@MainActor func setGtkThumbnail(_ widget: UnsafeMutablePointer<GtkWidget>, url: URL?, pixels: Int) {
    let binding: GtkThumbnailBinding
    if let existing = g_object_get_data(cast(widget), "ippm-thumbnail") {
        binding = Unmanaged<GtkThumbnailBinding>.fromOpaque(existing).takeUnretainedValue()
    } else {
        binding = GtkThumbnailBinding()
        binding.widget = widget
        g_object_set_data_full(cast(widget), "ippm-thumbnail", Unmanaged.passRetained(binding).toOpaque(), releaseGtkThumbnail)
    }
    binding.show(url, pixels: pixels)
}
struct Thumbnail: GtkWidgetRepresentable {
    var url: URL
    var pixels: Int
    func makeGtkWidget(context: Context) -> Gtk.Widget { Gtk.Widget(gtk_image_new()!) }
    func updateGtkWidget(_ widget: Gtk.Widget, context: Context) {
        gtk_image_set_pixel_size(cast(widget.widgetPointer), Int32(pixels / 2))
        setGtkThumbnail(widget.widgetPointer, url: url, pixels: pixels)
    }
}
#elseif canImport(WinUIBackend)
import WinUI
import WinUIBackend
import WindowsFoundation

/// WinUI loads BitmapImage URIs asynchronously; request only the displayed resolution.
struct Thumbnail: WinUIElementRepresentable {
    var url: URL
    var pixels: Int
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeWinUIElement(context: Context) -> WinUI.Image { WinUI.Image() }
    func updateWinUIElement(_ image: WinUI.Image, context: Context) {
        let key = "\(pixels):\(url.absoluteString)"
        guard context.coordinator.key != key else { return }
        context.coordinator.key = key
        let bitmap = BitmapImage(WindowsFoundation.Uri(url.absoluteString))
        bitmap.decodePixelWidth = Int32(pixels)
        image.stretch = .uniform
        image.source = bitmap
    }
    final class Coordinator { var key: String? }
}
#else
struct Thumbnail: View {
    var url: URL
    var pixels: Int
    var body: some View { Image(url).resizable() }
}
#endif
