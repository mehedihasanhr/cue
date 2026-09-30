import CoreGraphics
import Foundation

/// The frame as the editor's canvas sees it: where a point of the recording, or of the flat
/// finished frame, is *drawn* once the picture has been turned — and, for a drag, back.
///
/// The canvas draws its outlines and handles in the finished frame's own space, normalised
/// to the output with the origin top-left (the space `PictureMapping` and every annotation
/// rectangle use), and a mask in the recording's. Both go through the renderer's own
/// `perspectiveProjection`, the one map every layer on the picture is warped by, so a handle
/// drawn with these sits on the pixel the export puts there. When the picture is square-on
/// every one of these is the plain arithmetic the canvas always did: the flat frame *is*
/// the drawn one.
public extension SceneDescriptor {
    // MARK: - The finished frame, normalised

    /// Where a point of the flat finished frame is drawn, both as fractions of the output
    /// with the origin top-left.
    func tiltedFramePoint(_ point: CGPoint) -> CGPoint {
        guard let projection = perspectiveProjection else { return point }
        return normalised(projection.project(pixels(point)))
    }

    /// The point of the flat finished frame that is drawn at `point` — `tiltedFramePoint(_:)`
    /// run backwards. `nil` past the turned picture's horizon, where nothing of the flat frame
    /// is drawn.
    func flatFramePoint(_ point: CGPoint) -> CGPoint? {
        guard let projection = perspectiveProjection else { return point }
        return projection.unproject(pixels(point)).map(normalised)
    }

    /// `tiltedFramePoint(_:)` as one projective matrix, row-major, acting on the column
    /// `(x, y, 1)` of a normalised flat point and giving the drawn one once divided through
    /// by its third term — or `nil` when the picture is square-on.
    ///
    /// For a view that has to be *drawn* turned rather than have points of it moved — the
    /// field a label is typed into, say — which a UI framework's projection effect takes as
    /// a matrix. The pixels either side of the projection are two more matrices, so this is
    /// the product of three.
    var tiltedFrameMatrix: [Double]? {
        guard let projection = perspectiveProjection, outputSize.width > 0, outputSize.height > 0 else { return nil }
        let w = outputSize.width, h = outputSize.height
        let plane = projection.plane
        // Normalised, top-left → pixels from the plane's middle, Core Image's way up.
        let into: [Double] = [w, 0, -plane.midX,
                              0, -h, h - plane.midY,
                              0, 0, 1]
        // Pixels, Core Image's way up → normalised, top-left.
        let out: [Double] = [1 / w, 0, 0,
                             0, -1 / h, 1,
                             0, 0, 1]
        return Self.product(out, Self.product(projection.homography, into))
    }

    private static func product(_ a: [Double], _ b: [Double]) -> [Double] {
        (0..<9).map { index in
            let row = index / 3, column = index % 3
            return (0..<3).reduce(0) { $0 + a[row * 3 + $1] * b[$1 * 3 + column] }
        }
    }

    // MARK: - The recording, normalised

    /// Where a point of the recording — a fraction of the whole recording, origin top-left,
    /// the space a mask is stored in — is drawn in the finished frame, as a fraction of the
    /// output with the origin top-left.
    ///
    /// Through the crop and the camera as `SceneRenderer.videoLayer(_:source:)` places the
    /// picture, then through the turn. A point the crop has cut away still has a place — off
    /// the picture's edge — so an outline that runs past the crop is drawn running past it.
    func framePoint(forSource point: CGPoint) -> CGPoint {
        let frame = transformedVideoFrame
        let crop = sourceCrop
        guard crop.width > 0, crop.height > 0, outputSize.width > 0, outputSize.height > 0 else { return point }
        let local = CGPoint(x: (point.x - crop.minX) / crop.width, y: (point.y - crop.minY) / crop.height)
        let flat = CGPoint(x: frame.minX + local.x * frame.width, y: frame.maxY - local.y * frame.height)
        return normalised(projected(flat))
    }

    /// The point of the recording drawn at `point` of the finished frame — the inverse of
    /// `framePoint(forSource:)`. `nil` past the turned picture's horizon.
    func sourcePoint(forFrame point: CGPoint) -> CGPoint? {
        let frame = transformedVideoFrame
        let crop = sourceCrop
        guard frame.width > 0, frame.height > 0 else { return nil }
        var flat = pixels(point)
        if let projection = perspectiveProjection {
            guard let back = projection.unproject(flat) else { return nil }
            flat = back
        }
        let local = CGPoint(x: (flat.x - frame.minX) / frame.width, y: (frame.maxY - flat.y) / frame.height)
        return CGPoint(x: crop.minX + local.x * crop.width, y: crop.minY + local.y * crop.height)
    }

    // MARK: - Between the two frames of reference

    /// A fraction of the output, origin top-left, as output pixels with Core Image's origin.
    private func pixels(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x * outputSize.width, y: (1 - point.y) * outputSize.height)
    }

    /// Output pixels with Core Image's origin, as a fraction of the output, origin top-left.
    private func normalised(_ point: CGPoint) -> CGPoint {
        guard outputSize.width > 0, outputSize.height > 0 else { return point }
        return CGPoint(x: point.x / outputSize.width, y: 1 - point.y / outputSize.height)
    }
}
