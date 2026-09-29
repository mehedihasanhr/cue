import CoreGraphics
import Foundation

/// The arithmetic of putting an annotation somewhere, and nothing else.
///
/// Pure functions, so the part that has to be exactly right can be checked without a
/// window, a preview or a pointer. The canvas calls these with the rectangle it is showing
/// and the point under the mouse; what comes back is converted to the finished frame's
/// normalised space by `PictureMapping`, and that is all the canvas does with numbers.
///
/// **Any square space.** Rotation only means something where a unit across is the same
/// length as a unit down, so these work in points on screen, or in output pixels — both are
/// square. Normalised coordinates are not (a 16:9 frame's "0.1 across" is 1.8 times "0.1
/// down"), which is why `aspect` is there for a caller that has only normalised numbers:
/// it stretches x by the frame's width-over-height first and puts it back afterwards.
public enum AnnotationGeometry {
    /// A place on the selection outline that can be dragged.
    public enum Handle: String, CaseIterable, Sendable, Identifiable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

        public var id: String { rawValue }

        /// Which way this handle is from the centre: −1, 0 or 1 on each axis, y down.
        public var direction: (x: Double, y: Double) {
            switch self {
            case .topLeft: (-1, -1)
            case .top: (0, -1)
            case .topRight: (1, -1)
            case .right: (1, 0)
            case .bottomRight: (1, 1)
            case .bottom: (0, 1)
            case .bottomLeft: (-1, 1)
            case .left: (-1, 0)
            }
        }

        public var isCorner: Bool { direction.x != 0 && direction.y != 0 }
    }

    // MARK: - Keeping numbers drawable

    /// A rectangle every later step can trust: finite, positive size, standardised.
    ///
    /// Deliberately not "inside the frame" — a label may hang off an edge, see
    /// `Commands.SetRegionRect.placed`. This is about numbers, not about placement.
    public static func sanitised(_ rect: CGRect) -> CGRect {
        let fallback = CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4)
        guard rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.width.isFinite, rect.height.isFinite else { return fallback }
        var rect = rect.standardized
        rect.size.width = min(4, max(0.001, rect.width))
        rect.size.height = min(4, max(0.001, rect.height))
        rect.origin.x = min(4, max(-4, rect.origin.x))
        rect.origin.y = min(4, max(-4, rect.origin.y))
        return rect
    }

    public static func sanitised(_ point: CGPoint, default fallback: CGPoint) -> CGPoint {
        guard point.x.isFinite, point.y.isFinite else { return fallback }
        return point
    }

    /// Any angle, as the same angle in (−180, 180].
    public static func normalisedDegrees(_ degrees: Double) -> Double {
        guard degrees.isFinite else { return 0 }
        var angle = degrees.truncatingRemainder(dividingBy: 360)
        if angle > 180 { angle -= 360 }
        if angle <= -180 { angle += 360 }
        return angle
    }

    // MARK: - Where the handles are

    /// A handle's point, with the rectangle turned by `rotation` degrees about its centre.
    public static func point(of handle: Handle, in rect: CGRect, rotation: Double, aspect: Double = 1) -> CGPoint {
        let square = stretched(rect, aspect)
        let local = CGVector(dx: handle.direction.x * square.width / 2,
                             dy: handle.direction.y * square.height / 2)
        return unstretched(square.center + rotated(local, by: rotation), aspect)
    }

    /// Where the rotation handle sits: above the top edge by `reach`, turned with the rest.
    public static func rotationHandle(of rect: CGRect, rotation: Double, reach: Double, aspect: Double = 1) -> CGPoint {
        let square = stretched(rect, aspect)
        let local = CGVector(dx: 0, dy: -square.height / 2 - reach)
        return unstretched(square.center + rotated(local, by: rotation), aspect)
    }

    // MARK: - Changing it

    /// The rectangle after dragging `handle` to `point`, with the opposite side held still.
    ///
    /// The rectangle keeps its rotation, and the drag is read in the rectangle's own turned
    /// frame — so pulling the right-hand edge of a label turned 30° lengthens it along its
    /// own baseline rather than skewing it towards the screen's horizontal. The opposite
    /// corner (or edge) is held where it is on the picture, which means the centre moves:
    /// the result is a new unrotated rect, placed so that once turned it lines up.
    ///
    /// A handle dragged past the opposite side stops at `minimumSide` rather than turning
    /// the rectangle inside out.
    ///
    /// - Parameters:
    ///   - keepingAspect: corners only — the rectangle keeps its proportions, sized by
    ///     whichever way the pointer went further.
    public static func resize(_ rect: CGRect,
                              rotation: Double,
                              dragging handle: Handle,
                              to point: CGPoint,
                              minimumSide: Double,
                              keepingAspect: Bool = false,
                              aspect: Double = 1) -> CGRect {
        let square = stretched(rect, aspect)
        let pointer = stretched(point, aspect)
        let (sx, sy) = handle.direction
        let minimumWidth = minimumSide * aspect
        let minimumHeight = minimumSide

        // The side that stays put, on the picture.
        let anchorLocal = CGVector(dx: -sx * square.width / 2, dy: -sy * square.height / 2)
        let anchor = square.center + rotated(anchorLocal, by: rotation)

        // The pointer, in the rectangle's own unturned frame, measured from that side.
        let reach = rotated(pointer - anchor, by: -rotation)

        var width = sx != 0 ? max(minimumWidth, sx * reach.dx) : square.width
        var height = sy != 0 ? max(minimumHeight, sy * reach.dy) : square.height

        if keepingAspect, handle.isCorner, square.width > 0, square.height > 0 {
            let ratio = square.width / square.height
            let scale = max(width / square.width, height / square.height)
            width = max(minimumWidth, square.width * scale)
            height = max(minimumHeight, width / ratio)
            width = height * ratio
        }

        // From the held side to the new centre, still in the rectangle's own frame. An edge
        // handle leaves the other axis alone: the held point is on the centre line there.
        let toCentre = CGVector(dx: sx * width / 2, dy: sy * height / 2)
        let centre = anchor + rotated(toCentre, by: rotation)
        let result = CGRect(x: centre.x - width / 2, y: centre.y - height / 2, width: width, height: height)
        return unstretched(result, aspect)
    }

    /// The rotation that turns the rectangle's top towards `point`, in degrees.
    ///
    /// - Parameter snapping: to the nearest `step` degrees — for Shift, and for landing
    ///   exactly level, which by hand nobody manages.
    public static func rotation(of rect: CGRect,
                                toward point: CGPoint,
                                snapping: Bool = false,
                                step: Double = 15,
                                aspect: Double = 1) -> Double {
        let centre = stretched(rect, aspect).center
        let pointer = stretched(point, aspect)
        // The handle starts straight above the centre, which is −90° in a y-down space.
        let radians = atan2(pointer.y - centre.y, pointer.x - centre.x) + .pi / 2
        var degrees = normalisedDegrees(radians * 180 / .pi)
        if snapping, step > 0 { degrees = normalisedDegrees((degrees / step).rounded() * step) }
        return degrees
    }

    /// The rectangle moved by `delta`. Separate so a keyboard nudge and a drag are the same
    /// sum.
    public static func moved(_ rect: CGRect, by delta: CGVector) -> CGRect {
        rect.offsetBy(dx: delta.dx, dy: delta.dy)
    }

    // MARK: - Square space

    private static func stretched(_ rect: CGRect, _ aspect: Double) -> CGRect {
        CGRect(x: rect.minX * aspect, y: rect.minY, width: rect.width * aspect, height: rect.height)
    }

    private static func unstretched(_ rect: CGRect, _ aspect: Double) -> CGRect {
        CGRect(x: rect.minX / aspect, y: rect.minY, width: rect.width / aspect, height: rect.height)
    }

    private static func stretched(_ point: CGPoint, _ aspect: Double) -> CGPoint {
        CGPoint(x: point.x * aspect, y: point.y)
    }

    private static func unstretched(_ point: CGPoint, _ aspect: Double) -> CGPoint {
        CGPoint(x: point.x / aspect, y: point.y)
    }

    /// Turned clockwise by `degrees`, as seen in a y-down space.
    static func rotated(_ vector: CGVector, by degrees: Double) -> CGVector {
        let radians = degrees * .pi / 180
        let c = cos(radians), s = sin(radians)
        return CGVector(dx: vector.dx * c - vector.dy * s, dy: vector.dx * s + vector.dy * c)
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

private func + (point: CGPoint, vector: CGVector) -> CGPoint {
    CGPoint(x: point.x + vector.dx, y: point.y + vector.dy)
}

private func - (lhs: CGPoint, rhs: CGPoint) -> CGVector {
    CGVector(dx: lhs.x - rhs.x, dy: lhs.y - rhs.y)
}
