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
    /// Background movies being read, held open between frames. See `BackgroundMovies`.
    let movies = BackgroundMovies()
    /// Where the person is in each camera frame, for a camera whose background is blurred
    /// or removed. See `PersonMatte`.
    let personMatte: any PersonMatting

    private static let unitRect = CGRect(x: 0, y: 0, width: 1, height: 1)

    public init(device: (any MTLDevice)? = MTLCreateSystemDefaultDevice(),
                colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!,
                personMatte: any PersonMatting = PersonMatte()) {
        self.colorSpace = colorSpace
        self.personMatte = personMatte
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
    /// - Parameter webcam: the camera's frame at this moment, from the recording's own
    ///   second video file. Defaulted, so every caller that has no webcam — the crop
    ///   tool's flattened preview, a GIF, every test written before the bubble existed —
    ///   goes on asking for exactly the frame it always got.
    /// - Parameters:
    ///   - blending: the recording's frame for the other side of a crossfade, at
    ///     `scene.blendedScene?.sourceTime`. Ignored by every frame that is not in one.
    ///   - blendingWebcam: the camera's frame for that other side.
    public func image(for scene: SceneDescriptor, source: CIImage?, webcam: CIImage? = nil,
                      blending: CIImage? = nil, blendingWebcam: CIImage? = nil) -> CIImage {
        blended(composed(scene, source: source, webcam: webcam),
                scene: scene, blending: blending, blendingWebcam: blendingWebcam)
    }

    /// One frame, every layer, before any transition mixes it with another.
    func composed(_ scene: SceneDescriptor, source: CIImage?, webcam: CIImage?) -> CIImage {
        let output = CGRect(origin: .zero, size: scene.outputSize)
        var image = background(for: scene).cropped(to: output)

        // A title slide shows no recording: its panel, when it has one, stands where the
        // picture would, and is framed exactly as the picture is. Not drawn at all once a
        // camera layout has taken the screen away entirely: a picture at no opacity is
        // still a decode, a crop and a mask for nothing.
        if let source = scene.title == nil ? source : titlePanel(scene), scene.videoOpacity > 0.001 {
            // The window's bar, when there is one, is part of the picture for everything
            // that follows: it casts the shadow with it and sits under what is drawn on top.
            var video = chromed(videoLayer(scene, source: source), in: scene)
            if scene.videoOpacity < 1 { video = Self.faded(video, to: scene.videoOpacity) }
            if scene.shadowOpacity > 0, scene.shadowRadius > 0 {
                image = shadow(under: video, scene: scene).composited(over: image)
            }
            // Turned in space as one piece — picture, bar and border — when the project
            // asks for a perspective. See `tilted(_:in:)`.
            image = tilted(video, in: scene).composited(over: image)
        }
        // The spotlight darkens the background and the recording, and nothing laid over
        // them: the bubble, the notes, the captions, the keys, the clicks and the pointer
        // all stay as bright as they were. See `spotlightingPointer(_:in:)`.
        image = spotlightingPointer(image, in: scene)
        if let title = scene.title, let words = TitleArtwork.image(title, in: scene) {
            image = words.composited(over: image)
        }

        // Above the picture and below everything written on top of it. The bubble is part
        // of the *picture* — a second camera pointed at the presenter — whereas an
        // annotation and a caption are notes about it and must never end up behind a face,
        // and the pointer is what the viewer is being asked to follow. Both defaults put
        // the bubble and the captions near the bottom of the frame, so this ordering is the
        // difference between a line of subtitle that can be read and one that cannot.
        if let layer = scene.webcam, let webcam, let bubble = webcamImage(layer, source: webcam, in: scene) {
            if layer.shadowOpacity > 0 {
                image = webcamShadow(layer, bubble: bubble, in: scene).composited(over: image)
            }
            image = bubble.composited(over: image)
        }
        // Over the bubble, so a lens that follows the pointer across it is not hidden
        // behind a face, and under everything written on the picture.
        if let source {
            image = magnifyingPointer(image, in: scene, source: source)
        }

        for annotation in scene.annotations {
            if let layer = annotationImage(annotation, in: scene) {
                // A note on the picture turns with it, so what it points at stays pointed at.
                image = tilted(layer, in: scene).composited(over: image)
            }
        }
        // Above the annotations and below the pointer: a caption belongs on top of the
        // picture, but the pointer is what the viewer is following and must never be
        // hidden behind a line of text.
        if let caption = scene.caption, let layer = CaptionArtwork.image(caption, outputSize: scene.outputSize) {
            image = layer.composited(over: image)
        }
        // The keys above the caption, and kept clear of it in any case — see
        // `KeycapArtwork.frame` — and below the click marks and the pointer, which are
        // what the viewer is following.
        // Clear of the camera bubble too: keys parked in the corner the bubble sits in
        // were drawn over the person's face.
        // Only a bubble is kept clear of: a camera filling the frame or half of it would
        // push the keys off the picture. The rect is the one the camera is drawn in at
        // this moment — moved by a layout, border inside it — so the keys clear what is
        // actually there.
        if let keys = scene.keys,
           let layer = KeycapArtwork.image(keys, outputSize: scene.outputSize,
                                           avoiding: keysAvoid(scene)) {
            image = layer.composited(over: image)
        }
        // Under the pointer, deliberately: the mark says where a click landed, and the
        // pointer is the thing the viewer is following. Clipped like the pointer is, so a
        // click near the edge of a zoomed recording does not spill onto the padding.
        for click in scene.clicks {
            if let layer = clickImage(click, in: scene) {
                image = tilted(layer.cropped(to: scene.visibleVideoFrame), in: scene).composited(over: image)
            }
        }
        if let cursor = scene.cursor, let layer = cursorImage(cursor, in: scene) {
            // Clipped to where the video is, like the video itself. The pointer is
            // positioned against the *zoomed* frame, which is larger than the hole it
            // shows through, so without this a pointer near the edge of the recording
            // is drawn floating on the padding beside the picture.
            // Clipped flat and then turned, so it is cut by the picture's own edge.
            image = tilted(layer.cropped(to: scene.visibleVideoFrame), in: scene).composited(over: image)
        }
        return image.cropped(to: output)
    }

    /// Renders straight into a pixel buffer — what both the preview and the writer want.
    public func render(_ scene: SceneDescriptor, source: CIImage?, webcam: CIImage? = nil,
                       blending: CIImage? = nil, blendingWebcam: CIImage? = nil, to buffer: CVPixelBuffer) {
        context.render(image(for: scene, source: source, webcam: webcam,
                             blending: blending, blendingWebcam: blendingWebcam),
                       to: buffer,
                       bounds: CGRect(origin: .zero, size: scene.outputSize),
                       colorSpace: colorSpace)
    }

    /// A still, for a thumbnail or a test.
    public func cgImage(for scene: SceneDescriptor, source: CIImage?, webcam: CIImage? = nil,
                        blending: CIImage? = nil, blendingWebcam: CIImage? = nil) -> CGImage? {
        context.createCGImage(image(for: scene, source: source, webcam: webcam,
                                    blending: blending, blendingWebcam: blendingWebcam),
                              from: CGRect(origin: .zero, size: scene.outputSize))
    }

    // MARK: - Layers

    func background(for scene: SceneDescriptor) -> CIImage {
        let output = CGRect(origin: .zero, size: scene.outputSize)
        // A blur on a flat colour is a full-frame Gaussian that cannot change anything,
        // so it is skipped rather than paid for.
        let sigma = isFlat(scene.background) ? 0 : scene.backgroundBlur

        let make = {
            var image = self.draw(scene.background, in: output)
            if sigma > 0 {
                image = image.clampedToExtent()
                    .applyingGaussianBlur(sigma: sigma)
                    .cropped(to: output)
            }
            return image
        }
        // A background that moves is a different picture every frame: keeping it would
        // only push the still ones out of the cache.
        guard !scene.background.moves else { return make() }
        return backgrounds.image(for: scene.background, size: scene.outputSize, blurSigma: sigma, make: make)
    }

    private func isFlat(_ layer: BackgroundLayer) -> Bool {
        if case .color = layer { return true }
        if case .missing = layer { return true }
        if case .transparent = layer { return true }
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

        case .transparent:
            return CIImage(color: .clear).cropped(to: output)

        case .fittedGradient(let stops, let angle, let isRadial):
            return fittedGradient(stops: stops, angle: angle, isRadial: isRadial, in: output)

        case .animated(let layer):
            return animatedBackground(layer, in: output)

        case .video(let url, let time):
            return videoBackground(url, time: time, in: output) ?? draw(.missing, in: output)

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

    static func ramp(_ stops: [GradientStop]) -> CGImage? {
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
    func videoLayer(_ scene: SceneDescriptor, source: CIImage) -> CIImage {
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
        // After every cover and blur, so a spotlight dims them too: it is about
        // everything that is *not* in its rectangle. See `spotlit(_:by:)`.
        image = spotlit(image, by: scene.blurs)

        let isCropped = scene.sourceCrop != Self.unitRect
        if isCropped {
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
        let region = image.extent
        let sx = target.width / region.width
        let sy = target.height / region.height
        let placement = CGAffineTransform(a: sx, b: 0, c: 0, d: sy,
                                          tx: target.minX - region.minX * sx,
                                          ty: target.minY - region.minY * sy)
        if isCropped {
            // A cropped picture is scaled up, and its outermost pixels are filtered with
            // whatever lies past them. Past a crop's edge that is nothing — transparency — so
            // the edge came out half see-through, a faint line of the background round the
            // picture; and a crop that is there to cut away a resized window's black band
            // (`SceneBuilder.pictureCrop(at:)`) must not bring a trace of it back. Its own
            // edge pixels, repeated outwards, are what the filter should see, and the result
            // is cut back to exactly where the picture goes.
            image = image.clampedToExtent().transformed(by: placement).cropped(to: target)
        } else {
            image = image.transformed(by: placement)
        }

        // The colour correction: on the recording, placed, and on nothing laid over it
        // afterwards. Not on a title's panel, which is a colour somebody chose.
        if let grade = scene.grade, scene.title == nil {
            image = graded(image, by: grade)
        }

        // Softened along the camera's travel while it moves fast, before the corners are
        // cut so the frame's edge stays sharp — see `cameraBlurred(_:by:)`.
        if let motion = scene.cameraMotion {
            image = cameraBlurred(image, by: motion)
        }
        image = roundedPicture(image, in: scene)
        // Over the picture and inside its edge, taking its shape — see `bordered(_:by:in:)`.
        if let border = scene.border {
            image = bordered(image, by: border, in: scene)
        }
        // Cropped to where the video is allowed to be. Ordinarily that is the hole the
        // padding left, so a zoomed-in picture magnifies inside it and never spills over
        // the frame around it. When the whole frame zooms it is that hole grown and moved,
        // which is what lets the picture push out past the padding — see
        // `SceneDescriptor.visibleVideoFrame`.
        return image.cropped(to: scene.visibleVideoFrame)
    }

    private func applyBlur(_ blur: BlurLayer, to image: CIImage) -> CIImage {
        let extent = image.extent
        let rect = CGRect(x: extent.minX + blur.rect.minX * extent.width,
                          y: extent.minY + (1 - blur.rect.maxY) * extent.height,
                          width: blur.rect.width * extent.width,
                          height: blur.rect.height * extent.height)
        guard rect.width > 1, rect.height > 1 else { return image }

        let region = image.cropped(to: rect)
        var obscured: CIImage
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
        case .cover:
            obscured = CIImage(color: CIColor(red: blur.color.r, green: blur.color.g,
                                              blue: blur.color.b, alpha: blur.color.a))
                .cropped(to: rect)
        case .spotlight:
            // Not something over its rectangle at all. Handled once for every spotlight
            // in the frame, after this loop — see `spotlit(_:by:)`.
            return image
        }
        // Zero for every region written before corners existed, and zero is the exact
        // path those regions always took.
        if blur.cornerRadius > 0 {
            obscured = maskedToRoundedRectangle(obscured, rect, cornerRadius: blur.cornerRadius)
        }
        return obscured.composited(over: image)
    }

    /// Rounds an image's corners by masking it.
    func rounded(_ image: CIImage, radius: Double) -> CIImage {
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
        // The window's bar too, when there is one: it is part of what stands off the
        // background.
        let rect = scene.shadowCaster
        guard !rect.isNull, rect.width > 1 else { return CIImage.empty() }
        // A turned picture casts a turned shadow, and a deeper one under it.
        if let projection = scene.perspectiveProjection {
            return tiltedShadow(scene, projection: projection)
        }

        let filter = CIFilter.roundedRectangleGenerator()
        filter.extent = rect
        // Never quite square. A generator with no rounding is a plain block of colour, and
        // Core Image folds "a block of colour, blurred, cropped" into a colour with no edges
        // at all: a square frame with a shadow came out with the whole background black.
        // A pixel of rounding is invisible under a blur and keeps the shape a shape.
        filter.radius = Float(max(1, min(scene.shadowCornerRadius, min(rect.width, rect.height) / 2)))
        filter.color = CIColor(red: 0, green: 0, blue: 0, alpha: scene.shadowOpacity)
        guard let shape = filter.outputImage else { return CIImage.empty() }

        // Blurred as it is, not clamped first: clamping repeats the shape's solid sides out
        // to infinity, and the shadow came out as a dark band three blurs wide with a hard
        // edge where it was cropped. Outside the shape is nothing, which is what fades.
        return shape
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
        guard size > 1 else { return nil }

        let point = CGPoint(x: video.minX + cursor.position.x * video.width,
                            y: video.maxY - cursor.position.y * video.height)

        // The pointer as it really looked, when the recording kept one — the person's own
        // size, outline and colour, and their accessibility pointer if they use one. Scaled
        // to the same on-screen size as the drawn pointer would have been, so turning it on
        // changes what the pointer *is*, not how big it is.
        let picture: CIImage
        let drawn: CGSize
        let hotspot: CGPoint
        // A style of Klik's own is drawn at this frame's size, so it is as sharp in a 4K
        // export as in the preview, and carries its own point.
        if cursor.appearance != .asRecorded,
           let styled = PointerStyleArtwork.drawing(cursor.appearance, size: size, color: cursor.dotColor) {
            picture = styled.image
            drawn = styled.image.extent.size
            hotspot = styled.hotspot
        } else if let artwork = cursor.artwork, let recorded = RecordedCursorArtwork.image(artwork) {
            let extent = recorded.extent
            guard extent.width > 1, extent.height > 1 else { return nil }
            drawn = CGSize(width: size, height: size * artwork.aspect)
            picture = recorded.transformed(by: CGAffineTransform(scaleX: drawn.width / extent.width,
                                                                 y: drawn.height / extent.height))
            hotspot = artwork.hotspot
        } else {
            guard let image = CursorArtwork.image(cursor.shape, size: size) else { return nil }
            picture = image
            drawn = image.extent.size
            hotspot = CursorArtwork.hotspot(of: cursor.shape)
        }

        // Placed by its own hotspot rather than by a corner. A pointer's point is not its
        // top-left — an I-beam's is halfway down the middle, a crosshair's is dead centre,
        // and even the arrow's tip sits a little inside its picture — and assuming
        // otherwise puts the pointer somewhere it never was. `hotspot` is measured from the
        // top-left, and Core Image's origin is the bottom-left, so the vertical one is
        // taken from the far side.
        let origin = CGPoint(x: point.x - hotspot.x * drawn.width,
                             y: point.y - (1 - hotspot.y) * drawn.height)
        let placed = picture.transformed(by: CGAffineTransform(translationX: origin.x - picture.extent.minX,
                                                               y: origin.y - picture.extent.minY))
        // Smeared *after* it is in place. The smear makes the picture bigger on every side,
        // and placing a picture by the corner of its smear moved the pointer by the length
        // of it — further the faster it was going, which is exactly when it is being
        // watched.
        return motionBlurred(placed, velocity: cursor.velocity, size: size)
            .applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: cursor.opacity),
            ])
    }

    /// A click, marked where it happened: a ring that spreads and fades.
    ///
    /// A screen recording is usually watched without sound, so a click has nothing to
    /// announce it. The pointer's swell says *something* happened; it is small, it is over
    /// in a quarter of a second, and on a busy screen it is genuinely easy to miss. A ring
    /// at the spot says which spot.
    ///
    /// Built from generators rather than drawn into a bitmap, unlike the pointer: a ring is
    /// two rounded rectangles with the same radius as their own half-width — which is a
    /// circle — and nothing about it varies per frame except numbers, so there is no
    /// drawing to cache and nothing for a cache key to get wrong.
    private func clickImage(_ click: ClickLayer, in scene: SceneDescriptor) -> CIImage? {
        let video = scene.transformedVideoFrame
        let point = CGPoint(x: video.minX + click.position.x * video.width,
                            y: video.maxY - click.position.y * video.height)
        let shorter = min(scene.outputSize.width, scene.outputSize.height)
        let progress = min(1, max(0, click.progress))

        let colour = click.color
        func ink(_ alpha: Double) -> CIColor {
            CIColor(red: colour.r, green: colour.g, blue: colour.b,
                    alpha: max(0, min(1, colour.a * alpha)))
        }

        let mark: CIImage? = switch click.style {
        case .ring: ringMark(click, at: point, shorter: shorter, progress: progress, ink: ink)
        case .ripple: rippleMark(click, at: point, shorter: shorter, progress: progress, ink: ink)
        case .glow: glowMark(click, at: point, shorter: shorter, progress: progress, ink: ink)
        }
        guard let mark else { return nil }
        return edged(mark, ink: colour, width: max(1.5, shorter * click.size * 0.03))
    }

    /// A mark with a soft edge of the opposite tone under it, so it shows on anything.
    ///
    /// The mark is white unless somebody changes it, and a great deal of what gets
    /// recorded is white: a document, a web page, a spreadsheet. A white ring on a white
    /// page is not there at all, and that is the click nobody could see. The edge is the
    /// mark's own shape, darker and blurred, so against dark content it disappears and
    /// against light content it is what is seen. It fades with the mark because it is made
    /// from it.
    private func edged(_ mark: CIImage, ink: ColorValue, width: Double) -> CIImage {
        let luminance = 0.2126 * ink.r + 0.7152 * ink.g + 0.0722 * ink.b
        // Dark under a light mark, light under a dark one.
        let tone: CGFloat = luminance > 0.5 ? 0 : 1
        let nothing = CIVector(x: 0, y: 0, z: 0, w: 0)
        let edge = mark
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": nothing,
                "inputGVector": nothing,
                "inputBVector": nothing,
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.85),
                "inputBiasVector": CIVector(x: tone, y: tone, z: tone, w: 0),
            ])
            // Wider than the mark before it is softened. Blurred at its own width, all
            // of the edge that is left is under the mark, where it cannot be seen.
            .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: width * 0.5])
            .applyingGaussianBlur(sigma: width * 0.6)
            // A blur has no edge of its own; three widths out there is nothing left of it.
            .cropped(to: mark.extent.insetBy(dx: -width * 3, dy: -width * 3))
        return mark.composited(over: edge)
    }

    /// One ring, spreading and fading.
    private func ringMark(_ click: ClickLayer, at point: CGPoint, shorter: Double,
                          progress: Double, ink: (Double) -> CIColor) -> CIImage? {
        // Out fast, then easing to a stop — the shape of something being released rather
        // than something being animated at a constant speed, which reads as mechanical.
        let eased = 1 - pow(1 - progress, 3)
        let radius = shorter * click.size * (0.28 + 0.72 * eased) / 2
        let thickness = max(1.5, shorter * click.size * 0.07)
        guard radius > thickness else { return nil }

        let fade = pow(1 - progress, 1.6)
        var mark = ring(at: point, radius: radius, thickness: thickness, color: ink(fade))
        // A right-click gets a second, tighter ring rather than a different colour: colour
        // is the user's setting, and overriding it to say "this one was the other button"
        // would take their choice away to make a distinction they may not care about.
        if click.isSecondary,
           let inner = ring(at: point, radius: radius * 0.55, thickness: thickness * 0.8,
                            color: ink(fade * 0.9)) {
            mark = inner.composited(over: mark ?? CIImage.empty())
        }
        // A wash inside the ring for the first half, so the spot reads even on a busy
        // screen where a thin outline can land on top of text.
        if progress < 0.5, let fill = disc(at: point, radius: radius,
                                           color: ink(fade * 0.18 * (1 - progress * 2))) {
            mark = (mark ?? CIImage.empty()).composited(over: fill)
        }
        return mark
    }

    /// Three rings, each setting off a little after the one before, like a drop in water.
    ///
    /// The same ring as `ringMark` draws, three times, so the two styles are recognisably
    /// the same family and a project switched from one to the other keeps its size and
    /// colour meaning what they meant.
    private func rippleMark(_ click: ClickLayer, at point: CGPoint, shorter: Double,
                            progress: Double, ink: (Double) -> CIColor) -> CIImage? {
        let thickness = max(1.2, shorter * click.size * 0.05)
        var mark: CIImage?
        let rings = click.isSecondary ? 4 : 3
        for index in 0..<rings {
            // Each ring has its own clock, started a sixth of the way after the last.
            let delay = Double(index) * 0.16
            let own = (progress - delay) / (1 - delay)
            guard own > 0, own < 1 else { continue }
            let eased = 1 - pow(1 - own, 3)
            let radius = shorter * click.size * (0.2 + 0.8 * eased) / 2
            guard radius > thickness else { continue }
            // Later rings are fainter: the first is the click, the rest are its echo.
            let strength = pow(1 - own, 1.4) * (1 - Double(index) * 0.22)
            guard let next = ring(at: point, radius: radius, thickness: thickness, color: ink(strength)) else {
                continue
            }
            mark = mark.map { next.composited(over: $0) } ?? next
        }
        return mark
    }

    /// A soft disc of light that swells and goes.
    private func glowMark(_ click: ClickLayer, at point: CGPoint, shorter: Double,
                          progress: Double, ink: (Double) -> CIColor) -> CIImage? {
        let eased = 1 - pow(1 - progress, 2.2)
        let radius = shorter * click.size * (0.35 + 0.65 * eased) / 2
        guard radius > 1 else { return nil }
        let strength = pow(1 - progress, 1.3) * (click.isSecondary ? 0.75 : 0.55)

        let filter = CIFilter.radialGradient()
        filter.center = point
        filter.radius0 = Float(radius * 0.15)
        filter.radius1 = Float(radius)
        filter.color0 = ink(strength)
        filter.color1 = ink(0)
        let extent = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
        return filter.outputImage?.cropped(to: extent)
    }

    /// A filled circle. `roundedRectangleGenerator` with a radius of half its own side is
    /// exactly that, and it antialiases the way every other shape here does.
    private func disc(at point: CGPoint, radius: Double, color: CIColor) -> CIImage? {
        guard radius > 0.5 else { return nil }
        let filter = CIFilter.roundedRectangleGenerator()
        let extent = CGRect(x: point.x - radius, y: point.y - radius,
                            width: radius * 2, height: radius * 2)
        filter.extent = extent
        filter.radius = Float(radius)
        filter.color = color
        // Generators are infinite; cropping is what gives the shape an edge.
        return filter.outputImage?.cropped(to: extent)
    }

    private func ring(at point: CGPoint, radius: Double, thickness: Double, color: CIColor) -> CIImage? {
        // The hole is cut with an opaque disc whatever the ring's own colour. Source-out
        // keeps the outer disc by one minus the inner one's alpha, so cutting with the
        // ring's colour left a fading ring filled with a wash of itself — a quarter of its
        // strength at half faded.
        guard let outer = disc(at: point, radius: radius, color: color),
              let inner = disc(at: point, radius: radius - thickness, color: CIColor(red: 0, green: 0, blue: 0))
        else { return nil }
        // Source-out keeps the outer disc only where the inner one is transparent, which
        // is the band between them.
        return outer.applyingFilter("CISourceOutCompositing", parameters: [
            kCIInputBackgroundImageKey: inner,
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

    /// Turns, scales and slides the drawn annotation about its own centre.
    ///
    /// Core Image's y runs up, the model's runs down: a clockwise turn on the picture is a
    /// negative angle here, and a slide down is a negative y. Written once, here, so the
    /// two conventions meet in one place.
    private func placed(_ image: CIImage, _ annotation: AnnotationLayer, about rect: CGRect,
                        in scene: SceneDescriptor) -> CIImage {
        let hasTurn = annotation.rotation != 0
        let hasScale = annotation.scale != 1
        let hasSlide = annotation.offset != .zero
        guard hasTurn || hasScale || hasSlide else { return image }
        let transform = CGAffineTransform(translationX: -rect.midX, y: -rect.midY)
            .concatenating(CGAffineTransform(scaleX: annotation.scale, y: annotation.scale))
            .concatenating(CGAffineTransform(rotationAngle: -annotation.rotation * .pi / 180))
            .concatenating(CGAffineTransform(translationX: rect.midX + annotation.offset.dx * scene.outputSize.width,
                                             y: rect.midY - annotation.offset.dy * scene.outputSize.height))
        return image.transformed(by: transform, highQualityDownsample: true)
    }

    private func annotationImage(_ annotation: AnnotationLayer, in scene: SceneDescriptor) -> CIImage? {
        let rect = CGRect(x: annotation.rect.minX * scene.outputSize.width,
                          y: (1 - annotation.rect.maxY) * scene.outputSize.height,
                          width: annotation.rect.width * scene.outputSize.width,
                          height: annotation.rect.height * scene.outputSize.height)
        guard rect.width > 1, rect.height > 1 else { return nil }

        guard var image = AnnotationArtwork.image(annotation, in: rect, outputHeight: scene.outputSize.height) else {
            return nil
        }
        image = placed(image, annotation, about: rect, in: scene)
        guard annotation.opacity < 1 else { return image }
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: annotation.opacity),
        ])
    }
}
