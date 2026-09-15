import os
import AppKit
import Observation

/// Everything copied on this Mac, newest first: text, links, colours, images and
/// files. Watches the pasteboard by polling its change count (there is no
/// notification), records which app copied it, and keeps the list bounded. Stored in
/// the app container (Application Support/Klik/Clipboard): the index as JSON, images
/// as PNG files.
@Observable
final class ClipboardHistory {
    private(set) var items: [ClipboardItem] = []
    var limit = 200 {
        didSet { trim(); saveIndex() }
    }

    @ObservationIgnored private var thumbnails: [UUID: NSImage] = [:]
    @ObservationIgnored private var icons: [String: NSImage] = [:]
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastChangeCount: Int
    @ObservationIgnored private let storage = DispatchQueue(label: "com.stackrover.klik.clipboard", qos: .utility)
    private let folderURL: URL

    /// Pasteboard types that ask not to be recorded (password managers, transient data).
    private static let concealedTypes: [NSPasteboard.PasteboardType] = [
        NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
        NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
        NSPasteboard.PasteboardType("com.agilebits.onepassword"),
    ]
    private static let maxTextLength = 200_000
    private static let pollInterval: TimeInterval = 0.5

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        folderURL = support.appendingPathComponent("Klik/Clipboard", isDirectory: true)
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        lastChangeCount = NSPasteboard.general.changeCount
        loadIndex()
    }

    // MARK: - Watching

    var isWatching: Bool { timer != nil }

    func startWatching() {
        guard timer == nil else { return }
        lastChangeCount = NSPasteboard.general.changeCount
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        Log.app.info("Clipboard history: watching")
    }

    func stopWatching() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let pasteboard = NSPasteboard.general
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        record(pasteboard)
    }

    /// Reads whatever is on the pasteboard now and stores it (unless it is marked as
    /// concealed, is one of Klik's own capture copies, or repeats the newest item).
    private func record(_ pasteboard: NSPasteboard) {
        let types = pasteboard.types ?? []
        guard !types.contains(where: Self.concealedTypes.contains), !types.contains(Clipboard.ownMarker) else { return }
        let source = NSWorkspace.shared.frontmostApplication

        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            let paths = urls.map { $0.path(percentEncoded: false) }
            add(ClipboardItem(kind: .files, text: paths.joined(separator: "\n"),
                              sourceBundleID: source?.bundleIdentifier, sourceName: source?.localizedName))
            return
        }
        if let string = pasteboard.string(forType: .string), !string.isEmpty {
            let (kind, text) = ClipboardItem.classify(String(string.prefix(Self.maxTextLength)))
            add(ClipboardItem(kind: kind, text: text, sourceBundleID: source?.bundleIdentifier, sourceName: source?.localizedName))
            return
        }
        let pngData = pasteboard.data(forType: .png)
        guard let data = pngData ?? pasteboard.data(forType: .tiff),
              let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return }
        let item = ClipboardItem(kind: .image, text: "Image", pixelWidth: width, pixelHeight: height,
                                 sourceBundleID: source?.bundleIdentifier, sourceName: source?.localizedName)
        let url = folderURL.appendingPathComponent(item.fileName)
        if let thumbnail = ImageEncoding.thumbnail(from: imageSource) { thumbnails[item.id] = thumbnail }
        let isPNG = pngData != nil
        storage.async {
            // TIFF is re-encoded as PNG off the main thread; `data` travels, not the source.
            let png = isPNG ? data : CGImageSourceCreateWithData(data as CFData, nil)
                .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
                .flatMap(ImageEncoding.png)
            guard let png else { return }
            try? png.write(to: url, options: .atomic)
        }
        add(item)
    }

    private func add(_ item: ClipboardItem) {
        if let newest = items.first, newest.kind == item.kind, newest.text == item.text, item.kind != .image {
            // Same thing copied again: just refresh its time.
            items[0].createdAt = item.createdAt
            saveIndex()
            return
        }
        items.insert(item, at: 0)
        trim()
        saveIndex()
    }

    // MARK: - Actions

    /// Puts the item back on the pasteboard (without recording it again) and moves it
    /// to the top, like a fresh copy.
    func copy(_ item: ClipboardItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        switch item.kind {
        case .text, .link, .color:
            pasteboard.setString(item.text, forType: .string)
        case .files:
            pasteboard.writeObjects(item.filePaths.map { URL(fileURLWithPath: $0) as NSURL })
        case .image:
            if let data = try? Data(contentsOf: folderURL.appendingPathComponent(item.fileName)) {
                pasteboard.setData(data, forType: .png)
            }
        }
        lastChangeCount = pasteboard.changeCount
        if let index = items.firstIndex(of: item), index > 0 {
            var moved = items.remove(at: index)
            moved.createdAt = .now
            items.insert(moved, at: 0)
            saveIndex()
        }
    }

    func togglePin(_ item: ClipboardItem) {
        guard let index = items.firstIndex(of: item) else { return }
        items[index].pinned.toggle()
        saveIndex()
    }

    func delete(_ item: ClipboardItem) {
        items.removeAll { $0.id == item.id }
        thumbnails[item.id] = nil
        removeFiles(of: [item])
        saveIndex()
    }

    /// Removes everything except pinned items.
    func clear() {
        let removed = items.filter { !$0.pinned }
        items.removeAll { !$0.pinned }
        for item in removed { thumbnails[item.id] = nil }
        removeFiles(of: removed)
        saveIndex()
    }

    private func removeFiles(of removed: [ClipboardItem]) {
        let urls = removed.filter { $0.kind == .image }.map { folderURL.appendingPathComponent($0.fileName) }
        guard !urls.isEmpty else { return }
        storage.async { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
    }

    // MARK: - Images & icons

    func thumbnail(for item: ClipboardItem) -> NSImage? {
        if let cached = thumbnails[item.id] { return cached }
        guard item.kind == .image else { return nil }
        let thumbnail = ImageEncoding.thumbnail(at: folderURL.appendingPathComponent(item.fileName))
        thumbnails[item.id] = thumbnail
        return thumbnail
    }

    /// Decodes uncached image thumbnails off the main thread.
    func warmThumbnails(limit: Int = 40) {
        let work = items.prefix(limit).filter { $0.kind == .image && thumbnails[$0.id] == nil }
            .map { ($0.id, folderURL.appendingPathComponent($0.fileName)) }
        guard !work.isEmpty else { return }
        storage.async { [weak self] in
            for (id, url) in work {
                guard let image = ImageEncoding.thumbnail(at: url) else { continue }
                Task { @MainActor in
                    guard let self, self.thumbnails[id] == nil else { return }
                    self.thumbnails[id] = image
                }
            }
        }
    }

    /// The icon of the app the item was copied from.
    func sourceIcon(for item: ClipboardItem) -> NSImage? {
        guard let bundleID = item.sourceBundleID else { return nil }
        if let cached = icons[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icons[bundleID] = icon
        return icon
    }

    // MARK: - Persistence

    private var indexURL: URL { folderURL.appendingPathComponent("index.json") }

    /// Pinned items survive; the oldest unpinned ones go.
    private func trim() {
        guard items.count > limit else { return }
        let keepUnpinned = max(0, limit - items.filter(\.pinned).count)
        var unpinnedSeen = 0
        var removed: [ClipboardItem] = []
        items = items.filter { item in
            if item.pinned { return true }
            unpinnedSeen += 1
            if unpinnedSeen <= keepUnpinned { return true }
            removed.append(item)
            return false
        }
        for item in removed { thumbnails[item.id] = nil }
        removeFiles(of: removed)
    }

    private func loadIndex() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([ClipboardItem].self, from: data)
        else { return }
        items = decoded
    }

    private func saveIndex() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        let url = indexURL
        storage.async { try? data.write(to: url, options: .atomic) }
    }
}
