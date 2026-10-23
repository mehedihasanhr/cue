import AppKit
import UniformTypeIdentifiers

/// Images that arrive from outside a capture — a dropped file, a picture dragged out
/// of a browser, the clipboard — read as `CapturedImage`s at a sensible scale.
@MainActor
enum ImageDrop {
    /// What a drop target takes from the pasteboard.
    static let pasteboardTypes: [NSPasteboard.PasteboardType] = [.fileURL, .png, .tiff]
    /// What a SwiftUI `.onDrop` takes. `.item` is there for Cue's own cards, which
    /// carry a file URL the island recognises before the providers are read.
    static let contentTypes: [UTType] = [.image, .fileURL, .item]

    /// The image in a file. Vector and other formats ImageIO cannot decode are drawn
    /// by AppKit instead.
    static func captured(at url: URL, capturedAt: Date = .now) -> CapturedImage? {
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = captured(from: source, capturedAt: capturedAt) {
            return image
        }
        guard let raster = ImageEncoding.rasterise(at: url, maxPixels: 4096), raster.size.width > 0 else { return nil }
        let scale = CGFloat(raster.image.width) / raster.size.width
        return CapturedImage(cgImage: raster.image, scale: max(scale, 1), displayID: 0, capturedAt: capturedAt)
    }

    static func captured(from data: Data, capturedAt: Date = .now) -> CapturedImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return captured(from: source, capturedAt: capturedAt)
    }

    static func captured(from source: CGImageSource, capturedAt: Date = .now) -> CapturedImage? {
        guard CGImageSourceGetCount(source) > 0, let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return CapturedImage(cgImage: image, scale: scale(of: source, pixelWidth: image.width, pixelHeight: image.height),
                             displayID: 0, capturedAt: capturedAt)
    }

    /// Pixels per point for an image of unknown origin: what its DPI says, else the
    /// screen's when it is big enough to be a Retina screenshot, else 1.
    static func scale(of source: CGImageSource, pixelWidth: Int, pixelHeight: Int) -> CGFloat {
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let dpi = properties[kCGImagePropertyDPIWidth] as? Double, dpi >= 144 {
            return (dpi / 72).rounded()
        }
        let screenScale = NSScreen.main?.backingScaleFactor ?? 2
        return pixelWidth >= 1200 && pixelHeight >= 800 ? screenScale : 1
    }

    /// The images in a set of drop providers, in the order they were dropped. Anything
    /// that is not a picture is skipped.
    static func captures(from providers: [NSItemProvider], capturedAt: Date = .now) async -> [CapturedImage] {
        var images: [CapturedImage] = []
        for provider in providers {
            if let url = await fileURL(from: provider), let image = captured(at: url, capturedAt: capturedAt) {
                images.append(image)
                continue
            }
            if let data = await imageData(from: provider), let image = captured(from: data, capturedAt: capturedAt) {
                images.append(image)
            }
        }
        return images
    }

    private static func fileURL(from provider: NSItemProvider) async -> URL? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { return nil }
        return await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url?.isFileURL == true ? url : nil)
            }
        }
    }

    private static func imageData(from provider: NSItemProvider) async -> Data? {
        let identifier = provider.registeredTypeIdentifiers.first { UTType($0)?.conforms(to: .image) == true }
        guard let identifier else { return nil }
        return await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }
}
