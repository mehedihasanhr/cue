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
        case cue
        /// A desktop picture shipped with macOS, by file name.
        case system
        /// A file the user picked, by bookmark id.
        case user
    }

    public let rawValue: String

    public init?(rawValue: String) {
        guard let separator = rawValue.firstIndex(of: ":") else { return nil }
        var namespace = String(rawValue[rawValue.startIndex..<separator])
        let name = rawValue[rawValue.index(after: separator)...]
        // Saved before the app was renamed from Klik to Cue.
        if namespace == "klik" { namespace = Namespace.cue.rawValue }
        guard Namespace(rawValue: namespace) != nil, !name.isEmpty else { return nil }
        self.rawValue = "\(namespace):\(name)"
    }

    public init(_ namespace: Namespace, _ name: some StringProtocol) {
        rawValue = "\(namespace.rawValue):\(name)"
    }

    public var namespace: Namespace {
        // Safe: `init?` rejects anything without a known namespace.
        Namespace(rawValue: String(rawValue.prefix(while: { $0 != ":" }))) ?? .cue
    }

    /// Everything after the colon. A system picture's name may contain a slash.
    public var name: String {
        guard let separator = rawValue.firstIndex(of: ":") else { return rawValue }
        return String(rawValue[rawValue.index(after: separator)...])
    }

    public var description: String { rawValue }

    public static func preset(_ gradient: GradientPreset) -> WallpaperID {
        WallpaperID(.cue, gradient.rawValue)
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
