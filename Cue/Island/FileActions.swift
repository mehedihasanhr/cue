import AppKit
import ImageIO
import Quartz
import UniformTypeIdentifiers

/// What can be done to files on the shelf: convert images, make them smaller, zip,
/// look at them, send them. New files are written into the shelf's own folder (Cue
/// may read what was dropped, not write beside it) and join the shelf, ready to be
/// dragged on.
enum FileActions {
    nonisolated enum ImageFormat: String, CaseIterable, Sendable {
        case jpeg, png, heic, avif, tiff

        var title: String {
            switch self {
            case .jpeg: "JPEG"
            case .png: "PNG"
            case .heic: "HEIC"
            case .avif: "AVIF"
            case .tiff: "TIFF"
            }
        }

        var type: UTType {
            switch self {
            case .jpeg: .jpeg
            case .png: .png
            case .heic: .heic
            case .avif: UTType("public.avif") ?? .heic
            case .tiff: .tiff
            }
        }

        var fileExtension: String { self == .jpeg ? "jpg" : rawValue }

        /// The ones this Mac's ImageIO can write (WebP it can only read).
        static var writable: [ImageFormat] {
            let types = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
            return allCases.filter { types.contains($0.type.identifier) }
        }
    }

    static func isImage(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)?.conforms(to: .image) ?? false
    }

    /// `url` re-encoded as `format`, into `folder`.
    nonisolated static func convert(_ url: URL, to format: ImageFormat, into folder: URL) -> URL? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let name = url.deletingPathExtension().lastPathComponent + "." + format.fileExtension
        let output = folder.appendingPathComponent(UUID().uuidString, isDirectory: true).appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, format.type.identifier as CFString, 1, nil) else { return nil }
        let options: [CFString: Any] = format == .png || format == .tiff ? [:] : [kCGImageDestinationLossyCompressionQuality: 0.9]
        CGImageDestinationAddImageFromSource(destination, source, 0, options as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output : nil
    }

    /// A smaller copy of an image: at most 2560 px on its long side, as JPEG at
    /// quality 0.7 (HEIC kept as HEIC, PNG with transparency kept as PNG).
    nonisolated static func compress(_ url: URL, into folder: URL) -> URL? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        let hasAlpha = properties[kCGImagePropertyHasAlpha] as? Bool ?? false
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
        let format: ImageFormat = type == .heic ? .heic : (hasAlpha ? .png : .jpeg)
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 2560,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else { return nil }
        let name = url.deletingPathExtension().lastPathComponent + " (smaller)." + format.fileExtension
        let output = folder.appendingPathComponent(UUID().uuidString, isDirectory: true).appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, format.type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output : nil
    }

    /// The files in one ZIP, made by the system's own archiver (a folder read "for
    /// uploading" comes back zipped), so nothing is launched.
    nonisolated static func zip(_ urls: [URL], into folder: URL) -> URL? {
        guard !urls.isEmpty else { return nil }
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let name = urls.count == 1 ? urls[0].deletingPathExtension().lastPathComponent : "Archive"
        let content = staging.appendingPathComponent(name, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        do {
            try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
            for url in urls { try FileManager.default.copyItem(at: url, to: content.appendingPathComponent(url.lastPathComponent)) }
        } catch {
            return nil
        }
        var result: URL?
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: content, options: .forUploading, error: &error) { zipped in
            let output = folder.appendingPathComponent(UUID().uuidString, isDirectory: true).appendingPathComponent(name + ".zip")
            try? FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? FileManager.default.copyItem(at: zipped, to: output)) != nil { result = output }
        }
        return result
    }

    // MARK: - Looking and sending

    @MainActor static func quickLook(_ urls: [URL]) {
        QuickLookSource.shared.show(urls)
    }

    @MainActor static func share(_ urls: [URL], via name: NSSharingService.Name) {
        NSSharingService(named: name)?.perform(withItems: urls)
    }

    @MainActor static func reveal(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}

/// Feeds the system's Quick Look panel.
@MainActor
private final class QuickLookSource: NSObject, @preconcurrency QLPreviewPanelDataSource {
    static let shared = QuickLookSource()
    private var urls: [URL] = []

    func show(_ urls: [URL]) {
        self.urls = urls
        guard let panel = QLPreviewPanel.shared() else { return }
        NSApp.activate()
        panel.dataSource = self
        panel.currentPreviewItemIndex = 0
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        urls[index] as NSURL
    }
}
