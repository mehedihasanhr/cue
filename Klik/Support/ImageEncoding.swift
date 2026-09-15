import AppKit
import ImageIO
import UniformTypeIdentifiers

/// PNG encoding and thumbnailing through ImageIO directly. Safe to call from any
/// thread, and it skips the `NSBitmapImageRep` copy the AppKit route makes of a
/// Retina-sized capture.
nonisolated enum ImageEncoding {
    static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// A thumbnail at most `maxPixels` on its long side, decoded straight from the file.
    /// Formats ImageIO cannot decode (SVG, EPS) are rasterised by AppKit instead.
    static func thumbnail(at url: URL, maxPixels: Int = 320) -> NSImage? {
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0,
           let thumbnail = thumbnail(from: source, maxPixels: maxPixels) {
            return thumbnail
        }
        return rasterised(at: url, maxPixels: maxPixels)?.image
    }

    static func thumbnail(from source: CGImageSource, maxPixels: Int = 320) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    /// AppKit's own decoders (vector formats included) drawn into a bitmap at most
    /// `maxPixels` on its long side, with the image's intrinsic size in points.
    static func rasterised(at url: URL, maxPixels: Int) -> (image: NSImage, size: CGSize)? {
        guard let cgImage = rasterise(at: url, maxPixels: maxPixels) else { return nil }
        return (NSImage(cgImage: cgImage.image, size: NSSize(width: cgImage.image.width, height: cgImage.image.height)), cgImage.size)
    }

    static func rasterise(at url: URL, maxPixels: Int) -> (image: CGImage, size: CGSize)? {
        guard let image = NSImage(contentsOf: url), image.isValid else { return nil }
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = CGFloat(maxPixels) / max(size.width, size.height)
        var rect = CGRect(origin: .zero, size: CGSize(width: (size.width * scale).rounded(.up), height: (size.height * scale).rounded(.up)))
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        return (cgImage, size)
    }
}
