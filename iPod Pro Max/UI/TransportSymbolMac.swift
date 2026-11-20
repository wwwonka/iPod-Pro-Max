#if canImport(AppKitBackend)
import AppKit
import Symbols

/// AppKit owns the symbol transition and its interruption; no custom drawing masks.
@MainActor final class TransportSymbolView: NSView {
    private let current = NSImageView()
    private(set) var symbol = ""
    var hasImage: Bool { current.image != nil }
    var tint: NSColor? { didSet { applyTint() } }
    private func applyTint() {
        let saved = NSAppearance.current; NSAppearance.current = effectiveAppearance
        defer { NSAppearance.current = saved }
        current.contentTintColor = tint?.withAlphaComponent(1)
        current.alphaValue = tint?.alphaComponent ?? 1
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyTint() }
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        current.imageScaling = .scaleNone; current.imageAlignment = .alignCenter
        current.wantsLayer = true; current.setAccessibilityElement(false); addSubview(current)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() { super.layout(); current.frame = bounds }
    func setSymbol(_ name: String, image: NSImage?, animated: Bool) {
        symbol = name
        guard animated, current.image != nil, let image, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            current.image = image; return
        }
        if #available(macOS 15, *) {
            // This automatically gains SF Symbols' Draw transitions on macOS 26.
            current.setSymbolImage(image, contentTransition: .replace.magic(fallback: .replace), options: .speed(3))
        } else if #available(macOS 14, *) {
            current.setSymbolImage(image, contentTransition: .replace, options: .speed(3))
        } else { current.image = image }
    }
}
#endif
