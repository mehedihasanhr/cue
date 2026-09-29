import Foundation

/// A gradient somebody made themselves: two or three colours, drawn straight across the
/// frame at an angle or outwards from its middle.
///
/// A type of its own rather than more cases on `FrameStyle.Background.gradient`, whose
/// shape — exactly two colours and an angle — is what every saved project has written.
/// Changing it would have made those projects fail to decode their background; a second
/// case leaves them reading exactly what they always read.
public struct BackgroundGradient: Codable, Equatable, Sendable {
    /// How the colours are laid across the frame.
    public enum Shape: String, Codable, Sendable, CaseIterable {
        /// From one side to the other, at `angle`.
        case linear
        /// From the middle of the frame out to its corners. `angle` means nothing here.
        case radial

        public var title: String {
            switch self {
            case .linear: "Linear"
            case .radial: "Radial"
            }
        }
    }

    /// One colour, and where along the sweep it is reached.
    public struct Stop: Codable, Equatable, Sendable {
        public var color: ColorValue
        /// 0 at the start of the sweep — the far side for a linear gradient, the middle
        /// for a radial one — and 1 at the end.
        public var location: Double

        public init(color: ColorValue, location: Double) {
            self.color = color
            self.location = location
        }
    }

    /// Fewer than two is a flat colour, which has its own tab; more than three is a
    /// wallpaper, which has a catalogue. The editor offers exactly this range.
    public static let stopCount: ClosedRange<Int> = 2...3

    public var stops: [Stop]
    public var shape: Shape
    /// In turns, the convention `FrameStyle.Background.gradient` already uses: 0 runs left
    /// to right, a quarter bottom to top.
    public var angle: Double

    public init(stops: [Stop] = BackgroundGradient.defaultStops,
                shape: Shape = .linear,
                angle: Double = 0.25) {
        self.stops = Self.tidied(stops)
        self.shape = shape
        self.angle = angle.isFinite ? angle : 0.25
    }

    /// Where a new gradient starts: the default background's two colours, so switching to
    /// a gradient of one's own changes nothing until something is changed.
    public static let defaultStops: [Stop] = [
        Stop(color: ColorValue(r: 0.36, g: 0.42, b: 0.85), location: 0),
        Stop(color: ColorValue(r: 0.15, g: 0.16, b: 0.35), location: 1),
    ]

    /// Field by field, like every stored style: a file with a shape this build does not
    /// know draws a linear gradient of its colours rather than losing the background.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let stops = (try? container.decodeIfPresent([Stop].self, forKey: .stops)) ?? nil
        let shape = (try? container.decodeIfPresent(Shape.self, forKey: .shape)) ?? nil
        let angle = (try? container.decodeIfPresent(Double.self, forKey: .angle)) ?? nil
        self.init(stops: stops ?? Self.defaultStops, shape: shape ?? .linear, angle: angle ?? 0.25)
    }

    enum CodingKeys: String, CodingKey {
        case stops, shape, angle
    }

    /// Held to what the renderer and the editor both understand: two or three stops, in
    /// order, each somewhere between the ends. A file can say anything, and a gradient of
    /// nine stops or of none must still draw as something the panel can show.
    static func tidied(_ stops: [Stop]) -> [Stop] {
        var kept = stops
            .filter { $0.location.isFinite }
            .map { Stop(color: $0.color, location: min(1, max(0, $0.location))) }
            .sorted { $0.location < $1.location }
        if kept.count > stopCount.upperBound {
            kept = [kept[0], kept[kept.count / 2], kept[kept.count - 1]]
        }
        switch kept.count {
        case 0:
            return defaultStops
        case 1:
            return [Stop(color: kept[0].color, location: 0), Stop(color: kept[0].color, location: 1)]
        default:
            return kept
        }
    }

    /// The same gradient with one more colour, or one fewer. A third colour goes in the
    /// middle, the mix of the two either side, so adding it changes nothing on screen
    /// until it is changed; taking one away keeps the two ends.
    public func withStopCount(_ count: Int) -> BackgroundGradient {
        let wanted = min(max(count, Self.stopCount.lowerBound), Self.stopCount.upperBound)
        var copy = self
        if wanted == 3, stops.count == 2 {
            let a = stops[0].color, b = stops[1].color
            let middle = ColorValue(r: (a.r + b.r) / 2, g: (a.g + b.g) / 2,
                                    b: (a.b + b.b) / 2, a: (a.a + b.a) / 2)
            copy.stops = [stops[0], Stop(color: middle, location: 0.5), stops[1]]
        } else if wanted == 2, stops.count == 3 {
            copy.stops = [stops[0], stops[2]]
        }
        return copy
    }
}

/// A window drawn around the recording: a title bar with three dots, or a browser's bar
/// with an address field in it.
///
/// Drawn by the renderer out of rounded rectangles rather than shipped as pictures, so it
/// is sharp at any export size and carries nobody's brand. The bar sits *above* the
/// picture and inside the padding: turning it on shrinks the picture a little so the
/// window as a whole still fits where the picture used to.
public struct WindowChrome: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable, Identifiable {
        /// No window — the picture on its own, as every project before this had it.
        case none
        /// A title bar with three dots in its corner.
        case window
        /// A title bar with the dots and an address field.
        case browser

        public var title: String {
            switch self {
            case .none: "None"
            case .window: "macOS Window"
            case .browser: "Browser"
            }
        }

        public var id: String { rawValue }
    }

    public enum Appearance: String, Codable, Sendable, CaseIterable, Identifiable {
        case light, dark

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .light: "Light"
            case .dark: "Dark"
            }
        }
    }

    public var kind: Kind
    public var appearance: Appearance

    public init(kind: Kind = .none, appearance: Appearance = .light) {
        self.kind = kind
        self.appearance = appearance
    }

    /// Whether anything is drawn at all.
    public var isVisible: Bool { kind != .none }

    /// Field by field: a window kind a newer build wrote is drawn as no window rather than
    /// costing the frame its whole style.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = ((try? container.decodeIfPresent(Kind.self, forKey: .kind)) ?? nil) ?? .none
        appearance = ((try? container.decodeIfPresent(Appearance.self, forKey: .appearance)) ?? nil) ?? .light
    }

    enum CodingKeys: String, CodingKey {
        case kind, appearance
    }
}
