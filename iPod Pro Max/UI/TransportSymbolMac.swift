#if canImport(AppKitBackend)
import AppKit
import Symbols

/// AppKit owns the symbol transition and its interruption; no custom drawing masks.
@MainActor final class TransportSymbolView: NSView {
    enum Transition { case system, crossfade }
    var transition: Transition = .system
    private let current = NSImageView(), outgoing = NSImageView()
    private(set) var symbol = ""
    private var currentAnchor = NSPoint.zero, outgoingAnchor = NSPoint.zero
    private struct SpeakerGlyph { let image: NSImage; let anchor: NSPoint }
    private static var speakerGlyphs: [String: SpeakerGlyph] = [:]
    /// Register the small rectangular mouth, rather than each SF glyph's box.
    /// This tiny raster measurement is cached once per speaker symbol.
    private static func speakerGlyph(_ name: String, image: NSImage) -> SpeakerGlyph {
        let cacheKey = "\(name)|\(image.size.width)|\(image.size.height)"
        if let cached = speakerGlyphs[cacheKey] { return cached }
        let scale: CGFloat = 4
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(ceil(image.size.width * scale)), pixelsHigh: Int(ceil(image.size.height * scale)), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        context.cgContext.clear(CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
        context.cgContext.scaleBy(x: scale, y: scale)
        image.draw(in: NSRect(origin: .zero, size: image.size), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        var anchor = NSPoint(x: image.alignmentRect.minX, y: image.alignmentRect.midY)
        if !name.contains("slash") {
            outer: for x in 0..<min(bitmap.pixelsWide, 16) {
                var first: Int?, last = 0
                for y in 0..<bitmap.pixelsHigh where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
                    if first == nil { first = y }; last = y
                }
                if let first, last - first >= 4 {
                    anchor = NSPoint(x: CGFloat(x) / scale, y: image.size.height - CGFloat(first + last + 1) / (2 * scale))
                    break outer
                }
            }
        }
        let copy = image.copy() as! NSImage
        copy.alignmentRect = NSRect(origin: .zero, size: image.size)
        let glyph = SpeakerGlyph(image: copy, anchor: anchor)
        speakerGlyphs[cacheKey] = glyph; return glyph
    }
    static func checkSpeakerAlignment() {
        let view = TransportSymbolView(frame: NSRect(x: 0, y: 0, width: 28, height: 32))
        view.transition = .crossfade
        for name in ["speaker.wave.1.fill", "speaker.wave.2.fill", "speaker.wave.3.fill"] {
            view.setSymbol(name, image: systemSymbol(name, pointSize: 10), animated: false); view.layoutSubtreeIfNeeded()
            let mouth = NSPoint(x: view.current.frame.minX + view.currentAnchor.x, y: view.current.frame.minY + view.currentAnchor.y)
            precondition(abs(mouth.x - 4) < 0.01 && abs(mouth.y - 16) < 0.01, "Speaker mouth keeps an exact fixed anchor")
        }
    }
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
        for view in [current, outgoing] {
            if transition == .crossfade, let image = view.image {
                let anchor = view === current ? currentAnchor : outgoingAnchor
                view.frame = NSRect(x: frame.minX - anchor.x, y: bounds.midY - anchor.y,
                                    width: image.size.width, height: image.size.height)
            } else { view.frame = frame }
            view.imageAlignment = transition == .crossfade ? .alignBottomLeft : .alignCenter
        }
    }
    func setSymbol(_ name: String, image: NSImage?, animated: Bool) {
        let oldAnchor = currentAnchor
        let resolved = transition == .crossfade ? image.map { Self.speakerGlyph(name, image: $0) } : nil
        let image = resolved?.image ?? image
        currentAnchor = resolved?.anchor ?? .zero
        symbol = name
        needsLayout = true
        guard animated, current.image != nil, let image, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            if #available(macOS 14, *) { current.removeAllSymbolEffects() }
            current.layer?.removeAllAnimations(); outgoing.layer?.removeAllAnimations()
            outgoing.image = nil; current.image = image; applyTint(); return
        }
        if transition == .crossfade {
            outgoingAnchor = oldAnchor
            outgoing.image = current.image; outgoing.contentTintColor = current.contentTintColor
            current.image = image
            needsLayout = true; layoutSubtreeIfNeeded()
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
