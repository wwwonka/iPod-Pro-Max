import SwiftCrossUI

// SF Symbols, drawn by AppKit into pixels that SwiftCrossUI's `Image` can show. SF Symbols may
// only be used on Apple platforms, so other backends get an empty box of the same size for now
// (a look-alike open icon set is the plan there).

enum SymbolTint: Hashable {
    case accent, primary, secondary
}

#if canImport(AppKit)
    import AppKit
    import ImageFormats

    struct Symbol: View {
        var name: String
        var size: Double = 16
        var pointSize: Double = 13
        var tint: SymbolTint = .accent

        var body: some View {
            if let image = SymbolCache.image(name, size: size, pointSize: pointSize, tint: tint) {
                Image(image).resizable().frame(width: size, height: size)
            } else {
                Spacer().frame(width: size, height: size)
            }
        }
    }

    /// Each symbol is rendered once per size and tint; sidebar and toolbar redraws reuse it.
    @MainActor
    enum SymbolCache {
        private struct Key: Hashable {
            var name: String
            var size: Double
            var pointSize: Double
            var tint: SymbolTint
        }

        private static var images: [Key: ImageFormats.Image<RGBA>] = [:]

        static func image(_ name: String, size: Double, pointSize: Double, tint: SymbolTint)
            -> ImageFormats.Image<RGBA>?
        {
            let key = Key(name: name, size: size, pointSize: pointSize, tint: tint)
            if let cached = images[key] { return cached }
            let image = render(key)
            images[key] = image
            return image
        }

        private static func render(_ key: Key) -> ImageFormats.Image<RGBA>? {
            let color: NSColor =
                switch key.tint {
                case .accent: .controlAccentColor
                case .primary: .labelColor
                case .secondary: .secondaryLabelColor
                }
            let config = NSImage.SymbolConfiguration(pointSize: key.pointSize, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
            guard let symbol = NSImage(systemSymbolName: key.name, accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
            else { return nil }

            let scale = NSScreen.main?.backingScaleFactor ?? 2
            let pixels = Int((key.size * scale).rounded())
            var bytes = [UInt8](repeating: 0, count: pixels * pixels * 4)
            bytes.withUnsafeMutableBytes { buffer in
                guard let context = CGContext(
                    data: buffer.baseAddress, width: pixels, height: pixels, bitsPerComponent: 8,
                    bytesPerRow: pixels * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { return }
                context.scaleBy(x: scale, y: scale)
                // Dynamic colors (label, accent) resolve against the app's light or dark appearance.
                NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
                    let s = symbol.size
                    symbol.draw(in: NSRect(x: (key.size - s.width) / 2, y: (key.size - s.height) / 2,
                                           width: s.width, height: s.height))
                    NSGraphicsContext.restoreGraphicsState()
                }
            }
            // ImageFormats expects straight alpha; CoreGraphics wrote premultiplied.
            for i in stride(from: 0, to: bytes.count, by: 4) {
                let a = Int(bytes[i + 3])
                guard a > 0, a < 255 else { continue }
                for c in 0..<3 { bytes[i + c] = UInt8(min(255, Int(bytes[i + c]) * 255 / a)) }
            }
            return ImageFormats.Image(width: pixels, height: pixels, bytes: bytes)
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
