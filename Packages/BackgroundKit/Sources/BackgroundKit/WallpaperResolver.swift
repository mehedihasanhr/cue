import Foundation

/// Turning an id into something drawable, without a UI.
///
/// `Sendable` and free of AppKit state on purpose: the preview resolves on the main
/// actor and the exporter will resolve off it, and if those two ever disagreed the
/// export would not be the thing the user approved.
public struct WallpaperResolver: Sendable {
    public static let shared = WallpaperResolver()

    private let bookmarks: WallpaperBookmarks

    public init(bookmarks: WallpaperBookmarks = .shared) {
        self.bookmarks = bookmarks
    }

    public func source(for id: WallpaperID) -> WallpaperSource? {
        switch id.namespace {
        case .klik:
            return GradientPreset(rawValue: id.name).map(WallpaperSource.procedural)
        case .system:
            let url = WallpaperCatalog.systemFolder.appendingPathComponent(id.name)
            return FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
                ? .file(url) : nil
        case .user:
            // A user picture is copied into the project, so an id in this namespace is
            // only ever a recent in the picker — never something a document depends on.
            guard let data = Data(base64Encoded: id.name),
                  let url = WallpaperBookmarks.resolve(data) else { return nil }
            return .file(url)
        }
    }

    /// Runs `body` with whatever grant the source needs, if any.
    public func withAccess<T, E: Error>(to source: WallpaperSource, _ body: (URL?) throws(E) -> T) throws(E) -> T {
        switch source {
        case .procedural:
            return try body(nil)
        case .file(let url):
            return try WallpaperBookmarks.withAccess(to: url, body)
        }
    }
}
