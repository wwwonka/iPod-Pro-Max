import SwiftCrossUI

// SF Symbols on every platform. macOS draws the real, vector symbols. GTK and WinUI draw glyphs
// from the "SF-Symbols" font (github.com/DrunkSonic/SF-Symbols-for-Windows), which is Apple's
// artwork without a license to use it off Apple platforms: it is only ever installed locally from
// prototypes/swiftcrossui/local/ (git-ignored), never committed or shipped. Without it, symbols
// are empty boxes of the right size.

enum SymbolTint: Hashable {
    case accent, primary, secondary
}

/// The font numbers its glyphs from U+E900 without names. These were matched by shape against
/// the real symbols (scripts/match-glyph.swift); a missing name draws nothing.
let symbolCodepoints: [String: UInt32] = [
    "music.note": 0xF134,
    "music.note.list": 0xF133,
    "music.mic": 0xF12D,
    "ipod": 0xEE8E,
    "book": 0xF286,
    "antenna.radiowaves.left.and.right": 0xEE31,
    "photo.on.rectangle.angled": 0xED80,
    "plus": 0xEC22,
    "square.and.arrow.down": 0xF2FC,
    "magnifyingglass": 0xF12C,
    "film": 0xEDF5,  // landscape, as in SF Symbols 4
    "sidebar.left": 0xED77,
    "chevron.right": 0xEBCC,
    // The traffic lights' glyphs (the font's minus is a long bar: the lights use U+2212).
    "xmark": 0xEBE5,
    "arrow.up.left.and.arrow.down.right": 0xEB46,
]

/// The Mac system colors of each tint, for platforms drawing the font; nil means the text color.
func symbolRGB(_ tint: SymbolTint, dark: Bool) -> (r: UInt8, g: UInt8, b: UInt8)? {
    switch tint {
    case .accent: dark ? (0x0A, 0x84, 0xFF) : (0x00, 0x7A, 0xFF)
    case .primary: nil
    case .secondary: dark ? (0x98, 0x98, 0x9D) : (0x8A, 0x8A, 0x8E)
    }
}

#if canImport(AppKitBackend)
    import AppKit
    import AppKitBackend

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
            view.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: pointSize, weight: .regular))
            view.contentTintColor =
                switch tint {
                case .accent: .controlAccentColor
                case .primary: .labelColor
                case .secondary: .secondaryLabelColor
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
        guard let codepoint = symbolCodepoints[name], let scalar = Unicode.Scalar(codepoint) else { return "" }
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
        let glyph = symbolCodepoints[name].flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? ""
        if text.text != glyph {
            text.fontFamily = symbolFont
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
