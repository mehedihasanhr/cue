import os
import AppKit
import Observation
import UniformTypeIdentifiers

/// One file the user dropped or pasted onto the island, kept for later use.
nonisolated struct AssetItem: Identifiable, Codable, Hashable {
    enum Kind: String, Codable {
        case image, file
    }

    let id: UUID
    var fileName: String
    var kind: Kind
    var byteSize: Int
    var pixelWidth: Int
    var pixelHeight: Int
    var createdAt: Date

    var title: String { (fileName as NSString).deletingPathExtension }
    var dimensions: String { "\(pixelWidth) × \(pixelHeight)" }
    var sizeText: String { ByteCountFormatter.string(fromByteCount: Int64(byteSize), countStyle: .file) }
}

/// Images and files dropped or pasted onto the Dynamic Island, newest first. Each
/// lives in its own folder in the app container (Application Support/Klik/Assets/
/// <id>/<original name>) so it keeps its name and can be dragged back out anywhere.
@Observable
final class AssetStore {
    private(set) var items: [AssetItem] = []
    /// Bumped when a thumbnail arrives, so cards showing a placeholder refresh.
    private(set) var thumbnailVersion = 0

    @ObservationIgnored private var thumbnails = LRUCache<UUID, NSImage>(capacity: 300)
    @ObservationIgnored private var loadingThumbnails: Set<UUID> = []
    @ObservationIgnored private let storage = DispatchQueue(label: "com.stackrover.klik.assets", qos: .utility)
    let folderURL: URL

    private static let indexFileName = "index.json"

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        folderURL = support.appendingPathComponent("Klik/Assets", isDirectory: true)
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        loadIndex()
    }

    // MARK: - Adding

    /// Copies the files in (synchronously: dropped files are readable only for the
    /// duration of the drop). Returns what was added.
    @discardableResult
    func add(fileURLs: [URL]) -> [AssetItem] {
        var added: [AssetItem] = []
        for url in fileURLs {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            let id = UUID()
            let destination = folderURL.appendingPathComponent(id.uuidString, isDirectory: true).appendingPathComponent(url.lastPathComponent)
            do {
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                let granted = url.startAccessingSecurityScopedResource()
                defer { if granted { url.stopAccessingSecurityScopedResource() } }
                try FileManager.default.copyItem(at: url, to: destination)
            } catch {
                Log.app.error("Assets: cannot copy \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                continue
            }
            added.append(register(id: id, at: destination))
        }
        return added
    }

    /// Saves raw image data (a picture dragged out of a browser, or pasted).
    @discardableResult
    func add(imageData data: Data, preferredName: String? = nil) -> AssetItem? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let id = UUID()
        let type = (CGImageSourceGetType(source) as String?).flatMap(UTType.init) ?? .png
        let isPNG = type.conforms(to: .png)
        let payload: Data
        let ext: String
        if isPNG || type.conforms(to: .jpeg) || type.conforms(to: .gif) || type.conforms(to: .heic) || type.conforms(to: .webP) {
            payload = data
            ext = type.preferredFilenameExtension ?? "png"
        } else {
            // TIFF and the like are re-encoded as PNG, which every app accepts.
            guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil), let png = ImageEncoding.png(cgImage) else { return nil }
            payload = png
            ext = "png"
        }
        let base = preferredName.map { ($0 as NSString).deletingPathExtension } ?? "Image \(Self.nameFormatter.string(from: .now))"
        let destination = folderURL.appendingPathComponent(id.uuidString, isDirectory: true).appendingPathComponent("\(base).\(ext)")
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try payload.write(to: destination, options: .atomic)
        } catch {
            Log.app.error("Assets: cannot save image: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        return register(id: id, at: destination)
    }

    /// Saves whatever is on the pasteboard: files first, else an image. Nil when there
    /// is neither.
    @discardableResult
    func addFromPasteboard(_ pasteboard: NSPasteboard = .general) -> [AssetItem]? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            let added = add(fileURLs: urls)
            return added.isEmpty ? nil : added
        }
        if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff), let item = add(imageData: data) {
            return [item]
        }
        return nil
    }

    private static let nameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter
    }()

    private func register(id: UUID, at url: URL) -> AssetItem {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        var item = AssetItem(id: id, fileName: url.lastPathComponent, kind: .file, byteSize: size, pixelWidth: 0, pixelHeight: 0, createdAt: .now)
        if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
           let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            item.kind = .image
            item.pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
            item.pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
            if let thumbnail = ImageEncoding.thumbnail(from: source) { thumbnails[id] = thumbnail }
        }
        items.insert(item, at: 0)
        saveIndex()
        Log.app.info("Assets: added \(item.fileName, privacy: .public)")
        return item
    }

    // MARK: - Using

    func fileURL(for item: AssetItem) -> URL {
        folderURL.appendingPathComponent(item.id.uuidString, isDirectory: true).appendingPathComponent(item.fileName)
    }

    /// Images go on the pasteboard as image data (paste into any editor); other files
    /// as a file URL (paste into Finder, attach in Mail…).
    func copy(_ item: AssetItem) {
        let url = fileURL(for: item)
        if item.kind == .image, let data = try? Data(contentsOf: url) {
            if UTType(filenameExtension: url.pathExtension)?.conforms(to: .png) == true {
                Clipboard.copy(pngData: data)
            } else if let source = CGImageSourceCreateWithData(data as CFData, nil), let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                Clipboard.copy(cgImage)
            }
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
    }

    func open(_ item: AssetItem) {
        NSWorkspace.shared.open(fileURL(for: item))
    }

    func reveal(_ item: AssetItem) {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL(for: item)])
    }

    func delete(_ item: AssetItem) {
        items.removeAll { $0.id == item.id }
        thumbnails[item.id] = nil
        saveIndex()
        let folder = folderURL.appendingPathComponent(item.id.uuidString, isDirectory: true)
        storage.async { try? FileManager.default.removeItem(at: folder) }
    }

    // MARK: - Thumbnails

    /// Images get a real thumbnail (loaded off the main thread); other files their
    /// Finder icon.
    func thumbnail(for item: AssetItem) -> NSImage? {
        _ = thumbnailVersion
        if let cached = thumbnails[item.id] { return cached }
        let url = fileURL(for: item)
        guard item.kind == .image else {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            thumbnails[item.id] = icon
            return icon
        }
        guard !loadingThumbnails.contains(item.id) else { return nil }
        loadingThumbnails.insert(item.id)
        let id = item.id
        storage.async { [weak self] in
            let image = ImageEncoding.thumbnail(at: url)
            Task { @MainActor in
                guard let self else { return }
                self.loadingThumbnails.remove(id)
                guard let image else { return }
                self.thumbnails[id] = image
                self.thumbnailVersion += 1
            }
        }
        return nil
    }

    // MARK: - Persistence

    private var indexURL: URL { folderURL.appendingPathComponent(Self.indexFileName) }

    private func loadIndex() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([AssetItem].self, from: data)
        else { return }
        items = decoded
    }

    private func saveIndex() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        let url = indexURL
        storage.async { try? data.write(to: url, options: .atomic) }
    }
}
