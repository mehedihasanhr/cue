import RenderKit
import SwiftUI
import TimelineKit

/// The turn the Perspective look gives the picture, in the canvas's own points.
///
/// Everything the overlays already do — where a mask's box is, where a label's corner is,
/// how a resize pulls a side — is worked out on the *flat* picture, and stays that way:
/// that arithmetic is right, tested, and knows nothing of angles. This is the one step
/// laid on top. Going out, a point of the flat canvas is moved to where the renderer draws
/// it (`drawn(_:)`), so an outline is the turned quadrilateral and a grip sits on the
/// turned corner. Coming back, a drag's location on the turned picture is moved to the flat
/// point under it (`flat(_:)`), so a resize or a move is worked out exactly as it always
/// was. Both go through `SceneDescriptor`'s mapping, which is the renderer's own
/// `perspectiveProjection`, so a handle drawn here sits on the pixel the export puts there.
///
/// Square-on — every project without a perspective, and the crop tool's bare picture —
/// both directions hand the point back untouched, and nothing on the canvas moves.
struct CanvasTilt {
    /// Where the finished frame is, in view coordinates.
    let stage: CGRect
    let scene: SceneDescriptor?

    /// Whether the picture is turned at all.
    var isTilted: Bool { scene?.perspectiveProjection != nil && stage.width > 0 && stage.height > 0 }

    /// Where a point of the flat canvas is drawn on the turned picture.
    func drawn(_ point: CGPoint) -> CGPoint {
        guard isTilted, let scene else { return point }
        return view(scene.tiltedFramePoint(normalised(point)))
    }

    /// The point of the flat canvas under a point of the turned picture — `drawn(_:)`
    /// backwards, for a drag. A point past the turned picture's horizon has no flat point;
    /// `nil` there, and a drag keeps what it had.
    func flat(_ point: CGPoint) -> CGPoint? {
        guard isTilted, let scene else { return point }
        return scene.flatFramePoint(normalised(point)).map(view)
    }

    /// How far a drag has gone on the flat picture: from the flat point under where it
    /// started to the flat point under where it is. On a turned picture the same distance
    /// on screen is a longer way on the far side than on the near one, so the translation
    /// the gesture reports cannot simply be used.
    func flatTranslation(from start: CGPoint, to location: CGPoint) -> CGSize? {
        guard let from = flat(start), let to = flat(location) else { return nil }
        return CGSize(width: to.x - from.x, height: to.y - from.y)
    }

    /// The four corners of a flat box, turned about its middle by `rotation` degrees as the
    /// renderer turns an annotation, then drawn — top left, top right, bottom right, bottom
    /// left.
    func corners(of rect: CGRect, rotation: Double = 0) -> [CGPoint] {
        [AnnotationGeometry.Handle.topLeft, .topRight, .bottomRight, .bottomLeft]
            .map { drawn(AnnotationGeometry.point(of: $0, in: rect, rotation: rotation)) }
    }

    /// A flat box's outline as it is drawn on the turned picture: a quadrilateral, since a
    /// projective map keeps straight lines straight.
    func outline(of rect: CGRect, rotation: Double = 0) -> Path {
        Path { path in path.addLines(corners(of: rect, rotation: rotation)); path.closeSubpath() }
    }

    /// A straight line of the flat canvas, drawn.
    func line(from start: CGPoint, to end: CGPoint) -> Path {
        Path { path in
            path.move(to: drawn(start))
            path.addLine(to: drawn(end))
        }
    }

    /// The whole map as a projection a view can be drawn through, for something that has
    /// to be *seen* turned — the field a label is typed into — rather than have its points
    /// moved. Identity when the picture is flat.
    ///
    /// For a view laid out in the canvas's own coordinates, as the overlays' views are: in
    /// a stack pinned to the canvas's top-left and moved into place by an offset.
    var projection: ProjectionTransform {
        guard isTilted, let matrix = scene?.tiltedFrameMatrix else { return ProjectionTransform() }
        // View → normalised, the turn, normalised → view: three matrices, one product.
        let into: [Double] = [1 / stage.width, 0, -stage.minX / stage.width,
                              0, 1 / stage.height, -stage.minY / stage.height,
                              0, 0, 1]
        let out: [Double] = [stage.width, 0, stage.minX,
                             0, stage.height, stage.minY,
                             0, 0, 1]
        let m = Self.product(out, Self.product(matrix, into))
        // SwiftUI's matrix is written for a row vector on the left, so it is this one
        // transposed: its third row is the translation and its third column the divide.
        var transform = ProjectionTransform()
        transform.m11 = m[0]; transform.m21 = m[1]; transform.m31 = m[2]
        transform.m12 = m[3]; transform.m22 = m[4]; transform.m32 = m[5]
        transform.m13 = m[6]; transform.m23 = m[7]; transform.m33 = m[8]
        return transform
    }

    // MARK: - Between the canvas and the frame

    private func normalised(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - stage.minX) / stage.width, y: (point.y - stage.minY) / stage.height)
    }

    private func view(_ point: CGPoint) -> CGPoint {
        CGPoint(x: stage.minX + point.x * stage.width, y: stage.minY + point.y * stage.height)
    }

    private static func product(_ a: [Double], _ b: [Double]) -> [Double] {
        (0..<9).map { index in
            let row = index / 3, column = index % 3
            return (0..<3).reduce(0) { $0 + a[row * 3 + $1] * b[$1 * 3 + column] }
        }
    }
}
