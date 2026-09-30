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
    /// How much of the recording is on show, 0…1: less than 1 only while a camera layout
    /// that hides the screen — Camera Only — is arriving, staying or leaving. The pointer
    /// and the click marks fade with it, because they are part of the screen.
    ///
    /// 1 for every frame of every project without a camera layout, which is the frame it
    /// always was.
    public var videoOpacity: Double
    public var cornerRadius: Double
    public var shadowRadius: Double
    public var shadowOpacity: Double
    /// The line round the picture, or `nil` for none — which is what every project with
    /// no border describes, so its frame is the frame it always was. See `BorderLayer`.
    public var border: BorderLayer?
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
    /// The keys being pressed, if any are. `nil` draws nothing, which is what every
    /// project with an empty Keys lane describes.
    public var keys: KeyLayer?
    /// The camera bubble, when the recording has one and it is turned on.
    ///
    /// `nil` is load-bearing: a timeline whose webcam is off must describe a frame that is
    /// byte-identical to one described before this field existed, and the only way to be
    /// sure of that is for the absent case to be the absence of a layer rather than a
    /// layer with `isEnabled: false` in it that the renderer then has to remember to skip.
    public var webcam: WebcamLayer?
    /// Where in the recording this frame comes from — or, when `sourceMedia` names a
    /// movie brought into the project, where in that movie.
    public var sourceTime: CMTime
    /// The package-relative path of the movie this frame's picture comes from, or `nil`
    /// for the recording — which is every frame of every project made before a project
    /// could hold more than one take. Whatever reads frames for the renderer reads them
    /// from this file at `sourceTime`. See `Clip.source`.
    public var sourceMedia: String? = nil
    /// The words of a title slide, when this frame is one. A title shows no recording:
    /// the renderer draws the background — or a panel in the picture's place — and these.
    /// `nil` for every frame of footage, which is every frame a project made before titles
    /// describes.
    public var title: TitleLayer? = nil
    /// How this frame is mixed with another at a transition between two clips, or `nil`
    /// for a frame that is not in one. See `SceneBlend`.
    public var blend: SceneBlend? = nil
    /// The part of the source that is shown, normalised, top-left origin.
    /// The unit rect means no crop.
    public var sourceCrop: CGRect
    /// The window drawn round the picture, or `nil` for none — which is what every project
    /// without one describes, so its frame is the frame it always was. See `ChromeLayer`.
    ///
    /// Set after `init` rather than passed to it, like `cameraMotion`: both are added by
    /// the builder once the rest of the frame is known, and neither changes what any
    /// existing caller of the initialiser gets.
    public var chrome: ChromeLayer? = nil
    /// The phone or tablet drawn round the picture, or `nil` for none — which is what every
    /// project without one describes. Never set together with `chrome`: the two are kinds
    /// of the one frame. See `DeviceLayer`.
    ///
    /// Nothing in it is in pixels — the handset is measured off the picture's edge — so,
    /// unlike the bar, `scaled(by:)` has nothing to do for it.
    public var device: DeviceLayer? = nil
    /// How far the camera travels while this frame's shutter is open, or `nil` when it is
    /// still or motion blur is off. See `CameraMotionLayer`.
    public var cameraMotion: CameraMotionLayer? = nil
    /// The picture turned in space, or `nil` for square-on — which is what every project
    /// without a perspective describes, so its frame is the frame it always was. See
    /// `PerspectiveLayer`.
    public var perspective: PerspectiveLayer? = nil
    /// Colour correction for the recording's picture, or `nil` for none. See `GradeLayer`.
    public var grade: GradeLayer? = nil

    public init(outputSize: CGSize,
                background: BackgroundLayer,
                backgroundBlur: Double = 0,
                videoFrame: CGRect,
                videoOpacity: Double = 1,
                cornerRadius: Double = 0,
                shadowRadius: Double = 0,
                shadowOpacity: Double = 0,
                border: BorderLayer? = nil,
                zoom: Double = 1,
                zoomCenter: CGPoint = CGPoint(x: 0.5, y: 0.5),
                zoomsWholeFrame: Bool = false,
                blurs: [BlurLayer] = [],
                cursor: CursorLayer? = nil,
                clicks: [ClickLayer] = [],
                annotations: [AnnotationLayer] = [],
                caption: CaptionLayer? = nil,
                keys: KeyLayer? = nil,
                webcam: WebcamLayer? = nil,
                sourceTime: CMTime = .zero,
                sourceCrop: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1),
                sourceMedia: String? = nil) {
        self.outputSize = outputSize
        self.background = background
        self.backgroundBlur = backgroundBlur
        self.videoFrame = videoFrame
        self.videoOpacity = videoOpacity
        self.cornerRadius = cornerRadius
        self.shadowRadius = shadowRadius
        self.shadowOpacity = shadowOpacity
        self.border = border
        self.zoom = zoom
        self.zoomCenter = zoomCenter
        self.zoomsWholeFrame = zoomsWholeFrame
        self.blurs = blurs
        self.cursor = cursor
        self.clicks = clicks
        self.annotations = annotations
        self.caption = caption
        self.keys = keys
        self.webcam = webcam
        self.sourceTime = sourceTime
        self.sourceCrop = sourceCrop
        self.sourceMedia = sourceMedia
    }

    /// Where the video ends up once the camera has moved.
    ///
    /// A zoom brings the *centre of the framed region to the centre of the picture*. That is
    /// what a camera does, and it is the whole of the arithmetic below: the framing is `1/zoom`
    /// of the recording around `zoomCenter`, so magnifying by `zoom` and putting that point in
    /// the middle makes the region fill the frame exactly.
    ///
    /// It used to scale about the aimed-at point and leave that point where it was, which is a
    /// resize rather than a camera move. The source coordinate landing in the middle of the
    /// frame came out as `c + (0.5 - c) / zoom` instead of `c`, so every shot not aimed at the
    /// exact centre drifted towards the middle of the picture — further the harder it zoomed,
    /// and invisible at 0.5, 0.5, which is the only centre the tests were using.
    ///
    /// `videoFrame` is always centred in the output (`SceneBuilder.descriptor`), so its middle
    /// is the output's middle and this one rectangle serves both readings of `zoomsWholeFrame`.
    ///
    /// The y is flipped, and that flip is a fix rather than a flourish: `zoomCenter`
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

    /// The picture darkened except round the pointer, and a lens on the recording there.
    /// `nil` for every project that asks for neither, so its frame is the one it always
    /// was. See `PointerSpotlightLayer` and `PointerMagnifierLayer`.
    public var pointerSpotlight: PointerSpotlightLayer?
    public var pointerMagnifier: PointerMagnifierLayer?

    /// The rectangle the picture is actually allowed to occupy.
    ///
    /// The one question every clip in the renderer is really asking. Ordinarily it is the
    /// hole the padding left, and a zoomed picture is magnified *inside* that hole. When
    /// the whole frame zooms it is the hole itself, grown and moved — held to the output,
    /// because nothing is drawn off the edge of the video being written.
    public var visibleVideoFrame: CGRect {
        guard frameFollowsCamera else { return videoFrame }
        let bounds = CGRect(origin: .zero, size: outputSize)
        let grown = transformedVideoFrame.intersection(bounds)
        return grown.isNull ? videoFrame : grown
    }

    /// Whether the picture's frame — its corners, shadow, border and window bar — moves and
    /// scales with the camera rather than staying in the hole the padding left.
    ///
    /// Always true for a pull back, whatever `zoomsWholeFrame` says. Magnifying only the
    /// contents is a choice about pushing in: the picture fills its hole and the camera
    /// looks closer inside it. Pulled back there is nothing to fill the hole with — the
    /// recording has run out — so the only honest picture is the framed recording itself,
    /// smaller, with its corners and shadow, and the background showing round it. At
    /// exactly 1× the transformed frame *is* the hole, so switching rule as the camera
    /// crosses 1× moves nothing.
    public var frameFollowsCamera: Bool {
        zoomsWholeFrame || zoom < 1
    }

    public var transformedVideoFrame: CGRect {
        let size = CGSize(width: videoFrame.width * zoom, height: videoFrame.height * zoom)
        return CGRect(x: videoFrame.midX - zoomCenter.x * size.width,
                      y: videoFrame.midY - (1 - zoomCenter.y) * size.height,
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
        // In output pixels like the two above, so it is the fourth field that has to
        // follow the size — a border left at full width on a third-size frame is a mat.
        copy.border?.width = (border?.width ?? 0) * factor
        // The bubble's `rect` is normalised, so it follows `outputSize` without help — but
        // its corner radius is already resolved into output pixels, and a radius left at
        // full size against a third-size bubble is a circle where a rounded square belongs.
        // It would have shown only while the picture moved, and corrected itself the moment
        // playback stopped, which is the most confusing way for a bug to appear.
        copy.webcam?.cornerRadius = webcam.map { $0.cornerRadius * factor } ?? 0
        // The window's bar and the camera's travel are in output pixels too, and a bar
        // left at full height on a third-size frame would be most of the picture.
        copy.chrome?.barHeight = (chrome?.barHeight ?? 0) * factor
        copy.cameraMotion = cameraMotion?.scaled(by: factor)
        // The bubble's border is in output pixels for the same reason, and would have come
        // out three times as heavy on a third-size frame.
        copy.webcam?.border?.width = (webcam?.border?.width ?? 0) * factor
        // The other side of a crossfade is a frame too, and has to come out the same size
        // as this one to be mixed with it.
        copy.blend = blend?.scaled(by: factor)
        return copy
    }
}

/// Something hidden in this frame — or, for a spotlight, the one thing that is not.
public struct BlurLayer: Equatable, Sendable {
    /// Normalised to the video, not the output, so it stays on the thing it was put over
    /// when the camera moves.
    public var rect: CGRect
    public var style: BlurRegion.Style
    public var radius: Double
    /// A cover's colour.
    public var color: ColorValue
    /// How dark a spotlight makes the rest of the picture, 0…1.
    public var dimming: Double
    /// A spotlight's feather, as a fraction of the shorter side of the recording.
    public var softness: Double
    /// The corners, as a fraction of the region's own shorter side. See
    /// `BlurRegion.cornerRadius`.
    public var cornerRadius: Double

    /// The last four are defaulted so every description written before they existed —
    /// and every test — still reads as the plain blur it was.
    public init(rect: CGRect, style: BlurRegion.Style, radius: Double,
                color: ColorValue = .black,
                dimming: Double = BlurRegion.defaultDimming,
                softness: Double = BlurRegion.defaultSoftness,
                cornerRadius: Double = 0) {
        self.rect = rect
        self.style = style
        self.radius = radius
        self.color = color
        self.dimming = dimming
        self.softness = softness
        self.cornerRadius = cornerRadius
    }
}

/// The line round the recording's picture.
///
/// Drawn *inside* the picture's edge, over its outermost pixels, so that turning it on
/// moves nothing: `videoFrame`, the shadow and the corners are exactly what they were
/// without it. Its outer edge is the picture's own edge — rounded corners included,
/// because it is clipped by the same mask the picture is.
public struct BorderLayer: Equatable, Sendable {
    /// In output pixels, like `cornerRadius`, before the camera moves.
    public var width: Double
    public var color: ColorValue

    public init(width: Double, color: ColorValue) {
        self.width = width
        self.color = color
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
    /// What the mark looks like. A ring unless the project says otherwise, which is what
    /// every project made before there was a choice draws.
    public var style: CursorStyle.ClickStyle

    public init(position: CGPoint, progress: Double, color: ColorValue,
                size: Double, isSecondary: Bool,
                style: CursorStyle.ClickStyle = .ring) {
        self.position = position
        self.progress = progress
        self.color = color
        self.size = size
        self.isSecondary = isSecondary
        self.style = style
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
    /// Which drawing, when it is not the recorded one. `asRecorded` draws `artwork` or
    /// `shape`, which is what every description written before there was a choice meant.
    public var appearance: CursorStyle.Appearance = .asRecorded
    /// The `dot` style's colour.
    public var dotColor: ColorValue = CursorStyle.defaultDotColor

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
    /// Degrees clockwise on the picture, about the rect's centre.
    public var rotation: Double
    /// About the rect's centre, from the entrance or exit. Applied to the drawing rather
    /// than to the rect, so an annotation popping in is the same artwork growing — not a
    /// new drawing at every size along the way.
    public var scale: Double
    /// From the entrance or exit: `dx` a fraction of the output's width, `dy` of its
    /// height, top-left origin like `rect`.
    public var offset: CGVector
    /// Thickness, fill, type and shadow — part of the drawing, so part of its cache key.
    public var style: AnnotationStyle

    public init(kind: AnnotationItem.Kind, rect: CGRect, color: ColorValue, fontSize: Double, opacity: Double,
                rotation: Double = 0, scale: Double = 1, offset: CGVector = .zero,
                style: AnnotationStyle = AnnotationStyle()) {
        self.kind = kind
        self.rect = rect
        self.color = color
        self.fontSize = fontSize
        self.opacity = opacity
        self.rotation = rotation
        self.scale = scale
        self.offset = offset
        self.style = style
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
    public var typeface: CaptionStyle.Typeface
    /// A family by name, in place of `typeface`; empty for the system's type. See
    /// `CaptionStyle.fontFamily`.
    public var fontFamily: String
    /// Which word of the line is being said, counting from nought, when the project lights
    /// words up as they are said. `nil` draws the line in one colour.
    public var spokenWord: Int?
    public var highlightColor: ColorValue
    /// How big the plate is drawn, 1 being its own size. Only ever other than 1 while a
    /// line is arriving.
    public var scale: Double
    /// How far below its place the plate is drawn, as a fraction of the output's height.
    public var drop: Double

    public init(text: String,
                fontSize: Double,
                color: ColorValue,
                backgroundOpacity: Double,
                position: CaptionStyle.Position,
                margin: Double,
                opacity: Double = 1,
                typeface: CaptionStyle.Typeface = .standard,
                spokenWord: Int? = nil,
                highlightColor: ColorValue = ColorValue(r: 1, g: 0.84, b: 0.2),
                scale: Double = 1,
                drop: Double = 0,
                fontFamily: String = "") {
        self.text = text
        self.fontSize = fontSize
        self.color = color
        self.backgroundOpacity = backgroundOpacity
        self.position = position
        self.margin = margin
        self.opacity = opacity
        self.typeface = typeface
        self.fontFamily = fontFamily
        self.spokenWord = spokenWord
        self.highlightColor = highlightColor
        self.scale = scale
        self.drop = drop
    }
}

/// The camera: the webcam recording, over the picture — in its bubble, or wherever the
/// camera layout in force has put it.
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
    /// How much of the camera is on show, 0…1. Less than 1 only while a layout change is
    /// fading it in or out — see `CameraLayout.hidden`.
    public var opacity: Double
    /// Which part of the camera's picture is shown, already held to what can be drawn.
    public var crop: WebcamCrop
    /// The line round the camera, in output pixels, or `nil` for none — which is what every
    /// project written before there was one describes. Drawn inside the edge, like the
    /// picture's own border, so turning it on moves nothing and `rect` stays the whole of
    /// what is drawn.
    public var border: BorderLayer?
    /// What happens to the room behind the person.
    public var background: WebcamSettings.Background
    /// How soft a blurred background is, 0…1. The renderer turns it into a radius against
    /// the camera frame's own size, so the same setting reads the same at any resolution.
    public var backgroundBlur: Double
    /// Whether this is the bubble — a small thing in a corner — rather than the camera
    /// filling the frame or a pane of it.
    ///
    /// What the keys ask before stepping out of its way, and what the preview asks before
    /// offering a handle to drag it by: keys moved clear of a camera that fills the frame
    /// would be pushed off the picture, and dragging a pane would park a bubble somewhere
    /// nobody asked for one.
    public var isBubble: Bool

    public init(rect: CGRect, cornerRadius: Double, isMirrored: Bool, shadowOpacity: Double,
                opacity: Double = 1,
                crop: WebcamCrop = WebcamCrop(),
                border: BorderLayer? = nil,
                background: WebcamSettings.Background = .keep,
                backgroundBlur: Double = 0.5,
                isBubble: Bool = true) {
        self.rect = rect
        self.cornerRadius = cornerRadius
        self.isMirrored = isMirrored
        self.shadowOpacity = shadowOpacity
        self.opacity = opacity
        self.crop = crop
        self.border = border
        self.background = background
        self.backgroundBlur = backgroundBlur
        self.isBubble = isBubble
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
