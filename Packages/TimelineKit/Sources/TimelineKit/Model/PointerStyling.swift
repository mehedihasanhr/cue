import CoreMedia
import Foundation

public extension CursorStyle {
    /// What the pointer is drawn as.
    ///
    /// `asRecorded` is everything that came before there was a choice: the picture the
    /// recording kept, or Klik's drawing of the shape the pointer had. The others — the
    /// system's own pointers, of macOS 26 and before it, and a few drawings of Klik's —
    /// are made at the size of the frame being written, so they are as sharp in a 4K
    /// export as in the preview, and each one is placed by its own point, which for the
    /// dot is its middle.
    enum Appearance: String, Codable, Sendable, CaseIterable {
        case asRecorded
        /// The pointer macOS 26 draws: the rounded arrow, black with a white outline, and
        /// the system's own hand, I-beam and the rest when the pointer changes shape.
        case macOS26
        /// The pointer macOS drew from 10.0 to 15 — the sharp arrow and the upright hand —
        /// black with a white outline.
        case macOS14
        /// macOS 26's pointer with the colours swapped: white with a black outline, as
        /// Accessibility's pointer colours can set it. Reads best on dark pages.
        case macOS26White
        /// The classic pointer, white with a black outline.
        case macOS14White
        /// macOS 26's pointer filled with the chosen colour and outlined in white, the way
        /// Accessibility's pointer fill colour draws it.
        case macOS26Colour
        /// macOS 26's shapes filled with a gradient from the chosen colour into its
        /// neighbour on the colour wheel, outlined in white, with a shadow of its colour.
        case gradient
        /// A near-black pointer with a glowing outline in the chosen colour.
        case neon
        /// A frosted, icy-white pointer with a crisp dark outline.
        case frost
        /// The drawn arrow, a size up, whatever the pointer turned into.
        case largeArrow
        /// A small arrow, outline only, with a light shadow.
        case minimal
        /// A filled circle with a soft ring round it, the way a presentation tool shows a
        /// pointer.
        case dot
        /// No pointer at all. The click marks and sounds stay.
        case clicksOnly

        public var title: String {
            switch self {
            case .asRecorded: "As recorded"
            case .macOS26: "macOS 26"
            case .macOS14: "macOS 14"
            case .macOS26White: "macOS 26 white"
            case .macOS14White: "macOS 14 white"
            case .macOS26Colour: "macOS 26 colour"
            case .gradient: "Gradient"
            case .neon: "Neon"
            case .frost: "Frost"
            case .largeArrow: "Large arrow"
            case .minimal: "Minimal"
            case .dot: "Dot"
            case .clicksOnly: "Invisible but clicks"
            }
        }

        /// Styles from a build that drew its own arrows and discs, read as the system
        /// pointer nearest to each, so a project saved with one still opens.
        private static let retired: [String: Appearance] = [
            "blackArrow": .macOS14, "softArrow": .macOS26, "colourArrow": .macOS26Colour,
            "hand": .macOS26, "touch": .dot, "ring": .dot, "crosshair": .asRecorded,
        ]

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            guard let appearance = Appearance(rawValue: raw) ?? Self.retired[raw] else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                        debugDescription: "No pointer style called \(raw)"))
            }
            self = appearance
        }

        /// Whether the style is drawn in the chosen pointer colour (`CursorStyle.dotColor`).
        public var usesColour: Bool { self == .dot || self == .macOS26Colour || self == .gradient || self == .neon }

        /// Whether the style is one of the system's own pointers.
        public var isSystemPointer: Bool {
            switch self {
            case .macOS26, .macOS14, .macOS26White, .macOS14White, .macOS26Colour: true
            case .asRecorded, .largeArrow, .minimal, .dot, .clicksOnly, .gradient, .neon, .frost: false
            }
        }

        /// Whether the style is drawn from the system's shapes — its own pointers, and the
        /// styled ones built on them — and so has a drawing for every shape the pointer
        /// takes.
        public var usesSystemShapes: Bool {
            isSystemPointer || self == .gradient || self == .neon || self == .frost
        }

        /// Whether anything is drawn where the pointer is.
        public var drawsPointer: Bool { self != .clicksOnly }

        /// Whether the pointer's recorded shape — arrow, I-beam, hand — decides what is
        /// drawn: the recorded pointer and the system's, which have a drawing for each.
        /// Every other style is one drawing throughout.
        public var followsRecordedShape: Bool { self == .asRecorded || usesSystemShapes }
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

/// The pointer brought back to where it started over the last moments of the video, so
/// the video can be played on a loop without the pointer jumping at the seam.
///
/// For the videos that *are* played on a loop: a GIF in a README, a muted hero video on a
/// landing page. A recording ends wherever the hand happened to stop, and the frame after
/// the last one is the first one, so without this the pointer teleports once a loop — the
/// one fault a looping video cannot hide, because the viewer sees it every few seconds.
///
/// Eased rather than slid: the pointer leaves the recorded path gently, travels home and
/// arrives at rest, so the last frame and the first are the same place. Worked out from
/// the time alone, like every other pointer rule, so scrubbing to the end shows what
/// playing to it shows.
public struct PointerLoop: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    /// How long the journey home takes, in seconds, ending at the end of the video.
    public var duration: Double
    /// Whether the camera comes home too — the zoom and the pan it had on the first frame.
    ///
    /// On by default: a pointer that loops inside a picture that jumps from 2× to the whole
    /// recording at the seam has not made the video loop. Off for somebody who wants the
    /// last zoom to hold to the very end and is happy with a cut.
    public var bringsCameraBack: Bool

    public static let durationRange: ClosedRange<Double> = 0.5...2

    public init(isEnabled: Bool = false, duration: Double = 1, bringsCameraBack: Bool = true) {
        self.isEnabled = isEnabled
        self.duration = PointerSpotlight.clamp(duration, Self.durationRange, fallback: 1)
        self.bringsCameraBack = bringsCameraBack
    }

    /// Field by field, for the reason `CursorStyle.init(from:)` gives.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, default fallback: @autoclosure () -> T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback()
        }
        self.init(isEnabled: value(.isEnabled, default: false),
                  duration: value(.duration, default: 1),
                  bringsCameraBack: value(.bringsCameraBack, default: true))
    }

    enum CodingKeys: String, CodingKey {
        case isEnabled, duration, bringsCameraBack
    }

    /// How far home the pointer is at `time` in a video `length` long: 0 until the journey
    /// begins, 1 at the very end, eased in and out between.
    ///
    /// A video shorter than two journeys gives half of itself to the journey instead, so a
    /// three-second GIF with a two-second loop still shows the pointer doing something
    /// before it starts home — and a journey never begins before the first frame, where it
    /// would be travelling to where it already is.
    ///
    /// Smootherstep rather than smoothstep: its speed *and* its acceleration are zero at
    /// both ends, so neither the departure from the recorded path nor the arrival shows a
    /// kink, even with motion blur measuring the pointer's speed across it.
    public func blend(at time: Double, length: Double) -> Double {
        guard isEnabled, length > 0, time.isFinite else { return 0 }
        let journey = min(duration, length / 2)
        guard journey > 0 else { return 0 }
        let start = length - journey
        let t = min(1, max(0, (time - start) / journey))
        return t * t * t * (t * (t * 6 - 15) + 10)
    }
}

/// The arrow leaning into its travel while it moves, and standing up again when it stops.
///
/// A drawn pointer that glides about bolt upright reads as a sprite; one that tilts a few
/// degrees into a fast move reads as a thing with weight being moved by a hand. The tilt
/// is a spring's: it builds as the pointer picks up speed, overshoots a touch when it
/// stops, and settles upright.
///
/// **Stateless.** A spring is normally simulated a frame at a time, which would make the
/// tilt at a moment depend on how the player got there — scrubbing and playing would show
/// different pointers. Here the spring's answer is worked out directly: the tilt at a
/// moment is the pointer's recent speed passed through the spring's impulse response, a
/// weighted sum over the last fraction of a second of the path. The same arithmetic, the
/// same answer, however the moment was reached. See `angle(at:position:frameWidth:)`.
public struct PointerSway: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    /// 0 to 1: how far the arrow may lean, as a share of `maximumAngle`.
    public var strength: Double

    public static let strengthRange: ClosedRange<Double> = 0.1...1
    /// The furthest the arrow ever leans, in degrees, at full strength and full speed.
    /// Past twenty the arrow stops reading as leaning and starts reading as pointing
    /// somewhere else.
    public static let maximumAngle = 20.0

    public init(isEnabled: Bool = false, strength: Double = 0.6) {
        self.isEnabled = isEnabled
        self.strength = PointerSpotlight.clamp(strength, Self.strengthRange, fallback: 0.6)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, default fallback: @autoclosure () -> T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback()
        }
        self.init(isEnabled: value(.isEnabled, default: false),
                  strength: value(.strength, default: 0.6))
    }

    enum CodingKeys: String, CodingKey {
        case isEnabled, strength
    }

    // MARK: - The spring

    /// The spring's natural frequency, in hertz. About two swings a second: quick enough to
    /// follow a flick, slow enough that the lean is seen rather than felt as jitter.
    static let frequency = 2.2
    /// Under-damped a little, so a stop gives one small overshoot and no more.
    static let damping = 0.6
    /// How far back the sum reaches. By then the spring's envelope has fallen below one
    /// per cent and nothing older can move the arrow.
    static let memory = 0.6
    /// How finely the path is read over that stretch.
    static let step = 1.0 / 120
    /// The speed, in frame widths per second, at which the lean is most of the way to its
    /// limit. A deliberate move across a screen is about this; a flick is well past it and
    /// only nudges the lean further, because the curve flattens.
    static let referenceSpeed = 0.8
    /// A step faster than this — several frame widths a second — is a cut in the footage or
    /// a jump to another screen, not a movement, and must not throw the arrow over.
    static let teleportSpeed = 8.0

    /// The spring's impulse response at `age` seconds: how much a push that long ago still
    /// moves the arrow now. Integrates to one, so a pointer moving steadily leans by exactly
    /// the angle its speed asks for.
    static func response(_ age: Double) -> Double {
        let omega = 2 * Double.pi * frequency
        let zeta = damping
        let damped = omega * (1 - zeta * zeta).squareRoot()
        return omega * omega / damped * exp(-zeta * omega * age) * sin(damped * age)
    }

    /// The lean the arrow is asked for by a speed across the frame: signed, saturating
    /// smoothly towards `maximumAngle × strength`, in radians.
    func target(forSpeed speed: Double) -> Double {
        let limit = Self.maximumAngle * strength * .pi / 180
        return limit * tanh(speed / Self.referenceSpeed)
    }

    /// How far the arrow leans at `time`, in radians — positive when it is travelling to
    /// the right, which swings its tail back to the left.
    ///
    /// - Parameters:
    ///   - position: where the pointer is drawn at a moment, in any units, or `nil` where
    ///     it is not drawn at all. Called at a fixed spacing back through `memory`.
    ///   - frameWidth: how wide the frame is in the same units, so a speed means the same at
    ///     every recording size.
    ///
    /// Only the sideways speed leans the arrow. A pointer moving straight up or down has no
    /// side to lean to, and tilting it anyway reads as a wobble.
    public func angle(at time: Double, position: (Double) -> CGPoint?, frameWidth: Double) -> Double {
        guard isEnabled, frameWidth > 0, time.isFinite else { return 0 }
        let steps = Int((Self.memory / Self.step).rounded())
        var points: [CGPoint?] = []
        points.reserveCapacity(steps + 2)
        for index in 0...(steps + 1) {
            points.append(position(time - Double(index) * Self.step))
        }
        var total = 0.0
        for index in 0...steps {
            guard let now = points[index], let before = points[index + 1] else { continue }
            let speed = (now.x - before.x) / Self.step / frameWidth
            guard abs(speed) < Self.teleportSpeed else { continue }
            // Sampled at the middle of the step, which is where that speed was measured.
            let age = (Double(index) + 0.5) * Self.step
            total += target(forSpeed: speed) * Self.response(age) * Self.step
        }
        let limit = Self.maximumAngle * strength * .pi / 180 * 1.25
        return min(max(total, -limit), limit)
    }
}

public extension Timeline {
    /// How far the looping pointer — and, when it asks, the camera — has come home at
    /// `time`, 0 to 1. Always 0 while the project does not loop.
    func pointerLoopBlend(at time: CMTime) -> Double {
        cursor.loop.blend(at: time.seconds, length: duration.seconds)
    }
}
