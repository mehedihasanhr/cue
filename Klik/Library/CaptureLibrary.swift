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
    /// Captures whose file is still being written (or rewritten); served from memory
    /// meanwhile so copy, drag and the editor never wait for the disk.
    @ObservationIgnored private var pendingImages: [UUID: CGImage] = [:]
    /// File names handed out but not yet on disk, so two captures in one second differ.
    @ObservationIgnored private var reservedNames: Set<String> = []
    /// All file work runs here in order, off the main thread: a rewrite or delete of an
    /// item can never overtake its first write.
    @ObservationIgnored private let storage = DispatchQueue(label: "com.stackrover.klik.storage", qos: .utility)
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

    /// Lists the capture at once and writes its file in the background.
    @discardableResult
    func add(_ image: CapturedImage) -> CaptureItem {
        let url = withFolderAccess { uniqueURL(for: Self.fileName(for: image.capturedAt)) }
        reservedNames.insert(url.lastPathComponent)
        let item = CaptureItem(
            id: UUID(), fileName: url.lastPathComponent, bookmark: Data(), createdAt: image.capturedAt,
            pixelWidth: image.cgImage.width, pixelHeight: image.cgImage.height, scale: image.scale
        )
        items.insert(item, at: 0)
        pendingImages[item.id] = image.cgImage
        thumbnails[item.id] = Self.makeThumbnail(image.cgImage)
        write(image.cgImage, for: item.id, to: url, isNew: true)
        return item
    }

    /// Overwrites an item's file with an edited image.
    func replaceImage(of item: CaptureItem, with cgImage: CGImage) {
        guard let index = items.firstIndex(where: { $0.id == item.id }), let url = storedURL(for: item) else { return }
        items[index].pixelWidth = cgImage.width
        items[index].pixelHeight = cgImage.height
        pendingImages[item.id] = cgImage
        thumbnails[item.id] = Self.makeThumbnail(cgImage)
        saveIndex()
        write(cgImage, for: item.id, to: url, isNew: false)
    }

    /// Encodes and writes on the storage queue, then records the outcome on the main actor.
    private func write(_ cgImage: CGImage, for id: UUID, to url: URL, isNew: Bool) {
        let scoped = folderIsCustom ? folderURL : nil
        storage.async {
            let accessing = scoped?.startAccessingSecurityScopedResource() ?? false
            defer { if accessing { scoped?.stopAccessingSecurityScopedResource() } }
            let result = Result { () throws -> Data in
                guard let png = ImageEncoding.png(cgImage) else { throw CocoaError(.fileWriteUnknown) }
                try png.write(to: url, options: .atomic)
                return (try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)) ?? Data()
            }
            Task { @MainActor in self.didWrite(cgImage, for: id, to: url, isNew: isNew, result: result) }
        }
    }

    private func didWrite(_ cgImage: CGImage, for id: UUID, to url: URL, isNew: Bool, result: Result<Data, any Error>) {
        reservedNames.remove(url.lastPathComponent)
        // A newer image for the same item may already be queued; keep serving that one.
        if pendingImages[id] === cgImage { pendingImages[id] = nil }
        switch result {
        case .success(let bookmark):
            if isNew, let index = items.firstIndex(where: { $0.id == id }) {
                items[index].bookmark = bookmark
                saveIndex()
                Log.app.info("Saved capture \(url.lastPathComponent, privacy: .public)")
            }
        case .failure(let error):
            Log.app.error("Could not \(isNew ? "save" : "overwrite", privacy: .public) capture: \(error.localizedDescription, privacy: .public)")
            if isNew {
                items.removeAll { $0.id == id }
                thumbnails[id] = nil
                saveIndex()
            }
        }
    }

    func delete(_ item: CaptureItem) {
        let url = storedURL(for: item)
        items.removeAll { $0.id == item.id }
        thumbnails[item.id] = nil
        pendingImages[item.id] = nil
        saveIndex()
        guard let url else { return }
        let scoped = folderIsCustom ? folderURL : nil
        storage.async {
            let accessing = scoped?.startAccessingSecurityScopedResource() ?? false
            defer { if accessing { scoped?.stopAccessingSecurityScopedResource() } }
            let itemAccess = url.startAccessingSecurityScopedResource()
            defer { if itemAccess { url.stopAccessingSecurityScopedResource() } }
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
    }

    func image(for item: CaptureItem) -> CapturedImage? {
        if let pending = pendingImages[item.id] {
            return CapturedImage(cgImage: pending, scale: item.scale, displayID: 0, capturedAt: item.createdAt)
        }
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
        if let pending = pendingImages[item.id] {
            Clipboard.copy(pending)
            return
        }
        guard let url = fileURL(for: item) else { return }
        withScopedAccess(to: url) {
            guard let data = try? Data(contentsOf: url) else { return }
            Clipboard.copy(pngData: data)
        }
    }

    /// The item's file, whether or not it has been written yet.
    private func storedURL(for item: CaptureItem) -> URL? {
        fileURL(for: item) ?? (pendingImages[item.id] != nil ? folderURL.appendingPathComponent(item.fileName) : nil)
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
        while FileManager.default.fileExists(atPath: url.path) || reservedNames.contains(url.lastPathComponent) {
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

    /// A real 320 px bitmap — wrapping the full capture in a small `NSImage` would keep
    /// every capture of the session in memory at full size.
    private static func makeThumbnail(_ image: CGImage) -> NSImage {
        let maxSide: CGFloat = 320
        let scale = min(1, maxSide / CGFloat(max(image.width, image.height)))
        let size = CGSize(width: max(1, (CGFloat(image.width) * scale).rounded()), height: max(1, (CGFloat(image.height) * scale).rounded()))
        guard scale < 1,
              let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return NSImage(cgImage: image, size: size) }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(origin: .zero, size: size))
        guard let small = context.makeImage() else { return NSImage(cgImage: image, size: size) }
        return NSImage(cgImage: small, size: size)
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
