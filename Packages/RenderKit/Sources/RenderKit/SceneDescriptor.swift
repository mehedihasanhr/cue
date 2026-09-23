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
    public var annotations: [AnnotationLayer]
    /// The line being spoken, if any is.
    public var caption: CaptionLayer?
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
                blurs: [BlurLayer] = [],
                cursor: CursorLayer? = nil,
                annotations: [AnnotationLayer] = [],
                caption: CaptionLayer? = nil,
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
        self.blurs = blurs
        self.cursor = cursor
        self.annotations = annotations
        self.caption = caption
        self.sourceTime = sourceTime
        self.sourceCrop = sourceCrop
    }

    /// Where the video ends up once the camera has moved.
    ///
    /// Zooming scales the video about a point and keeps that point where it was, which is
    /// what makes a zoom feel like a camera rather than a resize.
    public var transformedVideoFrame: CGRect {
        let anchor = CGPoint(x: videoFrame.minX + videoFrame.width * zoomCenter.x,
                             y: videoFrame.minY + videoFrame.height * zoomCenter.y)
        let size = CGSize(width: videoFrame.width * zoom, height: videoFrame.height * zoom)
        return CGRect(x: anchor.x - (anchor.x - videoFrame.minX) * zoom,
                      y: anchor.y - (anchor.y - videoFrame.minY) * zoom,
                      width: size.width,
                      height: size.height)
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

    public init(position: CGPoint,
                shape: CursorShapeKind,
                scale: Double,
                opacity: Double = 1,
                velocity: CGVector = .zero,
                sizeFollowsZoom: Bool = false) {
        self.position = position
        self.shape = shape
        self.scale = scale
        self.opacity = opacity
        self.velocity = velocity
        self.sizeFollowsZoom = sizeFollowsZoom
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
