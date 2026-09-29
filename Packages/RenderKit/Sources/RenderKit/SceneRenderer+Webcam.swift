import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import TimelineKit

/// The camera: the webcam's frame, its background dealt with, cropped into its bubble or
/// pane, bordered, and faded as a layout change asks.
extension SceneRenderer {
    /// The webcam, filled into its bubble and masked to its shape.
    ///
    /// Not cached, unlike the cursor and the caption plate: those two are *drawings* that
    /// repeat for as long as nothing about them changes, whereas this is a fresh camera
    /// frame every time — a cache keyed on the frame would never hit, and one keyed on
    /// anything less would draw yesterday's face. What is left is a scale, an optional
    /// flip, a crop and a mask, which is four Core Image nodes the GPU folds into the pass
    /// it was already making. (The one expensive step, finding the person, *is* remembered
    /// per frame — see `PersonMatte`.)
    ///
    /// Fill, not fit — see `WebcamLayer` for why. With no crop the overhang is cropped
    /// symmetrically, so a 16:9 camera in a circular bubble shows the middle of the shot,
    /// which is where a face is; `WebcamLayer.crop` zooms in from there and slides the
    /// window across what is left over.
    func webcamImage(_ layer: WebcamLayer, source: CIImage, in scene: SceneDescriptor) -> CIImage? {
        let target = layer.pixelRect(in: scene.outputSize)
        let extent = source.extent
        guard target.width > 1, target.height > 1, extent.width > 0, extent.height > 0,
              layer.opacity > 0.001 else { return nil }

        // Before anything moves it: the person is found in the camera's own frame, which is
        // the picture the mask is remembered against.
        var image = backgroundTreated(source, layer: layer)
        // Mirrored before anything else, about the frame's own middle, so the flip does not
        // also move the picture: a negative scale reflects through the origin, and Core
        // Image's origin is a corner rather than the centre of the camera's frame.
        if layer.isMirrored {
            image = image.transformed(by: CGAffineTransform(translationX: extent.midX, y: 0)
                .scaledBy(x: -1, y: 1)
                .translatedBy(x: -extent.midX, y: 0))
        }

        // The larger of the two ratios, which is what makes this a fill: the smaller one
        // would leave a gap down one pair of sides. The crop's zoom goes in from there.
        let crop = layer.crop.sanitised
        let scale = max(target.width / extent.width, target.height / extent.height) * crop.zoom
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        // What is left over once the frame is filled, on each axis, and the crop's offset
        // spends it: −1 puts the window against the left (or top) of the picture, +1 the
        // right (or bottom). Core Image's y runs up, the model's down, hence the sign.
        let spare = CGSize(width: max(0, image.extent.width - target.width),
                           height: max(0, image.extent.height - target.height))
        let centre = CGPoint(x: target.midX - crop.offset.x * spare.width / 2,
                             y: target.midY + crop.offset.y * spare.height / 2)
        image = image.transformed(by: CGAffineTransform(translationX: centre.x - image.extent.midX,
                                                        y: centre.y - image.extent.midY))
        image = image.cropped(to: target)
        guard image.extent.width > 1, image.extent.height > 1 else { return nil }

        if layer.cornerRadius > 0.5 { image = rounded(image, radius: layer.cornerRadius) }
        if let border = layer.border {
            image = webcamBordered(image, by: border, in: target, radius: layer.cornerRadius)
        }
        return layer.opacity < 1 ? Self.faded(image, to: layer.opacity) : image
    }

    /// The camera's frame with its background blurred or taken away, as the layer asks.
    ///
    /// When no person can be found — segmentation failed, or nobody is in the shot — the
    /// frame is left as it was filmed. Blurring the whole picture, or removing all of it,
    /// would turn a moment of the presenter leaning out of shot into a bubble that has
    /// broken.
    func backgroundTreated(_ source: CIImage, layer: WebcamLayer) -> CIImage {
        guard layer.background != .keep else { return source }
        let extent = source.extent
        guard let matte = personMatte.matte(for: source) else { return source }

        let behind: CIImage
        switch layer.background {
        case .keep:
            return source
        case .blur:
            // Against the camera frame's own size, so the same setting is as soft at 720p
            // as at 4K: at full strength, a twenty-fifth of the shorter side.
            let sigma = layer.backgroundBlur * min(extent.width, extent.height) * 0.04
            guard sigma > 0.25 else { return source }
            behind = source.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: extent)
        case .remove:
            behind = CIImage(color: .clear).cropped(to: extent)
        }
        return source.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: behind,
            kCIInputMaskImageKey: matte,
        ]).cropped(to: extent)
    }

    /// The line round the camera, inside its edge and following its corners.
    ///
    /// Composited *over* the camera rather than atop it, which is where it parts company
    /// with the picture's border: a camera whose background has been removed is mostly
    /// transparent, and atop would keep the line only where the person is.
    func webcamBordered(_ image: CIImage, by border: BorderLayer, in rect: CGRect, radius: Double) -> CIImage {
        let width = min(border.width, min(rect.width, rect.height) / 2)
        guard width > 0.25, border.color.a > 0 else { return image }
        let colour = CIColor(red: border.color.r, green: border.color.g,
                             blue: border.color.b, alpha: border.color.a)
        var band = Self.roundedRectangle(rect, radius: radius, color: colour)
        let inner = rect.insetBy(dx: width, dy: width)
        if inner.width > 0, inner.height > 0 {
            let hole = Self.roundedRectangle(inner, radius: max(0, radius - width), color: .white)
            band = band.applyingFilter("CISourceOutCompositing", parameters: [
                kCIInputBackgroundImageKey: hole,
            ])
        }
        return band.composited(over: image)
    }

    /// The soft dark shape under the camera.
    ///
    /// Its own rather than `shadow(under:)`: that one is measured off the video's frame and
    /// its corner radius, and both of those are the wrong shape here. The radius is tied to
    /// the bubble's own side, so a circular bubble casts a round shadow rather than a
    /// square one peeking out from behind it.
    ///
    /// A camera with its background removed casts the shadow of the person instead — the
    /// bubble's shape would be a dark disc behind somebody standing in front of the screen.
    func webcamShadow(_ layer: WebcamLayer, bubble: CIImage, in scene: SceneDescriptor) -> CIImage {
        let rect = layer.pixelRect(in: scene.outputSize)
        guard rect.width > 1, rect.height > 1 else { return CIImage.empty() }
        // Proportional to the bubble rather than to the frame's shadow setting: the bubble
        // is a small object close to the picture, and the video's shadow radius — tuned for
        // lifting a whole screenshot off a wallpaper — would smear right across it.
        let blur = min(rect.width, rect.height) * 0.09
        let opacity = layer.shadowOpacity * layer.opacity

        let shape: CIImage
        if layer.background == .remove {
            let nothing = CIVector(x: 0, y: 0, z: 0, w: 0)
            shape = bubble.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": nothing,
                "inputGVector": nothing,
                "inputBVector": nothing,
                // `bubble` has already been faded by the layer's opacity.
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: layer.shadowOpacity),
                "inputBiasVector": nothing,
            ])
        } else {
            let filter = CIFilter.roundedRectangleGenerator()
            filter.extent = rect
            filter.radius = Float(min(layer.cornerRadius, min(rect.width, rect.height) / 2))
            filter.color = CIColor(red: 0, green: 0, blue: 0, alpha: opacity)
            guard let generated = filter.outputImage else { return CIImage.empty() }
            // Blurred as it is, with nothing round it, and not clamped to its extent first.
            // It was clamped: that repeats the shape's edge pixels out to infinity, and the
            // edge of a rounded rectangle is solid along its straight sides — so the "shadow"
            // was a band of full-strength dark three blurs wide, ending in a hard line where
            // it was cropped, rather than anything soft.
            shape = generated.cropped(to: rect)
        }

        return shape
            .applyingGaussianBlur(sigma: blur)
            .cropped(to: rect.insetBy(dx: -blur * 3, dy: -blur * 3))
            .transformed(by: CGAffineTransform(translationX: 0, y: -blur * 0.6))
    }

    /// Where the keys must not go: the bubble, while it is a bubble and mostly there.
    ///
    /// Only past half-visible, so while the bubble fades out the keys come back down once,
    /// in the middle of the fade, rather than sitting clear of a bubble that has gone.
    func keysAvoid(_ scene: SceneDescriptor) -> [CGRect] {
        guard let webcam = scene.webcam, webcam.isBubble, webcam.opacity >= 0.5 else { return [] }
        return [Self.outputRect(of: webcam.rect, in: scene.outputSize)]
    }

    /// An image at a fraction of its opacity.
    static func faded(_ image: CIImage, to opacity: Double) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: min(max(opacity, 0), 1)),
        ])
    }
}
