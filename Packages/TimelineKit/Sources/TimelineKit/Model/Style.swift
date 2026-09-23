import CoreGraphics
import Foundation

/// What the recording sits on and inside.
///
/// The part that turns a screen capture into something worth posting: a background, room
/// around the frame, rounded corners, a shadow. All of it is applied at render time, so
/// changing any of it is free and reversible.
public struct FrameStyle: Codable, Equatable, Sendable {
    public enum Background: Codable, Equatable, Sendable {
        case color(ColorValue)
        case gradient(from: ColorValue, to: ColorValue, angle: Double)
        /// Relative to the project package, so the project stays portable.
        case image(path: String)
        /// A named background from the shared catalogue — a generated gradient or one of
        /// the system's desktop pictures.
        ///
        /// An id rather than the thing itself, for three reasons at once: a generated
        /// gradient has as many stops as it likes and `.gradient` has exactly two; a
        /// system picture's path is specific to one version of macOS while its name is
        /// not; and a picker can only put a ring around the swatch that is selected if
        /// the document remembers *which* swatch that was.
        case wallpaper(id: String)
    }

    public var background: Background
    /// Fraction of the *shorter* output side, so padding looks the same at 1080p and 4K
    /// and in any aspect ratio.
    public var padding: Double
    /// Fraction of the shorter side of the video frame.
    public var cornerRadius: Double
    public var shadowRadius: Double
    public var shadowOpacity: Double
    /// Blur applied to the background, which is what makes a busy wallpaper usable
    /// behind a recording instead of a distraction.
    ///
    /// A fraction of the shorter output side, like `padding` and `shadowRadius`: as a
    /// raw sigma the same setting softened a 1080p export and barely touched a 4K one.
    public var backgroundBlur: Double
    public var aspect: AspectPreset
    /// The part of the recording that makes it into the frame.
    ///
    /// Optional rather than a full-frame default for two reasons: an older `project.json`
    /// decodes with no `crop` key and no migration, and `Timeline: Equatable` drives
    /// `isDirty`, so a stray full-frame crop would mark an untouched project as edited.
    public var crop: CropRect?

    public init(background: Background = .gradient(from: ColorValue(r: 0.36, g: 0.42, b: 0.85),
                                                   to: ColorValue(r: 0.15, g: 0.16, b: 0.35),
                                                   angle: 0.25),
                padding: Double = 0.06,
                cornerRadius: Double = 0.02,
                shadowRadius: Double = 0.03,
                shadowOpacity: Double = 0.45,
                backgroundBlur: Double = 0,
                aspect: AspectPreset = .source,
                crop: CropRect? = nil) {
        self.background = background
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.shadowRadius = shadowRadius
        self.shadowOpacity = shadowOpacity
        self.backgroundBlur = backgroundBlur
        self.aspect = aspect
        self.crop = crop
    }
}

/// The part of the recording that is shown.
///
/// Normalised with a top-left origin, the same convention `BlurRegion.rect` uses — which
/// is what the renderer's `(1 - rect.maxY)` flip is converting from. A named type rather
/// than a bare `CGRect` because there is real arithmetic here (clamping, a minimum side,
/// an even pixel size) and because it stops "which space is this rect in?" being asked
/// at every call site.
public struct CropRect: Codable, Equatable, Sendable {
    public var rect: CGRect

    /// Small enough to be a deliberate close-up, large enough that a crop can never be a
    /// handful of pixels the exporter then has to refuse.
    public static let minimumSide: CGFloat = 0.05

    public static let full = CropRect(rect: CGRect(x: 0, y: 0, width: 1, height: 1))

    public init(rect: CGRect) {
        var rect = rect.standardized
        rect.size.width = min(1, max(Self.minimumSide, rect.width))
        rect.size.height = min(1, max(Self.minimumSide, rect.height))
        rect.origin.x = min(1 - rect.width, max(0, rect.minX))
        rect.origin.y = min(1 - rect.height, max(0, rect.minY))
        self.rect = rect
    }

    /// Whether this crop takes nothing away.
    public var isFull: Bool {
        abs(rect.minX) < 1e-6 && abs(rect.minY) < 1e-6
            && abs(rect.width - 1) < 1e-6 && abs(rect.height - 1) < 1e-6
    }

    /// The cropped size in pixels, even and never degenerate — an odd dimension is a
    /// problem for every video encoder that will ever be pointed at this.
    public func pixels(in videoSize: CGSize) -> CGSize {
        let width = max(2, ((videoSize.width * rect.width) / 2).rounded() * 2)
        let height = max(2, ((videoSize.height * rect.height) / 2).rounded() * 2)
        return CGSize(width: width, height: height)
    }
}

/// The shape of the exported frame.
public enum AspectPreset: String, Codable, Sendable, CaseIterable {
    /// Whatever was recorded.
    case source
    case wide16x9
    case square
    case vertical9x16
    case classic4x3

    public var ratio: Double? {
        switch self {
        case .source: nil
        case .wide16x9: 16.0 / 9
        case .square: 1
        case .vertical9x16: 9.0 / 16
        case .classic4x3: 4.0 / 3
        }
    }

    public var title: String {
        switch self {
        case .source: "Source"
        case .wide16x9: "16 : 9"
        case .square: "1 : 1"
        case .vertical9x16: "9 : 16"
        case .classic4x3: "4 : 3"
        }
    }

    /// The longer label a menu button wears, where there is room to say what it means.
    public var displayName: String {
        switch self {
        case .source: "Source"
        case .wide16x9: "Wide 16:9"
        case .square: "Square 1:1"
        case .vertical9x16: "Vertical 9:16"
        case .classic4x3: "Classic 4:3"
        }
    }

    public var symbolName: String {
        switch self {
        case .source: "rectangle.dashed"
        case .wide16x9: "rectangle.ratio.16.to.9"
        case .square: "square"
        case .vertical9x16: "rectangle.ratio.9.to.16"
        case .classic4x3: "rectangle.ratio.4.to.3"
        }
    }
}

/// How the pointer is drawn.
///
/// None of this would be possible from a recording with the cursor burned in, which is
/// why the recorder writes cursor positions as data and leaves the video clean.
public struct CursorStyle: Codable, Equatable, Sendable {
    public var isVisible: Bool
    /// Multiplier on the system size. Bigger than 1 by default: a 4K recording watched
    /// in a small player has a pointer nobody can follow.
    public var scale: Double
    /// 0 is the raw sampled path, 1 is as smooth as it goes.
    public var smoothing: Double
    public var clickEffect: Bool
    public var motionBlur: Bool
    /// Keep the pointer's size steady while the camera zooms, instead of letting the
    /// zoom magnify it too.
    public var sizeIsIndependentOfZoom: Bool

    public init(isVisible: Bool = true,
                scale: Double = 1.4,
                smoothing: Double = 0.6,
                clickEffect: Bool = true,
                motionBlur: Bool = false,
                sizeIsIndependentOfZoom: Bool = true) {
        self.isVisible = isVisible
        self.scale = scale
        self.smoothing = smoothing
        self.clickEffect = clickEffect
        self.motionBlur = motionBlur
        self.sizeIsIndependentOfZoom = sizeIsIndependentOfZoom
    }
}

/// The camera bubble, when there is one.
public struct WebcamSettings: Codable, Equatable, Sendable {
    public enum Corner: String, Codable, Sendable, CaseIterable {
        case bottomLeft, bottomRight, topLeft, topRight, custom
    }

    public var isEnabled: Bool
    public var corner: Corner
    /// Used when `corner` is `.custom`, normalised to the output frame.
    public var position: CGPoint
    /// Fraction of the shorter output side.
    public var size: Double
    /// 0 is a square, 1 is a circle.
    public var roundness: Double
    public var isMirrored: Bool
    public var shadowOpacity: Double
    /// Grow the bubble slightly while the camera is zoomed in, so it keeps its weight in
    /// the frame instead of shrinking away.
    public var reactsToZoom: Bool

    public init(isEnabled: Bool = false,
                corner: Corner = .bottomRight,
                position: CGPoint = CGPoint(x: 0.85, y: 0.85),
                size: Double = 0.22,
                roundness: Double = 1,
                isMirrored: Bool = true,
                shadowOpacity: Double = 0.4,
                reactsToZoom: Bool = true) {
        self.isEnabled = isEnabled
        self.corner = corner
        self.position = position
        self.size = size
        self.roundness = roundness
        self.isMirrored = isMirrored
        self.shadowOpacity = shadowOpacity
        self.reactsToZoom = reactsToZoom
    }
}

/// How captions are drawn, when there are any.
///
/// One style for every cue rather than per-cue styling: subtitles that change size or
/// colour line by line are a fault, not a feature, and the one thing people do want to
/// change — where they sit, so they miss the thing being demonstrated — is here.
public struct CaptionStyle: Codable, Equatable, Sendable {
    public enum Position: String, Codable, Sendable, CaseIterable {
        case bottom, top

        public var title: String {
            switch self {
            case .bottom: "Bottom"
            case .top: "Top"
            }
        }
    }

    public var isVisible: Bool
    /// Fraction of the output height, like `AnnotationItem.fontSize`, so captions keep
    /// their weight at any export size.
    public var fontSize: Double
    public var color: ColorValue
    /// The plate behind the words. Captions over a bright screenshot are unreadable
    /// without one, and a drop shadow alone is not enough on white.
    public var backgroundOpacity: Double
    public var position: Position
    /// How far in from the top or bottom edge, as a fraction of the output height.
    public var margin: Double

    public init(isVisible: Bool = true,
                fontSize: Double = 0.05,
                color: ColorValue = .white,
                backgroundOpacity: Double = 0.55,
                position: Position = .bottom,
                margin: Double = 0.06) {
        self.isVisible = isVisible
        self.fontSize = fontSize
        self.color = color
        self.backgroundOpacity = backgroundOpacity
        self.position = position
        self.margin = margin
    }
}
