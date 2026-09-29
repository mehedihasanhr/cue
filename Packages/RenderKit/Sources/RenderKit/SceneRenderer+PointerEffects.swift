import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import TimelineKit

/// The spotlight and the magnifier that follow the pointer.
extension SceneRenderer {
    /// How much of the spotlight's radius is feather, half inside the circle and half
    /// outside it. Enough that the edge reads as light falling off rather than as a hole
    /// cut in the picture.
    static let spotlightFeather = 0.35

    /// Darkens the frame so far — the background and the recording — except for a soft
    /// circle round the pointer.
    ///
    /// Called before the camera bubble and everything written over the picture are laid
    /// down, which is the decision about what is dimmed: the picture is, and nothing on it
    /// is. A caption, a note or a key the viewer is meant to read stays exactly as bright
    /// as it was, and so does the presenter's face.
    func spotlightingPointer(_ image: CIImage, in scene: SceneDescriptor) -> CIImage {
        guard let spot = scene.pointerSpotlight, spot.dimming > 0.001 else { return image }
        let output = CGRect(origin: .zero, size: scene.outputSize)
        let video = scene.transformedVideoFrame
        // Where the pointer is drawn, which on a turned picture is not where it is in the
        // flat frame.
        let centre = scene.projected(CGPoint(x: video.minX + spot.center.x * video.width,
                                             y: video.maxY - spot.center.y * video.height))
        let radius = min(output.width, output.height) * spot.radius
        guard radius > 1 else { return image }
        let feather = radius * Self.spotlightFeather

        let shade = CIFilter.radialGradient()
        shade.center = centre
        shade.radius0 = Float(max(0, radius - feather / 2))
        shade.radius1 = Float(radius + feather / 2)
        shade.color0 = CIColor(red: 0, green: 0, blue: 0, alpha: 0)
        shade.color1 = CIColor(red: 0, green: 0, blue: 0, alpha: min(1, spot.dimming))
        guard let dark = shade.outputImage?.cropped(to: output) else { return image }
        return dark.composited(over: image).cropped(to: output)
    }

    /// Where the lens is, in output pixels with Core Image's bottom-left origin: the
    /// pointer it is looking at, and the circle it is drawn in.
    ///
    /// Centred on the pointer, and slid only as far as it must to keep the whole circle
    /// and its border inside the frame. A lens cut off by the edge of the video is the
    /// fault this exists to prevent: the pointer is near an edge exactly when it is on a
    /// menu bar, a toolbar or a scroll bar, which is where magnifying is wanted most.
    static func lensGeometry(_ lens: PointerMagnifierLayer,
                             in scene: SceneDescriptor) -> (pointer: CGPoint, centre: CGPoint, radius: Double) {
        let size = scene.outputSize
        let video = scene.transformedVideoFrame
        let pointer = CGPoint(x: video.minX + lens.center.x * video.width,
                              y: video.maxY - lens.center.y * video.height)
        let radius = min(size.width, size.height) * lens.diameter / 2
        let reach = radius + lensBorder(radius: radius) + 1
        func held(_ value: Double, within length: Double) -> Double {
            length >= reach * 2 ? min(max(value, reach), length - reach) : length / 2
        }
        return (pointer, CGPoint(x: held(pointer.x, within: size.width), y: held(pointer.y, within: size.height)), radius)
    }

    /// The border's width: thin, and never thinner than a pixel and a half.
    static func lensBorder(radius: Double) -> Double {
        max(1.5, radius * 0.024)
    }

    /// Lays the lens over the frame so far.
    ///
    /// The picture inside is the recording itself, taken through the same `videoLayer`
    /// the frame was — so every blur, cover and mask is in the lens exactly as it is in
    /// the picture, and nothing hidden can be read by magnifying it — but placed at the
    /// lens's size from the full-resolution source. Enlarging the finished frame instead
    /// would magnify a picture already shrunk to fit the output, which is how text in a
    /// lens ends up soft.
    func magnifyingPointer(_ image: CIImage, in scene: SceneDescriptor, source: CIImage) -> CIImage {
        guard let lens = scene.pointerMagnifier, lens.opacity > 0.001, lens.factor > 0 else { return image }
        let output = CGRect(origin: .zero, size: scene.outputSize)
        let (pointer, centre, radius) = Self.lensGeometry(lens, in: scene)
        guard radius > 2 else { return image }
        let circle = CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)

        // The picture as it is framed now, magnified about the pointer and moved so the
        // pointer's spot is the lens's middle. Described as a frame of its own, with the
        // camera already in it, and drawn by the one function that draws the picture.
        let video = scene.transformedVideoFrame
        var magnified = scene
        magnified.videoFrame = CGRect(x: centre.x + (video.minX - pointer.x) * lens.factor,
                                      y: centre.y + (video.minY - pointer.y) * lens.factor,
                                      width: video.width * lens.factor,
                                      height: video.height * lens.factor)
        magnified.zoom = 1
        magnified.zoomCenter = CGPoint(x: 0.5, y: 0.5)
        magnified.zoomsWholeFrame = false
        magnified.cornerRadius = 0
        magnified.border = nil
        let picture = videoLayer(magnified, source: source).cropped(to: circle)

        // Dark behind the picture, for the part of a lens that looks past the recording's
        // edge — there is nothing there, and nothing should look like something.
        let backdrop = CIImage(color: CIColor(red: 0.08, green: 0.08, blue: 0.09)).cropped(to: circle)
        guard let inside = Self.circle(picture.composited(over: backdrop), in: circle) else { return image }

        let border = Self.lensBorder(radius: radius)
        var drawn = inside
        if let rim = Self.ring(centre: centre, radius: radius, thickness: border,
                               color: CIColor(red: 1, green: 1, blue: 1, alpha: 0.92)) {
            drawn = rim.composited(over: drawn)
        }
        // A faint dark line just outside the white one, so the lens has an edge on a white
        // page as well as on a dark one.
        if let edge = Self.ring(centre: centre, radius: radius + border * 0.8, thickness: border * 0.8,
                                color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.3)) {
            drawn = drawn.composited(over: edge)
        }
        // Lifted off the picture by a soft shadow, the way the recording is lifted off its
        // background.
        let blur = radius * 0.06
        if let shape = Self.circle(CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.35)).cropped(to: circle),
                                   in: circle) {
            // Not clamped before the blur: that repeats the edge of the square the circle
            // sits in out to infinity, and draws faint rays where the circle touches it.
            let shadow = shape
                .applyingGaussianBlur(sigma: blur)
                .cropped(to: circle.insetBy(dx: -blur * 3, dy: -blur * 3))
                .transformed(by: CGAffineTransform(translationX: 0, y: -blur * 0.5))
            drawn = drawn.composited(over: shadow)
        }
        if lens.opacity < 1 {
            drawn = drawn.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: lens.opacity),
            ])
        }
        // Turned with the picture it is a lens on, so it stays over the pointer.
        return tilted(drawn, in: scene).composited(over: image).cropped(to: output)
    }

    /// An image cut to the circle inscribed in `rect`.
    private static func circle(_ image: CIImage, in rect: CGRect) -> CIImage? {
        let mask = CIFilter.roundedRectangleGenerator()
        mask.extent = rect
        mask.radius = Float(min(rect.width, rect.height) / 2)
        mask.color = .white
        guard let shape = mask.outputImage?.cropped(to: rect) else { return nil }
        let blend = CIFilter.blendWithMask()
        blend.inputImage = image
        blend.maskImage = shape
        blend.backgroundImage = CIImage(color: .clear).cropped(to: rect)
        return blend.outputImage?.cropped(to: rect)
    }

    private static func disc(centre: CGPoint, radius: Double, color: CIColor) -> CIImage? {
        guard radius > 0.5 else { return nil }
        let rect = CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)
        let filter = CIFilter.roundedRectangleGenerator()
        filter.extent = rect
        filter.radius = Float(radius)
        filter.color = color
        return filter.outputImage?.cropped(to: rect)
    }

    /// A band whose outer edge is `radius` from the centre.
    ///
    /// The hole is cut with an opaque disc whatever the band's own alpha. Source-out keeps
    /// the band where the hole is *transparent*, so a hole as translucent as a 92% white
    /// band leaves 8% of the band behind across the whole middle — a grey veil over the
    /// picture inside the lens.
    private static func ring(centre: CGPoint, radius: Double, thickness: Double, color: CIColor) -> CIImage? {
        guard let outer = disc(centre: centre, radius: radius, color: color),
              let inner = disc(centre: centre, radius: radius - thickness, color: .white)
        else { return nil }
        return outer.applyingFilter("CISourceOutCompositing", parameters: [
            kCIInputBackgroundImageKey: inner,
        ])
    }
}
