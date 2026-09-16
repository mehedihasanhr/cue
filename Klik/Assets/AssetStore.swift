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
    /// Kept at the top of the list and by "Clear".
    var pinned = false

    private enum CodingKeys: String, CodingKey { case id, fileName, kind, byteSize, pixelWidth, pixelHeight, createdAt, pinned }

    init(id: UUID, fileName: String, kind: Kind, byteSize: Int, pixelWidth: Int, pixelHeight: Int, createdAt: Date) {
        self.id = id
        self.fileName = fileName
        self.kind = kind
        self.byteSize = byteSize
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.createdAt = createdAt
    }

    /// Indexes written before pinning existed have no `pinned` key.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        fileName = try container.decode(String.self, forKey: .fileName)
        kind = try container.decode(Kind.self, forKey: .kind)
        byteSize = try container.decode(Int.self, forKey: .byteSize)
        pixelWidth = try container.decode(Int.self, forKey: .pixelWidth)
        pixelHeight = try container.decode(Int.self, forKey: .pixelHeight)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        pinned = try container.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
    }

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
        if Self.isImageType(url) {
            item.kind = .image
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0,
               let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
                item.pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
                item.pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
                if let thumbnail = ImageEncoding.thumbnail(from: source) { thumbnails[id] = thumbnail }
            } else if let rendered = ImageEncoding.rasterised(at: url, maxPixels: 320) {
                // SVG and friends: ImageIO cannot decode them, AppKit can.
                item.pixelWidth = Int(rendered.size.width)
                item.pixelHeight = Int(rendered.size.height)
                thumbnails[id] = rendered.image
            }
        }
        items.insert(item, at: 0)
        saveIndex()
        Log.app.info("Assets: added \(item.fileName, privacy: .public)")
        return item
    }

    /// Anything the system calls an image, including vector formats such as SVG.
    private static func isImageType(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
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
                return
            }
            if let source = CGImageSourceCreateWithData(data as CFData, nil), let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                Clipboard.copy(cgImage)
                return
            }
            // A vector (SVG): the file itself, plus a Retina-sized bitmap for image-only targets.
            if let rendered = ImageEncoding.rasterise(at: url, maxPixels: Int(max(item.pixelWidth, item.pixelHeight, 1) * 2)) {
                Clipboard.copy(rendered.image, fileURL: url)
                return
            }
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
    }

    /// Renames the file (its extension is kept).
    func rename(_ item: AssetItem, to title: String) {
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        guard !cleaned.isEmpty, cleaned != item.title, let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        let ext = (item.fileName as NSString).pathExtension
        let newName = ext.isEmpty ? cleaned : "\(cleaned).\(ext)"
        let source = fileURL(for: item)
        let destination = source.deletingLastPathComponent().appendingPathComponent(newName)
        do {
            try FileManager.default.moveItem(at: source, to: destination)
        } catch {
            Log.app.error("Assets: cannot rename: \(error.localizedDescription, privacy: .public)")
            return
        }
        items[index].fileName = newName
        saveIndex()
    }

    func open(_ item: AssetItem) {
        NSWorkspace.shared.open(fileURL(for: item))
    }

    func reveal(_ item: AssetItem) {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL(for: item)])
    }

    func togglePin(_ item: AssetItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].pinned.toggle()
        saveIndex()
    }

    func delete(_ item: AssetItem) {
        items.removeAll { $0.id == item.id }
        thumbnails[item.id] = nil
        saveIndex()
        removeFolder(of: item)
    }

    /// Removes everything except pinned items.
    func clear() {
        let removed = items.filter { !$0.pinned }
        items.removeAll { !$0.pinned }
        for item in removed { thumbnails[item.id] = nil }
        saveIndex()
        removed.forEach(removeFolder)
    }

    private func removeFolder(of item: AssetItem) {
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
        let needsSize = item.pixelWidth == 0
        storage.async { [weak self] in
            var image = ImageEncoding.thumbnail(at: url)
            var size: CGSize?
            if needsSize, let rendered = ImageEncoding.rasterised(at: url, maxPixels: 320) {
                image = image ?? rendered.image
                size = rendered.size
            }
            Task { @MainActor in
                guard let self else { return }
                self.loadingThumbnails.remove(id)
                guard let image else { return }
                self.thumbnails[id] = image
                self.thumbnailVersion += 1
                // Vectors registered before Klik could size them.
                if let size, let index = self.items.firstIndex(where: { $0.id == id }), self.items[index].pixelWidth == 0 {
                    self.items[index].pixelWidth = Int(size.width)
                    self.items[index].pixelHeight = Int(size.height)
                    self.saveIndex()
                }
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
        // SVGs and other vectors stored before they counted as images.
        var upgraded = false
        for index in items.indices where items[index].kind == .file && Self.isImageType(fileURL(for: items[index])) {
            items[index].kind = .image
            upgraded = true
        }
        if upgraded { saveIndex() }
    }

    private func saveIndex() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        let url = indexURL
        storage.async { try? data.write(to: url, options: .atomic) }
    }
}
