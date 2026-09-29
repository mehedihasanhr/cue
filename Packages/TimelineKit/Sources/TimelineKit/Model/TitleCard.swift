import Foundation

/// The words on a title slide, and how they are set.
///
/// A slide has no footage, so everything it shows is here or in the project's own look:
/// the background, the padding, the corners and the shadow come from `FrameStyle`, exactly
/// as they frame the recording, so a title in the middle of a video looks like part of
/// the same video rather than a card from somewhere else.
///
/// Sizes are fractions of the picture's height rather than points, like a caption's, so a
/// title reads the same at 1080p, at 4K and in a vertical reframe.
public struct TitleCard: Equatable, Codable, Sendable {
    /// Where the words sit in the picture.
    public enum Layout: String, Codable, Sendable, CaseIterable {
        /// In the middle, centred: an opening title.
        case centred
        /// Against the left edge, halfway down: a chapter heading.
        case left
        /// Low and to the left: the name of the person or the thing about to be shown.
        case lowerThird

        public var title: String {
            switch self {
            case .centred: "Centred"
            case .left: "Left"
            case .lowerThird: "Lower Third"
            }
        }
    }

    /// What the words are set on.
    public enum Backdrop: String, Codable, Sendable, CaseIterable {
        /// The project's own background, with nothing in the picture's place.
        case background
        /// A plain panel where the recording would be, with the recording's corners,
        /// shadow and border — so the slide sits in the frame the way the footage does.
        case panel

        public var title: String {
            switch self {
            case .background: "Background"
            case .panel: "Panel"
            }
        }
    }

    /// How the words arrive.
    public enum Entrance: String, Codable, Sendable, CaseIterable {
        case none, fade, rise

        public var title: String {
            switch self {
            case .none: "None"
            case .fade: "Fade In"
            case .rise: "Rise"
            }
        }
    }

    public var title: String
    /// A second, smaller line under the title. Empty draws nothing.
    public var subtitle: String
    public var layout: Layout
    public var backdrop: Backdrop
    public var entrance: Entrance
    /// The title's size, as a fraction of the picture's height. The subtitle is set at a
    /// fixed proportion of it, so the two cannot be sized into a muddle.
    public var size: Double
    public var textColor: ColorValue
    /// The panel's colour, when the backdrop is a panel.
    public var panelColor: ColorValue
    public var typeface: CaptionStyle.Typeface
    /// A family chosen by name, set in place of `typeface`; empty for the system's own
    /// type. One this Mac does not have falls back to `typeface`.
    public var fontFamily: String

    public static let minimumSize = 0.03
    public static let maximumSize = 0.2
    /// How long the entrance takes, in seconds. Long enough to be seen as an arrival,
    /// short enough to be over before anyone has started reading.
    public static let entranceLength = 0.6

    public init(title: String = "Title",
                subtitle: String = "",
                layout: Layout = .centred,
                backdrop: Backdrop = .background,
                entrance: Entrance = .fade,
                size: Double = 0.09,
                textColor: ColorValue = .white,
                panelColor: ColorValue = ColorValue(r: 0.98, g: 0.98, b: 0.97),
                typeface: CaptionStyle.Typeface = .standard,
                fontFamily: String = "") {
        self.title = title
        self.subtitle = subtitle
        self.layout = layout
        self.backdrop = backdrop
        self.entrance = entrance
        self.size = size
        self.textColor = textColor
        self.panelColor = panelColor
        self.typeface = typeface
        self.fontFamily = fontFamily
    }

    /// The size, held to what can be drawn. A file can ask for a title four times the
    /// height of the picture.
    public var sanitisedSize: Double {
        size.isFinite ? min(Self.maximumSize, max(Self.minimumSize, size)) : 0.09
    }

    /// How far through its entrance the card is, `elapsed` seconds into the slide:
    /// the words' opacity, and how far below their place they are drawn as a fraction of
    /// the title's size.
    ///
    /// Out fast and easing to rest, as the captions arrive, so a slide and a caption in
    /// the same video move alike.
    public func pose(elapsed: Double) -> (opacity: Double, drop: Double) {
        guard entrance != .none else { return (1, 0) }
        let progress = min(1, max(0, elapsed / Self.entranceLength))
        let eased = 1 - pow(1 - progress, 3)
        switch entrance {
        case .none: return (1, 0)
        case .fade: return (eased, 0)
        case .rise: return (eased, (1 - eased) * 0.5)
        }
    }

    // MARK: - Reading a project back

    private enum CodingKeys: String, CodingKey {
        case title, subtitle, layout, backdrop, entrance, size, textColor, panelColor, typeface, fontFamily
    }

    /// Field by field, each falling back to its default on its own — the rule every part
    /// of a project is read by. A layout a newer build added costs the layout, not the
    /// words.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, default fallback: T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        let defaults = TitleCard()
        self.init(title: value(.title, default: defaults.title),
                  subtitle: value(.subtitle, default: defaults.subtitle),
                  layout: value(.layout, default: defaults.layout),
                  backdrop: value(.backdrop, default: defaults.backdrop),
                  entrance: value(.entrance, default: defaults.entrance),
                  size: value(.size, default: defaults.size),
                  textColor: value(.textColor, default: defaults.textColor),
                  panelColor: value(.panelColor, default: defaults.panelColor),
                  typeface: value(.typeface, default: defaults.typeface),
                  fontFamily: value(.fontFamily, default: defaults.fontFamily))
    }
}
