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
    static func thumbnail(at url: URL, maxPixels: Int = 320) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return thumbnail(from: source, maxPixels: maxPixels)
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
}
