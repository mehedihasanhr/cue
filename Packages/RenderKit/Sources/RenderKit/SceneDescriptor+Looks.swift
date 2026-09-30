import CoreGraphics
import Foundation
import TimelineKit

/// The picture turned in space, as this frame draws it.
///
/// The angles are the ones in force at this moment — already eased flat by a zoom when the
/// project straightens while zoomed in — so the renderer has nothing left to decide but
/// where the corners go. Angles, not pixels, so the layer is the same at any size and a
/// preview scaled down draws exactly the same shape.
public struct PerspectiveLayer: Equatable, Sendable {
    /// Degrees about the vertical axis; positive sends the left edge away.
    public var turn: Double
    /// Degrees about the horizontal axis; positive sends the top away.
    public var lean: Double
    /// Degrees in the plane of the frame, clockwise.
    public var rotation: Double
    /// How strong the extra shadow is, 0…1, before it is scaled by how far the picture is
    /// turned.
    public var depthShadow: Double

    public init(turn: Double, lean: Double, rotation: Double = 0, depthShadow: Double = 0.5) {
        self.turn = turn
        self.lean = lean
        self.rotation = rotation
        self.depthShadow = depthShadow
    }

    /// How turned the picture looks, 0 for flat and 1 from about 25°. What the depth shadow
    /// grows with.
    public var amount: Double {
        min(1, max(abs(turn), abs(lean), abs(rotation) * 1.5) / 25)
    }
}

/// Colour correction for the recording's picture, in the model's −1…1 units. The renderer
/// turns each into its filter's own. See `ColorGrade`.
public struct GradeLayer: Equatable, Sendable {
    public var brightness: Double
    public var contrast: Double
    public var saturation: Double
    public var temperature: Double
    public var tint: Double
    /// A `.cube` file, absolute and openable by the time it gets here — like a background
    /// picture, the descriptor carries where it is rather than what is in it.
    public var lut: URL?
    public var lutIntensity: Double

    public init(brightness: Double = 0, contrast: Double = 0, saturation: Double = 0,
                temperature: Double = 0, tint: Double = 0,
                lut: URL? = nil, lutIntensity: Double = 1) {
        self.brightness = brightness
        self.contrast = contrast
        self.saturation = saturation
        self.temperature = temperature
        self.tint = tint
        self.lut = lut
        self.lutIntensity = lutIntensity
    }
}

/// Where the flat frame's points land once the picture is turned: a projective map of the
/// plane, worked out from three rotations and a camera.
///
/// The picture is a card turned about its own centre and seen from a camera in front of
/// it; everything drawn on the picture — the pointer, a click, an annotation — is a point
/// on that card and goes where this says. The turned card is then shrunk, if it has to be,
/// to fit the room the flat one had, and centred on it, so tilting never pushes the picture
/// into the padding or off the frame.
///
/// In output pixels with Core Image's origin, bottom-left, like the renderer.
public struct PerspectiveProjection: Equatable, Sendable {
    /// The flat rectangle being turned: the picture and its window bar.
    public let plane: CGRect
    private let focal: Double
    private let matrix: [Double]
    private let fit: Double
    private let middle: CGPoint

    /// `nil` for a layer too small to turn or a plane with no area.
    public init?(_ layer: PerspectiveLayer, plane: CGRect) {
        guard plane.width > 1, plane.height > 1,
              abs(layer.turn) + abs(layer.lean) + abs(layer.rotation) > 0.001 else { return nil }
        self.plane = plane
        // A camera twice the card's size away: enough depth for the far edge to be
        // visibly smaller, not so much that a small turn looks like a fish-eye.
        let focal = 2 * max(plane.width, plane.height)
        self.focal = focal

        let radians = Double.pi / 180
        let c = -layer.rotation * radians  // clockwise on screen, y up
        let a = -layer.lean * radians      // top away
        let b = -layer.turn * radians      // left edge away
        // Ry(b) · Rx(a) · Rz(c), written out: spin in the plane, then lean, then turn.
        let rz = [cos(c), -sin(c), 0, sin(c), cos(c), 0, 0, 0, 1]
        let rx = [1, 0, 0, 0, cos(a), -sin(a), 0, sin(a), cos(a)]
        let ry = [cos(b), 0, sin(b), 0, 1, 0, -sin(b), 0, cos(b)]
        let matrix = Self.multiply(ry, Self.multiply(rx, rz))
        self.matrix = matrix

        // Fitted to the flat rectangle's own size, then centred on it.
        let corners = [CGPoint(x: plane.minX, y: plane.minY), CGPoint(x: plane.maxX, y: plane.minY),
                       CGPoint(x: plane.maxX, y: plane.maxY), CGPoint(x: plane.minX, y: plane.maxY)]
            .map { Self.raw($0, plane: plane, focal: focal, matrix: matrix) }
        let xs = corners.map(\.x), ys = corners.map(\.y)
        let width = xs.max()! - xs.min()!, height = ys.max()! - ys.min()!
        guard width > 0, height > 0 else { return nil }
        fit = min(1, plane.width / width, plane.height / height)
        middle = CGPoint(x: (xs.max()! + xs.min()!) / 2, y: (ys.max()! + ys.min()!) / 2)
    }

    /// Where a point of the flat frame is drawn.
    public func project(_ point: CGPoint) -> CGPoint {
        let turned = Self.raw(point, plane: plane, focal: focal, matrix: matrix)
        return CGPoint(x: plane.midX + (turned.x - middle.x) * fit,
                       y: plane.midY + (turned.y - middle.y) * fit)
    }

    /// Where a drawn point came from on the flat frame: `project(_:)` run backwards, for
    /// turning a drag on the turned picture into a move on the flat one.
    ///
    /// Exact rather than searched for, because the map is a projective one — a rotation
    /// followed by a divide by depth, then a scale and a shift — which is a single 3×3
    /// matrix acting on the point, and a matrix has an inverse. `nil` for a point on or past
    /// the turned plane's horizon, which no point of the flat frame is drawn at: a pointer
    /// dragged out there has nowhere on the picture to be, and the caller keeps what it had.
    public func unproject(_ point: CGPoint) -> CGPoint? {
        let h = homography
        // The adjugate over the determinant, written out.
        let a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], k = h[7], l = h[8]
        let inverse = [e * l - f * k, c * k - b * l, b * f - c * e,
                       f * g - d * l, a * l - c * g, c * d - a * f,
                       d * k - e * g, b * g - a * k, a * e - b * d]
        let determinant = a * inverse[0] + b * inverse[3] + c * inverse[6]
        guard abs(determinant) > 1e-12 else { return nil }
        let x = point.x, y = point.y
        let u = inverse[0] * x + inverse[1] * y + inverse[2]
        let v = inverse[3] * x + inverse[4] * y + inverse[5]
        let w = inverse[6] * x + inverse[7] * y + inverse[8]
        guard abs(w) > 1e-12 else { return nil }
        let flat = CGPoint(x: plane.midX + u / w, y: plane.midY + v / w)
        // In front of the camera, and on the side of the horizon the plane is drawn on: the
        // depth the forward map divides by has to be the positive one it would have used.
        let depth = focal - (matrix[6] * (flat.x - plane.midX) + matrix[7] * (flat.y - plane.midY))
        guard depth > focal * 0.1, flat.x.isFinite, flat.y.isFinite else { return nil }
        return flat
    }

    /// `project(_:)` as one projective matrix, row by row, acting on a point measured from
    /// the plane's middle, `(x − midX, y − midY, 1)`, and giving a drawn point once divided
    /// through by its third term.
    ///
    /// Worked from `raw(_:)`: the turned point is `(rx, ry, rz)`, drawn `focal / (focal −
    /// rz)` times larger, and then scaled by `fit` about `middle` and put back on the plane's
    /// middle. Multiplying every term through by `focal − rz` leaves nothing but sums of
    /// `x` and `y`, which is what makes it a matrix. The floor on the depth in `raw(_:)` is
    /// never reached at the angles the model allows, so it is not part of it.
    var homography: [Double] {
        let m = matrix
        let ax = plane.midX + (plane.midX - middle.x) * fit
        let ay = plane.midY + (plane.midY - middle.y) * fit
        let scale = fit * focal
        return [scale * m[0] - ax * m[6], scale * m[1] - ax * m[7], ax * focal,
                scale * m[3] - ay * m[6], scale * m[4] - ay * m[7], ay * focal,
                -m[6], -m[7], focal]
    }

    /// The plane's four corners, turned, in the order Core Image's perspective filters name
    /// them.
    public var corners: (topLeft: CGPoint, topRight: CGPoint, bottomRight: CGPoint, bottomLeft: CGPoint) {
        (project(CGPoint(x: plane.minX, y: plane.maxY)),
         project(CGPoint(x: plane.maxX, y: plane.maxY)),
         project(CGPoint(x: plane.maxX, y: plane.minY)),
         project(CGPoint(x: plane.minX, y: plane.minY)))
    }

    private static func raw(_ point: CGPoint, plane: CGRect, focal: Double, matrix m: [Double]) -> CGPoint {
        let x = point.x - plane.midX
        let y = point.y - plane.midY
        let rx = m[0] * x + m[1] * y
        let ry = m[3] * x + m[4] * y
        let rz = m[6] * x + m[7] * y
        // Towards the viewer is bigger. The angles are held well short of edge-on, so the
        // card never reaches the camera; the floor is for a file that says otherwise.
        let depth = focal / max(focal * 0.1, focal - rz)
        return CGPoint(x: plane.midX + rx * depth, y: plane.midY + ry * depth)
    }

    private static func multiply(_ a: [Double], _ b: [Double]) -> [Double] {
        var out = [Double](repeating: 0, count: 9)
        for row in 0..<3 {
            for column in 0..<3 {
                out[row * 3 + column] = (0..<3).reduce(0) { $0 + a[row * 3 + $1] * b[$1 * 3 + column] }
            }
        }
        return out
    }
}

public extension SceneDescriptor {
    /// The map from the flat frame to the turned one, or `nil` when the picture is flat.
    ///
    /// Not for a title: its words are laid out square in the picture's place and are not
    /// part of any picture, so a title is drawn flat whatever the project's perspective.
    var perspectiveProjection: PerspectiveProjection? {
        guard title == nil, let perspective else { return nil }
        return PerspectiveProjection(perspective, plane: shadowCaster)
    }

    /// Where a point of the flat frame is drawn, in output pixels with Core Image's origin.
    /// The point itself when the picture is flat.
    func projected(_ point: CGPoint) -> CGPoint {
        perspectiveProjection?.project(point) ?? point
    }
}
