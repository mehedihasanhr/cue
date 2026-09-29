import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

extension SceneRenderer {
    /// The picture softened along the camera's travel: streaked outwards while it pushes
    /// in or pulls out, and along the direction of a pan.
    ///
    /// Applied to the placed picture before its corners are rounded and it is cut to its
    /// frame, so the edges of the frame stay crisp while what is inside it moves — a
    /// camera's shutter blurs the scene, not the window it is seen through.
    func cameraBlurred(_ picture: CIImage, by motion: CameraMotionLayer) -> CIImage {
        let extent = picture.extent
        guard extent.width > 1, extent.height > 1 else { return picture }
        var image = picture.clampedToExtent()

        // Measured, not assumed: Core Image's zoom blur streaks each point outwards by a
        // factor of about e^(0.0205 × amount) of its distance from the centre, so the
        // amount that streaks a point by exactly the growth is this.
        let growth = abs(motion.growth)
        if growth > 0.0005 {
            let zoom = CIFilter.zoomBlur()
            zoom.inputImage = image
            zoom.center = motion.center
            zoom.amount = Float(log(1 + growth) / 0.0205)
            image = zoom.outputImage ?? image
        }

        // Core Image's motion blur reaches about twice its radius either way, so a
        // quarter of the travel spreads each point over the distance it moved.
        let travel = hypot(motion.travel.dx, motion.travel.dy)
        if travel > 0.5 {
            let pan = CIFilter.motionBlur()
            pan.inputImage = image
            pan.angle = Float(atan2(motion.travel.dy, motion.travel.dx))
            pan.radius = Float(travel / 4)
            image = pan.outputImage ?? image
        }
        return image.cropped(to: extent)
    }
}
