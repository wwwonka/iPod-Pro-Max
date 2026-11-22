#if canImport(AppKitBackend)
import AppKit
import Symbols

/// AppKit owns the symbol transition and its interruption; no custom drawing masks.
@MainActor final class TransportSymbolView: NSView {
    enum Transition { case system, crossfade }
    var transition: Transition = .system
    private let current = NSImageView(), outgoing = NSImageView()
    private(set) var symbol = ""
    var hasImage: Bool { current.image != nil }
    var tint: NSColor? { didSet { applyTint() } }
    private func applyTint() {
        let saved = NSAppearance.current; NSAppearance.current = effectiveAppearance
        defer { NSAppearance.current = saved }
        current.contentTintColor = tint?.withAlphaComponent(1)
        outgoing.contentTintColor = tint?.withAlphaComponent(1)
        current.alphaValue = tint?.alphaComponent ?? 1
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyTint() }
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        current.imageScaling = .scaleNone; current.imageAlignment = .alignCenter
        current.wantsLayer = true; current.setAccessibilityElement(false)
        outgoing.imageScaling = .scaleNone; outgoing.wantsLayer = true; outgoing.setAccessibilityElement(false)
        addSubview(outgoing); addSubview(current)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() {
        super.layout()
        let frame = transition == .crossfade ? NSRect(x: (bounds.width - 20) / 2, y: (bounds.height - 16) / 2, width: 20, height: 16) : bounds
        for view in [current, outgoing] { view.frame = frame; view.imageAlignment = transition == .crossfade ? .alignLeft : .alignCenter }
    }
    func setSymbol(_ name: String, image: NSImage?, animated: Bool) {
        symbol = name
        guard animated, current.image != nil, let image, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            if #available(macOS 14, *) { current.removeAllSymbolEffects() }
            current.layer?.removeAllAnimations(); outgoing.layer?.removeAllAnimations()
            outgoing.image = nil; current.image = image; applyTint(); return
        }
        if transition == .crossfade {
            outgoing.image = current.image; outgoing.contentTintColor = current.contentTintColor
            current.image = image
            let alpha = tint?.alphaComponent ?? 1
            CATransaction.begin(); CATransaction.setDisableActions(true)
            outgoing.alphaValue = 0; current.alphaValue = alpha
            CATransaction.commit()
            for (view, from, to) in [(outgoing, alpha, CGFloat(0)), (current, CGFloat(0), alpha)] {
                let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = from; fade.toValue = to
                fade.duration = 0.14; fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
                view.layer?.add(fade, forKey: "symbolCrossfade")
            }
            return
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
