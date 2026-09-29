import CoreGraphics
import CoreMedia
import Foundation
import TimelineKit

/// One frame, described.
///
/// The seam between the edit and the pixels: `SceneBuilder` turns a timeline and a time
/// into this, and `SceneRenderer` turns this into an image. Because it is a value with no
/// behaviour, "does the export match the preview?" is a comparison of two of these
/// rather than an argument about two renderers.
public struct SceneDescriptor: Equatable, Sendable {
    /// The size of the finished frame, in pixels.
    public var outputSize: CGSize
    public var background: BackgroundLayer
    public var backgroundBlur: Double
    /// Where the recording sits in the output, before the camera moves.
    public var videoFrame: CGRect
    public var cornerRadius: Double
    public var shadowRadius: Double
    public var shadowOpacity: Double
    /// The camera: how far in, and about which point of the *video* (0…1).
    public var zoom: Double
    public var zoomCenter: CGPoint
    public var blurs: [BlurLayer]
    public var cursor: CursorLayer?
    /// Where clicks happened, while their marks are still showing. Usually empty, often
    /// one, occasionally two — a double-click is two marks, and collapsing them would hide
    /// the second tap, which is the one somebody is watching for.
    public var clicks: [ClickLayer]
    public var annotations: [AnnotationLayer]
    /// The line being spoken, if any is.
    public var caption: CaptionLayer?
    /// The camera bubble, when the recording has one and it is turned on.
    ///
    /// `nil` is load-bearing: a timeline whose webcam is off must describe a frame that is
    /// byte-identical to one described before this field existed, and the only way to be
    /// sure of that is for the absent case to be the absence of a layer rather than a
    /// layer with `isEnabled: false` in it that the renderer then has to remember to skip.
    public var webcam: WebcamLayer?
    /// Where in the recording this frame comes from.
    public var sourceTime: CMTime
    /// The part of the source that is shown, normalised, top-left origin.
    /// The unit rect means no crop.
    public var sourceCrop: CGRect

    public init(outputSize: CGSize,
                background: BackgroundLayer,
                backgroundBlur: Double = 0,
                videoFrame: CGRect,
                cornerRadius: Double = 0,
                shadowRadius: Double = 0,
                shadowOpacity: Double = 0,
                zoom: Double = 1,
                zoomCenter: CGPoint = CGPoint(x: 0.5, y: 0.5),
                zoomsWholeFrame: Bool = false,
                blurs: [BlurLayer] = [],
                cursor: CursorLayer? = nil,
                clicks: [ClickLayer] = [],
                annotations: [AnnotationLayer] = [],
                caption: CaptionLayer? = nil,
                webcam: WebcamLayer? = nil,
                sourceTime: CMTime = .zero,
                sourceCrop: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) {
        self.outputSize = outputSize
        self.background = background
        self.backgroundBlur = backgroundBlur
        self.videoFrame = videoFrame
        self.cornerRadius = cornerRadius
        self.shadowRadius = shadowRadius
        self.shadowOpacity = shadowOpacity
        self.zoom = zoom
        self.zoomCenter = zoomCenter
        self.zoomsWholeFrame = zoomsWholeFrame
        self.blurs = blurs
        self.cursor = cursor
        self.clicks = clicks
        self.annotations = annotations
        self.caption = caption
        self.webcam = webcam
        self.sourceTime = sourceTime
        self.sourceCrop = sourceCrop
    }

    /// Where the video ends up once the camera has moved.
    ///
    /// Zooming scales the video about a point and keeps that point where it was, which is
    /// what makes a zoom feel like a camera rather than a resize.
    ///
    /// The anchor's y is flipped, and that flip is a fix rather than a flourish: `zoomCenter`
    /// is normalised to the picture from its *top*, like every other normalised point in the
    /// model — a blur's rect (`SceneRenderer.applyBlur`), an annotation's, the cursor's
    /// position, the crop, and the pointer positions the camera clamps itself against — while
    /// this rect lives in Core Image's bottom-left output space. Without the flip a zoom aimed
    /// at the top of the frame showed the bottom of it, which also meant a zoom following the
    /// pointer framed the mirror image of where the pointer was. Every other reader of this
    /// rect already flips (`CanvasGeometry.videoInOutput`, the cursor layer), so this was the
    /// one place the two conventions met and nobody converted.
    /// Whether the zoom magnifies the framed picture as a whole rather than only its
    /// contents. See `CameraStyle.zoomsWholeFrame`.
    public var zoomsWholeFrame: Bool = false

    /// The rectangle the picture is actually allowed to occupy.
    ///
    /// The one question every clip in the renderer is really asking. Ordinarily it is the
    /// hole the padding left, and a zoomed picture is magnified *inside* that hole. When
    /// the whole frame zooms it is the hole itself, grown and moved — held to the output,
    /// because nothing is drawn off the edge of the video being written.
    public var visibleVideoFrame: CGRect {
        guard zoomsWholeFrame else { return videoFrame }
        let bounds = CGRect(origin: .zero, size: outputSize)
        let grown = transformedVideoFrame.intersection(bounds)
        return grown.isNull ? videoFrame : grown
    }

    public var transformedVideoFrame: CGRect {
        let anchor = CGPoint(x: videoFrame.minX + videoFrame.width * zoomCenter.x,
                             y: videoFrame.minY + videoFrame.height * (1 - zoomCenter.y))
        let size = CGSize(width: videoFrame.width * zoom, height: videoFrame.height * zoom)
        return CGRect(x: anchor.x - (anchor.x - videoFrame.minX) * zoom,
                      y: anchor.y - (anchor.y - videoFrame.minY) * zoom,
                      width: size.width,
                      height: size.height)
    }

    /// The same frame, described at a fraction of its size.
    ///
    /// The preview pane is a few hundred points across; a 4K project composites eight
    /// megapixels to fill it, and the difference is thrown away by the window server.
    /// This is how the preview asks for the smaller picture *while it is moving* — not by
    /// rendering the full frame and shrinking it, which would pay the full cost and then
    /// some, but by describing a smaller frame so every blur, every rounded-corner mask
    /// and every composite runs over fewer pixels.
    ///
    /// Why this can live on the descriptor rather than in the renderer: almost everything
    /// here is already normalised — a blur's rect, an annotation's rect and font size, the
    /// cursor's position and scale, the caption's font size, the crop, the zoom and its
    /// centre are all fractions of something, so they land in the same relative place at
    /// any size. Only four fields are in output pixels, and they are the four scaled here.
    /// That is also why the scaling is *not* a shortcut the renderer could take on its own:
    /// it is a decision about what the picture is, made by the one caller allowed to make
    /// it, and the export never makes it.
    ///
    /// `factor` of 1 returns `self` unchanged — identical, not merely equal — because the
    /// frame at rest and the frame the export writes must be the same bytes, and the
    /// cheapest way to be sure of that is for there to be no arithmetic to be wrong about.
    ///
    /// One thing does *not* scale: `BlurLayer.radius` is a sigma in source-recording
    /// pixels, applied before the footage is fitted into `videoFrame`, so a smaller output
    /// downscales the blurred region further and the obscured patch comes out proportionally
    /// softer-edged than it will in the file. That is a visible difference, and it is
    /// allowed for exactly the same reason the whole frame being softer is allowed: it
    /// lasts only while the picture is moving.
    public func scaled(by factor: Double) -> SceneDescriptor {
        guard factor > 0, factor != 1 else { return self }
        var copy = self
        // Rounded, because this size becomes a `CGImage`'s and a pixel buffer's, and a
        // fractional one there is a rounding decision made somewhere we cannot see.
        copy.outputSize = CGSize(width: max(1, (outputSize.width * factor).rounded()),
                                 height: max(1, (outputSize.height * factor).rounded()))
        copy.videoFrame = videoFrame.applying(CGAffineTransform(scaleX: factor, y: factor))
        copy.cornerRadius = cornerRadius * factor
        copy.shadowRadius = shadowRadius * factor
        // The bubble's `rect` is normalised, so it follows `outputSize` without help — but
        // its corner radius is already resolved into output pixels, and a radius left at
        // full size against a third-size bubble is a circle where a rounded square belongs.
        // It would have shown only while the picture moved, and corrected itself the moment
        // playback stopped, which is the most confusing way for a bug to appear.
        copy.webcam?.cornerRadius = webcam.map { $0.cornerRadius * factor } ?? 0
        return copy
    }
}

/// Something hidden in this frame.
public struct BlurLayer: Equatable, Sendable {
    /// Normalised to the video, not the output, so it stays on the thing it was put over
    /// when the camera moves.
    public var rect: CGRect
    public var style: BlurRegion.Style
    public var radius: Double

    public init(rect: CGRect, style: BlurRegion.Style, radius: Double) {
        self.rect = rect
        self.style = style
        self.radius = radius
    }
}

/// A click, marked where it happened.
///
/// The position is normalised to the video like the pointer's, so the mark travels with a
/// zoom and is dropped by the same crop. The *size* is not here: it is a fraction of the
/// finished frame, which only the renderer knows, and resolving it twice is how a ring
/// ends up a different size in the preview than in the export.
public struct ClickLayer: Equatable, Sendable {
    /// Normalised to the video, top-left origin.
    public var position: CGPoint
    /// 0 the instant the button went down, 1 when the mark has finished spreading.
    public var progress: Double
    public var color: ColorValue
    /// How big the ring grows, as a fraction of the shorter side of the output.
    public var size: Double
    public var isSecondary: Bool

    public init(position: CGPoint, progress: Double, color: ColorValue,
                size: Double, isSecondary: Bool) {
        self.position = position
        self.progress = progress
        self.color = color
        self.size = size
        self.isSecondary = isSecondary
    }
}

/// The pointer, where it was and how big.
public struct CursorLayer: Equatable, Sendable {
    /// Normalised to the video.
    public var position: CGPoint
    public var shape: CursorShapeKind
    /// Multiplier on the drawn size, click bounce included.
    public var scale: Double
    public var opacity: Double
    /// Recorded points per second, direction included. Zero when motion blur is off, so
    /// the renderer needs no second flag to decide.
    public var velocity: CGVector
    /// Let the camera magnify the pointer along with the content.
    ///
    /// The inverse of `CursorStyle.sizeIsIndependentOfZoom`, which is on by default —
    /// so this is off by default, and the pointer keeps its size through a zoom.
    public var sizeFollowsZoom: Bool
    /// The pointer as it really looked, when the recording kept a picture of it.
    ///
    /// `nil` falls back to `shape` and the drawn artwork, which is what every recording
    /// made before the real pointer was saved has — and what a project gets when the
    /// person turns the real one off.
    public var artwork: RecordedCursor?

    public init(position: CGPoint,
                shape: CursorShapeKind,
                scale: Double,
                opacity: Double = 1,
                velocity: CGVector = .zero,
                sizeFollowsZoom: Bool = false,
                artwork: RecordedCursor? = nil) {
        self.position = position
        self.shape = shape
        self.scale = scale
        self.opacity = opacity
        self.velocity = velocity
        self.sizeFollowsZoom = sizeFollowsZoom
        self.artwork = artwork
    }
}

/// A picture of the pointer, taken while it was on screen.
///
/// A file rather than the image itself, because a `SceneDescriptor` is a value that
/// crosses to the exporter and back, is compared for equality every frame, and is scaled
/// for the preview. A URL and two numbers do all of that cheaply; a `CIImage` does none of
/// it. The renderer opens and caches it.
public struct RecordedCursor: Equatable, Sendable {
    public var url: URL
    /// Which point of the image is the pointer's point, as a fraction of it, measured from
    /// the top-left the way the system reports a hotspot.
    public var hotspot: CGPoint
    /// Height over width, so the renderer can size it without opening it.
    public var aspect: Double

    public init(url: URL, hotspot: CGPoint, aspect: Double) {
        self.url = url
        self.hotspot = hotspot
        self.aspect = aspect
    }
}

/// Which pointer to draw.
///
/// Klik draws its own rather than shipping Apple's cursor artwork, so this is a small set
/// of shapes the renderer knows how to make — not a name from the system.
public enum CursorShapeKind: String, Equatable, Sendable {
    case arrow, iBeam, pointingHand, openHand, crosshair, resizeHorizontal, resizeVertical
}

/// Something drawn on top.
public struct AnnotationLayer: Equatable, Sendable {
    public var kind: AnnotationItem.Kind
    /// Normalised to the output frame: an annotation is a note on the finished video, so
    /// it does not travel with the camera.
    public var rect: CGRect
    public var color: ColorValue
    public var fontSize: Double
    public var opacity: Double

    public init(kind: AnnotationItem.Kind, rect: CGRect, color: ColorValue, fontSize: Double, opacity: Double) {
        self.kind = kind
        self.rect = rect
        self.color = color
        self.fontSize = fontSize
        self.opacity = opacity
    }
}

/// The line being spoken, on screen while it is being said.
///
/// Positioned by the renderer rather than carrying a rectangle, unlike an annotation:
/// a caption's whole job is to sit in the same place every time and be the width the
/// words need. Giving it a rect would invite it to be dragged somewhere, and a subtitle
/// that moves line to line is a fault.
public struct CaptionLayer: Equatable, Sendable {
    public var text: String
    public var fontSize: Double
    public var color: ColorValue
    public var backgroundOpacity: Double
    public var position: CaptionStyle.Position
    public var margin: Double
    public var opacity: Double

    public init(text: String,
                fontSize: Double,
                color: ColorValue,
                backgroundOpacity: Double,
                position: CaptionStyle.Position,
                margin: Double,
                opacity: Double = 1) {
        self.text = text
        self.fontSize = fontSize
        self.color = color
        self.backgroundOpacity = backgroundOpacity
        self.position = position
        self.margin = margin
        self.opacity = opacity
    }
}

/// The camera bubble: the webcam recording, over the picture.
///
/// Placed by the builder rather than by the renderer, and that split is the same one the
/// annotation layer makes for the same reason: corner, size and zoom reaction are
/// arithmetic on a `WebcamSettings` and an output size, and arithmetic is worth being able
/// to test without a GPU. What is left here is a rectangle and how to fill it.
///
/// **The aspect ratio.** The rectangle is square — `WebcamSettings.size` is one number, a
/// fraction of the shorter output side, and `roundness` turns that square into a circle —
/// while a camera is 16:9 or 4:3. The two cannot both be honoured, so the bubble *fills*
/// rather than fits: the camera frame is scaled until it covers the square and the
/// overhanging sides are cropped away, centred. Letterboxing inside a circle would draw
/// two black chords across a face, and stretching would make the face wide, and both of
/// those are worse than losing the edges of a shot that is mostly wall anyway. It is also
/// what every videoconferencing app does, so it is what people already expect to see.
public struct WebcamLayer: Equatable, Sendable {
    /// Where the bubble sits, normalised to the *output* frame with a top-left origin —
    /// the annotation convention, not the video's. A bubble is a fixture of the finished
    /// video: it must not slide about when the camera zooms into the recording behind it.
    public var rect: CGRect
    /// The corner radius in output pixels, already resolved from `roundness`, so the
    /// renderer has nothing left to decide. Half the bubble's side is a circle.
    public var cornerRadius: Double
    /// Flip left-to-right, which is what makes a camera behave like a mirror. On by
    /// default in the model, because a face that raises the wrong hand is unsettling.
    public var isMirrored: Bool
    public var shadowOpacity: Double

    public init(rect: CGRect, cornerRadius: Double, isMirrored: Bool, shadowOpacity: Double) {
        self.rect = rect
        self.cornerRadius = cornerRadius
        self.isMirrored = isMirrored
        self.shadowOpacity = shadowOpacity
    }

    /// The bubble in output pixels with a bottom-left origin — Core Image's space, and the
    /// renderer's. Here rather than inside the renderer so the flip is written once, and so
    /// the overlay that drags the bubble can ask exactly the question the renderer asks.
    public func pixelRect(in outputSize: CGSize) -> CGRect {
        CGRect(x: rect.minX * outputSize.width,
               y: (1 - rect.maxY) * outputSize.height,
               width: rect.width * outputSize.width,
               height: rect.height * outputSize.height)
    }
}
