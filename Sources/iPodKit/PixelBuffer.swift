//
//  PixelBuffer.swift
//  iPod Pro Max
//
//  A decoded image as plain bytes, and the aspect-fit scaling the iPod thumbnails need. Replaces
//  CoreGraphics so artwork and photos render the same way, byte for byte, on macOS, Linux and Windows.
//  Decoding (JPEG, PNG…) is MediaKit's job; everything from here to RGB565/YUV is pure Swift.
//

import Foundation

/// 8-bit RGBX pixels, 4 bytes per pixel, top row first. The fourth byte is ignored: decoders
/// composite transparency over black first, the way the iPod shows a transparent cover.
public struct PixelBuffer: Sendable, Hashable {
    public let width: Int
    public let height: Int
    public var bytes: [UInt8]

    public init(width: Int, height: Int, bytes: [UInt8]) {
        precondition(bytes.count == width * height * 4, "PixelBuffer needs width × height × 4 bytes")
        self.width = width
        self.height = height
        self.bytes = bytes
    }

    /// Builds a buffer from straight (non-premultiplied) RGBA, blending each pixel over black.
    public init(width: Int, height: Int, straightRGBA rgba: [UInt8]) {
        var out = rgba
        var i = 0
        while i < out.count {
            let a = UInt16(out[i + 3])
            if a != 255 {
                out[i] = UInt8((UInt16(out[i]) * a + 127) / 255)
                out[i + 1] = UInt8((UInt16(out[i + 1]) * a + 127) / 255)
                out[i + 2] = UInt8((UInt16(out[i + 2]) * a + 127) / 255)
            }
            out[i + 3] = 255
            i += 4
        }
        self.init(width: width, height: height, bytes: out)
    }

    /// Size of the image scaled to fit `width` × `height`, aspect ratio kept (same rounding as before
    /// the CoreGraphics removal, so thumbnails keep their exact dimensions and padding).
    public static func fittedSize(sourceWidth: Int, sourceHeight: Int, width W: Int, height H: Int) -> (width: Int, height: Int) {
        let iw = max(sourceWidth, 1), ih = max(sourceHeight, 1)
        let ws = Double(W) / Double(iw), hs = Double(H) / Double(ih)
        var sw = W, sh = H
        if ws < hs { sw = W; sh = min(Int(ceil(Double(ih) * ws)), H) }
        else if ws > hs { sw = min(Int(ceil(Double(iw) * hs)), W); sh = H }
        return (max(sw, 1), max(sh, 1))
    }

    /// Aspect-fits the image into a black `W` × `H` canvas, centered. Returns RGBX bytes and the
    /// size of the scaled picture inside the canvas.
    public func fitted(width W: Int, height H: Int) -> (bytes: [UInt8], width: Int, height: Int) {
        let (sw, sh) = Self.fittedSize(sourceWidth: width, sourceHeight: height, width: W, height: H)
        let scaled = resized(width: sw, height: sh)
        let hpad = (W - sw) / 2, vpad = (H - sh) / 2
        var canvas = [UInt8](repeating: 0, count: W * H * 4)
        for i in stride(from: 3, to: canvas.count, by: 4) { canvas[i] = 255 }
        scaled.bytes.withUnsafeBufferPointer { src in
            canvas.withUnsafeMutableBufferPointer { dst in
                for y in 0..<sh {
                    let s = y * sw * 4
                    let d = ((y + vpad) * W + hpad) * 4
                    for x in 0..<(sw * 4) { dst[d + x] = src[s + x] }
                }
            }
        }
        return (canvas, sw, sh)
    }

    /// Resamples to exactly `w` × `h` with a separable triangle filter widened when shrinking
    /// (area-averaging quality, like CoreGraphics' high interpolation). Integer weights keep the
    /// result identical on every OS.
    public func resized(width w: Int, height h: Int) -> PixelBuffer {
        if w == width && h == height { return self }
        let horizontal = Self.filterTaps(source: width, destination: w)
        let vertical = Self.filterTaps(source: height, destination: h)

        // Pass 1: rows, width → w.
        var tmp = [UInt8](repeating: 255, count: w * height * 4)
        bytes.withUnsafeBufferPointer { src in
            tmp.withUnsafeMutableBufferPointer { dst in
                for y in 0..<height {
                    let row = y * width * 4
                    for x in 0..<w {
                        let taps = horizontal[x]
                        var r: Int32 = 0, g: Int32 = 0, b: Int32 = 0
                        for (k, weight) in taps.weights.enumerated() {
                            let p = row + (taps.first + k) * 4
                            r += Int32(src[p]) * weight
                            g += Int32(src[p + 1]) * weight
                            b += Int32(src[p + 2]) * weight
                        }
                        let o = (y * w + x) * 4
                        dst[o] = Self.clamp(r); dst[o + 1] = Self.clamp(g); dst[o + 2] = Self.clamp(b)
                    }
                }
            }
        }
        // Pass 2: columns, height → h.
        var out = [UInt8](repeating: 255, count: w * h * 4)
        tmp.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for y in 0..<h {
                    let taps = vertical[y]
                    for x in 0..<w {
                        var r: Int32 = 0, g: Int32 = 0, b: Int32 = 0
                        for (k, weight) in taps.weights.enumerated() {
                            let p = ((taps.first + k) * w + x) * 4
                            r += Int32(src[p]) * weight
                            g += Int32(src[p + 1]) * weight
                            b += Int32(src[p + 2]) * weight
                        }
                        let o = (y * w + x) * 4
                        dst[o] = Self.clamp(r); dst[o + 1] = Self.clamp(g); dst[o + 2] = Self.clamp(b)
                    }
                }
            }
        }
        return PixelBuffer(width: w, height: h, bytes: out)
    }

    private static let precisionBits: Int32 = 14

    @inline(__always) private static func clamp(_ v: Int32) -> UInt8 {
        let rounded = (v + (1 << (precisionBits - 1))) >> precisionBits
        return UInt8(clamping: rounded)
    }

    private struct Taps {
        var first: Int
        var weights: [Int32]
    }

    /// Weights for each destination pixel. Only +, -, *, / on Double (exactly rounded everywhere),
    /// then fixed point whose sum is exactly 1 << precisionBits.
    private static func filterTaps(source: Int, destination: Int) -> [Taps] {
        let scale = Double(source) / Double(destination)
        let support = max(scale, 1.0)
        let one = Int32(1) << precisionBits
        var result: [Taps] = []
        result.reserveCapacity(destination)
        for i in 0..<destination {
            let center = (Double(i) + 0.5) * scale
            let lo = max(0, Int((center - support).rounded(.down)))
            let hi = min(source, Int((center + support).rounded(.up)))
            var raw: [Double] = []
            var sum = 0.0
            for j in lo..<max(hi, lo + 1) {
                let d = abs((Double(j) + 0.5 - center) / support)
                let wgt = max(0, 1 - d)
                raw.append(wgt)
                sum += wgt
            }
            var ints: [Int32]
            if sum <= 0 {
                let nearest = min(max(Int(center), 0), source - 1)
                result.append(Taps(first: nearest, weights: [one]))
                continue
            }
            ints = raw.map { Int32(($0 / sum * Double(one)).rounded()) }
            // Give the rounding remainder to the largest tap so the weights sum to exactly one.
            let error = one - ints.reduce(0, +)
            if error != 0, let m = ints.indices.max(by: { ints[$0] < ints[$1] }) { ints[m] += error }
            // Trim zero taps at both ends.
            var first = lo
            while ints.count > 1, ints.first == 0 { ints.removeFirst(); first += 1 }
            while ints.count > 1, ints.last == 0 { ints.removeLast() }
            result.append(Taps(first: first, weights: ints))
        }
        return result
    }
}

/// Packs RGBX bytes into the 16-bit RGB565 the iPod screens use.
public enum RGB565 {
    public static func pack(_ rgbx: [UInt8], bigEndian: Bool = false) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: rgbx.count / 2)
        rgbx.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                var o = 0
                var i = 0
                while i < src.count {
                    let p = (UInt16(src[i]) >> 3) << 11 | (UInt16(src[i + 1]) >> 2) << 5 | UInt16(src[i + 2]) >> 3
                    if bigEndian { dst[o] = UInt8(p >> 8); dst[o + 1] = UInt8(p & 0xFF) }
                    else { dst[o] = UInt8(p & 0xFF); dst[o + 1] = UInt8(p >> 8) }
                    o += 2
                    i += 4
                }
            }
        }
        return out
    }
}
