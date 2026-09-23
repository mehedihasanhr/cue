import AppKit
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Metal
import TimelineKit

/// Draws a described frame.
///
/// Core Image on Metal: the compositing a demo video needs — scale, mask, blur, shadow,
/// blend — is what it is built for, and one `CIContext` renders into the same
/// `CVPixelBuffer` the preview view and the export encoder both want. Reaching for a
/// hand-written Metal pass would buy nothing until a full-frame blur at 4K shows up in a
/// profile.
///
/// `nonisolated` and instantiated per consumer: the preview holds one on its draw thread,
/// the exporter holds another. They share nothing but the descriptor they are given.
public final class SceneRenderer: @unchecked Sendable {
    public let context: CIContext
    /// The space everything is worked in. Public because the exporter renders into its
    /// own buffers and has to ask for the same one — the preview and the file coming out
    /// different colours is exactly what pinning this prevents.
    public let colorSpace: CGColorSpace
    private let backgrounds = BackgroundCache()

    private static let unitRect = CGRect(x: 0, y: 0, width: 1, height: 1)

    public init(device: (any MTLDevice)? = MTLCreateSystemDefaultDevice(),
                colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!) {
        self.colorSpace = colorSpace
        let options: [CIContextOption: Any] = [
            .workingColorSpace: colorSpace,
            .outputColorSpace: colorSpace,
            // The preview and the export must agree, and they only do if both work in
            // the same space. Pinning it is what stops an export coming out darker.
            .cacheIntermediates: false,
        ]
        if let device {
            context = CIContext(mtlDevice: device, options: options)
        } else {
            context = CIContext(options: options)
        }
    }

    /// The finished frame as a `CIImage`, in output pixels with the origin bottom-left
    /// (Core Image's convention, and `CVPixelBuffer`'s).
    public func image(for scene: SceneDescriptor, source: CIImage?) -> CIImage {
        let output = CGRect(origin: .zero, size: scene.outputSize)
        var image = background(for: scene).cropped(to: output)

        if let source {
            let video = videoLayer(scene, source: source)
            if scene.shadowOpacity > 0, scene.shadowRadius > 0 {
                image = shadow(under: video, scene: scene).composited(over: image)
            }
            image = video.composited(over: image)
        }

        for annotation in scene.annotations {
            if let layer = annotationImage(annotation, in: scene) {
                image = layer.composited(over: image)
            }
        }
        // Above the annotations and below the pointer: a caption belongs on top of the
        // picture, but the pointer is what the viewer is following and must never be
        // hidden behind a line of text.
        if let caption = scene.caption, let layer = CaptionArtwork.image(caption, outputSize: scene.outputSize) {
            image = layer.composited(over: image)
        }
        if let cursor = scene.cursor, let layer = cursorImage(cursor, in: scene) {
            // Clipped to where the video is, like the video itself. The pointer is
            // positioned against the *zoomed* frame, which is larger than the hole it
            // shows through, so without this a pointer near the edge of the recording
            // is drawn floating on the padding beside the picture.
            image = layer.cropped(to: scene.videoFrame).composited(over: image)
        }
        return image.cropped(to: output)
    }

    /// Renders straight into a pixel buffer — what both the preview and the writer want.
    public func render(_ scene: SceneDescriptor, source: CIImage?, to buffer: CVPixelBuffer) {
        context.render(image(for: scene, source: source),
                       to: buffer,
                       bounds: CGRect(origin: .zero, size: scene.outputSize),
                       colorSpace: colorSpace)
    }

    /// A still, for a thumbnail or a test.
    public func cgImage(for scene: SceneDescriptor, source: CIImage?) -> CGImage? {
        context.createCGImage(image(for: scene, source: source),
                              from: CGRect(origin: .zero, size: scene.outputSize))
    }

    // MARK: - Layers

    private func background(for scene: SceneDescriptor) -> CIImage {
        let output = CGRect(origin: .zero, size: scene.outputSize)
        // A blur on a flat colour is a full-frame Gaussian that cannot change anything,
        // so it is skipped rather than paid for.
        let sigma = isFlat(scene.background) ? 0 : scene.backgroundBlur

        return backgrounds.image(for: scene.background, size: scene.outputSize, blurSigma: sigma) {
            var image = self.draw(scene.background, in: output)
            if sigma > 0 {
                image = image.clampedToExtent()
                    .applyingGaussianBlur(sigma: sigma)
                    .cropped(to: output)
            }
            return image
        }
    }

    private func isFlat(_ layer: BackgroundLayer) -> Bool {
        if case .color = layer { return true }
        if case .missing = layer { return true }
        return false
    }

    private func draw(_ layer: BackgroundLayer, in output: CGRect) -> CIImage {
        switch layer {
        case .color(let color):
            return CIImage(color: CIColor(red: color.r, green: color.g, blue: color.b, alpha: color.a))
                .cropped(to: output)

        case .missing:
            // The background a document asked for is not on this Mac. Drawn as the
            // default flat colour rather than as black, so a missing wallpaper looks
            // like a background rather than like a broken render.
            let color = BackgroundLayer.fallbackColor
            return CIImage(color: CIColor(red: color.r, green: color.g, blue: color.b, alpha: color.a))
                .cropped(to: output)

        case .gradient(let stops, let angle):
            return gradient(stops: stops, angle: angle, in: output)

        case .image(let url):
            guard let image = BackgroundImageLoader.load(url, fitting: output.size) else {
                return draw(.missing, in: output)
            }
            // Fill, not fit: a wallpaper with bars down the side is not a background.
            let scale = max(output.width / image.extent.width, output.height / image.extent.height)
            let filled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            return filled
                .transformed(by: CGAffineTransform(translationX: output.midX - filled.extent.midX,
                                                   y: output.midY - filled.extent.midY))
                .cropped(to: output)
        }
    }

    /// A linear gradient of any number of stops.
    ///
    /// Two stops stay on `CIFilter.linearGradient`, so every background that already
    /// shipped renders byte for byte as it did. More than two needs a real colour ramp,
    /// which Core Image has no generator for — so one is drawn as a 512×1 strip and
    /// stretched. A gradient has no high frequencies in it, so the upscale costs
    /// nothing visible.
    private func gradient(stops: [GradientStop], angle: Double, in output: CGRect) -> CIImage {
        let sorted = stops.sorted { $0.location < $1.location }
        guard let first = sorted.first else { return CIImage(color: .black).cropped(to: output) }
        guard sorted.count > 1 else {
            let c = first.color
            return CIImage(color: CIColor(red: c.r, green: c.g, blue: c.b, alpha: c.a)).cropped(to: output)
        }

        let radians = angle * 2 * .pi
        let length = max(output.width, output.height) * 1.5
        let centre = CGPoint(x: output.midX, y: output.midY)
        let start = CGPoint(x: centre.x - cos(radians) * length / 2,
                            y: centre.y - sin(radians) * length / 2)
        let end = CGPoint(x: centre.x + cos(radians) * length / 2,
                          y: centre.y + sin(radians) * length / 2)

        if sorted.count == 2 {
            let filter = CIFilter.linearGradient()
            filter.point0 = start
            filter.point1 = end
            filter.color0 = CIColor(red: sorted[0].color.r, green: sorted[0].color.g,
                                    blue: sorted[0].color.b, alpha: sorted[0].color.a)
            filter.color1 = CIColor(red: sorted[1].color.r, green: sorted[1].color.g,
                                    blue: sorted[1].color.b, alpha: sorted[1].color.a)
            return (filter.outputImage ?? CIImage(color: .black)).cropped(to: output)
        }

        guard let strip = Self.ramp(sorted) else { return CIImage(color: .black).cropped(to: output) }
        // The strip runs 0…1 along x; rotate and stretch it onto the sweep.
        let sweep = CGAffineTransform(translationX: start.x, y: start.y)
            .rotated(by: radians)
            .scaledBy(x: length / Double(strip.width), y: length)
            .translatedBy(x: 0, y: -0.5)
        return CIImage(cgImage: strip)
            .transformed(by: sweep)
            .clampedToExtent()
            .cropped(to: output)
    }

    private static func ramp(_ stops: [GradientStop]) -> CGImage? {
        let width = 512
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: width, height: 1, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let colors = stops.map { CGColor(srgbRed: $0.color.r, green: $0.color.g, blue: $0.color.b, alpha: $0.color.a) }
        let locations = stops.map { CGFloat(min(1, max(0, $0.location))) }
        guard let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)
        else { return nil }
        context.drawLinearGradient(gradient,
                                   start: CGPoint(x: 0, y: 0.5),
                                   end: CGPoint(x: CGFloat(width), y: 0.5),
                                   options: CGGradientDrawingOptions([.drawsBeforeStartLocation, .drawsAfterEndLocation]))
        return context.makeImage()
    }

    /// The recording: scaled into place, camera applied, corners rounded, blurs applied.
    private func videoLayer(_ scene: SceneDescriptor, source: CIImage) -> CIImage {
        var image = source
        let target = scene.transformedVideoFrame
        guard source.extent.width > 0, source.extent.height > 0 else { return source }

        // Blurs run before the crop because a blur is attached to the footage: its rect
        // is authored against the whole recording, and changing the crop must not slide
        // it onto something else. One that falls entirely outside the crop then goes
        // away with the pixels it was covering, which is right.
        for blur in scene.blurs {
            image = applyBlur(blur, to: image)
        }

        if scene.sourceCrop != Self.unitRect {
            let extent = image.extent
            image = image.cropped(to: CGRect(x: extent.minX + scene.sourceCrop.minX * extent.width,
                                             y: extent.minY + (1 - scene.sourceCrop.maxY) * extent.height,
                                             width: scene.sourceCrop.width * extent.width,
                                             height: scene.sourceCrop.height * extent.height))
            guard image.extent.width > 0, image.extent.height > 0 else { return source }
        }

        // Measured against `image`, not `source`: after a crop those are different sizes,
        // and scaling the cropped picture by the uncropped ratio is the mistake this
        // line exists to not make.
        let scale = CGAffineTransform(scaleX: target.width / image.extent.width,
                                      y: target.height / image.extent.height)
        image = image.transformed(by: scale)
        image = image.transformed(by: CGAffineTransform(translationX: target.minX - image.extent.minX,
                                                        y: target.minY - image.extent.minY))

        if scene.cornerRadius > 0 {
            image = rounded(image, radius: scene.cornerRadius * (target.width / scene.videoFrame.width))
        }
        // Cropped to where the video is meant to be: a zoomed-in frame must not spill
        // over the padding that frames it.
        return image.cropped(to: scene.videoFrame)
    }

    private func applyBlur(_ blur: BlurLayer, to image: CIImage) -> CIImage {
        let extent = image.extent
        let rect = CGRect(x: extent.minX + blur.rect.minX * extent.width,
                          y: extent.minY + (1 - blur.rect.maxY) * extent.height,
                          width: blur.rect.width * extent.width,
                          height: blur.rect.height * extent.height)
        guard rect.width > 1, rect.height > 1 else { return image }

        let region = image.cropped(to: rect)
        let obscured: CIImage
        switch blur.style {
        case .gaussian:
            obscured = region.clampedToExtent()
                .applyingGaussianBlur(sigma: blur.radius)
                .cropped(to: rect)
        case .pixelate:
            let filter = CIFilter.pixellate()
            filter.inputImage = region.clampedToExtent()
            filter.scale = Float(max(2, blur.radius))
            filter.center = CGPoint(x: rect.midX, y: rect.midY)
            obscured = (filter.outputImage ?? region).cropped(to: rect)
        }
        return obscured.composited(over: image)
    }

    /// Rounds an image's corners by masking it.
    private func rounded(_ image: CIImage, radius: Double) -> CIImage {
        let extent = image.extent
        guard radius > 0.5 else { return image }

        let filter = CIFilter.roundedRectangleGenerator()
        filter.extent = extent
        filter.radius = Float(min(radius, min(extent.width, extent.height) / 2))
        filter.color = .white
        guard let mask = filter.outputImage else { return image }

        let blend = CIFilter.blendWithMask()
        blend.inputImage = image
        blend.maskImage = mask
        blend.backgroundImage = CIImage(color: .clear).cropped(to: extent)
        return blend.outputImage ?? image
    }

    /// The soft dark shape under the video that lifts it off the background.
    private func shadow(under video: CIImage, scene: SceneDescriptor) -> CIImage {
        let rect = scene.transformedVideoFrame.intersection(scene.videoFrame)
        guard !rect.isNull, rect.width > 1 else { return CIImage.empty() }

        let filter = CIFilter.roundedRectangleGenerator()
        filter.extent = rect
        filter.radius = Float(min(scene.cornerRadius, min(rect.width, rect.height) / 2))
        filter.color = CIColor(red: 0, green: 0, blue: 0, alpha: scene.shadowOpacity)
        guard let shape = filter.outputImage else { return CIImage.empty() }

        return shape
            .clampedToExtent()
            .applyingGaussianBlur(sigma: scene.shadowRadius)
            .cropped(to: rect.insetBy(dx: -scene.shadowRadius * 3, dy: -scene.shadowRadius * 3))
            .transformed(by: CGAffineTransform(translationX: 0, y: -scene.shadowRadius * 0.6))
    }

    // MARK: - Cursor and annotations

    /// The pointer, drawn rather than sampled.
    ///
    /// Klik draws its own shapes: the system's cursor artwork is Apple's, and a recording
    /// that has to ship a copy of it is a licensing question nobody needs. Drawn once per
    /// size and cached, because a pointer is redrawn every frame and a `CGContext` per
    /// frame would show up in a profile immediately.
    private func cursorImage(_ cursor: CursorLayer, in scene: SceneDescriptor) -> CIImage? {
        let video = scene.transformedVideoFrame
        // Sized against the output, not the video, so a zoom does not magnify the
        // pointer along with the content — which is what `sizeIsIndependentOfZoom` means.
        // `sizeFollowsZoom` is the other choice: some people want the pointer to grow
        // with what it is pointing at.
        let zoomFactor = cursor.sizeFollowsZoom ? scene.zoom : 1
        let size = min(scene.outputSize.width, scene.outputSize.height) * 0.035 * cursor.scale * zoomFactor
        guard size > 1, var image = CursorArtwork.image(cursor.shape, size: size) else { return nil }

        image = motionBlurred(image, velocity: cursor.velocity, size: size)

        let point = CGPoint(x: video.minX + cursor.position.x * video.width,
                            y: video.maxY - cursor.position.y * video.height)
        // The hotspot is the pointer's tip, which is its top-left in Core Image's
        // bottom-left space.
        return image
            .transformed(by: CGAffineTransform(translationX: point.x, y: point.y - image.extent.height))
            .applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: cursor.opacity),
            ])
    }

    /// Smears the pointer along its travel, when it is travelling.
    ///
    /// Gated on speed, and capped: a stationary pointer must come out untouched, and a
    /// flick across a 4K screen must not turn it into a streak across the frame.
    private func motionBlurred(_ image: CIImage, velocity: CGVector, size: Double) -> CIImage {
        let speed = hypot(velocity.dx, velocity.dy)
        // Below roughly a third of the frame per second there is nothing to smear.
        guard speed > 600 else { return image }
        let radius = min(size * 0.4, size * 0.4 * (speed - 600) / 2_400)
        guard radius > 0.5 else { return image }

        let filter = CIFilter.motionBlur()
        // Core Image's y runs up and the recorded pointer's runs down.
        filter.inputImage = image.clampedToExtent()
        filter.angle = Float(atan2(-velocity.dy, velocity.dx))
        filter.radius = Float(radius)
        return (filter.outputImage ?? image).cropped(to: image.extent.insetBy(dx: -radius, dy: -radius))
    }

    private func annotationImage(_ annotation: AnnotationLayer, in scene: SceneDescriptor) -> CIImage? {
        let rect = CGRect(x: annotation.rect.minX * scene.outputSize.width,
                          y: (1 - annotation.rect.maxY) * scene.outputSize.height,
                          width: annotation.rect.width * scene.outputSize.width,
                          height: annotation.rect.height * scene.outputSize.height)
        guard rect.width > 1, rect.height > 1 else { return nil }

        guard let image = AnnotationArtwork.image(annotation, in: rect, outputHeight: scene.outputSize.height) else {
            return nil
        }
        guard annotation.opacity < 1 else { return image }
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: annotation.opacity),
        ])
    }
}
