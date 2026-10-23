import Foundation
import os

/// The files a user has picked as backgrounds, remembered between projects.
///
/// Recents for a picker, not document state: a project stores its own copy of whatever
/// image it uses, so nothing here is needed to open one. Lifted from the host app's
/// `StudioPreferences` rather than rewritten, including the deliberate choice to let a
/// stale bookmark still resolve.
public struct WallpaperBookmarks: Sendable {
    public static let shared = WallpaperBookmarks()

    /// How many recent pictures to offer. Enough to find last week's, few enough that
    /// the row does not become a second library.
    public static let limit = 12

    private let key = "background.recents"
    /// Named rather than held: `UserDefaults` is thread-safe but not `Sendable`, and
    /// this has to cross actors with the resolver.
    private let suiteName: String?

    public init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults {
        suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    public var recents: [Data] {
        (defaults.array(forKey: key) as? [Data]) ?? []
    }

    /// Bookmarks a URL and moves it to the front of the list.
    @discardableResult
    public func remember(_ url: URL) -> Data? {
        guard let bookmark = Self.bookmark(url) else { return nil }
        var stored = recents.filter { Self.resolve($0)?.standardizedFileURL != url.standardizedFileURL }
        stored.insert(bookmark, at: 0)
        defaults.set(Array(stored.prefix(Self.limit)), forKey: key)
        return bookmark
    }

    public func forget(_ bookmark: Data) {
        defaults.set(recents.filter { $0 != bookmark }, forKey: key)
    }

    /// The recents that still point at something, newest first.
    public func resolvedRecents() -> [(bookmark: Data, url: URL)] {
        recents.compactMap { bookmark in
            Self.resolve(bookmark).map { (bookmark, $0) }
        }
    }

    public static func bookmark(_ url: URL) -> Data? {
        do {
            return try url.bookmarkData(options: .withSecurityScope,
                                        includingResourceValuesForKeys: nil,
                                        relativeTo: nil)
        } catch {
            log.error("Could not bookmark \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    public static func resolve(_ bookmark: Data) -> URL? {
        var stale = false
        // A stale bookmark still resolves; the file moved, and re-picking it is the
        // user's next action, not something to do silently behind them.
        return try? URL(resolvingBookmarkData: bookmark,
                        options: .withSecurityScope,
                        relativeTo: nil,
                        bookmarkDataIsStale: &stale)
    }

    /// Runs `body` with access to a bookmarked location.
    ///
    /// Sandboxed access to a user-picked file has to be opened and closed around each
    /// use; forgetting the close leaks a grant for the life of the process.
    public static func withAccess<T, E: Error>(to url: URL?, _ body: (URL?) throws(E) -> T) throws(E) -> T {
        guard let url else { return try body(nil) }
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        return try body(url)
    }

    private static let log = Logger(subsystem: "com.stackrover.cue", category: "backgrounds")
}
