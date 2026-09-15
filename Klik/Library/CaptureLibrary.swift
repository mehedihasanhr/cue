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

    /// Bounded: 320 px thumbnails are ~270 KB each, and a long library would
    /// otherwise hold hundreds of megabytes after one scroll through.
    @ObservationIgnored private var thumbnails = LRUCache<UUID, NSImage>(capacity: 300)
    @ObservationIgnored private var loadingThumbnails: Set<UUID> = []
    /// Bumped when a thumbnail arrives, so cards showing a placeholder refresh.
    private(set) var thumbnailVersion = 0
    /// Small PNGs in the app container, written once per capture, so a thumbnail is a
    /// ~1 ms read instead of decoding a multi-megabyte Retina PNG.
    private let thumbnailFolder: URL
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
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        thumbnailFolder = support.appendingPathComponent("Klik/Thumbnails", isDirectory: true)
        folderURL = Self.defaultFolder()
        if let data = defaults.data(forKey: Self.folderBookmarkKey), let url = Self.resolve(bookmark: data) {
            folderURL = url
            folderIsCustom = true
        }
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: thumbnailFolder, withIntermediateDirectories: true)
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
        cacheThumbnail(Self.makeThumbnail(image.cgImage), for: item.id)
        write(image.cgImage, for: item.id, to: url, isNew: true)
        return item
    }

    /// Overwrites an item's file with an edited image.
    func replaceImage(of item: CaptureItem, with cgImage: CGImage) {
        guard let index = items.firstIndex(where: { $0.id == item.id }), let url = storedURL(for: item) else { return }
        items[index].pixelWidth = cgImage.width
        items[index].pixelHeight = cgImage.height
        pendingImages[item.id] = cgImage
        cacheThumbnail(Self.makeThumbnail(cgImage), for: item.id)
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
        let thumbnailURL = thumbnailURL(for: item.id)
        storage.async { try? FileManager.default.removeItem(at: thumbnailURL) }
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

    /// The cached thumbnail, or nil while it loads off the main thread (cards showing
    /// a placeholder refresh through `thumbnailVersion`).
    func thumbnail(for item: CaptureItem) -> NSImage? {
        _ = thumbnailVersion
        if let cached = thumbnails[item.id] { return cached }
        loadThumbnail(for: item)
        return nil
    }

    /// Loads the thumbnails of the newest captures ahead of the first opening of the
    /// island / panel.
    func warmThumbnails(limit: Int = 40) {
        for item in items.prefix(limit) where thumbnails[item.id] == nil {
            loadThumbnail(for: item)
        }
    }

    /// The small PNG if it exists, else decoded from the capture (and the small PNG
    /// written for next time).
    private func loadThumbnail(for item: CaptureItem) {
        guard !loadingThumbnails.contains(item.id) else { return }
        let id = item.id
        let small = thumbnailURL(for: id)
        let full = fileURL(for: item)
        loadingThumbnails.insert(id)
        storage.async { [weak self] in
            var image = NSImage(contentsOf: small)
            if image == nil, let full {
                let granted = full.startAccessingSecurityScopedResource()
                image = ImageEncoding.thumbnail(at: full)
                if granted { full.stopAccessingSecurityScopedResource() }
                if let cgImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil), let png = ImageEncoding.png(cgImage) {
                    try? png.write(to: small, options: .atomic)
                }
            }
            Task { @MainActor in
                guard let self else { return }
                self.loadingThumbnails.remove(id)
                guard let image else { return }
                self.thumbnails[id] = image
                self.thumbnailVersion += 1
            }
        }
    }

    /// Caches a freshly made thumbnail and writes its small PNG in the background.
    private func cacheThumbnail(_ image: NSImage, for id: UUID) {
        thumbnails[id] = image
        thumbnailVersion += 1
        let url = thumbnailURL(for: id)
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        storage.async {
            if let png = ImageEncoding.png(cgImage) { try? png.write(to: url, options: .atomic) }
        }
    }

    private func thumbnailURL(for id: UUID) -> URL {
        thumbnailFolder.appendingPathComponent("\(id.uuidString).png")
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

    /// Renames the capture's file (the title is the file name without ".png"). The
    /// move happens at once so the new name is real before anything else touches it.
    func rename(_ item: CaptureItem, to title: String) {
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        guard !cleaned.isEmpty, cleaned != item.title, let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        guard let source = storedURL(for: item) else { return }
        let destination = withFolderAccess { uniqueURL(for: "\(cleaned).png") }
        if pendingImages[item.id] == nil {
            let moved: Bool = withFolderAccess {
                let scoped = source.startAccessingSecurityScopedResource()
                defer { if scoped { source.stopAccessingSecurityScopedResource() } }
                do {
                    try FileManager.default.moveItem(at: source, to: destination)
                    return true
                } catch {
                    Log.app.error("Could not rename capture: \(error.localizedDescription, privacy: .public)")
                    return false
                }
            }
            guard moved else { return }
            items[index].bookmark = withFolderAccess {
                (try? destination.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)) ?? Data()
            }
        } else {
            // Still being written: the pending write lands under the old name, so move it after.
            let old = source
            reservedNames.insert(destination.lastPathComponent)
            storage.async { try? FileManager.default.moveItem(at: old, to: destination) }
        }
        items[index].fileName = destination.lastPathComponent
        saveIndex()
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
