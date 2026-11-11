import Foundation
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
    case "square.stack": "Albums"
    case "clock": "Recent"
    case "antenna.radiowaves.left.and.right": "Podcasts"
    case "book": "Books"
    case "film", "film.stack", "tv", "music.note.tv": "Video"
    case "cpu": "CPU"
    case "photo.on.rectangle.angled": "Photos"
    case "plus": "+"
    case "xmark": "×"
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
        // `music.mic` is Apple's earlier name for this same symbol on macOS 15 and older.
        let image = NSImage(systemSymbolName: name, accessibilityDescription: description)
            ?? (name == "microphone.dynamic.on.stand" ? NSImage(systemSymbolName: "music.mic", accessibilityDescription: description) : nil)
        guard let pointSize else { return image }
        return image?.withSymbolConfiguration(.init(pointSize: pointSize, weight: .regular))
    }

    /// A custom symbol as a template image, so it is tinted like an SF Symbol. Square, centered and
    /// sized by `pointSize` (its height a bit over it: Apple's glyph is narrow and reads small otherwise).
    func customSymbolImage(_ symbol: CustomSymbol, description: String?, pointSize: Double) -> NSImage {
        let side = CGFloat(pointSize * 1.4)
        let b = symbol.bounds
        let width = CGFloat(b.maxX - b.minX), height = CGFloat(b.maxY - b.minY)
        let scale = CGFloat(pointSize * 1.15) / max(height, 1)
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { _ in
            let path = NSBezierPath()
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
        let foreground = tint.flatMap { symbolRGB($0, dark: dark) }.map { rgb in
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
