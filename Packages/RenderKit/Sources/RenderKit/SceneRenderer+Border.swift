import CoreGraphics
import CoreImage
import Foundation
import TimelineKit

extension SceneRenderer {
    /// The border, laid over the picture's outermost pixels.
    ///
    /// Inside the edge rather than outside it, and that is what keeps the promise the
    /// model makes: the picture does not shrink or move when the border is turned on,
    /// the shadow falls from the same shape, and a frame with no padding still has a
    /// border to show. Its outer edge is the picture's own — it is composited *atop* the
    /// picture, which takes the picture's alpha, so a rounded corner clips the border
    /// exactly as it clips the picture. Its inner edge is a second rounded rectangle,
    /// inset by the width, with the radius shrunk by the same amount so the two arcs are
    /// concentric.
    ///
    /// Drawn against the frame the border belongs to. When the whole frame zooms that
    /// is the grown, moved one, and the width grows with it, as the corner radius does;
    /// when only the contents zoom it is the hole the padding left, which is where the
    /// picture's edge stays.
    func bordered(_ picture: CIImage, by border: BorderLayer, in scene: SceneDescriptor) -> CIImage {
        let frame = scene.pictureEdge
        guard frame.width > 1, frame.height > 1 else { return picture }
        let grown = scene.frameFollowsCamera && scene.videoFrame.width > 0
            ? frame.width / scene.videoFrame.width : 1
        let width = min(border.width * grown, min(frame.width, frame.height) / 2)
        guard width > 0.25, border.color.a > 0 else { return picture }

        let colour = CIColor(red: border.color.r, green: border.color.g,
                             blue: border.color.b, alpha: border.color.a)
        var band = CIImage(color: colour).cropped(to: frame)
        let inner = frame.insetBy(dx: width, dy: width)
        if inner.width > 0, inner.height > 0 {
            let radius = max(0, scene.cornerRadius * grown - width)
            var hole = Self.roundedRectangle(inner, radius: radius, color: .white)
            // Under a window's bar the picture's top corners are square, so the hole's
            // are too — otherwise the rim thickens into the corners it no longer has.
            if scene.chromeBarFrame != nil {
                let top = CGRect(x: inner.minX, y: inner.midY, width: inner.width, height: inner.height / 2)
                hole = CIImage(color: .white).cropped(to: top).composited(over: hole)
            }
            // Source-out keeps the band only where the hole is transparent: the rim.
            band = band.applyingFilter("CISourceOutCompositing", parameters: [
                kCIInputBackgroundImageKey: hole,
            ])
        }
        // Atop: the band where the picture is, and the picture's own edge everywhere.
        return band.applyingFilter("CISourceAtopCompositing", parameters: [
            kCIInputBackgroundImageKey: picture,
        ])
    }
}
