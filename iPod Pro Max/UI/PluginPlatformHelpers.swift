import Foundation
import PluginKit
import SwiftCrossUI

#if canImport(AppKitBackend)
import AppKit
import AppKitBackend
#elseif canImport(GtkBackend)
import CGtk
import Gtk
import GtkBackend
#elseif canImport(WinUIBackend)
import WinSDK
import WinUI
import WinUIBackend
#endif

@MainActor
func copyToClipboard(_ text: String) {
    #if canImport(AppKitBackend)
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(text, forType: .string)
    #elseif canImport(GtkBackend)
    if let display = gdk_display_get_default(),
       let clipboard = gdk_display_get_clipboard(display) {
        gdk_clipboard_set_text(clipboard, text)
    }
    #elseif os(Windows)
    let utf16 = Array(text.utf16) + [0]
    let bytes = utf16.count * MemoryLayout<UInt16>.size
    if OpenClipboard(nil) {
        EmptyClipboard()
        if let hMem = GlobalAlloc(UINT(GMEM_MOVEABLE), SIZE_T(bytes)) {
            if let ptr = GlobalLock(hMem) {
                memcpy(ptr, utf16, bytes)
                GlobalUnlock(hMem)
                SetClipboardData(UINT(CF_UNICODETEXT), hMem)
            } else {
                GlobalFree(hMem)
            }
        }
        CloseClipboard()
    }
    #endif
}

// MARK: - Plug-in SVG Badge View

struct PluginBadgeView: View {
    var badge: ParsedSVGBadge?
    var size: Double = 22

    var body: some View {
        if let badge {
            #if canImport(AppKitBackend)
            MacBadgeImageView(badge: badge, size: size)
                .frame(width: size, height: size)
            #else
            Symbol(name: "puzzlepiece.extension", size: size, pointSize: size * 0.78, tint: .primary)
            #endif
        } else {
            Symbol(name: "puzzlepiece.extension", size: size, pointSize: size * 0.78, tint: .secondary)
        }
    }
}

#if canImport(AppKitBackend)
private struct MacBadgeImageView: NSViewRepresentable {
    var badge: ParsedSVGBadge
    var size: Double

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyDown
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        let symbol = CustomSymbol(parsedBadge: badge)
        view.image = customSymbolImage(symbol, description: nil, pointSize: size * 0.78)
        view.contentTintColor = .labelColor
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSImageView, context: Context) -> ViewSize {
        ViewSize(size, size)
    }
}
#endif

// MARK: - Drag-and-drop `.ippmplugin` onto Window (PLG-13)

extension View {
    /// Registers the enclosing window as a drop destination for `.ippmplugin` files.
    func pluginPackageDropTarget() -> some View {
        #if canImport(AppKitBackend)
        background(MacPackageDropProbe())
        #else
        self
        #endif
    }
}

#if canImport(AppKitBackend)
private struct MacPackageDropProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> PackageDropProbeView {
        PackageDropProbeView()
    }

    func updateNSView(_ nsView: PackageDropProbeView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PackageDropProbeView, context: Context) -> ViewSize {
        ViewSize(0, 0)
    }
}

@MainActor
private final class PackageDropOverlayView: NSView {
    private let badge = NSTextField(labelWithString: "Install Plug-in")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        registerForDraggedTypes([.fileURL])

        badge.font = .systemFont(ofSize: 16, weight: .semibold)
        badge.textColor = .white
        badge.alignment = .center
        badge.isBezeled = false
        badge.drawsBackground = false
        badge.isEditable = false
        addSubview(badge)
        updateBadgeAppearance(hovering: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let type = NSApp.currentEvent?.type {
            switch type {
            case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                 .otherMouseDown, .otherMouseUp, .mouseMoved, .scrollWheel,
                 .mouseEntered, .mouseExited, .cursorUpdate:
                return nil
            default:
                break
            }
        }
        return super.hitTest(point)
    }

    override func layout() {
        super.layout()
        badge.sizeToFit()
        badge.frame.origin = NSPoint(
            x: (bounds.width - badge.frame.width) / 2,
            y: (bounds.height - badge.frame.height) / 2
        )
    }

    private func updateBadgeAppearance(hovering: Bool) {
        layer?.borderWidth = hovering ? 3 : 0
        layer?.borderColor = hovering ? NSColor.controlAccentColor.cgColor : nil
        layer?.backgroundColor = hovering ? NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor : nil
        badge.isHidden = !hovering
    }

    private func packageURL(from info: NSDraggingInfo) -> URL? {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL]
        return urls?.first { $0.pathExtension.lowercased() == "ippmplugin" }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard packageURL(from: sender) != nil else { return [] }
        updateBadgeAppearance(hovering: true)
        PluginController.shared.dragHoveringPackage = true
        PluginController.shared.refreshObservers()
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        updateBadgeAppearance(hovering: false)
        PluginController.shared.dragHoveringPackage = false
        PluginController.shared.refreshObservers()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        updateBadgeAppearance(hovering: false)
        PluginController.shared.dragHoveringPackage = false
        guard let url = packageURL(from: sender) else {
            PluginController.shared.refreshObservers()
            return false
        }
        PluginController.shared.inspectPackageForInstall(at: url)
        return true
    }
}

@MainActor
private final class PackageDropProbeView: NSView {
    private weak var installedWindow: NSWindow?
    private var overlay: PackageDropOverlayView?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, installedWindow !== window, let content = window.contentView else { return }
        installedWindow = window
        let dropView = PackageDropOverlayView(frame: content.bounds)
        dropView.autoresizingMask = [.width, .height]
        content.addSubview(dropView, positioned: .above, relativeTo: nil)
        overlay = dropView
    }
}
#endif
