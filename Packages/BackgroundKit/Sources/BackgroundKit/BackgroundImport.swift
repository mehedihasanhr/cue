import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Taking a picture the user chose and making it part of a project.
///
/// The copy is the point. A sandboxed app cannot open a path it merely remembers, and a
/// project that refers to `~/Pictures/whatever.heic` stops working the moment it is
/// moved to another Mac. Copying costs a few megabytes once and makes the project a
/// self-contained thing again.
public enum BackgroundImport {
    /// Where imported pictures live inside a project package.
    public static let folderName = "Backgrounds"

    /// Long edge of the stored copy. Past 4K a background is only costing disk: it is
    /// scaled to fill a frame that is at most that big, and usually blurred as well.
    public static let maximumPixels = 3840

    public enum Failure: Error, LocalizedError {
        case unreadable
        case couldNotEncode

        public var errorDescription: String? {
            switch self {
            case .unreadable: "That image couldn't be read."
            case .couldNotEncode: "That image couldn't be saved into the project."
            }
        }
    }

    /// Asks for a picture. Returns `nil` when the user cancels.
    @MainActor
    public static func choose() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose a background image"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// Copies `url` into `packageURL/Backgrounds/`, downsampled, and returns the path to
    /// store in the document — package-relative, with forward slashes.
    public static func copy(_ url: URL, into packageURL: URL) throws -> String {
        let image = try WallpaperBookmarks.withAccess(to: url) { granted -> CGImage in
            guard let granted,
                  let source = CGImageSourceCreateWithURL(granted as CFURL, nil),
                  let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: maximumPixels,
                  ] as CFDictionary)
            else { throw Failure.unreadable }
            return decoded
        }

        let folder = packageURL.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "\(UUID().uuidString).heic"
        let destination = folder.appendingPathComponent(name)

        guard let writer = CGImageDestinationCreateWithURL(destination as CFURL, UTType.heic.identifier as CFString, 1, nil) else {
            throw Failure.couldNotEncode
        }
        CGImageDestinationAddImage(writer, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(writer) else { throw Failure.couldNotEncode }

        return "\(folderName)/\(name)"
    }

    /// The imported pictures a project is not using any more.
    ///
    /// Called after a save rather than after an edit: undoing a background change has to
    /// be able to find the file again.
    public static func unused(in packageURL: URL, keeping paths: Set<String>) -> [URL] {
        let folder = packageURL.appendingPathComponent(folderName, isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { !paths.contains("\(folderName)/\($0.lastPathComponent)") }
    }
}
