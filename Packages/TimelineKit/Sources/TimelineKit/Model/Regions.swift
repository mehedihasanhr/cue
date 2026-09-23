import CoreGraphics
import CoreMedia
import Foundation

/// Anything that occupies a stretch of the timeline.
///
/// One protocol so moving, resizing, snapping and deleting are written once rather than
/// once per kind — a zoom and a caption differ in what they draw, not in how they sit
/// on a timeline.
public protocol TimelineRegion: Identifiable, Equatable, Codable, Sendable where ID == UUID {
    var id: UUID { get }
    var start: CMTime { get set }
    var duration: CMTime { get set }
}

public extension TimelineRegion {
    var end: CMTime { start + duration }
    var range: CMTimeRange { CMTimeRange(start: start, duration: duration) }

    func contains(_ time: CMTime) -> Bool { time >= start && time < end }

    /// Where `time` sits inside this region, 0…1. Used by everything that eases.
    func progress(at time: CMTime) -> Double {
        guard duration.seconds > 0 else { return 0 }
        return min(1, max(0, (time - start).seconds / duration.seconds))
    }
}

/// How a value travels from one end of a transition to the other.
public enum Easing: String, Codable, Sendable, CaseIterable {
    case linear
    /// The default: a spring, because a zoom that arrives without settling reads as a
    /// jump cut, however long it takes.
    case spring
    case easeInOut

    public func apply(_ t: Double) -> Double {
        let t = min(1, max(0, t))
        switch self {
        case .linear:
            return t
        case .easeInOut:
            return t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
        case .spring:
            // A critically-damped-looking curve with a touch of overshoot, evaluated
            // rather than simulated so scrubbing to a time gives the same answer as
            // playing to it.
            let overshoot = 1.70158 * 0.6
            let shifted = t - 1
            return 1 + (overshoot + 1) * pow(shifted, 3) + overshoot * pow(shifted, 2)
        }
    }
}

/// A push in towards part of the picture.
///
/// `center` is normalised (0…1 of the frame) so the same edit survives an export at a
/// different resolution — an absolute point would be wrong the moment the output size
/// changed.
public struct ZoomRegion: TimelineRegion {
    /// What asked for this zoom.
    ///
    /// Kept so the editor can say *why* a zoom is there — "this one is here because you
    /// clicked" is the difference between a suggestion a user trusts and one they undo.
    /// It also decides which of two overlapping suggestions keeps its aim: a focused
    /// text field is a better thing to point at than the window around it.
    public enum Source: String, Codable, Sendable {
        /// Placed by hand. The default, and never overruled by a suggestion.
        case manual
        case click
        case typing
        case field
        case window
        case application

        /// How specific this is about what to look at, low to high.
        var specificity: Int {
            switch self {
            case .application: 0
            case .window: 1
            case .click: 2
            case .typing: 3
            case .field: 4
            case .manual: 5
            }
        }

        public var title: String {
            switch self {
            case .manual: "Zoom"
            case .click: "Click"
            case .typing: "Typing"
            case .field: "Text field"
            case .window: "Window"
            case .application: "App switch"
            }
        }
    }

    public let id: UUID
    public var start: CMTime
    public var duration: CMTime
    public var scale: Double
    public var center: CGPoint
    public var easing: Easing
    /// How long the move in and out takes. Both are clamped to half the region so a
    /// short zoom never spends longer arriving than it spends there.
    public var transition: CMTime
    /// Follow the cursor while zoomed in, instead of holding `center`.
    public var followsCursor: Bool
    /// Optional so a project written before the field existed still decodes — a missing
    /// key reads as `nil`, which the editor shows as a plain zoom.
    public var source: Source?

    public init(id: UUID = UUID(),
                start: CMTime,
                duration: CMTime,
                scale: Double = 2,
                center: CGPoint = CGPoint(x: 0.5, y: 0.5),
                easing: Easing = .spring,
                transition: CMTime = CMTime(value: 1, timescale: 2),
                followsCursor: Bool = true,
                source: Source? = nil) {
        self.id = id
        self.start = start
        self.duration = duration
        self.scale = max(1, min(scale, 8))
        self.center = center
        self.easing = easing
        self.transition = transition
        self.followsCursor = followsCursor
        self.source = source
    }

    /// How far in the camera is at `time`, 1 being not at all.
    ///
    /// Eased in at the start and out at the end, so a region is a movement rather than a
    /// switch. Outside the region it is exactly 1, which is what lets several zooms be
    /// summed without them fighting.
    public func scale(at time: CMTime) -> Double {
        guard contains(time) else { return 1 }
        let ramp = min(transition, CMTimeMultiplyByFloat64(duration, multiplier: 0.5))
        guard ramp.seconds > 0 else { return scale }

        let sinceStart = (time - start).seconds
        let untilEnd = (end - time).seconds
        let progress = min(sinceStart, untilEnd) / ramp.seconds
        return 1 + (scale - 1) * easing.apply(min(1, max(0, progress)))
    }
}

/// Something hidden: a password, a name, a face.
public struct BlurRegion: TimelineRegion {
    public enum Style: String, Codable, Sendable, CaseIterable {
        case gaussian, pixelate
    }

    public let id: UUID
    public var start: CMTime
    public var duration: CMTime
    /// Normalised to the frame, for the same reason `ZoomRegion.center` is.
    public var rect: CGRect
    public var style: Style
    public var radius: Double

    public init(id: UUID = UUID(), start: CMTime, duration: CMTime,
                rect: CGRect, style: Style = .gaussian, radius: Double = 18) {
        self.id = id
        self.start = start
        self.duration = duration
        self.rect = rect
        self.style = style
        self.radius = radius
    }
}

/// Something added on top: a label, an arrow, a picture.
public struct AnnotationItem: TimelineRegion {
    public enum Kind: Codable, Equatable, Sendable {
        case text(String)
        case arrow(from: CGPoint, to: CGPoint)
        case rectangle
        case image(path: String)
    }

    public let id: UUID
    public var start: CMTime
    public var duration: CMTime
    public var kind: Kind
    public var rect: CGRect
    public var color: ColorValue
    public var fontSize: Double

    public init(id: UUID = UUID(), start: CMTime, duration: CMTime, kind: Kind,
                rect: CGRect, color: ColorValue = .init(r: 1, g: 0.23, b: 0.19),
                fontSize: Double = 0.06) {
        self.id = id
        self.start = start
        self.duration = duration
        self.kind = kind
        self.rect = rect
        self.color = color
        self.fontSize = fontSize
    }
}

/// A line of spoken text, on screen while it is being said.
public struct CaptionCue: TimelineRegion {
    public let id: UUID
    public var start: CMTime
    public var duration: CMTime
    public var text: String

    public init(id: UUID = UUID(), start: CMTime, duration: CMTime, text: String) {
        self.id = id
        self.start = start
        self.duration = duration
        self.text = text
    }
}

/// Sound from somewhere other than the recording: music, a voiceover, a sound effect.
public struct AudioRegion: TimelineRegion {
    public let id: UUID
    public var start: CMTime
    public var duration: CMTime
    /// Relative to the project package, so a project stays portable.
    public var path: String
    public var gain: Double
    /// The in-point in the audio file, so trimming a region does not re-cut the sound.
    public var sourceStart: CMTime

    public init(id: UUID = UUID(), start: CMTime, duration: CMTime, path: String,
                gain: Double = 1, sourceStart: CMTime = .zero) {
        self.id = id
        self.start = start
        self.duration = duration
        self.path = path
        self.gain = gain
        self.sourceStart = sourceStart
    }
}

/// A colour that survives being written to disk.
///
/// Not `NSColor` or `Color`: a document has to decode to the same colour on another Mac
/// a year later, which means storing numbers, not a platform object.
public struct ColorValue: Codable, Equatable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double

    public init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    public static let black = ColorValue(r: 0, g: 0, b: 0)
    public static let white = ColorValue(r: 1, g: 1, b: 1)
}
