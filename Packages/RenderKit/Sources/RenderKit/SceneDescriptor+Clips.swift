import CoreGraphics
import CoreMedia
import Foundation
import TimelineKit

/// A title slide's words, as one frame shows them.
///
/// Laid out by the renderer inside the frame the recording would occupy — `videoFrame` —
/// so a title sits where the footage sits, inside the project's padding, and a vertical
/// reframe moves the words exactly as it moves the picture. Everything here is a fraction
/// or a colour; nothing is in pixels, so `SceneDescriptor.scaled(by:)` has nothing to do.
public struct TitleLayer: Equatable, Sendable {
    public var title: String
    public var subtitle: String
    public var layout: TitleCard.Layout
    public var textColor: ColorValue
    /// The panel drawn where the recording would be, or `nil` for the words straight on
    /// the background.
    public var panelColor: ColorValue?
    public var typeface: CaptionStyle.Typeface
    /// A family by name, in place of `typeface`; empty for the system's type.
    public var fontFamily: String
    /// The title's size, as a fraction of the picture's height.
    public var size: Double
    /// The words' opacity, from the entrance.
    public var opacity: Double
    /// How far below their place the words are drawn, as a fraction of the title's size.
    public var drop: Double

    public init(title: String,
                subtitle: String = "",
                layout: TitleCard.Layout = .centred,
                textColor: ColorValue = .white,
                panelColor: ColorValue? = nil,
                typeface: CaptionStyle.Typeface = .standard,
                size: Double = 0.09,
                opacity: Double = 1,
                drop: Double = 0,
                fontFamily: String = "") {
        self.title = title
        self.subtitle = subtitle
        self.layout = layout
        self.textColor = textColor
        self.panelColor = panelColor
        self.typeface = typeface
        self.fontFamily = fontFamily
        self.size = size
        self.opacity = opacity
        self.drop = drop
    }

    /// A card as it looks `elapsed` seconds after its slide begins.
    public init(_ card: TitleCard, elapsed: Double) {
        let pose = card.pose(elapsed: elapsed)
        self.init(title: card.title,
                  subtitle: card.subtitle,
                  layout: card.layout,
                  textColor: card.textColor,
                  panelColor: card.backdrop == .panel ? card.panelColor : nil,
                  typeface: card.typeface,
                  size: card.sanitisedSize,
                  opacity: pose.opacity,
                  drop: pose.drop,
                  fontFamily: card.fontFamily)
    }
}

/// How a frame inside a transition is mixed with something else.
///
/// Indirect because a crossfade carries the whole of the other frame, described exactly
/// as any frame is — the other clip's picture, pointer, camera bubble — so the renderer
/// draws it with the code that draws every frame and mixes the two. Nothing about the
/// other side is drawn by a second path.
public indirect enum SceneBlend: Equatable, Sendable {
    /// Towards black, or towards the project's background, by `amount` (0…1).
    case dip(amount: Double, toBackground: Bool)
    /// Mixed with another frame, which counts for `amount` (0…1) of the result.
    case crossfade(SceneDescriptor, amount: Double)

    func scaled(by factor: Double) -> SceneBlend {
        switch self {
        case .dip: self
        case .crossfade(let other, let amount): .crossfade(other.scaled(by: factor), amount: amount)
        }
    }
}

extension SceneDescriptor {
    /// The other frame a crossfade mixes this one with, when it does.
    ///
    /// What every caller that reads frames out of the recording asks, so it can fetch the
    /// other side's picture at `sourceTime` and hand it to the renderer beside this one's.
    public var blendedScene: SceneDescriptor? {
        guard case .crossfade(let other, _) = blend else { return nil }
        return other
    }

    /// Whether this frame draws the recording at all. A title slide does not, so a caller
    /// need not read a frame for it.
    public var showsRecording: Bool { title == nil }
}
