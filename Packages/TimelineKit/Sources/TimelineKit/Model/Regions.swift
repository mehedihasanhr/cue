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

    /// Whether this zoom does anything.
    ///
    /// Deliberately not the same as deleting it, and deliberately not the same as
    /// `isLocked`. A lock says "do not move this"; switching one off says "not this one,
    /// not now" while keeping its framing, its timing and its place on the lane so it can
    /// be brought back without being re-aimed. That is the difference between trying
    /// something and losing it — and it is what makes a whole run of suggested zooms
    /// something you can audition rather than something you have to accept or destroy.
    ///
    /// Read by the camera and by nothing else: a disabled zoom is still on the timeline,
    /// still selectable, still editable, and contributes exactly nothing to the frame.
    public var isEnabled: Bool

    /// Whether somebody has framed this zoom by hand.
    ///
    /// Auto-zoom's contract is that a later run replaces the previous run's output, which
    /// is right until the moment the user drags one of those suggestions to where they
    /// actually wanted it. After that it is no longer the run's output: it is an edit that
    /// happens to have started life as a suggestion, and throwing it away is throwing away
    /// work nobody can get back.
    ///
    /// Deliberately not the same as `source = .manual`: where a zoom came from is worth
    /// keeping — "suggested by a click, then framed by you" is a more useful thing for the
    /// inspector to say than either half alone — and rewriting the provenance to protect
    /// the edit would lose it.
    ///
    /// Set by direct manipulation only. Sliding the scale or the ramp is tuning, and a zoom
    /// somebody tuned but never aimed is still the run's to replace.
    public var isEdited: Bool

    /// A cut rather than a movement.
    ///
    /// The camera is fully in on the first frame the region covers and fully out on the
    /// first frame after it, with no travel at either end. For the moment where a smooth
    /// push-in reads as slow — a keyboard shortcut appearing, a dialog opening — and the
    /// viewer should simply find themselves closer. The ramp is kept underneath, not
    /// zeroed, so switching this off gives the zoom its movement back exactly as it was.
    ///
    /// An instant zoom never glides either: gliding is one movement turning into another,
    /// and this zoom has asked for no movement at all. See `ZoomGlide`.
    public var isInstant: Bool

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
    /// As far out as a zoom will go: the recording at half its size, with the background
    /// showing all round it.
    ///
    /// Below 1 a zoom stops being a push in and becomes a pull back — the framed picture
    /// shrinks inside the frame, corners, shadow and border with it, and more of the
    /// background shows. It is the move for an opening or closing shot, or for stepping
    /// back from a close-up so the viewer sees the whole screen again with room around it.
    /// Half is where the picture is still readable on a laptop; much further and it is a
    /// thumbnail on a wallpaper.
    ///
    /// Projects written before this existed only ever hold 1 or more, and decode exactly
    /// as they did: the decoder reads `scale` as it was stored and clamps nothing.
    public static let minimumScale = 0.5

    /// How strongly a camera at this scale departs from the whole picture.
    ///
    /// When zooms overlap the strongest decides the shot. Measured in doublings rather than
    /// as the raw number, so a pull back to 0.5× and a push in to 2× count as equally
    /// strong: both are one doubling away from 1×. Comparing the raw scales would let any
    /// push in, however slight, beat any pull back, however deep.
    public static func strength(ofScale scale: Double) -> Double {
        abs(log2(max(scale, 1e-6)))
    }

    /// Whether this zoom pulls back rather than pushing in.
    public var zoomsOut: Bool { scale < 1 }
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
                isLocked: Bool = false,
                isEnabled: Bool = true,
                isEdited: Bool = false,
                isInstant: Bool = false) {
        self.id = id
        self.start = start
        self.duration = duration
        self.scale = max(ZoomRegion.minimumScale, min(scale, ZoomRegion.maximumScale))
        self.center = center
        self.easing = easing
        self.transition = transition
        self.transitionIn = transitionIn
        self.transitionOut = transitionOut
        self.followsCursor = followsCursor
        self.source = source
        self.isLocked = isLocked
        self.isEnabled = isEnabled
        self.isEdited = isEdited
        self.isInstant = isInstant
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
        // Absent means on, which is what every zoom written before this existed was.
        isEnabled = value(.isEnabled, default: true)
        // Absent means untouched. A project saved before this existed has no record of
        // which of its suggestions were framed by hand, and guessing `true` would freeze
        // every one of them against a regeneration the user may well want.
        isEdited = value(.isEdited, default: false)
        // Absent means a movement, which is what every zoom written before this existed was.
        isInstant = value(.isInstant, default: false)
    }

    /// Spelled out so the decoder above and the synthesised encoder agree, and so renaming
    /// a property is a compile error rather than a silently unreadable project.
    enum CodingKeys: String, CodingKey {
        case id, start, duration, scale, center, easing, transition
        case transitionIn, transitionOut, followsCursor, source, isLocked, isEnabled, isEdited
        case isInstant
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
        // A cut has no ramps at all, whatever is stored: zero at both ends is exactly the
        // seam a split leaves, so `scale(at:)` needs no second idea of "already there".
        guard !isInstant else { return (.zero, .zero) }
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
    /// switch. The same curve serves a pull back: below 1 it eases from 1 down to `scale`
    /// and back up again, so a zoom out arrives and leaves exactly as a zoom in does. Outside the region it is exactly 1, which is what lets several zooms be
    /// summed without them fighting. A ramp of zero at either end means the camera is
    /// already there on the first frame it covers — the seam a split leaves.
    public func scale(at time: CMTime) -> Double {
        // A zoom that is switched off is 1 everywhere, which is the same answer as a zoom
        // that is not there. Asked here rather than by each caller so there is one place
        // that decides it and no way for the preview and the exporter to disagree.
        guard isEnabled, contains(time) else { return 1 }
        let ramps = ramps
        // A ramp of zero is "arrived", not "divide by zero": the progress it contributes
        // is 1 everywhere inside the region, so the other end alone decides the curve.
        let rising = ramps.in.seconds > 0 ? (time - start).seconds / ramps.in.seconds : 1
        let falling = ramps.out.seconds > 0 ? (end - time).seconds / ramps.out.seconds : 1
        let progress = min(1, max(0, min(rising, falling)))
        return 1 + (scale - 1) * easing.apply(progress)
    }
}

/// Something hidden — a password, a name, a face — or, as a spotlight, the one thing
/// that is *not* dimmed.
///
/// One region for four kinds, because they are the same edit: a rectangle of the
/// recording, for a stretch of time. Only what happens inside it differs.
public struct BlurRegion: TimelineRegion {
    /// The raw values of the first two are what every project written so far stores,
    /// and they stay exactly as they are — renaming one would make every blur in every
    /// old project unreadable.
    public enum Style: String, Codable, Sendable, CaseIterable {
        case gaussian, pixelate
        /// A solid colour over the area. The one kind that cannot be reversed by
        /// looking closely, which is what a password wants.
        case cover
        /// The area is left alone and everything else in the picture is dimmed.
        case spotlight
    }

    public let id: UUID
    public var start: CMTime
    public var duration: CMTime
    /// Normalised to the frame, for the same reason `ZoomRegion.center` is.
    public var rect: CGRect
    public var style: Style
    public var radius: Double
    /// The cover's colour. Black unless somebody says otherwise.
    public var color: ColorValue
    /// How much a spotlight darkens the rest of the picture, 0 to 1.
    public var dimming: Double
    /// How soft a spotlight's edge is, as a fraction of the shorter side of the
    /// recording — so the feather is the same width at 1080p and at 4K.
    public var softness: Double
    /// Rounded corners on the region, as a fraction of its own shorter side: 0 is
    /// square, 0.5 is a pill. Zero for every region written before it existed, which
    /// keeps those drawn pixel for pixel as they were.
    public var cornerRadius: Double
    /// Where the mask goes while it follows what it covers, or `nil` for a mask that stays
    /// where it was put — which is every mask written before following existed, and draws
    /// exactly as it did. See `MaskPath`.
    public var path: MaskPath?

    public static let defaultDimming = 0.6
    public static let defaultSoftness = 0.02

    public init(id: UUID = UUID(), start: CMTime, duration: CMTime,
                rect: CGRect, style: Style = .gaussian, radius: Double = 18,
                color: ColorValue = .black,
                dimming: Double = BlurRegion.defaultDimming,
                softness: Double = BlurRegion.defaultSoftness,
                cornerRadius: Double = 0,
                path: MaskPath? = nil) {
        self.id = id
        self.start = start
        self.duration = duration
        self.rect = rect
        self.style = style
        self.radius = radius
        self.color = color
        self.dimming = dimming
        self.softness = softness
        self.cornerRadius = cornerRadius
        self.path = path?.isEmpty == true ? nil : path
    }

    /// Decoded field by field, for the reason `ZoomRegion.init(from:)` gives: the lane is
    /// decoded as one array, so one region that will not decode costs the project every
    /// blur it has. A region written before the cover and the spotlight existed carries
    /// only the first six keys and decodes to exactly the region it was; a kind this build
    /// has never heard of is read as a blur rather than thrown away, so the thing it was
    /// hiding stays hidden.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, default fallback: @autoclosure () -> T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback()
        }
        id = value(.id, default: UUID())
        start = value(.start, default: .zero)
        duration = value(.duration, default: .zero)
        rect = value(.rect, default: CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4))
        style = value(.style, default: .gaussian)
        radius = value(.radius, default: 18)
        color = value(.color, default: ColorValue.black)
        dimming = min(max(value(.dimming, default: Self.defaultDimming), 0), 1)
        softness = min(max(value(.softness, default: Self.defaultSoftness), 0), 0.2)
        cornerRadius = min(max(value(.cornerRadius, default: 0), 0), 0.5)
        // A path that cannot be read, or has nothing in it, is a still mask: it goes on
        // hiding what it was put over rather than costing the project the region.
        let path = (try? container.decodeIfPresent(MaskPath.self, forKey: .path)) ?? nil
        self.path = path?.isEmpty == true ? nil : path
    }

    /// Spelled out so the decoder above and the synthesised encoder agree, and so renaming
    /// a property is a compile error rather than a silently unreadable project.
    enum CodingKeys: String, CodingKey {
        case id, start, duration, rect, style, radius, color, dimming, softness, cornerRadius, path
    }
}

/// Something added on top: a label, an arrow, a box, a picture.
///
/// One type for every kind, on purpose. Where it sits, how it is turned, how see-through
/// it is, when it comes and goes and how it arrives — all of that is the same whatever the
/// annotation says, so it is written once here and every kind gets it. Only `kind` holds
/// what differs.
///
/// **Coordinates.** `rect` is normalised to the *finished frame*, top-left origin, 0…1 on
/// each axis — never to the preview on screen, which changes size with the window. That is
/// what keeps a label exactly where it was put through a window resize, a different export
/// size and a reopen, and it is why preview and export can share one renderer. `rotation`
/// turns the rect about its own centre, measured on the finished picture (so a square stays
/// square at any aspect ratio). An arrow's two ends are normalised to the rect.
///
/// **Order.** The position in `Timeline.annotations` is the stacking order: later is on
/// top. It is data, not an accident of drawing, so the reorder commands change it and
/// nothing else does.
public struct AnnotationItem: TimelineRegion {
    public enum Kind: Codable, Equatable, Sendable {
        case text(String)
        case arrow(from: CGPoint, to: CGPoint)
        case rectangle
        case image(path: String)
        case ellipse
        /// Two ends normalised to the rect, like an arrow's, with no head.
        case line(from: CGPoint, to: CGPoint)
        /// A marker-pen stroke over something: a translucent rounded fill, never opaque.
        case highlight
        /// A numbered circle. Always round, whatever shape of box it is given.
        case step(Int)
        /// Words in a bubble, with a tail whose tip is normalised to the rect and may lie
        /// outside it — that is the point of a tail.
        case callout(String, tail: CGPoint)
    }

    /// What an annotation is pinned to.
    ///
    /// Only `canvas` is drawn today. `content` is here so a project can say "this arrow
    /// points at the button, follow the button" when zooms learn to carry annotations with
    /// them — deciding the field now means that is a new behaviour rather than a migration.
    public enum Attachment: String, Codable, Sendable, CaseIterable {
        /// Stays where it is on the finished frame, whatever the camera does. Titles,
        /// explanations, anything addressed to the viewer.
        case canvas
        /// Stays on the part of the recording it was put over. Arrows at buttons.
        case content
    }

    public let id: UUID
    public var start: CMTime
    public var duration: CMTime
    public var kind: Kind
    public var rect: CGRect
    public var color: ColorValue
    public var fontSize: Double
    /// Degrees, clockwise as seen on the picture, about the rect's centre.
    public var rotation: Double
    /// 0…1, on top of whatever the entrance and exit are doing.
    public var opacity: Double
    public var animation: AnnotationAnimation
    /// A locked annotation draws as normal and can be selected and restyled, but will not
    /// move — on the picture or on the timeline.
    public var isLocked: Bool
    /// Off. Kept on the timeline, drawn nowhere — not in the preview and not in the export,
    /// so what you see is always what you get.
    public var isHidden: Bool
    public var attachment: Attachment
    /// Line thickness, fill, type and shadow. Its defaults draw exactly what every
    /// annotation drew before any of it could be set.
    public var style: AnnotationStyle

    public init(id: UUID = UUID(), start: CMTime, duration: CMTime, kind: Kind,
                rect: CGRect, color: ColorValue = .init(r: 1, g: 0.23, b: 0.19),
                fontSize: Double = 0.06,
                rotation: Double = 0,
                opacity: Double = 1,
                animation: AnnotationAnimation = AnnotationAnimation(),
                isLocked: Bool = false,
                isHidden: Bool = false,
                attachment: Attachment = .canvas,
                style: AnnotationStyle = AnnotationStyle()) {
        self.id = id
        self.start = start
        self.duration = duration
        self.kind = kind
        self.rect = rect
        self.color = color
        self.fontSize = fontSize
        self.rotation = rotation
        self.opacity = opacity
        self.animation = animation
        self.isLocked = isLocked
        self.isHidden = isHidden
        self.attachment = attachment
        self.style = style
        sanitise()
    }

    /// Read field by field, for the reason `Timeline.init(from:)` gives — and more so here,
    /// because the annotation lane is decoded as one array: one item that failed to decode
    /// used to take every annotation in the project with it. A project written before the
    /// shared fields existed opens with each at its default, which is exactly how it looked.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, default fallback: @autoclosure () -> T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback()
        }
        id = value(.id, default: UUID())
        start = value(.start, default: .zero)
        duration = value(.duration, default: CMTime(seconds: 3, preferredTimescale: 600))
        kind = value(.kind, default: .rectangle)
        rect = value(.rect, default: CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4))
        color = value(.color, default: ColorValue(r: 1, g: 0.23, b: 0.19))
        fontSize = value(.fontSize, default: 0.06)
        rotation = value(.rotation, default: 0)
        opacity = value(.opacity, default: 1)
        animation = value(.animation, default: AnnotationAnimation())
        isLocked = value(.isLocked, default: false)
        isHidden = value(.isHidden, default: false)
        attachment = value(.attachment, default: .canvas)
        style = value(.style, default: AnnotationStyle())
        sanitise()
    }

    enum CodingKeys: String, CodingKey {
        case id, start, duration, kind, rect, color, fontSize
        case rotation, opacity, animation, isLocked, isHidden, attachment, style
    }

    /// Makes every number one the renderer can draw.
    ///
    /// NaN and infinity do not come from a person, they come from a division somewhere —
    /// a zero-sized view, a drag measured against a stage that had not laid out — and once
    /// one is in the project file it is in every frame of every export. So nothing
    /// unreadable gets past the model: a broken value becomes the default rather than a
    /// broken annotation.
    public mutating func sanitise() {
        if !start.isNumeric || start.seconds.isNaN || start < .zero { start = .zero }
        if !duration.isNumeric || duration.seconds.isNaN || duration < .zero { duration = .zero }
        rect = AnnotationGeometry.sanitised(rect)
        if !fontSize.isFinite { fontSize = 0.06 }
        fontSize = min(1, max(0.005, fontSize))
        rotation = AnnotationGeometry.normalisedDegrees(rotation)
        opacity = opacity.isFinite ? min(1, max(0, opacity)) : 1
        animation.sanitise()
        if case .arrow(let from, let to) = kind {
            kind = .arrow(from: AnnotationGeometry.sanitised(from, default: CGPoint(x: 0, y: 1)),
                          to: AnnotationGeometry.sanitised(to, default: CGPoint(x: 1, y: 0)))
        }
        sanitiseNewerKinds()
        style.sanitise()
    }

    /// The same annotation as it is `offset` seconds after its start: how visible, how big
    /// and how far from home. Asked by the renderer, so preview and export animate alike.
    public func pose(atOffset offset: Double) -> AnnotationPose {
        var pose = animation.pose(atOffset: offset, of: duration.seconds)
        pose.opacity *= opacity
        return pose
    }
}

/// A line of spoken text, on screen while it is being said.
public struct CaptionCue: TimelineRegion {
    /// One word of a line, and when in the line it is said.
    ///
    /// As fractions of the cue rather than as times, so a cue that is dragged, stretched
    /// or trimmed carries its words with it and nothing has to be recomputed.
    public struct Word: Codable, Equatable, Sendable {
        public var text: String
        /// Where in the cue the word begins, 0 at its start and 1 at its end.
        public var from: Double
        /// Where it ends.
        public var to: Double

        public init(text: String, from: Double, to: Double) {
            self.text = text
            self.from = min(1, max(0, from))
            self.to = min(1, max(self.from, to))
        }
    }

    public let id: UUID
    public var start: CMTime
    public var duration: CMTime
    public var text: String
    /// When each word was said, when a recogniser said so. Empty for a line typed by hand
    /// and for every caption made before word timings were kept.
    public var words: [Word]

    public init(id: UUID = UUID(), start: CMTime, duration: CMTime, text: String, words: [Word] = []) {
        self.id = id
        self.start = start
        self.duration = duration
        self.text = text
        self.words = words
    }

    /// Read field by field, so a caption written before it had words opens as the caption
    /// it was — and so one caption that will not decode does not cost the project all of
    /// them, which is what decoding a lane as one array does otherwise.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, default fallback: @autoclosure () -> T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback()
        }
        id = value(.id, default: UUID())
        start = value(.start, default: .zero)
        duration = value(.duration, default: CMTime(seconds: 2, preferredTimescale: 600))
        text = value(.text, default: "")
        words = value(.words, default: [])
    }

    enum CodingKeys: String, CodingKey {
        case id, start, duration, text, words
    }

    /// The words of the line and when each is said, whether or not anybody recorded it.
    ///
    /// The recogniser's timings when they still describe the text. Once the text has been
    /// edited they describe a sentence that is no longer there, so the words as they now
    /// stand are spread across the cue by length instead — a long word takes longer to say
    /// than a short one, which is near enough for a highlight to move along in step.
    public var timedWords: [Word] {
        let spoken = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !spoken.isEmpty else { return [] }
        if words.count == spoken.count,
           zip(words, spoken).allSatisfy({ $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == $1 }) {
            return words
        }
        let lengths = spoken.map { Double(max(1, $0.count)) }
        let total = lengths.reduce(0, +)
        var from = 0.0
        return zip(spoken, lengths).map { word, length in
            defer { from += length / total }
            return Word(text: word, from: from, to: from + length / total)
        }
    }

    /// Which word is being said at a moment on the timeline, or `nil` between words and
    /// outside the cue.
    public func wordIndex(at time: CMTime) -> Int? {
        guard duration.seconds > 0, contains(time) else { return nil }
        let progress = (time - start).seconds / duration.seconds
        let timed = timedWords
        // The last word that has begun: a highlight that goes out between words flickers
        // at the rate of speech, so it stays on a word until the next one starts.
        return timed.lastIndex { $0.from <= progress + 0.000_1 }
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
    /// Seconds over which the sound rises from silence where it starts.
    ///
    /// Music that starts and stops at full volume sounds like a mistake, which is why
    /// nearly every piece of music laid under a video wants both of these.
    public var fadeIn: Double
    /// Seconds over which it falls to silence where it ends.
    public var fadeOut: Double
    /// Lower this sound wherever somebody is speaking. Meant for music; see `Ducking`.
    public var ducksUnderSpeech: Bool
    /// How much lower, in decibels, while somebody speaks. Positive: 12 means 12 dB down.
    public var duckAmount: Double
    /// Seconds of the sound's own shape that lie before its start and after its end.
    ///
    /// Nought, except for a piece cut out of a longer sound for an excerpt export: its
    /// fades then carry on from where they had got to, rather than starting again at the
    /// excerpt's edges — a stretch taken from the middle of a fade-in begins part-way up
    /// it, as the full edit plays it. Not saved: an excerpt is made to export and never
    /// written down.
    public var leadIn: Double = 0
    public var leadOut: Double = 0

    public static let defaultDuckAmount: Double = 12

    public init(id: UUID = UUID(), start: CMTime, duration: CMTime, path: String,
                gain: Double = 1, sourceStart: CMTime = .zero,
                fadeIn: Double = 0, fadeOut: Double = 0,
                ducksUnderSpeech: Bool = false, duckAmount: Double = AudioRegion.defaultDuckAmount) {
        self.id = id
        self.start = start
        self.duration = duration
        self.path = path
        self.gain = gain
        self.sourceStart = sourceStart
        self.fadeIn = fadeIn
        self.fadeOut = fadeOut
        self.ducksUnderSpeech = ducksUnderSpeech
        self.duckAmount = duckAmount
    }

    /// The fades as they are heard: never longer than the sound, and never overlapping.
    ///
    /// Stored as asked for and fitted here, so trimming a sound short and then long again
    /// gives its fades back rather than having cut them down on the way.
    public var heardFades: (fadeIn: Double, fadeOut: Double) {
        let length = max(0, duration.seconds) + max(0, leadIn) + max(0, leadOut)
        let rising = fadeIn.isFinite ? min(max(0, fadeIn), length) : 0
        let falling = fadeOut.isFinite ? min(max(0, fadeOut), length - rising) : 0
        return (rising, falling)
    }

    /// How loud it is at a moment, as a fraction of `gain`: 0 in silence, 1 at full level.
    public func envelope(at time: CMTime) -> Double {
        guard contains(time) else { return 0 }
        return shape(at: time)
    }

    /// The fades' level at a moment, whether or not the sound is playing then — so the
    /// very end of a sound without a fade out reads 1, where `envelope` reads 0.
    public func shape(at time: CMTime) -> Double {
        let fades = heardFades
        let into = (time - start).seconds + max(0, leadIn)
        let left = (end - time).seconds + max(0, leadOut)
        var level = 1.0
        if fades.fadeIn > 0 { level = min(level, into / fades.fadeIn) }
        if fades.fadeOut > 0 { level = min(level, left / fades.fadeOut) }
        return max(0, min(1, level))
    }

    /// The moments inside the sound where its level turns a corner. Between two
    /// neighbours the level is a straight line, so ramps laid corner to corner are exact.
    public var fadeCorners: [CMTime] {
        let fades = heardFades
        let first = start.seconds, last = end.seconds
        let risesFrom = first - max(0, leadIn), fallsTo = last + max(0, leadOut)
        var corners: Set<Double> = [first, last]
        if fades.fadeIn > 0 { corners.insert(risesFrom + fades.fadeIn) }
        if fades.fadeOut > 0 { corners.insert(fallsTo - fades.fadeOut) }
        if fades.fadeIn > 0, fades.fadeOut > 0 {
            // Where the rising line meets the falling one — a corner only when they meet
            // below full level, which is a piece short enough to be inside both fades.
            let meeting = (fallsTo * fades.fadeIn + risesFrom * fades.fadeOut) / (fades.fadeIn + fades.fadeOut)
            if (meeting - risesFrom) / fades.fadeIn < 1 { corners.insert(meeting) }
        }
        return corners.filter { $0 >= first && $0 <= last }.sorted()
            .map { CMTime(seconds: $0, preferredTimescale: 48_000) }
    }

    /// Decoded field by field, so a project saved before fades existed keeps its sounds.
    /// The synthesised decoder wants every key, and one missing would have thrown away
    /// every piece of music in the project.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        start = try container.decode(CMTime.self, forKey: .start)
        duration = try container.decode(CMTime.self, forKey: .duration)
        path = try container.decode(String.self, forKey: .path)
        gain = try container.decodeIfPresent(Double.self, forKey: .gain) ?? 1
        sourceStart = try container.decodeIfPresent(CMTime.self, forKey: .sourceStart) ?? .zero
        fadeIn = (try? container.decodeIfPresent(Double.self, forKey: .fadeIn)) ?? 0
        fadeOut = (try? container.decodeIfPresent(Double.self, forKey: .fadeOut)) ?? 0
        ducksUnderSpeech = (try? container.decodeIfPresent(Bool.self, forKey: .ducksUnderSpeech)) ?? false
        duckAmount = (try? container.decodeIfPresent(Double.self, forKey: .duckAmount)) ?? Self.defaultDuckAmount
    }

    enum CodingKeys: String, CodingKey {
        case id, start, duration, path, gain, sourceStart, fadeIn, fadeOut, ducksUnderSpeech, duckAmount
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

    /// Turn the pointer spotlight on here, when the Pointer panel limits it to marked
    /// stretches. See `PointerEffectScope` for why the stretches are these ones.
    public var spotlights: Bool
    /// Turn the pointer magnifier on here, on the same terms.
    public var magnifies: Bool

    public init(id: UUID = UUID(),
                start: CMTime,
                duration: CMTime,
                isHidden: Bool = true,
                smoothing: Double = 0,
                isHeld: Bool = false,
                transition: CMTime = CMTime(value: 1, timescale: 5),
                spotlights: Bool = false,
                magnifies: Bool = false) {
        self.id = id
        self.start = start
        self.duration = duration
        self.isHidden = isHidden
        self.smoothing = smoothing
        self.isHeld = isHeld
        self.transition = transition
        self.spotlights = spotlights
        self.magnifies = magnifies
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
        spotlights = value(.spotlights, default: false)
        magnifies = value(.magnifies, default: false)
    }

    /// Spelled out so the decoder above and the synthesised encoder agree, and so renaming
    /// a property is a compile error rather than a silently unreadable project.
    enum CodingKeys: String, CodingKey {
        case id, start, duration, isHidden, smoothing, isHeld, transition
        case spotlights, magnifies
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
                                                CMTimeMultiplyByFloat64(duration, multiplier: 0.5))),
                     spotlights: spotlights,
                     magnifies: magnifies)
    }

    /// Whether this region asks for anything at all.
    ///
    /// A region that hides nothing, smooths nothing and holds nothing is a chip on the
    /// timeline that changes no pixel — worth saying out loud so the inspector can warn
    /// instead of leaving someone wondering why the picture did not move.
    public var isInert: Bool { !isHidden && !isHeld && smoothing <= 0 && !spotlights && !magnifies }

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
        if spotlights { return "Spotlight" }
        if magnifies { return "Magnified" }
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
