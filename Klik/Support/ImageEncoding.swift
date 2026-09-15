import ImageIO
import UniformTypeIdentifiers

/// PNG encoding through ImageIO directly. Safe to call from any thread, and it skips the
/// `NSBitmapImageRep` copy the AppKit route makes of a Retina-sized capture.
nonisolated enum ImageEncoding {
    static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
