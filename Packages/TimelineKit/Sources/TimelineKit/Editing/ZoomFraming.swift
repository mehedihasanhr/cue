import CoreGraphics
import Foundation

/// A zoom read as a rectangle of the recording, and the arithmetic for dragging it.
///
/// `ZoomRegion` stores a centre and a scale, because that is what the camera needs. Nobody
/// edits a zoom that way: what people know is *which part of the screen they want in shot*,
/// which is a rectangle. This is the one conversion between the two, and every surface that
/// draws or drags a framing box goes through it — the overlay on the preview, the model's
/// commands, and the tests.
///
/// One place, deliberately. The box on screen and the camera in the renderer disagreeing by
/// a rounding is the whole class of bug where a shot is framed one way and exports another,
/// and the only reliable cure is for there to be nothing to disagree.
///
/// **Normalised to the recording, top-left origin**, like a blur's rect. A zoom magnifies
/// both axes by one number, so the area is always *square in normalised space* — which is
/// the recording's own aspect ratio in pixels. That is what guarantees the output is never
/// stretched: there is no way to express a non-uniform framing, at any point in this type.
///
/// **What the box promises**: the part of the recording that fills the *picture* — the
/// rectangle the padding leaves for the footage, which is where a zoom lands its framing.
/// When the whole frame zooms (`CameraStyle.zoomsWholeFrame`) the picture also grows over
/// that padding, so the finished video shows a little more of the recording around the box,
/// or background where the recording runs out. The box does not widen to claim that bleed:
/// it would stop being square, stop meaning `scale`, and draw two different rectangles for
/// one zoom depending on a switch somewhere else.
public enum ZoomFraming {
    /// The tightest framing the camera will honour, as a fraction of the recording.
    public static var minimumSide: Double { 1 / ZoomRegion.maximumScale }

    /// What a zoom currently frames.
    ///
    /// Clamped, because the renderer clamps: the camera is held inside the picture at the
    /// last moment, so a zoom whose stored centre points off the edge is rendered pointing
    /// somewhere else. Drawing the stored centre showed a framing box hanging off the top
    /// of the picture that the finished video never used — the overlay promising one shot
    /// and the export giving another.
    public static func area(of zoom: ZoomRegion) -> CGRect {
        honoured(scale: zoom.scale, center: zoom.center)
    }

    /// The rectangle a drawn one will actually become: square, no wider than the whole
    /// recording, no tighter than the renderer allows, and wholly inside the picture.
    ///
    /// The centre is re-derived from the clamped scale rather than taken from the
    /// rectangle: if the drag asked for more than the renderer will give, the centre has to
    /// be the centre of what will actually be shown, or the picture drifts away from the
    /// box. Overlays draw through this, so what is under the pointer mid-drag is the
    /// framing that will be stored rather than the one that was asked for.
    public static func honoured(_ rect: CGRect) -> CGRect {
        honoured(scale: scale(forSide: rect.width),
                 center: CGPoint(x: rect.midX, y: rect.midY))
    }

    /// The scale a framing of this width stands for.
    ///
    /// A smaller box is a bigger zoom — the relationship a viewfinder has — and this is the
    /// only expression of it. Clamped to what the camera will actually do, so the number
    /// the box reports and the number the slider shows cannot part company at the ends.
    public static func scale(forSide side: Double) -> Double {
        min(ZoomRegion.maximumScale, max(1, 1 / max(side, 1e-6)))
    }

    /// How far a camera at this scale reaches from its own centre, as a fraction of the
    /// recording — which is also the distance it has to keep from every edge.
    public static func halfSide(forScale scale: Double) -> Double {
        0.5 / min(ZoomRegion.maximumScale, max(1, scale))
    }

    /// Where a camera at this scale may actually look.
    ///
    /// At 2× the centre can only travel between 0.25 and 0.75 before the frame shows its
    /// own edge. That sentence was written out four times — in the renderer's camera, here,
    /// in the suggester, and once more in the test that exists to check the first two agree
    /// — so a change to any one of them was a silent disagreement between the box on screen
    /// and the shot in the file. This is the one copy.
    public static func honoured(center: CGPoint, scale: Double) -> CGPoint {
        let half = halfSide(forScale: scale)
        return CGPoint(x: min(1 - half, max(half, center.x)),
                       y: min(1 - half, max(half, center.y)))
    }

    /// The framing a zoom at this scale, aimed here, works out to.
    public static func honoured(scale: Double, center: CGPoint) -> CGRect {
        let half = halfSide(forScale: scale)
        let centre = honoured(center: center, scale: scale)
        return CGRect(x: centre.x - half, y: centre.y - half, width: half * 2, height: half * 2)
    }

    /// The same framing moved, held inside the recording.
    public static func moved(_ area: CGRect, by delta: CGSize) -> CGRect {
        honoured(area.offsetBy(dx: delta.width, dy: delta.height))
    }

    // MARK: - Handles

    /// The eight ways to take hold of a framing box's edge.
    ///
    /// Every one of them does the same job — changing how much is in shot — and the only
    /// difference between them is which part of the box holds still while it happens. A
    /// zoom is one number, so there is no such thing as resizing one axis here; an edge
    /// handle opens the box evenly on the axis it is not dragging.
    public enum Handle: String, CaseIterable, Sendable, Hashable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

        public var isCorner: Bool {
            switch self {
            case .topLeft, .topRight, .bottomLeft, .bottomRight: true
            default: false
            }
        }

        public var movesLeft: Bool { self == .topLeft || self == .left || self == .bottomLeft }
        public var movesRight: Bool { self == .topRight || self == .right || self == .bottomRight }
        public var movesTop: Bool { self == .topLeft || self == .top || self == .topRight }
        public var movesBottom: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }

        /// How much of the pointer's travel counts, per axis.
        ///
        /// A corner is pulled along its diagonal, so both axes push it and the average of
        /// the two is the movement. An edge has one axis, and the other must count for
        /// nothing — otherwise dragging the left edge straight down would resize the box,
        /// which is the handle doing something nobody asked it for.
        public var axes: (x: Double, y: Double) {
            switch (movesLeft || movesRight, movesTop || movesBottom) {
            case (true, true): (0.5, 0.5)
            case (true, false): (1, 0)
            default: (0, 1)
            }
        }

        /// Where this handle sits on a box.
        public func point(in rect: CGRect) -> CGPoint {
            CGPoint(x: movesLeft ? rect.minX : (movesRight ? rect.maxX : rect.midX),
                    y: movesTop ? rect.minY : (movesBottom ? rect.maxY : rect.midY))
        }

        /// The handle's own area on a box of this size — what it draws in, and what a view
        /// widens by a few points to get something worth aiming at.
        ///
        /// A corner's arms run *inward* from its vertex, so its area hangs inside the box;
        /// an edge's bar straddles the middle of the edge it moves. Here rather than in the
        /// view because getting it wrong is not a cosmetic mistake: a handle placed by a
        /// method that fills the space it is offered — SwiftUI's `.position`, as it happens
        /// — takes its grab area with it, and one handle covering the whole picture silently
        /// swallows every other gesture on it, including dragging the box.
        public func frame(in rect: CGRect, size: CGSize) -> CGRect {
            let x = isCorner ? (movesRight ? point(in: rect).x - size.width : point(in: rect).x)
                             : point(in: rect).x - size.width / 2
            let y = isCorner ? (movesBottom ? point(in: rect).y - size.height : point(in: rect).y)
                             : point(in: rect).y - size.height / 2
            return CGRect(x: x, y: y, width: size.width, height: size.height)
        }
    }

    /// The framing after a drag on one of its handles.
    ///
    /// `delta` is the pointer's travel as a fraction of the recording. The edges this handle
    /// does not move stay where they are, so a resize feels like pulling a sheet rather than
    /// moving it — and an edge handle holds the *middle* of the other axis, because the axis
    /// it is not dragging has no near or far side to it.
    public static func resized(_ start: CGRect, by delta: CGSize, handle: Handle) -> CGRect {
        let axes = handle.axes
        let outward = (x: (handle.movesLeft ? -delta.width : delta.width) * axes.x,
                       y: (handle.movesTop ? -delta.height : delta.height) * axes.y)
        return resized(start, to: start.width + outward.x + outward.y, handle: handle)
    }

    /// The framing resized to a given side, anchored the way this handle anchors.
    public static func resized(_ start: CGRect, to side: Double, handle: Handle) -> CGRect {
        let side = max(minimumSide, min(1, side))
        let x: Double = if handle.movesLeft { start.maxX - side }
            else if handle.movesRight { start.minX }
            else { start.midX - side / 2 }
        let y: Double = if handle.movesTop { start.maxY - side }
            else if handle.movesBottom { start.minY }
            else { start.midY - side / 2 }
        return honoured(CGRect(x: x, y: y, width: side, height: side))
    }

    /// The framing scaled about its own middle — what the keyboard's `+` and `-` do.
    public static func scaled(_ area: CGRect, by factor: Double) -> CGRect {
        let side = max(minimumSide, min(1, area.width * factor))
        return honoured(CGRect(x: area.midX - side / 2, y: area.midY - side / 2,
                               width: side, height: side))
    }
}

/// Where a point on screen is in the recording, and back.
///
/// Two nested aspect fits: the recording sits somewhere inside the finished frame — the
/// padding, the crop and the camera all move it — and the finished frame sits somewhere
/// inside the preview pane. Overlays have to go both ways through that, every frame of
/// every drag, and getting one of the two conventions wrong is the bug where a box is
/// dragged an inch and the shot moves half an inch.
///
/// Everything here is in **points**, not pixels. A Retina display changes how many pixels a
/// point is drawn with and changes nothing about this arithmetic, which is why there is no
/// scale factor anywhere in it: a mapping that mentioned one would be a mapping with a way
/// to be wrong on one class of display and right on another.
public struct PictureMapping: Equatable, Sendable {
    /// Where the finished frame is, in view points.
    public let stage: CGRect
    /// Where the recording is inside the finished frame, normalised, top-left origin.
    public let video: CGRect

    public init(stage: CGRect, video: CGRect) {
        self.stage = stage
        self.video = video
    }

    /// A rect normalised to the finished frame, in view points.
    public func view(frame rect: CGRect) -> CGRect {
        CGRect(x: stage.minX + rect.minX * stage.width,
               y: stage.minY + rect.minY * stage.height,
               width: rect.width * stage.width,
               height: rect.height * stage.height)
    }

    /// A rect in view points, normalised to the finished frame.
    public func frame(view rect: CGRect) -> CGRect {
        guard stage.width > 0, stage.height > 0 else { return .zero }
        return CGRect(x: (rect.minX - stage.minX) / stage.width,
                      y: (rect.minY - stage.minY) / stage.height,
                      width: rect.width / stage.width,
                      height: rect.height / stage.height)
    }

    /// A rect normalised to the recording, in view points.
    public func view(recording rect: CGRect) -> CGRect {
        view(frame: CGRect(x: video.minX + rect.minX * video.width,
                           y: video.minY + rect.minY * video.height,
                           width: rect.width * video.width,
                           height: rect.height * video.height))
    }

    /// A rect in view points, normalised to the recording.
    public func recording(view rect: CGRect) -> CGRect {
        guard video.width > 0, video.height > 0 else { return .zero }
        let output = frame(view: rect)
        return CGRect(x: (output.minX - video.minX) / video.width,
                      y: (output.minY - video.minY) / video.height,
                      width: output.width / video.width,
                      height: output.height / video.height)
    }

    /// A drag's travel in view points, as a fraction of the recording.
    ///
    /// Measured as the difference between two mapped origins rather than by dividing, so
    /// there is exactly one expression of the scale factor and a change to the mapping
    /// cannot leave the movement behind.
    public func delta(view translation: CGSize) -> CGSize {
        let zero = recording(view: .zero).origin
        let moved = recording(view: CGRect(origin: CGPoint(x: translation.width,
                                                           y: translation.height),
                                           size: .zero)).origin
        return CGSize(width: moved.x - zero.x, height: moved.y - zero.y)
    }
}
