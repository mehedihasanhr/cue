import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// The picture turned in space, and everything drawn on it turned with it.
extension SceneRenderer {
    /// A layer of the flat frame, turned the way the picture is.
    ///
    /// The picture, the pointer, a click and an annotation each go through this with the
    /// same map, so they stay where they were on the picture relative to one another: a
    /// pointer drawn over a button in the flat frame is drawn over that button once the
    /// picture has been turned. The map is the whole plane's, not only the picture's
    /// rectangle — an annotation hanging off the edge of the picture is carried along
    /// with it rather than left behind.
    ///
    /// The layer itself when the picture is flat, which is every frame of every project
    /// that has not asked for a perspective.
    func tilted(_ layer: CIImage, in scene: SceneDescriptor) -> CIImage {
        guard let projection = scene.perspectiveProjection else { return layer }
        return Self.warp(layer, by: projection)
    }

    static func warp(_ image: CIImage, by projection: PerspectiveProjection) -> CIImage {
        guard !image.extent.isEmpty, !image.extent.isInfinite else { return image }
        let corners = projection.corners
        let filter = CIFilter.perspectiveTransformWithExtent()
        filter.inputImage = image
        // The plane's rectangle names the map; the image can be any size and anywhere.
        filter.extent = projection.plane
        filter.topLeft = corners.topLeft
        filter.topRight = corners.topRight
        filter.bottomRight = corners.bottomRight
        filter.bottomLeft = corners.bottomLeft
        return filter.outputImage ?? image
    }

    /// The shadow of a turned picture: its own shape, turned, blurred — and under it a
    /// wider, fainter one dropped further, which is what makes a turned card look like it
    /// stands off the background rather than lies on it.
    ///
    /// The shape is a rounded rectangle with at least a pixel of rounding before it is
    /// turned, for the reason `shadow(under:scene:)` gives: a plain block of colour,
    /// blurred, is folded by Core Image into a colour with no edges.
    func tiltedShadow(_ scene: SceneDescriptor, projection: PerspectiveProjection) -> CIImage {
        let rect = projection.plane
        let shape = Self.roundedRectangle(rect,
                                          radius: max(1, min(scene.cornerRadius, min(rect.width, rect.height) / 2)),
                                          color: CIColor(red: 0, green: 0, blue: 0, alpha: 1))
            .cropped(to: rect)
        let turned = Self.warp(shape, by: projection)
        let bounds = turned.extent
        guard !bounds.isEmpty, !bounds.isInfinite else { return CIImage.empty() }

        func faded(_ image: CIImage, _ alpha: Double) -> CIImage {
            image.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha),
            ])
        }

        let sigma = scene.shadowRadius
        var shadow = faded(turned, scene.shadowOpacity)
            .applyingGaussianBlur(sigma: sigma)
            .cropped(to: bounds.insetBy(dx: -sigma * 3, dy: -sigma * 3))
            .transformed(by: CGAffineTransform(translationX: 0, y: -sigma * 0.6))

        let amount = (scene.perspective?.amount ?? 0) * min(1, max(0, scene.perspective?.depthShadow ?? 0))
        if amount > 0.01 {
            let shorter = min(scene.outputSize.width, scene.outputSize.height)
            let depthSigma = sigma * 1.5 + shorter * 0.02 * amount
            let drop = shorter * 0.025 * amount
            let depth = faded(turned, scene.shadowOpacity * 0.6 * amount)
                .applyingGaussianBlur(sigma: depthSigma)
                .cropped(to: bounds.insetBy(dx: -depthSigma * 3, dy: -depthSigma * 3))
                .transformed(by: CGAffineTransform(translationX: 0, y: -drop))
            shadow = shadow.composited(over: depth)
        }
        return shadow
    }
}
