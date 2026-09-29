import Foundation

/// How an annotation is drawn, beyond its colour and its size of type.
///
/// One value rather than seven loose fields on `AnnotationItem`, so everything that has to
/// carry "how it looks" — a copy, a paste, the renderer's cache key — carries all of it by
/// naming one thing. A field added here later travels with every copy without anybody
/// having to remember the copy.
///
/// **The defaults are the old look.** Every default below is what an annotation drew
/// before it could be told otherwise, so a project written then opens exactly as it was.
/// Not every setting means something for every kind — a fill is for a box or an ellipse,
/// a backdrop is for words — and the ones that do not apply are simply not read.
public struct AnnotationStyle: Codable, Hashable, Sendable {
    public enum Fill: String, Codable, Sendable, CaseIterable {
        case none, solid, translucent

        public var title: String {
            switch self {
            case .none: "None"
            case .solid: "Solid"
            case .translucent: "Translucent"
            }
        }
    }

    public enum Weight: String, Codable, Sendable, CaseIterable {
        case regular, semibold, bold

        public var title: String {
            switch self {
            case .regular: "Regular"
            case .semibold: "Semibold"
            case .bold: "Bold"
            }
        }
    }

    /// What sits behind the words.
    public enum Backdrop: String, Codable, Sendable, CaseIterable {
        case none
        /// A soft dark plate, for words over a light or busy picture.
        case dark
        /// A soft light plate, for words over a dark one.
        case light
        /// A plate in the annotation's own colour, with the words in black or white —
        /// whichever reads on it.
        case solid

        public var title: String {
            switch self {
            case .none: "None"
            case .dark: "Soft Dark"
            case .light: "Soft Light"
            case .solid: "Solid"
            }
        }
    }

    public enum Alignment: String, Codable, Sendable, CaseIterable {
        case left, center, right

        public var title: String {
            switch self {
            case .left: "Left"
            case .center: "Centre"
            case .right: "Right"
            }
        }
    }

    /// How thick outlines, lines and arrows are, as a multiple of the kind's own standard
    /// line. A multiple rather than a width so that 1 is, exactly, the line every box and
    /// arrow was drawn with before this existed.
    public var thickness: Double
    /// Inside a box or an ellipse.
    public var fill: Fill
    public var weight: Weight
    public var backdrop: Backdrop
    /// A ring round every letter in black or white, for words over something busy.
    public var outlinesText: Bool
    public var alignment: Alignment
    /// A soft drop shadow under whatever is drawn.
    public var hasShadow: Bool
    /// The family the words are set in, by name, or empty for the system's own type.
    ///
    /// A name rather than a file, so the project means the same font on another Mac; one
    /// that Mac does not have is drawn in the system's type rather than not at all.
    public var fontFamily: String

    public static let thicknessRange: ClosedRange<Double> = 0.25...8

    public init(thickness: Double = 1,
                fill: Fill = .none,
                weight: Weight = .semibold,
                backdrop: Backdrop = .none,
                outlinesText: Bool = false,
                alignment: Alignment = .left,
                hasShadow: Bool = false,
                fontFamily: String = "") {
        self.thickness = thickness
        self.fill = fill
        self.weight = weight
        self.backdrop = backdrop
        self.outlinesText = outlinesText
        self.alignment = alignment
        self.hasShadow = hasShadow
        self.fontFamily = fontFamily
        sanitise()
    }

    /// Field by field, so a setting this version does not know — a fill added next year,
    /// read by this one — costs that setting and not the annotation.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, default fallback: @autoclosure () -> T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback()
        }
        thickness = value(.thickness, default: 1)
        fill = value(.fill, default: .none)
        weight = value(.weight, default: .semibold)
        backdrop = value(.backdrop, default: .none)
        outlinesText = value(.outlinesText, default: false)
        alignment = value(.alignment, default: .left)
        hasShadow = value(.hasShadow, default: false)
        fontFamily = value(.fontFamily, default: "")
        sanitise()
    }

    enum CodingKeys: String, CodingKey {
        case thickness, fill, weight, backdrop, outlinesText, alignment, hasShadow, fontFamily
    }

    mutating func sanitise() {
        thickness = thickness.isFinite
            ? min(Self.thicknessRange.upperBound, max(Self.thicknessRange.lowerBound, thickness))
            : 1
        fontFamily = fontFamily.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Legibility

extension AnnotationStyle {
    /// The soft plates, as drawn: see-through enough that the picture still shows, dark and
    /// light enough that most colours read on them as they are.
    public static let darkPlate = ColorValue(r: 0.05, g: 0.05, b: 0.07, a: 0.85)
    public static let lightPlate = ColorValue(r: 1, g: 1, b: 1, a: 0.92)

    /// What the words are made to reach against what is behind them. Three to one is the bar
    /// for large type, which an annotation always is; this aims a little above it, because
    /// the renderer's wider colour space and the soft edges of letters both take a little
    /// off on the way to the screen.
    public static let minimumContrast = 3.5

    /// What is drawn behind the words in `colour`, or `nil` for nothing.
    public func plate(for colour: ColorValue) -> ColorValue? {
        switch backdrop {
        case .none: nil
        case .dark: Self.darkPlate
        case .light: Self.lightPlate
        case .solid: colour
        }
    }

    /// The colour the words are drawn in.
    ///
    /// The annotation's own colour wherever it reads. On a solid plate that colour *is*
    /// the plate, so the words go black or white. On a soft plate they keep their colour
    /// if it reads, and otherwise keep its hue and are lightened (on the dark plate) or
    /// darkened (on the light one) just until it does — red on the light plate becomes a
    /// deeper red rather than black, which is still the colour that was chosen. What is
    /// under a soft plate is the video and can be anything, so each is judged at its
    /// weakest: the dark one over white, the light one over black.
    public func textColour(for colour: ColorValue) -> ColorValue {
        switch backdrop {
        case .none:
            return colour
        case .solid:
            return Self.contrasting(colour)
        case .dark, .light:
            let plate = backdrop == .dark
                ? Self.darkPlate.composited(over: .white)
                : Self.lightPlate.composited(over: .black)
            let toward = backdrop == .dark ? ColorValue.white : ColorValue.black
            for step in 0...20 {
                let share = Double(step) / 20
                let candidate = ColorValue(r: colour.r + (toward.r - colour.r) * share,
                                           g: colour.g + (toward.g - colour.g) * share,
                                           b: colour.b + (toward.b - colour.b) * share,
                                           a: colour.a)
                if candidate.contrastRatio(with: plate) >= Self.minimumContrast { return candidate }
            }
            return ColorValue(r: toward.r, g: toward.g, b: toward.b, a: colour.a)
        }
    }

    /// White, wherever white reads on `colour`; near-black where it does not.
    ///
    /// Not simply whichever contrasts more: by the numbers black edges out white on a
    /// saturated red or blue, and a red badge with a black number in it looks like a
    /// warning label rather than a step. White is what people expect on a strong colour, so
    /// it wins whenever it clears the bar for large type. Near-black rather than black: pure
    /// black type on a bright plate looks cut out rather than printed.
    public static func contrasting(_ colour: ColorValue) -> ColorValue {
        let solid = ColorValue(r: colour.r, g: colour.g, b: colour.b)
        let dark = ColorValue(r: 0.07, g: 0.07, b: 0.08)
        let white = solid.contrastRatio(with: .white)
        return white >= minimumContrast || white >= solid.contrastRatio(with: dark) ? .white : dark
    }
}

extension ColorValue {
    /// Relative luminance, as WCAG defines it, of the colour ignoring its alpha.
    public var relativeLuminance: Double {
        func linear(_ channel: Double) -> Double {
            let c = min(1, max(0, channel))
            return c <= 0.040_45 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    /// How far apart two colours are to the eye, from 1 (the same) to 21 (black and white).
    public func contrastRatio(with other: ColorValue) -> Double {
        let a = relativeLuminance, b = other.relativeLuminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// This colour laid over an opaque `background`, as the eye would see the two.
    public func composited(over background: ColorValue) -> ColorValue {
        let alpha = min(1, max(0, a))
        return ColorValue(r: r * alpha + background.r * (1 - alpha),
                          g: g * alpha + background.g * (1 - alpha),
                          b: b * alpha + background.b * (1 - alpha))
    }
}
