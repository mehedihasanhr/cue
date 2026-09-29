import AppKit
import ImageIO
import Observation
import UniformTypeIdentifiers

/// Wallpaper images: the macOS desktop pictures that ship with the system, plus files
/// the user picks. Loads are downsampled and cached; thumbnails come straight from
/// ImageIO so a picker stays snappy.
///
/// Shared by both editors. `@MainActor` because it publishes to views; the part the
/// renderer needs off the main actor is `WallpaperResolver`, which holds no state.
@MainActor
@Observable
public final class WallpaperCatalog {
    public static let shared = WallpaperCatalog()

    public init() {}

    nonisolated static let systemFolder = URL(fileURLWithPath: "/System/Library/Desktop Pictures", isDirectory: true)
    public static let maxRenderPixels = 2400
    private static let thumbnailPixels = 96

    /// Full-size renders are ~13 MB each; only the last few tried are worth keeping.
    @ObservationIgnored private var images = LRUCache<Wallpaper, CGImage>(capacity: 4)
    private var thumbnails: [Wallpaper: NSImage] = [:]

    nonisolated static let imageExtensions: Set<String> = ["heic", "jpg", "jpeg", "png"]

    /// The still (non-dynamic) desktop pictures installed on this Mac.
    ///
    /// One level deep, because the pictures the system ships are not all at the top:
    /// `Solid Colors/` is a folder, and a flat listing silently drops every one of them.
    /// The `.madesktop` stubs beside them are not images and are filtered out by
    /// extension.
    @ObservationIgnored public private(set) lazy var systemWallpapers: [Wallpaper] = {
        let manager = FileManager.default
        let top = (try? manager.contentsOfDirectory(at: Self.systemFolder,
                                                    includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        var found: [Wallpaper] = []
        for url in top {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory {
                let inside = (try? manager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
                found += inside
                    .filter { Self.imageExtensions.contains($0.pathExtension.lowercased()) }
                    .map { Wallpaper(name: "\(url.lastPathComponent)/\($0.lastPathComponent)", bookmark: nil) }
            } else if Self.imageExtensions.contains(url.pathExtension.lowercased()) {
                found.append(Wallpaper(name: url.lastPathComponent, bookmark: nil))
            }
        }
        return found.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }()

    /// Wallpapers the user added from disk this session (persisted in the document as bookmarks).
    public private(set) var customWallpapers: [Wallpaper] = []

    public func chooseCustomWallpaper() -> Wallpaper? {
        let panel = NSOpenPanel()
        panel.title = "Choose a background image"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url,
              let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        else { return nil }
        let wallpaper = Wallpaper(name: url.lastPathComponent, bookmark: bookmark)
        if !customWallpapers.contains(wallpaper) { customWallpapers.append(wallpaper) }
        return wallpaper
    }

    public func image(for wallpaper: Wallpaper) -> CGImage? {
        if let cached = images[wallpaper] { return cached }
        guard let image = load(wallpaper, maxPixels: Self.maxRenderPixels) else { return nil }
        images[wallpaper] = image
        return image
    }

    /// Decodes the full-size image off the main thread so selecting it doesn't stall the UI.
    public func prepare(_ wallpaper: Wallpaper) async {
        guard images[wallpaper] == nil, let url = url(for: wallpaper) else { return }
        let scoped = wallpaper.bookmark != nil
        let pixels = Self.maxRenderPixels
        if let image = await Task.detached(priority: .userInitiated, operation: { Self.decode(url: url, scoped: scoped, maxPixels: pixels) }).value {
            images[wallpaper] = image
        }
    }

    /// Cached only — decoding happens in `prepareThumbnails()` so the sidebar never
    /// blocks on HEIC decoding; call it early (app launch) and the picker opens instantly.
    public func thumbnail(for wallpaper: Wallpaper) -> NSImage? {
        thumbnails[wallpaper]
    }

    private var preparing = false

    /// Decodes every missing thumbnail off the main thread, then publishes them.
    public func prepareThumbnails() async {
        guard !preparing else { return }
        preparing = true
        defer { preparing = false }
        let pending = (customWallpapers + systemWallpapers).filter { thumbnails[$0] == nil }
        guard !pending.isEmpty else { return }
        let jobs = pending.compactMap { wallpaper in url(for: wallpaper).map { (wallpaper, $0) } }
        let pixels = Self.thumbnailPixels
        // Utility QoS keeps this on efficiency cores and off the battery.
        let decoded = await Task.detached(priority: .utility) { () -> [(Wallpaper, CGImage)] in
            jobs.compactMap { wallpaper, url in
                Self.decode(url: url, scoped: wallpaper.bookmark != nil, maxPixels: pixels).map { (wallpaper, $0) }
            }
        }.value
        for (wallpaper, image) in decoded {
            thumbnails[wallpaper] = NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
        }
    }

    private func load(_ wallpaper: Wallpaper, maxPixels: Int) -> CGImage? {
        guard let url = url(for: wallpaper) else { return nil }
        return Self.decode(url: url, scoped: wallpaper.bookmark != nil, maxPixels: maxPixels)
    }

    nonisolated static func decode(url: URL, scoped: Bool, maxPixels: Int) -> CGImage? {
        let granted = scoped && url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    func url(for wallpaper: Wallpaper) -> URL? {
        if let bookmark = wallpaper.bookmark {
            var stale = false
            return try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
        }
        return Self.systemFolder.appendingPathComponent(wallpaper.name)
    }
}
