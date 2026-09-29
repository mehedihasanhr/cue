import CoreMedia
import Foundation

public extension CursorStyle {
    /// What the pointer is drawn as.
    ///
    /// `asRecorded` is everything that came before there was a choice: the picture the
    /// recording kept, or Klik's drawing of the shape the pointer had. The others are
    /// drawings of Klik's own, made at the size of the frame being written, so they are
    /// as sharp in a 4K export as in the preview — and each one is placed by its own
    /// point, which for the dot is its middle.
    enum Appearance: String, Codable, Sendable, CaseIterable {
        case asRecorded
        /// The drawn arrow, a size up, whatever the pointer turned into.
        case largeArrow
        /// A filled circle with a soft ring round it, the way a presentation tool shows a
        /// pointer.
        case dot
        /// A small arrow, outline only, with a light shadow.
        case minimal
        /// No pointer at all. The click marks and sounds stay.
        case clicksOnly

        public var title: String {
            switch self {
            case .asRecorded: "As recorded"
            case .largeArrow: "Large arrow"
            case .dot: "Dot"
            case .minimal: "Minimal"
            case .clicksOnly: "Invisible but clicks"
            }
        }

        /// Whether anything is drawn where the pointer is.
        public var drawsPointer: Bool { self != .clicksOnly }

        /// Whether the pointer's recorded shape — arrow, I-beam, hand — decides what is
        /// drawn. Only for `asRecorded`; every other style is one drawing throughout.
        public var followsRecordedShape: Bool { self == .asRecorded }
    }
}

/// Whether an effect on the pointer is on for the whole video or only where a stretch on
/// the Pointer lane asks for it.
///
/// The stretches are the same `CursorRegion`s that hide, calm and hold the pointer. A
/// spotlight or a magnifier is almost always wanted for a moment — the one field being
/// filled in, the one line being read — and that lane is already where a moment of
/// pointer behaviour is marked, dragged and trimmed. A second lane with the same gestures
/// would be two ways of saying one thing.
public enum PointerEffectScope: String, Codable, Sendable, CaseIterable {
    case everywhere
    case markedStretches

    public var title: String {
        switch self {
        case .everywhere: "Whole video"
        case .markedStretches: "Marked stretches"
        }
    }
}

/// Darkens the picture except for a soft circle round the pointer.
///
/// Measured against the finished frame, like a click mark: the circle is the same share
/// of the picture at 1080p and at 4K, and does not swell when the camera zooms in.
public struct PointerSpotlight: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    /// The clear circle's radius, as a fraction of the shorter side of the finished frame.
    public var radius: Double
    /// How dark everything outside the circle becomes, 0 not at all and 1 black.
    public var dimming: Double
    public var scope: PointerEffectScope

    public static let radiusRange: ClosedRange<Double> = 0.05...0.45
    public static let dimmingRange: ClosedRange<Double> = 0.1...0.9

    public init(isEnabled: Bool = false,
                radius: Double = 0.16,
                dimming: Double = 0.55,
                scope: PointerEffectScope = .everywhere) {
        self.isEnabled = isEnabled
        self.radius = Self.clamp(radius, Self.radiusRange, fallback: 0.16)
        self.dimming = Self.clamp(dimming, Self.dimmingRange, fallback: 0.55)
        self.scope = scope
    }

    /// Field by field, for the reason `CursorStyle.init(from:)` gives. A file can also say
    /// a radius of 40, which is clamped rather than obeyed.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, default fallback: @autoclosure () -> T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback()
        }
        self.init(isEnabled: value(.isEnabled, default: false),
                  radius: value(.radius, default: 0.16),
                  dimming: value(.dimming, default: 0.55),
                  scope: value(.scope, default: .everywhere))
    }

    enum CodingKeys: String, CodingKey {
        case isEnabled, radius, dimming, scope
    }

    static func clamp(_ value: Double, _ range: ClosedRange<Double>, fallback: Double) -> Double {
        value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : fallback
    }
}

/// A round window on the recording around the pointer, magnified.
///
/// For small text a zoom would have to push the whole picture in to show: the lens
/// enlarges only what is under the pointer and leaves the rest of the frame where it was.
public struct PointerMagnifier: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    /// How much bigger things are inside the lens than outside it.
    public var factor: Double
    /// The lens's width, as a fraction of the shorter side of the finished frame.
    public var diameter: Double
    public var scope: PointerEffectScope

    public static let factorRange: ClosedRange<Double> = 1.5...3
    public static let diameterRange: ClosedRange<Double> = 0.12...0.5

    public init(isEnabled: Bool = false,
                factor: Double = 2,
                diameter: Double = 0.26,
                scope: PointerEffectScope = .everywhere) {
        self.isEnabled = isEnabled
        self.factor = PointerSpotlight.clamp(factor, Self.factorRange, fallback: 2)
        self.diameter = PointerSpotlight.clamp(diameter, Self.diameterRange, fallback: 0.26)
        self.scope = scope
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, default fallback: @autoclosure () -> T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback()
        }
        self.init(isEnabled: value(.isEnabled, default: false),
                  factor: value(.factor, default: 2),
                  diameter: value(.diameter, default: 0.26),
                  scope: value(.scope, default: .everywhere))
    }

    enum CodingKeys: String, CodingKey {
        case isEnabled, factor, diameter, scope
    }
}

public extension Timeline {
    /// How far the spotlight and the magnifier are in at a moment, 0 to 1 each.
    ///
    /// Not the pointer's own fading — hidden stretches and hiding while still are for the
    /// builder to multiply in, because they fade the pointer too. This is only whether the
    /// project asks for the effect here: always, or as far as the strongest marked stretch
    /// covering the moment has arrived. A stretch's ramp is what brings the effect in and
    /// takes it out again, the same ramp that fades a hidden pointer.
    func pointerEffectPresence(at time: CMTime) -> (spotlight: Double, magnifier: Double) {
        func presence(_ isEnabled: Bool, _ scope: PointerEffectScope,
                      _ asks: (CursorRegion) -> Bool) -> Double {
            guard isEnabled else { return 0 }
            guard scope == .markedStretches else { return 1 }
            var strongest = 0.0
            for region in cursorRegions where asks(region) {
                strongest = max(strongest, region.sanitised.presence(at: time))
            }
            return strongest
        }
        return (presence(cursor.spotlight.isEnabled, cursor.spotlight.scope) { $0.spotlights },
                presence(cursor.magnifier.isEnabled, cursor.magnifier.scope) { $0.magnifies })
    }
}
