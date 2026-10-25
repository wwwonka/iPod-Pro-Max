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
/// the real symbols (Tools: a Swift script comparing renders); nil means the font lacks it.
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
    // Not in the font: the closest glyph stands in.
    "sidebar.left": 0xF088,
]

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

    /// Pango markup drawing a symbol's glyph; empty when the font lacks it.
    func symbolMarkup(_ name: String, pointSize: Double, tint: SymbolTint, dark: Bool) -> String {
        guard let codepoint = symbolCodepoints[name], let scalar = Unicode.Scalar(codepoint) else { return "" }
        let color: String? =
            switch tint {
            case .accent: dark ? "#0A84FF" : "#007AFF"
            case .primary: nil
            case .secondary: dark ? "#98989D" : "#8A8A8E"
            }
        let foreground = color.map { " foreground='\($0)'" } ?? ""
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
            gtk_label_set_markup(label, symbolMarkup(name, pointSize: pointSize, tint: tint,
                                                     dark: context.environment.colorScheme == .dark))
        }

        func sizeThatFits(_ proposal: ProposedViewSize, gtkWidget: Gtk.Widget, context: Context) -> ViewSize {
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
