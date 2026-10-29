// Finds which glyph of the SF-Symbols font looks most like a real SF Symbol, to fill
// symbolCodepoints in Sources/iPodProMaxProto/Symbols.swift (macOS only: it draws the real symbol).
//   swift scripts/match-glyph.swift local/SF-SYMBOLS4.TTF <symbol name> [sheet.png]
import AppKit
import CoreText

let args = CommandLine.arguments
let fontURL = URL(fileURLWithPath: args[1])
let symbolName = args[2]
let side = 48

/// Ink of an image, cropped to its bounding box and scaled to fit side×side, as 0...1 values.
func normalized(_ draw: (CGContext) -> Void, canvas: Int = 256) -> [Double]? {
    let space = CGColorSpaceCreateDeviceGray()
    guard let ctx = CGContext(data: nil, width: canvas, height: canvas, bitsPerComponent: 8, bytesPerRow: canvas,
                              space: space, bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
    ctx.setFillColor(gray: 0, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: canvas, height: canvas))
    draw(ctx)
    let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
    var minX = canvas, minY = canvas, maxX = -1, maxY = -1
    for y in 0..<canvas { for x in 0..<canvas where data[y * canvas + x] > 40 {
        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
    } }
    guard maxX >= 0 else { return nil }
    let w = maxX - minX + 1, h = maxY - minY + 1
    let scale = Double(side) / Double(max(w, h))
    var out = [Double](repeating: 0, count: side * side)
    let ox = (Double(side) - Double(w) * scale) / 2, oy = (Double(side) - Double(h) * scale) / 2
    for y in 0..<side { for x in 0..<side {
        let sx = Int((Double(x) - ox) / scale) + minX, sy = Int((Double(y) - oy) / scale) + minY
        if sx >= minX, sx <= maxX, sy >= minY, sy <= maxY { out[y * side + x] = Double(data[sy * canvas + sx]) / 255 }
    } }
    // Aspect ratio as an extra feature.
    return out + [Double(w) / Double(h) * 4]
}

func distance(_ a: [Double], _ b: [Double]) -> Double {
    zip(a, b).reduce(0) { $0 + abs($1.0 - $1.1) }
}

// The real symbol.
let config = NSImage.SymbolConfiguration(pointSize: 160, weight: .regular)
guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?.withSymbolConfiguration(config),
      let symbolCG = symbol.cgImage(forProposedRect: nil, context: nil, hints: nil) else { fatalError("no symbol \(symbolName)") }
let target = normalized { ctx in
    let w = CGFloat(symbolCG.width), h = CGFloat(symbolCG.height)
    let s = min(220 / w, 220 / h)
    ctx.clip(to: CGRect(x: 18, y: 18, width: w * s, height: h * s), mask: symbolCG)
    ctx.setFillColor(gray: 1, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
}!

// Every glyph in the private use area.
let descriptors = CTFontManagerCreateFontDescriptorsFromURL(fontURL as CFURL) as! [CTFontDescriptor]
let font = CTFontCreateWithFontDescriptor(descriptors[0], 160, nil)
var scores: [(UInt32, Double)] = []
for code in UInt32(0xE000)...UInt32(0xF8FF) {
    var ch = UniChar(code)
    var glyph = CGGlyph(0)
    guard CTFontGetGlyphsForCharacters(font, &ch, &glyph, 1), glyph != 0 else { continue }
    guard let ink = normalized({ ctx in
        ctx.setFillColor(gray: 1, alpha: 1)
        var position = CGPoint(x: 40, y: 60)
        CTFontDrawGlyphs(font, &glyph, &position, 1, ctx)
    }) else { continue }
    scores.append((code, distance(ink, target)))
}
scores.sort { $0.1 < $1.1 }
print("\(scores.count) glyphs; best matches for \(symbolName):")
for (code, d) in scores.prefix(8) { print(String(format: "  0x%X  %.0f", code, d)) }

// Side by side: the symbol, then the best 8 glyphs.
if args.count > 3 {
    let cell = 120
    let sheet = NSImage(size: NSSize(width: cell * 9, height: cell))
    sheet.lockFocus()
    NSColor.white.setFill(); NSRect(x: 0, y: 0, width: cell * 9, height: cell).fill()
    symbol.withSymbolConfiguration(.init(pointSize: 60, weight: .regular))!.draw(in: NSRect(x: 20, y: 20, width: 80, height: 80))
    let small = CTFontCreateWithFontDescriptor(descriptors[0], 64, nil)
    for (i, (code, _)) in scores.prefix(8).enumerated() {
        let text = NSAttributedString(string: String(Character(Unicode.Scalar(code)!)), attributes: [.font: small as NSFont])
        text.draw(at: NSPoint(x: cell * (i + 1) + 20, y: 20))
        NSAttributedString(string: String(format: "%X", code), attributes: [.font: NSFont.systemFont(ofSize: 11)])
            .draw(at: NSPoint(x: cell * (i + 1) + 30, y: 4))
    }
    sheet.unlockFocus()
    let rep = NSBitmapImageRep(data: sheet.tiffRepresentation!)!
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[3]))
}
