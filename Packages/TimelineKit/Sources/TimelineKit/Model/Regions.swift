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
    /// A ramp for the start alone, when it differs from `transition`.
    ///
    /// Exists for one edit and is worth the field for it: splitting a zoom has to leave
    /// two regions that together look exactly like the one that was there, which means
    /// *no ramp at the seam* — the camera must already be in at the new region's first
    /// frame and still in at the old one's last. One `transition` cannot say that, because
    /// it says the same thing about both ends.
    ///
    /// `nil` means "whatever `transition` says", so a zoom nobody has split encodes and
    /// renders exactly as it did before these existed, and the inspector's one Ramp slider
    /// remains the whole story for it.
    public var transitionIn: CMTime?
    /// A ramp for the end alone. See `transitionIn`.
    public var transitionOut: CMTime?
    /// Follow the cursor while zoomed in, instead of holding `center`.
    public var followsCursor: Bool
    /// Optional so a project written before the field existed still decodes — a missing
    /// key reads as `nil`, which the editor shows as a plain zoom.
    public var source: Source?

    /// Held against being moved, resized, or replaced by a later auto-zoom run.
    ///
    /// The second pass over a take is mostly re-running auto-zoom and nudging what it
    /// produced, and both of those are destructive to the one zoom that was already right.
    /// A lock is the cheapest possible answer: it guards the two things that happen *to* a
    /// zoom without anyone meaning them — a drag on the lane, and a suggestion run — and
    /// deliberately does not guard the things someone has to aim at it, which are deleting
    /// it and editing it in the inspector where the padlock is. A lock that also swallowed
    /// the Delete key would be a region the user cannot get rid of without knowing why.
    public var isLocked: Bool

    /// What a zoom looks like when nobody has changed it, and what Reset puts back.
    ///
    /// Named constants rather than literals in the initialiser, so "the default" is one
    /// fact that the initialiser, the reset and the tests all read — three copies of 2.0
    /// is three places to disagree.
    public static let defaultScale = 2.0
    /// As far in as a zoom will go.
    ///
    /// A named constant because two places now decide it — the inspector's slider, and the
    /// rectangle drawn on the picture, which can ask for any magnification at all by being
    /// dragged small. They must agree, or a box drawn tighter than the slider allows would
    /// snap somewhere the user did not draw.
    public static let maximumScale = 8.0
    public static let defaultEasing = Easing.spring
    public static let defaultTransition = CMTime(value: 1, timescale: 2)

    public init(id: UUID = UUID(),
                start: CMTime,
                duration: CMTime,
                scale: Double = ZoomRegion.defaultScale,
                center: CGPoint = CGPoint(x: 0.5, y: 0.5),
                easing: Easing = ZoomRegion.defaultEasing,
                transition: CMTime = ZoomRegion.defaultTransition,
                transitionIn: CMTime? = nil,
                transitionOut: CMTime? = nil,
                followsCursor: Bool = true,
                source: Source? = nil,
                isLocked: Bool = false) {
        self.id = id
        self.start = start
        self.duration = duration
        self.scale = max(1, min(scale, 8))
        self.center = center
        self.easing = easing
        self.transition = transition
        self.transitionIn = transitionIn
        self.transitionOut = transitionOut
        self.followsCursor = followsCursor
        self.source = source
        self.isLocked = isLocked
    }

    /// Decodes a zoom written by an older or a newer build.
    ///
    /// Field by field, for the reason `Timeline.init(from:)` gives — and here it is not a
    /// nicety. `Timeline` decodes its whole zoom lane with one `decodeIfPresent`, so a
    /// single zoom that throws costs the user *every* zoom in the project. Before this
    /// existed the synthesised decoder was all-or-nothing, which means adding one
    /// non-optional field — `isLocked` — would have emptied the lane of every project
    /// saved up to now. The defaults are chosen so a zoom carrying only the fields that
    /// existed then decodes to exactly the zoom it was.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, default fallback: @autoclosure () -> T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback()
        }
        id = value(.id, default: UUID())
        start = value(.start, default: .zero)
        duration = value(.duration, default: .zero)
        scale = value(.scale, default: ZoomRegion.defaultScale)
        center = value(.center, default: CGPoint(x: 0.5, y: 0.5))
        easing = value(.easing, default: ZoomRegion.defaultEasing)
        transition = value(.transition, default: ZoomRegion.defaultTransition)
        // Absent unless a split wrote them, and `nil` is "use `transition` at both ends",
        // which is what every zoom written before the split existed meant.
        transitionIn = value(.transitionIn, default: nil)
        transitionOut = value(.transitionOut, default: nil)
        followsCursor = value(.followsCursor, default: true)
        source = value(.source, default: nil)
        isLocked = value(.isLocked, default: false)
    }

    /// Spelled out so the decoder above and the synthesised encoder agree, and so renaming
    /// a property is a compile error rather than a silently unreadable project.
    enum CodingKeys: String, CodingKey {
        case id, start, duration, scale, center, easing, transition
        case transitionIn, transitionOut, followsCursor, source, isLocked
    }

    /// How long the move in and how long the move out actually take.
    ///
    /// The two are clamped *together* rather than each to half the region, which is the
    /// generalisation of the old rule and not a change to it: with both ends asking for
    /// the same `transition` this returns `min(transition, duration / 2)` exactly, the
    /// number every existing project rendered with. Sharing the region in proportion
    /// matters only once the two differ — a zoom with no ramp at its start may spend the
    /// whole region ramping out, and halving it would have left the camera pulling back
    /// from the middle for no reason anyone asked for.
    public var ramps: (in: CMTime, out: CMTime) {
        let wanted = (in: max(.zero, transitionIn ?? transition),
                      out: max(.zero, transitionOut ?? transition))
        let total = wanted.in + wanted.out
        guard total > duration, total.seconds > 0 else { return wanted }
        let share = duration.seconds / total.seconds
        return (CMTimeMultiplyByFloat64(wanted.in, multiplier: share),
                CMTimeMultiplyByFloat64(wanted.out, multiplier: share))
    }

    /// How far in the camera is at `time`, 1 being not at all.
    ///
    /// Eased in at the start and out at the end, so a region is a movement rather than a
    /// switch. Outside the region it is exactly 1, which is what lets several zooms be
    /// summed without them fighting. A ramp of zero at either end means the camera is
    /// already there on the first frame it covers — the seam a split leaves.
    public func scale(at time: CMTime) -> Double {
        guard contains(time) else { return 1 }
        let ramps = ramps
        // A ramp of zero is "arrived", not "divide by zero": the progress it contributes
        // is 1 everywhere inside the region, so the other end alone decides the curve.
        let rising = ramps.in.seconds > 0 ? (time - start).seconds / ramps.in.seconds : 1
        let falling = ramps.out.seconds > 0 ? (end - time).seconds / ramps.out.seconds : 1
        let progress = min(1, max(0, min(rising, falling)))
        return 1 + (scale - 1) * easing.apply(progress)
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

/// One run of the recording's *own* sound, on a lane that no longer follows the picture.
///
/// The recording's sound is normally cut wherever the picture is cut, because it is one
/// take — that is what `Timeline.detachedSound == nil` means, and it is the right default.
/// But the three edits people reach for next are all edits to the sound *alone*: let
/// someone keep talking over a cut, take a cough out without losing the frame, slide
/// narration a few frames to land on an action. None of those can be spelled as a
/// property of a `Clip`, because a `Clip` has no timeline position of its own — the
/// sequence is contiguous by construction, which is exactly the invariant that makes the
/// picture trustworthy and exactly the one a detached sound has to break.
///
/// So a detached lane is a list of *regions* rather than a clip sequence: each run says
/// where it sits on the timeline, how long it lasts there, and which second of the
/// recording it starts at. Gaps are legal (that is silence, deliberately placed), order
/// is not load-bearing, and overlaps are possible — two runs over one moment simply means
/// two tracks in the mix, which is what any editor does with overlapping audio.
///
/// Conforming to `TimelineRegion` is the whole design: dragging, resizing, snapping,
/// deleting, shifting with a ripple and clamping to the edit are already written once for
/// every lane, and a run gets all of it by being the same shape as an `AudioRegion`.
public struct SoundRun: TimelineRegion {
    public let id: UUID
    public var start: CMTime
    public var duration: CMTime
    /// The in-point in the recording. Trimming a run changes how much source it consumes
    /// and never re-derives this from the timeline, for the reason `Clip.sourceStart`
    /// gives: that is how an edit stays attached to the footage it was made against.
    public var sourceStart: CMTime
    /// Source seconds per timeline second, carried over from the clip this run was
    /// detached from so a sped-up edit sounds identical the instant it is detached.
    public var speed: Double

    public init(id: UUID = UUID(),
                start: CMTime,
                duration: CMTime,
                sourceStart: CMTime,
                speed: Double = 1) {
        self.id = id
        self.start = start
        self.duration = duration
        self.sourceStart = sourceStart
        self.speed = max(Clip.minimumSpeed, min(speed, Clip.maximumSpeed))
    }

    /// Decoded field by field for the reason `Timeline.init(from:)` gives: a run missing
    /// its speed is a run at normal speed, not a project that will not open.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, default fallback: @autoclosure () -> T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback()
        }
        id = value(.id, default: UUID())
        start = value(.start, default: .zero)
        duration = value(.duration, default: .zero)
        sourceStart = value(.sourceStart, default: .zero)
        speed = value(.speed, default: 1)
    }

    enum CodingKeys: String, CodingKey {
        case id, start, duration, sourceStart, speed
    }

    /// How much of the recording this run consumes — derived, never stored, so it cannot
    /// disagree with how long the run occupies. The same bargain `Clip.duration` makes,
    /// read the other way round.
    public var sourceDuration: CMTime {
        CMTimeMultiplyByFloat64(duration, multiplier: speed)
    }

    public var sourceEnd: CMTime { sourceStart + sourceDuration }

    /// Where a timeline offset inside this run lands in the recording.
    public func sourceTime(atOffset offset: CMTime) -> CMTime {
        sourceStart + CMTimeMultiplyByFloat64(offset, multiplier: speed)
    }
}

/// A stretch where the pointer behaves differently from the rest of the recording.
///
/// `CursorStyle` is one setting for the whole take, and that is the right shape for
/// "how big is the pointer" — but not for the three things people actually ask of a
/// pointer in a demo, all of which are about *a moment*: get out of the way while a face
/// or a menu is on screen, calm one bad flick without over-smoothing the rest, and hold
/// still while something else is being read.
///
/// So this is an override laid on top of the global style rather than a replacement for
/// it: outside every region the pointer is drawn exactly as `CursorStyle` says, and a
/// project with no cursor regions renders frame for frame as it did before this existed.
///
/// A region rather than a pair of keyframes because that is what the edit *is* — a
/// stretch with a start and an end — and because `TimelineRegion` already carries
/// dragging, resizing, snapping, trimming and deleting for free.
public struct CursorRegion: TimelineRegion {
    public let id: UUID
    public var start: CMTime
    public var duration: CMTime

    /// Take the pointer out of the picture for this stretch.
    public var isHidden: Bool

    /// How much *more* the pointer is calmed here, 0 being not at all.
    ///
    /// On top of `CursorStyle.smoothing`, not instead of it: the global filter runs once
    /// over the whole recording and is what makes the pointer look deliberate, while this
    /// is for the one flick that survived it. Implemented as an average over a short
    /// window rather than a second pass of the global filter, because a filter has to run
    /// over every sample to give an answer and the renderer asks about one frame at a
    /// time — an average over `smoothingWindow(at:)` gives the same answer whether you
    /// scrubbed to this frame or played to it, which is the rule the whole renderer is
    /// built on.
    public var smoothing: Double

    /// Hold the pointer where it was when this region began.
    ///
    /// For the case smoothing cannot fix: the hand wanders off to the side while the
    /// viewer is meant to be reading something, and the honest edit is not a calmer
    /// wander but no wander at all. The pointer eases to a stop over `transition` rather
    /// than freezing between two frames, so it reads as the hand settling.
    public var isHeld: Bool

    /// How long the change takes to arrive at each end.
    ///
    /// Clamped to half the region, the same rule `ZoomRegion.transition` follows, so a
    /// short region never spends longer arriving than it spends there. Zero is allowed and
    /// means a hard cut — occasionally what you want when the pointer has to be gone on an
    /// exact frame.
    public var transition: CMTime

    /// The longest window `smoothing` asks the averaging to look back over.
    ///
    /// Half a second: beyond that the pointer is visibly somewhere the hand is not, which
    /// is a worse fault than the flick it was smoothing away.
    public static let maximumSmoothingWindow = 0.5

    public init(id: UUID = UUID(),
                start: CMTime,
                duration: CMTime,
                isHidden: Bool = true,
                smoothing: Double = 0,
                isHeld: Bool = false,
                transition: CMTime = CMTime(value: 1, timescale: 5)) {
        self.id = id
        self.start = start
        self.duration = duration
        self.isHidden = isHidden
        self.smoothing = smoothing
        self.isHeld = isHeld
        self.transition = transition
    }

    /// Decodes a stretch written by an older or a newer build.
    ///
    /// Field by field, for the reason `Timeline.init(from:)` gives: a key this build does
    /// not know, or one a hand edit broke, must not cost the user the whole region. The
    /// defaults are chosen so a region carrying nothing but a start and a length is a
    /// plain hidden pointer — which is what the menu item makes, and the only kind of
    /// cursor region anything could have written before these fields existed.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, default fallback: @autoclosure () -> T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback()
        }
        id = value(.id, default: UUID())
        start = value(.start, default: .zero)
        duration = value(.duration, default: .zero)
        isHidden = value(.isHidden, default: true)
        smoothing = value(.smoothing, default: 0)
        isHeld = value(.isHeld, default: false)
        transition = value(.transition, default: CMTime(value: 1, timescale: 5))
    }

    /// Spelled out so the decoder above and the synthesised encoder agree, and so renaming
    /// a property is a compile error rather than a silently unreadable project.
    enum CodingKeys: String, CodingKey {
        case id, start, duration, isHidden, smoothing, isHeld, transition
    }

    /// The same region, clamped to what the renderer can act on.
    ///
    /// Read-time clamping, like `CameraStyle.sanitised`: a project is a file, and a file
    /// can say `smoothing: 40` or a negative ramp.
    public var sanitised: CursorRegion {
        CursorRegion(id: id,
                     start: start,
                     duration: duration,
                     isHidden: isHidden,
                     smoothing: min(max(smoothing, 0), 1),
                     isHeld: isHeld,
                     transition: max(.zero, min(transition,
                                                CMTimeMultiplyByFloat64(duration, multiplier: 0.5))))
    }

    /// Whether this region asks for anything at all.
    ///
    /// A region that hides nothing, smooths nothing and holds nothing is a chip on the
    /// timeline that changes no pixel — worth saying out loud so the inspector can warn
    /// instead of leaving someone wondering why the picture did not move.
    public var isInert: Bool { !isHidden && !isHeld && smoothing <= 0 }

    /// How far this region's effect has arrived at `time`, 0 outside and 1 in the middle.
    ///
    /// Eased in at the start and out at the end for the same reason `ZoomRegion.scale(at:)`
    /// is: the interesting part of hiding a pointer is the boundary, and a pointer that
    /// vanishes between two frames reads as a dropped frame rather than as an edit. All
    /// three settings are scaled by this one number, so the fade, the smoothing and the
    /// hold arrive together instead of each choosing its own curve.
    ///
    /// `easeInOut` rather than `spring`: a spring overshoots, and overshooting an opacity
    /// means a pointer that goes past invisible and comes back.
    public func presence(at time: CMTime) -> Double {
        guard contains(time) else { return 0 }
        let ramp = min(transition, CMTimeMultiplyByFloat64(duration, multiplier: 0.5))
        guard ramp.seconds > 0 else { return 1 }
        let progress = min((time - start).seconds, (end - time).seconds) / ramp.seconds
        return Easing.easeInOut.apply(min(1, max(0, progress)))
    }

    /// How far back the averaging looks at `time`, in seconds — 0 when it should not.
    public func smoothingWindow(at time: CMTime) -> Double {
        let strength = min(max(smoothing, 0), 1) * presence(at: time)
        return strength > 0 ? strength * Self.maximumSmoothingWindow : 0
    }

    /// What the timeline chip calls this one.
    ///
    /// The strongest thing it does, not a list: the chip is thirty points wide at a
    /// sensible zoom, and "Hidden" is the whole story whatever else is set — nothing about
    /// a pointer nobody can see is worth a second word.
    public var title: String {
        if isHidden { return "Hidden" }
        if isHeld { return "Held" }
        if smoothing > 0 { return "Calm" }
        return "Pointer"
    }
}

/// What every cursor region covering one moment adds up to.
///
/// Resolved rather than "the region in force", and that is a deliberate choice about
/// overlaps. Picking one winner — the last, as captions do — means that where two regions
/// overlap the answer switches from one to the other on a single frame, and since each
/// region's `presence` is 0 at its own edges, the switch happens exactly where both are
/// weakest: the pointer would flash back into shot in the middle of two overlapping
/// hides. Taking the strongest of each effect instead is continuous by construction, so a
/// dragged region can be overlapped with another without anything popping, and needs no
/// rule about which one the user meant.
public struct CursorOverride: Equatable, Sendable {
    /// How far the pointer has faded out: 0 drawn as usual, 1 not drawn at all.
    public var hiding: Double
    /// Seconds of extra averaging, on top of `CursorStyle.smoothing`.
    public var smoothingWindow: Double
    /// How far the pointer has settled onto `heldSince`, 0 being not at all.
    public var holding: Double
    /// The timeline moment whose pointer position is being held.
    public var heldSince: CMTime?

    public init(hiding: Double = 0,
                smoothingWindow: Double = 0,
                holding: Double = 0,
                heldSince: CMTime? = nil) {
        self.hiding = hiding
        self.smoothingWindow = smoothingWindow
        self.holding = holding
        self.heldSince = heldSince
    }

    /// Nothing asked for: the pointer is drawn exactly as the global style says.
    public static let none = CursorOverride()

    public var isNothing: Bool { self == .none }
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
