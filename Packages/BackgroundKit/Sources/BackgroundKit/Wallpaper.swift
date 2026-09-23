import Foundation

/// A background picture: one of the system desktop pictures (by file name) or a
/// user file (security-scoped bookmark).
public struct Wallpaper: Hashable, Codable, Sendable {
    /// Relative to the system wallpaper folder, so it may contain a subfolder —
    /// `Solid Colors/Black.png`. Ignored entirely when `bookmark` is set.
    public var name: String
    public var bookmark: Data?

    public init(name: String, bookmark: Data? = nil) {
        self.name = name
        self.bookmark = bookmark
    }

    /// What to call it in a picker: the file's own name, without folder or extension.
    public var title: String {
        ((name as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    public var isCustom: Bool { bookmark != nil }
}
