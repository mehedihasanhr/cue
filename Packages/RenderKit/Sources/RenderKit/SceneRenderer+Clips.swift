import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import TimelineKit

/// Title slides and transitions, drawn with the renderer's own layers.
///
/// Neither is a second way of drawing a frame. A title's panel goes through the same
/// `videoLayer` the recording does, so it gets the project's corners, shadow and border
/// for nothing; and a crossfade draws the other side with `composed`, the code every frame
/// is drawn with, then mixes the two.
extension SceneRenderer {
    /// A frame mixed with whatever its transition mixes it with.
    func blended(_ image: CIImage, scene: SceneDescriptor, blending: CIImage?, blendingWebcam: CIImage?) -> CIImage {
        guard let blend = scene.blend else { return image }
        let output = CGRect(origin: .zero, size: scene.outputSize)
        switch blend {
        case .dip(let amount, let toBackground):
            let target = toBackground
                ? background(for: scene).cropped(to: output)
                : CIImage(color: .black).cropped(to: output)
            return mix(image, towards: target, by: amount, in: output)
        case .crossfade(let other, let amount):
            // Drawn at this frame's size whatever the other was described at: the preview
            // scales both together, and a mismatch would mix two pictures of different
            // sizes into one that is neither.
            let lent = composed(other, source: blending, webcam: blendingWebcam)
            return mix(image, towards: lent, by: amount, in: output)
        }
    }

    /// `amount` of the way from one picture to another, pixel by pixel.
    ///
    /// Linear, which is what makes the builder's trick of giving both sides of a crossfade
    /// the same annotations exact: a mark over two pictures, mixed, is that mark over the
    /// mixed picture.
    private func mix(_ image: CIImage, towards target: CIImage, by amount: Double, in output: CGRect) -> CIImage {
        let amount = min(1, max(0, amount))
        if amount <= 0 { return image }
        if amount >= 1 { return target.cropped(to: output) }
        let filter = CIFilter.dissolveTransition()
        filter.inputImage = image
        filter.targetImage = target
        filter.time = Float(amount)
        return (filter.outputImage ?? image).cropped(to: output)
    }

    /// The plain panel a title stands on, in the picture's place, or `nil` for a title set
    /// straight on the background.
    ///
    /// Handed to the renderer as if it were the recording's frame. Its size is the frame
    /// it fills — the renderer scales whatever it is given into `videoFrame` — so a flat
    /// colour of any size would do; this one needs no scaling at all.
    func titlePanel(_ scene: SceneDescriptor) -> CIImage? {
        guard let colour = scene.title?.panelColor,
              scene.videoFrame.width > 1, scene.videoFrame.height > 1 else { return nil }
        return CIImage(color: CIColor(red: colour.r, green: colour.g, blue: colour.b, alpha: colour.a))
            .cropped(to: CGRect(origin: .zero, size: scene.videoFrame.size))
    }
}
