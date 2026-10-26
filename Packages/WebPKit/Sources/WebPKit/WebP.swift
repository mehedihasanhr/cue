import CoreGraphics
import Foundation
import libwebp

/// Images as WebP.
public enum WebP {
    /// `image` encoded as a WebP file: lossy at `quality` (0…1), or lossless.
    /// Nil if it can't be drawn or encoded.
    public static func encode(_ image: CGImage, quality: Double = 0.9, lossless: Bool = false) -> Data? {
        let width = image.width, height = image.height
        let stride = width * 4
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var pixels = [UInt8](repeating: 0, count: stride * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: stride,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        // CoreGraphics draws premultiplied; WebP wants straight alpha.
        if image.alphaInfo != .none, image.alphaInfo != .noneSkipLast, image.alphaInfo != .noneSkipFirst {
            for index in Swift.stride(from: 0, to: pixels.count, by: 4) {
                let alpha = Int(pixels[index + 3])
                guard alpha > 0, alpha < 255 else { continue }
                for channel in 0..<3 {
                    pixels[index + channel] = UInt8(min(255, (Int(pixels[index + channel]) * 255 + alpha / 2) / alpha))
                }
            }
        }
        var output: UnsafeMutablePointer<UInt8>?
        let size = lossless
            ? WebPEncodeLosslessRGBA(pixels, Int32(width), Int32(height), Int32(stride), &output)
            : WebPEncodeRGBA(pixels, Int32(width), Int32(height), Int32(stride), Float(min(max(quality, 0), 1) * 100), &output)
        guard size > 0, let output else { return nil }
        defer { WebPFree(output) }
        return Data(bytes: output, count: size)
    }
}
