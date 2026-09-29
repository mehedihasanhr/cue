import Foundation

/// A stable, namespaced name for a background.
///
/// This is what a document stores. Not a path — a system desktop picture lives at a
/// version-specific location and a user's file needs a grant, so neither is portable —
/// and not a colour pair, because a generated gradient has as many stops as it likes.
/// An id is also the only payload that round-trips *which swatch is selected*, which is
/// what makes a picker show a ring around the right one a month later.
public struct WallpaperID: Hashable, Codable, Sendable, RawRepresentable, CustomStringConvertible {
    public enum Namespace: String, Sendable, CaseIterable {
        /// A gradient this app generates, by preset name.
        case klik
        /// A desktop picture shipped with macOS, by file name.
        case system
        /// A file the user picked, by bookmark id.
        case user
    }

    public let rawValue: String

    public init?(rawValue: String) {
        guard let separator = rawValue.firstIndex(of: ":") else { return nil }
        let namespace = String(rawValue[rawValue.startIndex..<separator])
        guard Namespace(rawValue: namespace) != nil else { return nil }
        guard rawValue.index(after: separator) < rawValue.endIndex else { return nil }
        self.rawValue = rawValue
    }

    public init(_ namespace: Namespace, _ name: some StringProtocol) {
        rawValue = "\(namespace.rawValue):\(name)"
    }

    public var namespace: Namespace {
        // Safe: `init?` rejects anything without a known namespace.
        Namespace(rawValue: String(rawValue.prefix(while: { $0 != ":" }))) ?? .klik
    }

    /// Everything after the colon. A system picture's name may contain a slash.
    public var name: String {
        guard let separator = rawValue.firstIndex(of: ":") else { return rawValue }
        return String(rawValue[rawValue.index(after: separator)...])
    }

    public var description: String { rawValue }

    public static func preset(_ gradient: GradientPreset) -> WallpaperID {
        WallpaperID(.klik, gradient.rawValue)
    }

    public static func system(_ wallpaper: Wallpaper) -> WallpaperID {
        WallpaperID(.system, wallpaper.name)
    }
}

/// What an id turns out to be: something to generate, or something to open.
public enum WallpaperSource: Hashable, Sendable {
    case procedural(GradientPreset)
    case file(URL)
}
