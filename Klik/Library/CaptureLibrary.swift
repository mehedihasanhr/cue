import os
import AppKit
import Observation
import UniformTypeIdentifiers

/// One saved capture. The file lives in the storage folder; `bookmark` keeps it
/// reachable under the sandbox even if the folder changes later.
struct CaptureItem: Identifiable, Codable, Hashable {
    let id: UUID
    var fileName: String
    var bookmark: Data
    let createdAt: Date
    var pixelWidth: Int
    var pixelHeight: Int
    var scale: Double

    var title: String { (fileName as NSString).deletingPathExtension }
    var dimensions: String { "\(pixelWidth) × \(pixelHeight)" }
}

/// Every capture Klik takes is written to the storage folder as PNG and listed here.
@Observable
final class CaptureLibrary {
    private(set) var items: [CaptureItem] = []   // newest first
    private(set) var folderURL: URL
    private(set) var folderIsCustom = false

    @ObservationIgnored private var thumbnails: [UUID: NSImage] = [:]
    private let defaults = UserDefaults.standard
    private static let folderBookmarkKey = "library.folderBookmark"
    private static let indexFileName = "library.json"

    init() {
        folderURL = Self.defaultFolder()
        if let data = defaults.data(forKey: Self.folderBookmarkKey), let url = Self.resolve(bookmark: data) {
            folderURL = url
            folderIsCustom = true
        }
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        loadIndex()
    }

    // MARK: - Folder

    /// ~/Pictures/Klik. Under the sandbox the Pictures directory is reachable through the
    /// `assets.pictures.read-write` entitlement; the container path resolves to the real folder.
    static func defaultFolder() -> URL {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return pictures.resolvingSymlinksInPath().appendingPathComponent("Klik", isDirectory: true)
    }

    /// Asks the user for a folder and remembers it (security-scoped bookmark).
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        panel.message = "Choose where Klik saves screenshots"
        panel.directoryURL = folderURL
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let bookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            defaults.set(bookmark, forKey: Self.folderBookmarkKey)
            folderURL = url
            folderIsCustom = true
            Log.app.info("Storage folder set to \(url.path, privacy: .public)")
        } catch {
            Log.app.error("Could not bookmark folder: \(error.localizedDescription, privacy: .public)")
        }
    }

    func useDefaultFolder() {
        defaults.removeObject(forKey: Self.folderBookmarkKey)
        folderURL = Self.defaultFolder()
        folderIsCustom = false
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
    }

    func revealFolder() {
        withFolderAccess { NSWorkspace.shared.activateFileViewerSelecting([folderURL]) }
    }

    // MARK: - Items

    @discardableResult
    func add(_ image: CapturedImage) -> CaptureItem? {
        guard let png = DocumentExporter.pngData(image.cgImage) else { return nil }
        let fileName = Self.fileName(for: image.capturedAt)
        return withFolderAccess {
            let url = uniqueURL(for: fileName)
            do {
                try png.write(to: url, options: .atomic)
                let bookmark = (try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)) ?? Data()
                let item = CaptureItem(
                    id: UUID(), fileName: url.lastPathComponent, bookmark: bookmark, createdAt: image.capturedAt,
                    pixelWidth: image.cgImage.width, pixelHeight: image.cgImage.height, scale: image.scale
                )
                items.insert(item, at: 0)
                thumbnails[item.id] = Self.makeThumbnail(image.cgImage)
                saveIndex()
                Log.app.info("Saved capture \(url.lastPathComponent, privacy: .public)")
                return item
            } catch {
                Log.app.error("Could not save capture: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
    }

    /// Overwrites an item's file with an edited image.
    func replaceImage(of item: CaptureItem, with cgImage: CGImage) {
        guard let png = DocumentExporter.pngData(cgImage), let url = fileURL(for: item) else { return }
        withScopedAccess(to: url) {
            do {
                try png.write(to: url, options: .atomic)
                if let index = items.firstIndex(of: item) {
                    items[index].pixelWidth = cgImage.width
                    items[index].pixelHeight = cgImage.height
                }
                thumbnails[item.id] = Self.makeThumbnail(cgImage)
                saveIndex()
            } catch {
                Log.app.error("Could not overwrite capture: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func delete(_ item: CaptureItem) {
        if let url = fileURL(for: item) {
            withScopedAccess(to: url) { try? FileManager.default.trashItem(at: url, resultingItemURL: nil) }
        }
        items.removeAll { $0.id == item.id }
        thumbnails[item.id] = nil
        saveIndex()
    }

    func image(for item: CaptureItem) -> CapturedImage? {
        guard let url = fileURL(for: item) else { return nil }
        return withScopedAccess(to: url) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else { return nil }
            return CapturedImage(cgImage: cgImage, scale: item.scale, displayID: 0, capturedAt: item.createdAt)
        }
    }

    func thumbnail(for item: CaptureItem) -> NSImage? {
        if let cached = thumbnails[item.id] { return cached }
        guard let url = fileURL(for: item) else { return nil }
        let thumbnail: NSImage? = withScopedAccess(to: url) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 320,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }
        thumbnails[item.id] = thumbnail
        return thumbnail
    }

    func fileURL(for item: CaptureItem) -> URL? {
        if let url = Self.resolve(bookmark: item.bookmark) { return url }
        let fallback = folderURL.appendingPathComponent(item.fileName)
        return FileManager.default.fileExists(atPath: fallback.path) ? fallback : nil
    }

    func copyToClipboard(_ item: CaptureItem) {
        guard let url = fileURL(for: item) else { return }
        withScopedAccess(to: url) {
            guard let data = try? Data(contentsOf: url) else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setData(data, forType: .png)
        }
    }

    // MARK: - Index persistence

    private var indexURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Klik", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent(Self.indexFileName)
    }

    private func loadIndex() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([CaptureItem].self, from: data)
        else { return }
        // Drop entries whose files were removed outside Klik.
        items = decoded.filter { fileURL(for: $0) != nil }
        if items.count != decoded.count { saveIndex() }
    }

    private func saveIndex() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    // MARK: - Helpers

    static func fileName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Screenshot \(formatter.string(from: date)).png"
    }

    private func uniqueURL(for fileName: String) -> URL {
        var url = folderURL.appendingPathComponent(fileName)
        var counter = 2
        let base = (fileName as NSString).deletingPathExtension
        while FileManager.default.fileExists(atPath: url.path) {
            url = folderURL.appendingPathComponent("\(base) (\(counter)).png")
            counter += 1
        }
        return url
    }

    private static func resolve(bookmark: Data) -> URL? {
        guard !bookmark.isEmpty else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func makeThumbnail(_ image: CGImage) -> NSImage {
        let maxSide: CGFloat = 320
        let scale = min(1, maxSide / CGFloat(max(image.width, image.height)))
        let size = NSSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        return NSImage(cgImage: image, size: size)
    }

    @discardableResult
    private func withFolderAccess<T>(_ body: () -> T) -> T {
        let accessing = folderIsCustom && folderURL.startAccessingSecurityScopedResource()
        defer { if accessing { folderURL.stopAccessingSecurityScopedResource() } }
        return body()
    }

    @discardableResult
    private func withScopedAccess<T>(to url: URL, _ body: () -> T) -> T {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        return withFolderAccess(body)
    }
}
