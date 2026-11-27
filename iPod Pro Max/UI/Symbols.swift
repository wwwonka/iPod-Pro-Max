import Foundation
import PluginKit
import SwiftCrossUI

// SF Symbols on every platform. macOS draws the real, vector symbols. GTK and WinUI draw glyphs
// from the "SF-Symbols" font (github.com/DrunkSonic/SF-Symbols-for-Windows), which is Apple's
// artwork without a license to use it off Apple platforms: it is only ever installed locally from
// Local/ (git-ignored), never committed or shipped. Without it, symbols
// are empty boxes of the right size.

enum SymbolTint: Hashable {
    case accent, primary, secondary, tertiary
    /// Any color, light and dark: the iPod page's banners and buttons.
    case color(SystemColor)
}

/// A color as sRGB 0xRRGGBB values for light and dark mode, usable as a SwiftCrossUI `Color` and
/// as a symbol tint (font glyphs take plain RGB).
struct SystemColor: Hashable, Sendable {
    var light: UInt32
    var dark: UInt32

    init(light: UInt32, dark: UInt32) {
        self.light = light
        self.dark = dark
    }

    init(_ both: UInt32) { self.init(light: both, dark: both) }

    func rgb(dark isDark: Bool) -> (r: UInt8, g: UInt8, b: UInt8) {
        let v = isDark ? dark : light
        return (UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF))
    }

    var color: SwiftCrossUI.Color {
        func make(_ v: UInt32) -> SwiftCrossUI.Color {
            SwiftCrossUI.Color(red: Double(v >> 16 & 0xFF) / 255, green: Double(v >> 8 & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
        }
        return SwiftCrossUI.Color.adaptive(light: make(light), dark: make(dark))
    }
}

/// The font numbers its glyphs from U+E900 without names. These were matched by shape against
/// the real symbols (scripts/match-glyph.swift); a missing name draws nothing.
let symbolCodepoints: [String: UInt32] = [
    "clock": 0xED2C,
    "person.fill": 0xF254,
    "square.stack": 0xF0D6,
    "play.fill": 0xF17D,
    "pause.fill": 0xF179,
    "backward.end.fill": 0xF15D,
    "forward.end.fill": 0xF161,
    "shuffle": 0xF15A,
    "repeat": 0xF157,
    "repeat.1": 0xF154,
    "speaker.wave.2.fill": 0xF140,

    "music.note": 0xF134,
    "music.note.list": 0xF133,
    "playlist-lines": 0xF133,
    "music.mic": 0xF12D,
    "microphone.dynamic.on.stand": 0xF12D,
    "ipod": 0xEE8E,
    "book": 0xF286,
    "antenna.radiowaves.left.and.right": 0xEE31,
    "photo.on.rectangle.angled": 0xED80,
    "plus": 0xEC22,
    "square.and.arrow.down": 0xF2FC,
    "magnifyingglass": 0xF12C,
    "film": 0xEDF5,  // landscape, as in SF Symbols 4
    // SF Symbols 4 font fallbacks for the newer video-navigation names.
    "film.stack": 0xEDF5,
    "tv": 0xEDF5,
    "music.note.tv": 0xEDF5,
    "sidebar.left": 0xED77,
    "chevron.right": 0xEBCC,
    "eject.fill": 0xF1E7,
    "eject": 0xF1E8,
    "pencil": 0xF2F8,
    "folder": 0xF2D9,
    "xmark.octagon.fill": 0xEBDA,
    "arrow.triangle.2.circlepath": 0xEB43,
    "checkmark.circle.fill": 0xEBB7,
    "exclamationmark.triangle": 0xF05B,
    "exclamationmark.triangle.fill": 0xF05A,
    // flask.fill (the experimental banner) came with SF Symbols 5: the font doesn't have it.
    // The traffic lights' glyphs (the font's minus is a long bar: the lights use U+2212).
    "xmark": 0xEBE5,
    "arrow.up.left.and.arrow.down.right": 0xEB46,
    // The favorite icon, in either style (Settings).
    "heart": 0xF04B,
    "heart.fill": 0xF046,
    "star": 0xF038,
    "star.fill": 0xF032,
]

/// Local-only SF font; fall back to a readable label if this machine doesn't have it.
private let localSymbolFontAvailable: Bool = {
    #if os(Windows)
    let base = ProcessInfo.processInfo.environment["LOCALAPPDATA"] ?? ""
    return FileManager.default.fileExists(atPath: base + "/Microsoft/Windows/Fonts/SF-SYMBOLS4.TTF")
    #elseif os(Linux)
    return FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.local/share/fonts/SF-SYMBOLS4.TTF")
    #else
    return true
    #endif
}()
private func symbolFallback(_ name: String) -> String {
    switch name {
    case "play.fill": "Play"
    case "pause.fill": "Pause"
    case "backward.end.fill": "Prev"
    case "forward.end.fill": "Next"
    case "music.note": "Music"
    case "ipod": "iPod"
    case "person.fill": "Artists"
    case "star.fill": "★"
    case "star": "☆"
    case "heart.fill": "♥"
    case "heart": "♡"
    case "square.stack": "Albums"
    case "clock": "Recent"
    case "antenna.radiowaves.left.and.right": "Podcasts"
    case "book": "Books"
    case "film", "film.stack", "tv", "music.note.tv": "Video"
    case "cpu": "CPU"
    case "photo.on.rectangle.angled": "Photos"
    case "plus": "+"
    case "xmark": "×"
    case "puzzlepiece.extension": "Plug-ins"
    default: name.replacingOccurrences(of: ".fill", with: "")
    }
}

/// The Mac system colors of each tint, for platforms drawing the font; nil means the text color.
func symbolRGB(_ tint: SymbolTint, dark: Bool) -> (r: UInt8, g: UInt8, b: UInt8)? {
    switch tint {
    case .accent: dark ? (0x0A, 0x84, 0xFF) : (0x00, 0x7A, 0xFF)
    case .primary: nil
    case .secondary: dark ? (0x98, 0x98, 0x9D) : (0x8A, 0x8A, 0x8E)
    case .tertiary: dark ? (0x5A, 0x5A, 0x5E) : (0xC4, 0xC4, 0xC6)
    case .color(let color): color.rgb(dark: dark)
    }
}

#if canImport(AppKitBackend)
    import AppKit
    import AppKitBackend

    /// An SF Symbol, at `pointSize` when given. Nil on macOS 10.15, which has no SF Symbols: the
    /// app then shows no icon there.
    func systemSymbol(_ name: String, description: String? = nil, pointSize: Double? = nil) -> NSImage? {
        if let custom = customSymbols[name] { return customSymbolImage(custom, description: description, pointSize: pointSize ?? 13) }
        guard #available(macOS 11, *) else { return nil }
        if name == "film.music" { return filmWithNote(description: description, pointSize: pointSize ?? 13) }
        // `music.mic` is Apple's earlier name for this same symbol on macOS 15 and older.
        let image = NSImage(systemSymbolName: name, accessibilityDescription: description)
            ?? (name == "microphone.dynamic.on.stand" ? NSImage(systemSymbolName: "music.mic", accessibilityDescription: description) : nil)
        guard let pointSize else { return image }
        return image?.withSymbolConfiguration(.init(pointSize: pointSize, weight: .regular))
    }

    /// Soundtracks: an undivided film frame with Apple's flat-topped music note.
    /// centred in its frame, both in the accent colour like the other music shelves.
    @available(macOS 11, *)
    func filmWithNote(description: String?, pointSize: Double) -> NSImage? {
        guard let film = NSImage(systemSymbolName: "film", accessibilityDescription: description)?
                .withSymbolConfiguration(.init(pointSize: pointSize, weight: .regular)),
              let note = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: pointSize * 0.60, weight: .regular))
        else { return nil }
        let size = film.size
        // Drawn when displayed, so the accent colour follows the system setting and appearance.
        let image = NSImage(size: size, flipped: false) { rect in
            // Preserve the film's perforated sides and rim, leaving its centre open.
            NSGraphicsContext.saveGraphicsState()
            let rim = NSBezierPath(rect: rect)
            rim.appendRect(rect.insetBy(dx: size.width * 0.27, dy: size.height * 0.19))
            rim.windingRule = .evenOdd
            rim.addClip()
            film.draw(in: rect)
            NSGraphicsContext.restoreGraphicsState()
            let h = size.height * 0.60
            let w = h * note.size.width / note.size.height
            let x = (size.width - w) / 2, y = (size.height - h) / 2
            note.draw(in: NSRect(x: x, y: y, width: w, height: h))
            NSColor.controlAccentColor.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        image.isTemplate = false
        // NSImageView lays out SF Symbols by their alignment rect, not their full canvas.
        // Preserve Film's metrics so the composite has exactly the same displayed size.
        image.alignmentRect = film.alignmentRect
        image.accessibilityDescription = description
        return image
    }

    /// A custom symbol as a template image, so it is tinted like an SF Symbol. Square, centered and
    /// sized by `pointSize` (its height a bit over it: Apple's glyph is narrow and reads small otherwise).
    func customSymbolImage(_ symbol: CustomSymbol, description: String?, pointSize: Double) -> NSImage {
        let side = CGFloat(pointSize * 1.4)
        let b = symbol.bounds
        let width = CGFloat(b.maxX - b.minX), height = CGFloat(b.maxY - b.minY)
        let refDim = symbol.fitBounds ? max(width, height, 1) : max(height, 1)
        let scale = CGFloat(pointSize * 1.15) / refDim
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { _ in
            let path = NSBezierPath()
            path.windingRule = .evenOdd
            for step in symbol.steps {
                switch step {
                case .move(let x, let y): path.move(to: NSPoint(x: x, y: y))
                case .line(let x, let y): path.line(to: NSPoint(x: x, y: y))
                case .curve(let x1, let y1, let x2, let y2, let x, let y):
                    path.curve(to: NSPoint(x: x, y: y), controlPoint1: NSPoint(x: x1, y: y1), controlPoint2: NSPoint(x: x2, y: y2))
                case .close: path.close()
                }
            }
            var transform = AffineTransform(translationByX: side / 2, byY: side / 2)
            transform.scale(scale)
            transform.translate(x: -(CGFloat(b.minX) + width / 2), y: -(CGFloat(b.minY) + height / 2))
            path.transform(using: transform)
            if let strokeWidth = symbol.strokeWidth {
                path.lineWidth = CGFloat(strokeWidth) * scale
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                NSColor.black.setStroke()
                path.stroke()
            } else {
                NSColor.black.setFill()
                path.fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = description
        return image
    }

    /// Composite monochrome template icon for a subscribed playlist (`SUB-4`): `playlist-lines`
    /// plus a scaled plug-in badge in the bottom-right corner (`icloud` fallback when no badge SVG).
    @MainActor
    private var compositeSubscriptionSymbolCache: [String: NSImage] = [:]

    @MainActor
    func subscriptionSidebarSymbol(pluginID: String?, parsedBadge: ParsedSVGBadge?, description: String?, pointSize: Double = 14) -> NSImage {
        let key = "v5:\(pluginID ?? "generic"):\(parsedBadge?.steps.count ?? 0):\(Int(pointSize))"
        if let cached = compositeSubscriptionSymbolCache[key] {
            return cached
        }

        if pluginID == "spotify" {
            let s = CGFloat(pointSize / 14.0)
            let side = 16.0 * s
            let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { _ in
                // Hollow outer ring matching SF Symbol "clock" ("Recently Added") circumference and stroke weight.
                let r = 6.15 * s
                let center = 8.0 * s
                let circle = NSBezierPath(ovalIn: NSRect(x: center - r, y: center - r, width: r * 2, height: r * 2))
                circle.lineWidth = 1.15 * s
                NSColor.black.setStroke()
                circle.stroke()

                // Three hollow curved Spotify waves centered cleanly inside the ring.
                let waves = NSBezierPath()
                waves.lineWidth = 1.05 * s
                waves.lineCapStyle = .round

                waves.move(to: NSPoint(x: 4.5 * s, y: 5.9 * s))
                waves.curve(to: NSPoint(x: 11.7 * s, y: 6.8 * s), controlPoint1: NSPoint(x: 6.9 * s, y: 5.1 * s), controlPoint2: NSPoint(x: 9.7 * s, y: 5.5 * s))

                waves.move(to: NSPoint(x: 5.0 * s, y: 8.1 * s))
                waves.curve(to: NSPoint(x: 11.0 * s, y: 8.85 * s), controlPoint1: NSPoint(x: 7.0 * s, y: 7.45 * s), controlPoint2: NSPoint(x: 9.3 * s, y: 7.75 * s))

                waves.move(to: NSPoint(x: 5.55 * s, y: 10.2 * s))
                waves.curve(to: NSPoint(x: 10.25 * s, y: 10.75 * s), controlPoint1: NSPoint(x: 7.15 * s, y: 9.65 * s), controlPoint2: NSPoint(x: 8.9 * s, y: 9.85 * s))

                NSColor.black.setStroke()
                waves.stroke()
                return true
            }
            image.isTemplate = true
            image.accessibilityDescription = description
            compositeSubscriptionSymbolCache[key] = image
            return image
        }

        if pluginID == "youtube-music" {
            let s = CGFloat(pointSize / 14.0)
            let side = 16.0 * s
            let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { _ in
                // Hollow outer ring matching SF Symbol "clock" ("Recently Added") circumference and stroke weight.
                let r = 6.15 * s
                let center = 8.0 * s
                let outer = NSBezierPath(ovalIn: NSRect(x: center - r, y: center - r, width: r * 2, height: r * 2))
                outer.lineWidth = 1.15 * s
                NSColor.black.setStroke()
                outer.stroke()

                // Inner YouTube Music concentric ring + hollow play triangle.
                let rInner = 3.75 * s
                let inner = NSBezierPath(ovalIn: NSRect(x: center - rInner, y: center - rInner, width: rInner * 2, height: rInner * 2))
                inner.lineWidth = 0.90 * s
                inner.stroke()

                let play = NSBezierPath()
                play.lineWidth = 0.95 * s
                play.lineJoinStyle = .round
                play.lineCapStyle = .round
                play.move(to: NSPoint(x: 6.95 * s, y: 6.15 * s))
                play.line(to: NSPoint(x: 6.95 * s, y: 9.85 * s))
                play.line(to: NSPoint(x: 10.05 * s, y: 8.0 * s))
                play.close()
                play.stroke()
                return true
            }
            image.isTemplate = true
            image.accessibilityDescription = description
            compositeSubscriptionSymbolCache[key] = image
            return image
        }

        let width = CGFloat(pointSize * 1.50)
        let height = CGFloat(pointSize * 1.15)
        let lines = customSymbols["playlist-lines"]
        let badgeSymbol = parsedBadge.map { CustomSymbol(parsedBadge: $0) }
        let badgeSize = CGFloat(pointSize * 0.86)
        let fallbackBadge = badgeSymbol == nil ? systemSymbol("icloud", pointSize: pointSize * 0.72) : nil

        let image = NSImage(size: NSSize(width: width, height: height), flipped: true) { _ in
            if let lines {
                let b = lines.bounds
                let w = CGFloat(b.maxX - b.minX)
                let h = CGFloat(b.maxY - b.minY)
                let targetWidth = CGFloat(pointSize * 0.50)
                let targetHeight = CGFloat(pointSize * 0.45)
                let scale = min(targetWidth / max(w, 1), targetHeight / max(h, 1))
                let path = NSBezierPath()
                for step in lines.steps {
                    switch step {
                    case .move(let x, let y): path.move(to: NSPoint(x: x, y: y))
                    case .line(let x, let y): path.line(to: NSPoint(x: x, y: y))
                    case .curve(let x1, let y1, let x2, let y2, let x, let y):
                        path.curve(to: NSPoint(x: x, y: y), controlPoint1: NSPoint(x: x1, y: y1), controlPoint2: NSPoint(x: x2, y: y2))
                    case .close: path.close()
                    }
                }
                let linesLeft = CGFloat(0.8)
                let linesTop = CGFloat(pointSize * 0.22)
                var t = AffineTransform(translationByX: linesLeft, byY: linesTop)
                t.scale(scale)
                t.translate(x: -CGFloat(b.minX), y: -CGFloat(b.minY))
                path.transform(using: t)
                NSColor.black.setFill()
                path.fill()
            }

            let badgeRect = NSRect(
                x: width - badgeSize - 0.3,
                y: (height - badgeSize) / 2 + 0.3,
                width: badgeSize,
                height: badgeSize
            )
            if let ctx = NSGraphicsContext.current?.cgContext {
                ctx.saveGState()
                ctx.setBlendMode(.clear)
                ctx.fillEllipse(in: badgeRect.insetBy(dx: -1.0, dy: -1.0))
                ctx.restoreGState()
            }

            if let badgeSymbol {
                let b = badgeSymbol.bounds
                let w = CGFloat(b.maxX - b.minX)
                let h = CGFloat(b.maxY - b.minY)
                let scale = badgeSize / max(w, h, 1)
                let path = NSBezierPath()
                path.windingRule = .evenOdd
                for step in badgeSymbol.steps {
                    switch step {
                    case .move(let x, let y): path.move(to: NSPoint(x: x, y: y))
                    case .line(let x, let y): path.line(to: NSPoint(x: x, y: y))
                    case .curve(let x1, let y1, let x2, let y2, let x, let y):
                        path.curve(to: NSPoint(x: x, y: y), controlPoint1: NSPoint(x: x1, y: y1), controlPoint2: NSPoint(x: x2, y: y2))
                    case .close: path.close()
                    }
                }
                var t = AffineTransform(translationByX: badgeRect.midX, byY: badgeRect.midY)
                t.scale(scale)
                t.translate(x: -(CGFloat(b.minX) + w / 2), y: -(CGFloat(b.minY) + h / 2))
                path.transform(using: t)
                NSColor.black.setFill()
                path.fill()
            } else if let fallbackBadge {
                fallbackBadge.draw(in: badgeRect, from: .zero, operation: .sourceOver, fraction: 1.0)
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = description
        compositeSubscriptionSymbolCache[key] = image
        return image
    }

    struct Symbol: NSViewRepresentable {
        var name: String
        var size: Double = 16
        var pointSize: Double = 13
        var tint: SymbolTint = .accent

        func makeNSView(context: Context) -> NSImageView {
            let view = NSImageView()
            view.imageScaling = .scaleNone
            return view
        }

        func updateNSView(_ view: NSImageView, context: Context) {
            view.image = systemSymbol(name, pointSize: pointSize)
            view.contentTintColor =
                switch tint {
                case .accent: .controlAccentColor
                case .primary: .labelColor
                case .secondary: .secondaryLabelColor
                case .tertiary: .tertiaryLabelColor
                case .color(let color):
                    {
                        let dark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                        let c = color.rgb(dark: dark)
                        return NSColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: 1)
                    }()
                }
        }

        func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSImageView, context: Context) -> ViewSize {
            ViewSize(size, size)
        }
    }
#elseif canImport(GtkBackend)
    import CGtk
    import Gtk
    import GtkBackend

    /// GTK's C types reach Swift as a mix of typed and opaque pointers; this converts between them.
    func cast<T, U>(_ pointer: T) -> U { unsafeBitCast(pointer, to: U.self) }

    /// Pango markup drawing a symbol's glyph; empty when the font lacks it.
    /// - Parameter tint: nil leaves the color to CSS.
    func symbolMarkup(_ name: String, pointSize: Double, tint: SymbolTint?, dark: Bool) -> String {
        let name = customSymbolFontStandIns[name] ?? name
        guard localSymbolFontAvailable, let codepoint = symbolCodepoints[name], let scalar = Unicode.Scalar(codepoint) else {
            return "<span size='8192'>\(symbolFallback(name))</span>"
        }
        // Typed: left to inference, the interpolation below printed `Optional(…)` and Pango rejected the markup.
        let foreground: String = tint.flatMap { symbolRGB($0, dark: dark) }.map { rgb in
            " foreground='#" + [rgb.r, rgb.g, rgb.b].map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined() + "'"
        } ?? ""
        return "<span font_family='SF-Symbols' size='\(Int(pointSize * 1024))'\(foreground)>\(Character(scalar))</span>"
    }

    struct Symbol: GtkWidgetRepresentable {
        var name: String
        var size: Double = 16
        var pointSize: Double = 13
        var tint: SymbolTint = .accent

        func makeGtkWidget(context: Context) -> Gtk.Widget {
            Gtk.Widget(gtk_label_new(nil))
        }

        func updateGtkWidget(_ widget: Gtk.Widget, context: Context) {
            let label: OpaquePointer = unsafeBitCast(widget.widgetPointer, to: OpaquePointer.self)
            let markup = symbolMarkup(name, pointSize: pointSize, tint: tint, dark: context.environment.colorScheme == .dark)
            // SwiftCrossUI updates views on every layout (each frame of a sidebar slide): only
            // re-parse the markup when it changed.
            if let current = gtk_label_get_label(label), String(cString: current) == markup { return }
            gtk_label_set_markup(label, markup)
        }

        func sizeThatFits(_ proposal: ProposedViewSize, gtkWidget: Gtk.Widget, context: Context) -> ViewSize {
            ViewSize(size, size)
        }
    }
#elseif canImport(WinUIBackend)
    import UWP
    import WinUI
    import WinUIBackend

    /// One font object for every glyph.
    @MainActor private let symbolFont = FontFamily("SF-Symbols")
    /// One brush per color: the tints are a handful of system colors.
    @MainActor private var symbolBrushes: [UInt32: SolidColorBrush] = [:]

    /// Shows a symbol's glyph in a TextBlock (empty when the font lacks it). Only what changed is
    /// set: SwiftCrossUI updates its views on every layout, and each property set makes XAML lay
    /// the glyph out again.
    @MainActor
    func showSymbol(_ name: String, in text: TextBlock, pointSize: Double, tint: SymbolTint, dark: Bool) {
        let name = customSymbolFontStandIns[name] ?? name
        let glyph = localSymbolFontAvailable ? (symbolCodepoints[name].flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? symbolFallback(name)) : symbolFallback(name)
        if text.text != glyph {
            if localSymbolFontAvailable && symbolCodepoints[name] != nil { text.fontFamily = symbolFont }
            text.text = glyph
        }
        if text.fontSize != pointSize { text.fontSize = pointSize }
        let rgb = symbolRGB(tint, dark: dark) ?? (dark ? (255, 255, 255) : (0, 0, 0))
        let key = UInt32(rgb.r) << 16 | UInt32(rgb.g) << 8 | UInt32(rgb.b)
        let brush = symbolBrushes[key] ?? {
            let brush = SolidColorBrush()
            brush.color = UWP.Color(a: 255, r: rgb.r, g: rgb.g, b: rgb.b)
            symbolBrushes[key] = brush
            return brush
        }()
        if text.foreground !== brush { text.foreground = brush }
    }

    /// The glyph centered in a Grid of the symbol's size.
    struct Symbol: WinUIElementRepresentable {
        var name: String
        var size: Double = 16
        var pointSize: Double = 13
        var tint: SymbolTint = .accent

        func makeWinUIElement(context: Context) -> WinUI.Grid {
            let text = TextBlock()
            text.horizontalAlignment = .center
            text.verticalAlignment = .center
            let grid = WinUI.Grid()
            grid.children.append(text)
            return grid
        }

        func updateWinUIElement(_ grid: WinUI.Grid, context: Context) {
            guard let text = grid.children.getAt(0) as? TextBlock else { return }
            showSymbol(name, in: text, pointSize: pointSize, tint: tint,
                       dark: context.environment.colorScheme == .dark)
        }

        func sizeThatFits(_ proposal: ProposedViewSize, winUIElement: WinUI.Grid, context: Context) -> ViewSize {
            ViewSize(size, size)
        }
    }
#else
    struct Symbol: View {
        var name: String
        var size: Double = 16
        var pointSize: Double = 13
        var tint: SymbolTint = .accent

        var body: some View {
            Spacer().frame(width: size, height: size)
        }
    }
#endif
