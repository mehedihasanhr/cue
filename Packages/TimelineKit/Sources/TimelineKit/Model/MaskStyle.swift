import CoreMedia
import Foundation

public extension BlurRegion.Style {
    /// What the chip, the inspector and the menu call this kind.
    var title: String {
        switch self {
        case .gaussian: "Blur"
        case .pixelate: "Pixelate"
        case .cover: "Cover"
        case .spotlight: "Spotlight"
        }
    }

    /// One sentence on what it does, for the inspector.
    var hint: String {
        switch self {
        case .gaussian: "Softens what is under it so it cannot be read."
        case .pixelate: "Turns what is under it into blocks."
        case .cover: "Paints over it. The only kind nothing can see through."
        case .spotlight: "Leaves this alone and dims everything else in the picture."
        }
    }

    /// Whether this kind hides what is under it. A spotlight is the one that does not:
    /// it is about what is *outside* the rectangle.
    var hides: Bool { self != .spotlight }

    /// The word for the strength slider, where the kind has one.
    var strengthTitle: String? {
        switch self {
        case .gaussian, .pixelate: "Strength"
        case .cover, .spotlight: nil
        }
    }
}

public extension BlurRegion {
    /// The same region at another time and with a new identity — for a paste, a
    /// duplicate, a copy of the footage it sits on.
    ///
    /// One place that lists every field, so a kind added later cannot be forgotten by one
    /// of the three copies: before this the pasteboard rebuilt a region from its rect,
    /// its kind and its radius, and a cover pasted somewhere else would have come out
    /// black whatever colour it was.
    func placed(at start: CMTime, duration: CMTime) -> BlurRegion {
        BlurRegion(start: start, duration: duration, rect: rect, style: style, radius: radius,
                   color: color, dimming: dimming, softness: softness, cornerRadius: cornerRadius,
                   path: path)
    }

    /// What the chip on the timeline says.
    var title: String { style.title }
}
