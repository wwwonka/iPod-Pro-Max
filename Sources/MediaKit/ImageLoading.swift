//
//  ImageLoading.swift
//  iPod Pro Max
//
//  Image decoding and JPEG re-encoding. ImageIO on the Mac; swift-image-formats (pure Swift JPEG,
//  libpng, libwebp) on Linux and Windows. Scaling is PixelBuffer's, the same on every OS.
//

import Foundation
import iPodKit
#if canImport(ImageIO)
import CoreGraphics
import ImageIO
#elseif canImport(ImageFormats)
import ImageFormats
#endif

public enum ImageLoading {
    /// Decodes JPEG, PNG or WebP data into pixels, transparency composited over black.
    public static func pixels(from data: Data) -> PixelBuffer? {
        #if canImport(ImageIO)
        guard let image = cgImage(from: data) else { return nil }
        return pixels(from: image)
        #elseif canImport(ImageFormats)
        let bytes = [UInt8](data)
        do {
            if bytes.starts(with: [0xFF, 0xD8]) {
                let image = try Image<RGB>.loadJPEG(from: bytes)
                var rgbx = [UInt8](repeating: 255, count: image.width * image.height * 4)
                var o = 0
                for i in stride(from: 0, to: image.bytes.count, by: 3) {
                    rgbx[o] = image.bytes[i]; rgbx[o + 1] = image.bytes[i + 1]; rgbx[o + 2] = image.bytes[i + 2]
                    o += 4
                }
                return PixelBuffer(width: image.width, height: image.height, bytes: rgbx)
            }
            let format: ImageFormat = bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? .png : .webp
            let image = try Image<RGBA>.load(from: bytes, as: format)
            return PixelBuffer(width: image.width, height: image.height, straightRGBA: image.bytes)
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    public static func pixels(from url: URL) -> PixelBuffer? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return pixels(from: data)
    }

    /// A picture file as an upright JPEG of at most `maxDimension` px. On the Mac the camera's orientation
    /// is applied (ImageIO); elsewhere the pixels are taken as stored.
    public static func photoJPEG(from url: URL, maxDimension: Int, quality: Double) -> Data? {
        #if canImport(ImageIO)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxDimension, kCGImageSourceShouldCache: false]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return jpegData(from: image, maxDimension: maxDimension, quality: quality)
        #else
        guard let data = try? Data(contentsOf: url) else { return nil }
        return jpegData(from: data, maxDimension: maxDimension, quality: quality)
        #endif
    }

    /// Re-encodes image data as JPEG, downscaling so the longest side is at most `maxDimension`.
    public static func jpegData(from data: Data, maxDimension: Int = 600, quality: Double = 0.85) -> Data? {
        #if canImport(ImageIO)
        guard let image = cgImage(from: data) else { return nil }
        return jpegData(from: image, maxDimension: maxDimension, quality: quality)
        #elseif canImport(ImageFormats)
        guard var buffer = pixels(from: data) else { return nil }
        let longest = max(buffer.width, buffer.height)
        if longest > maxDimension {
            let scale = Double(maxDimension) / Double(longest)
            buffer = buffer.resized(width: max(Int(Double(buffer.width) * scale), 1), height: max(Int(Double(buffer.height) * scale), 1))
        }
        var rgb = [UInt8](repeating: 0, count: buffer.width * buffer.height * 3)
        var o = 0
        for i in stride(from: 0, to: buffer.bytes.count, by: 4) {
            rgb[o] = buffer.bytes[i]; rgb[o + 1] = buffer.bytes[i + 1]; rgb[o + 2] = buffer.bytes[i + 2]
            o += 3
        }
        // swift-jpeg's scale: 0 is the best quality, 1 a medium one (T.81 tables).
        let compression = max(0, (1 - quality) * 2)
        guard let jpeg = try? Image<RGB>(width: buffer.width, height: buffer.height, bytes: rgb).encodeToJPEG(compression: compression) else { return nil }
        return Data(jpeg)
        #else
        return nil
        #endif
    }

    #if canImport(ImageIO)
    /// Decodes image data (JPEG/PNG/…) into a CGImage.
    public static func cgImage(from data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
    }

    public static func cgImage(from url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
    }

    /// Draws a CGImage at its own size into RGBX bytes, over black.
    public static func pixels(from image: CGImage) -> PixelBuffer? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let ok = bytes.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            // A bitmap context's buffer stores the top row first and draw keeps the image upright.
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? PixelBuffer(width: w, height: h, bytes: bytes) : nil
    }

    /// Re-encodes an image as JPEG, downscaling so the longest side is at most `maxDimension`.
    public static func jpegData(from image: CGImage, maxDimension: Int = 600, quality: Double = 0.85) -> Data? {
        var img = image
        let longest = max(image.width, image.height)
        if longest > maxDimension {
            let scale = Double(maxDimension) / Double(longest)
            let w = max(Int(Double(image.width) * scale), 1)
            let h = max(Int(Double(image.height) * scale), 1)
            if let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
                ctx.interpolationQuality = .high
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                if let scaled = ctx.makeImage() { img = scaled }
            }
        }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
    #endif
}
