import CoreGraphics
import Foundation

/// Where a vertical-video app draws its own buttons and words over a video.
///
/// Shown over the preview only, never exported: it is a guide to where not to put the
/// important part of the picture, not part of the picture. The areas are approximate — each
/// app moves its buttons from one release to the next and between phones — and are taken
/// from the safe-zone guides the platforms and ad tools publish, rounded outwards, for a
/// 1080 × 1920 frame. They are fractions of the finished frame, top-left origin, the space
/// annotations and captions are placed in.
public enum SafeZonePlatform: String, CaseIterable, Codable, Sendable, Identifiable {
    case youTubeShorts, tikTok, instagramReels

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .youTubeShorts: "YouTube Shorts"
        case .tikTok: "TikTok"
        case .instagramReels: "Instagram Reels"
        }
    }

    /// One area the app covers, and what covers it.
    public struct Covered: Equatable, Sendable {
        public let rect: CGRect
        public let label: String
    }

    public var covered: [Covered] {
        switch self {
        case .youTubeShorts:
            [Covered(rect: CGRect(x: 0, y: 0, width: 1, height: 0.07), label: "Search and menu"),
             Covered(rect: CGRect(x: 0.86, y: 0.42, width: 0.14, height: 0.37), label: "Buttons"),
             Covered(rect: CGRect(x: 0, y: 0.79, width: 1, height: 0.21), label: "Title, channel and sound")]
        case .tikTok:
            [Covered(rect: CGRect(x: 0, y: 0, width: 1, height: 0.08), label: "Following and For You"),
             Covered(rect: CGRect(x: 0.87, y: 0.36, width: 0.13, height: 0.44), label: "Buttons"),
             Covered(rect: CGRect(x: 0, y: 0.8, width: 1, height: 0.2), label: "Caption, account and sound")]
        case .instagramReels:
            [Covered(rect: CGRect(x: 0, y: 0, width: 1, height: 0.11), label: "Reels and camera"),
             Covered(rect: CGRect(x: 0.88, y: 0.5, width: 0.12, height: 0.28), label: "Buttons"),
             Covered(rect: CGRect(x: 0, y: 0.78, width: 1, height: 0.22), label: "Caption, account and sound")]
        }
    }

    /// The part of the frame nothing covers: inside the bars at top and bottom, and left of
    /// the buttons.
    public var clear: CGRect {
        let areas = covered
        let top = areas.filter { $0.rect.minY == 0 && $0.rect.width == 1 }.map(\.rect.maxY).max() ?? 0
        let bottom = areas.filter { $0.rect.maxY >= 1 && $0.rect.width == 1 }.map(\.rect.minY).min() ?? 1
        let right = areas.filter { $0.rect.width < 1 }.map(\.rect.minX).min() ?? 1
        return CGRect(x: 0, y: top, width: right, height: bottom - top)
    }

    /// Whether the guides mean anything for a frame of this shape: 9:16, give or take the
    /// rounding of a size to even pixels. On any other shape the app letterboxes the video
    /// and its buttons land somewhere else.
    public static func applies(to size: CGSize) -> Bool {
        guard size.width > 0, size.height > 0 else { return false }
        return abs(size.width / size.height - 9.0 / 16.0) < 0.01
    }
}
