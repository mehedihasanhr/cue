import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Pictures laid over the video — a logo, a screenshot, a diagram — kept inside the project.
///
/// Copied in rather than pointed at, for the reason every other file the edit uses is: a
/// project that is moved, sent or backed up must take its pictures with it.
enum OverlayImport {
    static let folderName = "Images"
    /// Enough for a picture filling a 4K export, and a bound on what one careless choice
    /// of a 12,000-pixel photograph costs the project.
    static let maximumPixels = 3840

    struct Imported {
        /// Relative to the project package.
        let path: String
        let pixelSize: CGSize
    }

    enum Failure: Error, LocalizedError {
        case unreadable
        case couldNotSave

        var errorDescription: String? {
            switch self {
            case .unreadable: "That picture couldn't be read."
            case .couldNotSave: "That picture couldn't be saved into the project."
            }
        }
    }

    @MainActor
    static func choose(title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// Stored as PNG whatever it was. A logo's transparency is the whole point of it, and
    /// PNG keeps it exactly; the lossy formats either lose it or blur the edges round it.
    static func copy(_ url: URL, into packageURL: URL) throws -> Imported {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maximumPixels,
              ] as CFDictionary)
        else { throw Failure.unreadable }

        let folder = packageURL.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "\(UUID().uuidString).png"
        let destination = folder.appendingPathComponent(name)
        guard let writer = CGImageDestinationCreateWithURL(destination as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw Failure.couldNotSave }
        CGImageDestinationAddImage(writer, image, nil)
        guard CGImageDestinationFinalize(writer) else { throw Failure.couldNotSave }
        return Imported(path: "\(folderName)/\(name)", pixelSize: CGSize(width: image.width, height: image.height))
    }
}
