import Foundation

/// A shape the user typed: two whole numbers, width and height.
///
/// Whole numbers rather than a ratio, because that is how people say a shape — "4 by 5",
/// never "0.8" — and because two integers survive a round trip through a JSON file
/// exactly, which a decimal ratio does not.
///
/// Every value that gets stored is a legal one: the initialiser and the decoder both
/// clamp, so the renderer never has to defend itself against a project file that says
/// `0 : 100`. What the *user* typed is checked separately by `refusal(width:height:)`,
/// which is how the inspector knows what to say when a number is turned down.
public struct CustomAspect: Codable, Equatable, Hashable, Sendable {
    public var width: Int
    public var height: Int

    /// Each side is a whole number from one to a hundred.
    public static let sideRange = 1...100
    /// No wider than 3 : 1 and no taller than 1 : 3. Beyond that the picture is a strip
    /// with a sliver of recording in it, and the padding arithmetic — a fraction of the
    /// shorter side — stops meaning anything.
    public static let ratioRange: ClosedRange<Double> = (1.0 / 3)...3.0

    /// What Custom means before anybody has typed anything.
    public init() {
        width = 3
        height = 2
    }

    /// Clamps each side into `sideRange`. A ratio outside `ratioRange` is kept as typed
    /// and clamped when it is read — see `ratio`.
    public init(width: Int, height: Int) {
        self.width = min(max(width, Self.sideRange.lowerBound), Self.sideRange.upperBound)
        self.height = min(max(height, Self.sideRange.lowerBound), Self.sideRange.upperBound)
    }

    /// Decoded field by field, so a hand-edited or half-written pair is a default rather
    /// than a style that will not decode.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let width = ((try? container.decodeIfPresent(Int.self, forKey: .width)) ?? nil) ?? 3
        let height = ((try? container.decodeIfPresent(Int.self, forKey: .height)) ?? nil) ?? 2
        self.init(width: width, height: height)
    }

    enum CodingKeys: String, CodingKey {
        case width, height
    }

    /// Width over height, held inside `ratioRange`.
    public var ratio: Double {
        min(max(Double(width) / Double(height), Self.ratioRange.lowerBound), Self.ratioRange.upperBound)
    }

    /// "4 : 5", the way the preset shapes read.
    public var title: String { "\(width) : \(height)" }

    /// Why a pair of numbers cannot be a shape, or `nil` when it can.
    ///
    /// Written for the inspector to show word for word, so the rule lives in one place
    /// and the message cannot drift from it.
    public enum Refusal: Equatable, Sendable {
        case notWhole
        case outOfRange
        case tooWide
        case tooTall

        public var message: String {
            switch self {
            case .notWhole: "Use whole numbers."
            case .outOfRange: "Use whole numbers from 1 to 100."
            case .tooWide: "Too wide. The widest shape is 3 : 1."
            case .tooTall: "Too tall. The tallest shape is 1 : 3."
            }
        }
    }

    /// Checks two typed numbers.
    public static func refusal(width: Int, height: Int) -> Refusal? {
        guard sideRange.contains(width), sideRange.contains(height) else { return .outOfRange }
        let ratio = Double(width) / Double(height)
        if ratio > ratioRange.upperBound { return .tooWide }
        if ratio < ratioRange.lowerBound { return .tooTall }
        return nil
    }

    /// Checks what was typed, before it is a number at all.
    public static func refusal(width: String, height: String) -> Refusal? {
        guard let w = Int(width.trimmingCharacters(in: .whitespaces)),
              let h = Int(height.trimmingCharacters(in: .whitespaces)) else { return .notWhole }
        return refusal(width: w, height: h)
    }
}

public extension FrameStyle {
    /// The shape of the finished frame as width over height, or `nil` for the recording's
    /// own. The one place that knows about both the presets and the typed numbers.
    var aspectRatio: Double? {
        aspect == .custom ? customAspect.ratio : aspect.ratio
    }

    /// How thick a border may be, as a fraction of the shorter side of the video frame.
    /// The inspector's slider and the renderer read the same range, so a project file
    /// asking for a border wider than the picture is drawn at this much and no more.
    static let borderWidthRange: ClosedRange<Double> = 0...0.03
}

public extension AspectPreset {
    /// The shapes in the order a picker shows them: the recording's own, then wide to
    /// tall, then the one you type. `allCases` keeps declaration order, which is the
    /// order they were added in and not one anybody would choose to read.
    static let menuOrder: [AspectPreset] = [
        .source, .wide16x9, .wide16x10, .classic4x3, .square, .portrait4x5, .portrait3x4, .vertical9x16, .custom,
    ]
}
