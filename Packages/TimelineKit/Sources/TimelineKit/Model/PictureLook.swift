import Foundation

/// The picture turned in space: leaning back, turned to one side, or both.
///
/// Angles in degrees, because that is what anybody typing one in means. Everything drawn
/// *on* the picture — the pointer, the click marks, the annotations — is turned with it,
/// so an arrow pointing at a button still points at it; the captions, the keys and the
/// camera bubble stay upright, because they are about the video rather than in it.
///
/// Flat by default, which is what every project written before this decodes to: a flat
/// picture is drawn by exactly the arithmetic it always was.
public struct FramePerspective: Codable, Equatable, Sendable {
    /// About the vertical axis. Positive turns the picture to face left: its left edge goes
    /// away from the viewer and its right edge comes closer.
    public var turn: Double
    /// About the horizontal axis. Positive leans the picture back: the top goes away.
    public var lean: Double
    /// In the plane of the frame, clockwise.
    public var rotation: Double
    /// How strongly a turned picture shadows the background beneath it, 0…1. Scaled by
    /// how far it is turned, so a flat picture casts only its ordinary shadow.
    public var depthShadow: Double
    /// While the camera is zoomed in the picture is turned flat, and turned back as it
    /// zooms out — so what is being zoomed in on is read square-on.
    public var straightensWhenZoomed: Bool

    public static let turnRange: ClosedRange<Double> = -35...35
    public static let leanRange: ClosedRange<Double> = -35...35
    public static let rotationRange: ClosedRange<Double> = -20...20

    public init(turn: Double = 0, lean: Double = 0, rotation: Double = 0,
                depthShadow: Double = 0.5, straightensWhenZoomed: Bool = true) {
        self.turn = turn
        self.lean = lean
        self.rotation = rotation
        self.depthShadow = depthShadow
        self.straightensWhenZoomed = straightensWhenZoomed
    }

    /// Whether the picture is square-on. Under a hundredth of a degree is nothing a pixel
    /// could show.
    public var isFlat: Bool {
        abs(turn) < 0.01 && abs(lean) < 0.01 && abs(rotation) < 0.01
    }

    /// Held to what the panel offers. A project is a file, and a file can ask for a
    /// picture turned edge-on, which would draw as a line.
    public var sanitised: FramePerspective {
        func held(_ value: Double, _ range: ClosedRange<Double>) -> Double {
            value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : 0
        }
        return FramePerspective(turn: held(turn, Self.turnRange),
                                lean: held(lean, Self.leanRange),
                                rotation: held(rotation, Self.rotationRange),
                                depthShadow: held(depthShadow, 0...1),
                                straightensWhenZoomed: straightensWhenZoomed)
    }

    /// Field by field, like every stored style: an angle that will not read is flat rather
    /// than the whole frame style lost.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        let factory = FramePerspective()
        self.init(turn: value(.turn, factory.turn),
                  lean: value(.lean, factory.lean),
                  rotation: value(.rotation, factory.rotation),
                  depthShadow: value(.depthShadow, factory.depthShadow),
                  straightensWhenZoomed: value(.straightensWhenZoomed, factory.straightensWhenZoomed))
    }

    enum CodingKeys: String, CodingKey {
        case turn, lean, rotation, depthShadow, straightensWhenZoomed
    }

    /// The angles a few people will want without dragging three sliders.
    public enum Preset: String, CaseIterable, Identifiable, Sendable {
        case flat, tiltLeft, tiltRight, leanBack, isometric

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .flat: "Flat"
            case .tiltLeft: "Tilt Left"
            case .tiltRight: "Tilt Right"
            case .leanBack: "Lean Back"
            case .isometric: "Isometric"
            }
        }

        /// Only the angles: a preset leaves the depth shadow and the zoom behaviour as
        /// they were set.
        var angles: (turn: Double, lean: Double, rotation: Double) {
            switch self {
            case .flat: (0, 0, 0)
            case .tiltLeft: (18, 6, 0)
            case .tiltRight: (-18, 6, 0)
            case .leanBack: (0, 24, 0)
            case .isometric: (-22, 26, 6)
            }
        }
    }

    /// This perspective with a preset's angles.
    public func with(_ preset: Preset) -> FramePerspective {
        var copy = self
        (copy.turn, copy.lean, copy.rotation) = preset.angles
        return copy
    }

    /// The preset these angles are, if they are one.
    public var preset: Preset? {
        Preset.allCases.first { preset in
            let a = preset.angles
            return abs(a.turn - turn) < 0.05 && abs(a.lean - lean) < 0.05 && abs(a.rotation - rotation) < 0.05
        }
    }
}

/// Colour correction for the recording: the picture only, never the background, the
/// camera or anything drawn over it.
///
/// Every slider is −1…1 with 0 meaning "as recorded", because the units behind them —
/// Core Image's brightness offset, a contrast multiplier, a white point in kelvin — mean
/// nothing to anybody moving a slider. The renderer turns each into its own units.
public struct ColorGrade: Codable, Equatable, Sendable {
    public var brightness: Double
    public var contrast: Double
    public var saturation: Double
    /// Negative is cooler, positive warmer.
    public var temperature: Double
    /// Negative is greener, positive more magenta.
    public var tint: Double
    /// A look-up table somebody loaded, copied into the project. `nil` for none.
    public var lut: LUTReference?
    /// How much of the table's change is kept, 0…1.
    public var lutIntensity: Double

    public static let range: ClosedRange<Double> = -1...1

    public init(brightness: Double = 0, contrast: Double = 0, saturation: Double = 0,
                temperature: Double = 0, tint: Double = 0,
                lut: LUTReference? = nil, lutIntensity: Double = 1) {
        self.brightness = brightness
        self.contrast = contrast
        self.saturation = saturation
        self.temperature = temperature
        self.tint = tint
        self.lut = lut
        self.lutIntensity = lutIntensity
    }

    /// Whether this changes nothing, so the renderer can skip it entirely.
    public var isNeutral: Bool {
        abs(brightness) < 0.001 && abs(contrast) < 0.001 && abs(saturation) < 0.001
            && abs(temperature) < 0.001 && abs(tint) < 0.001
            && (lut == nil || lutIntensity <= 0.001)
    }

    /// Held to −1…1 and 0…1. A file can say anything.
    public var sanitised: ColorGrade {
        func held(_ value: Double, _ range: ClosedRange<Double>) -> Double {
            value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : 0
        }
        return ColorGrade(brightness: held(brightness, Self.range),
                          contrast: held(contrast, Self.range),
                          saturation: held(saturation, Self.range),
                          temperature: held(temperature, Self.range),
                          tint: held(tint, Self.range),
                          lut: lut,
                          lutIntensity: lutIntensity.isFinite ? min(max(lutIntensity, 0), 1) : 1)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        self.init(brightness: value(.brightness, 0),
                  contrast: value(.contrast, 0),
                  saturation: value(.saturation, 0),
                  temperature: value(.temperature, 0),
                  tint: value(.tint, 0),
                  lut: value(.lut, nil),
                  lutIntensity: value(.lutIntensity, 1))
    }

    enum CodingKeys: String, CodingKey {
        case brightness, contrast, saturation, temperature, tint, lut, lutIntensity
    }

    /// A handful of starting points. Each sets the five sliders and leaves a loaded table
    /// where it is: a preset is a correction, the table is somebody's grade.
    public enum Preset: String, CaseIterable, Identifiable, Sendable {
        case none, vivid, warm, cool, muted, mono, punchy

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .none: "None"
            case .vivid: "Vivid"
            case .warm: "Warm"
            case .cool: "Cool"
            case .muted: "Muted"
            case .mono: "Mono"
            case .punchy: "Punchy"
            }
        }

        var sliders: (brightness: Double, contrast: Double, saturation: Double, temperature: Double, tint: Double) {
            switch self {
            case .none: (0, 0, 0, 0, 0)
            case .vivid: (0, 0.12, 0.35, 0, 0)
            case .warm: (0.02, 0.05, 0.08, 0.4, 0.05)
            case .cool: (0, 0.05, 0, -0.4, 0)
            case .muted: (0.03, -0.15, -0.4, 0, 0)
            case .mono: (0, 0.12, -1, 0, 0)
            case .punchy: (-0.02, 0.3, 0.2, 0, 0)
            }
        }
    }

    public func with(_ preset: Preset) -> ColorGrade {
        var copy = self
        let s = preset.sliders
        (copy.brightness, copy.contrast, copy.saturation, copy.temperature, copy.tint) =
            (s.brightness, s.contrast, s.saturation, s.temperature, s.tint)
        return copy
    }

    /// The preset the five sliders are at, if they are at one.
    public var preset: Preset? {
        Preset.allCases.first { preset in
            let s = preset.sliders
            return abs(s.brightness - brightness) < 0.005 && abs(s.contrast - contrast) < 0.005
                && abs(s.saturation - saturation) < 0.005 && abs(s.temperature - temperature) < 0.005
                && abs(s.tint - tint) < 0.005
        }
    }
}

/// A `.cube` table inside the project.
public struct LUTReference: Codable, Equatable, Sendable {
    /// Relative to the project package, like a background picture.
    public var path: String
    /// What the file was called, for the panel to show.
    public var name: String

    public init(path: String, name: String) {
        self.path = path
        self.name = name
    }

    /// Where tables are kept inside a project package.
    public static let folderName = "LUTs"
}

/// A background that moves: drawn fresh for every frame from the moment it is, so a frame
/// scrubbed to is the frame played to.
public struct AnimatedBackground: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable, Identifiable {
        /// A gradient slowly turning and breathing.
        case drift
        /// Soft blobs of colour wandering over a dark ground.
        case aurora
        /// A gradient with a fine film grain moving over it.
        case grain

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .drift: "Drift"
            case .aurora: "Aurora"
            case .grain: "Grain"
            }
        }
    }

    public var kind: Kind
    /// Two or three colours, in the order they are laid.
    public var colors: [ColorValue]
    /// 1 is the pace it was designed at; the panel offers a quarter of that to three times.
    public var speed: Double

    public static let speedRange: ClosedRange<Double> = 0.25...3

    public init(kind: Kind = .drift, colors: [ColorValue] = AnimatedBackground.defaultColors, speed: Double = 1) {
        self.kind = kind
        self.colors = Self.tidied(colors)
        self.speed = speed.isFinite ? min(max(speed, Self.speedRange.lowerBound), Self.speedRange.upperBound) : 1
    }

    /// The default background's two colours and a third between them, so choosing a moving
    /// background keeps the project's feel until a palette is picked.
    public static let defaultColors: [ColorValue] = [
        ColorValue(r: 0.36, g: 0.42, b: 0.85),
        ColorValue(r: 0.55, g: 0.33, b: 0.78),
        ColorValue(r: 0.15, g: 0.16, b: 0.35),
    ]

    /// Two or three, whatever a file says: one colour is doubled, more than three keeps the
    /// ends and the middle.
    static func tidied(_ colors: [ColorValue]) -> [ColorValue] {
        switch colors.count {
        case 0: defaultColors
        case 1: [colors[0], colors[0]]
        case 2, 3: colors
        default: [colors[0], colors[colors.count / 2], colors[colors.count - 1]]
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        self.init(kind: value(.kind, .drift), colors: value(.colors, Self.defaultColors), speed: value(.speed, 1))
    }

    enum CodingKeys: String, CodingKey {
        case kind, colors, speed
    }
}
