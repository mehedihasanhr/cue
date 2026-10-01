import CoreGraphics
import CoreImage
import Foundation
import TimelineKit

/// The pointer styles drawn at the frame's size: every style but the recorded pointer and
/// the invisible one — Klik's own drawings, and the system's pointers by way of
/// `SystemPointerArtwork`.
///
/// Drawn with Core Graphics at the size the frame asks for, never scaled up from a
/// smaller picture, so the edge is as clean at 4K as at 720p. Each drawing carries its own
/// point, worked out from the same numbers it is drawn with — the one lesson
/// `CursorArtwork.hotspot(of:)` was written to learn is that a pointer placed by anything
/// other than its own point is drawn somewhere it never was.
enum PointerStyleArtwork {
    struct Drawing: Sendable {
        let image: CIImage
        /// The pointer's point, as a fraction of the drawing from its top-left.
        let hotspot: CGPoint
    }

    private struct Key: Hashable, Sendable {
        let appearance: CursorStyle.Appearance
        /// Only the system pointers have a drawing for each shape; the rest key on the arrow.
        let shape: CursorShapeKind
        /// Rounded, so a click swell walking the size through a range does not miss the
        /// cache on every frame.
        let size: Int
        /// Only the colour styles have a colour of their own; the rest key on a fixed one.
        let r: Double, g: Double, b: Double, a: Double
    }

    /// A few sizes of each style: the swell and a zoom that grows the pointer both walk
    /// the size through a range.
    private static let cache = ArtworkCache<Key, Drawing>(capacity: 24)

    /// How much bigger the large arrow is than the drawn arrow at the same setting.
    static let largeArrowScale = 1.3
    /// How much smaller the minimal arrow is.
    static let minimalScale = 0.7

    /// The drawing for a style at a pointer size in output pixels — the size the drawn
    /// arrow of `asRecorded` would be — in the pointer's shape where the style has one for
    /// it, or `nil` for a style that is not drawn here.
    static func drawing(_ appearance: CursorStyle.Appearance, shape: CursorShapeKind = .arrow,
                        size: Double, color: ColorValue) -> Drawing? {
        guard appearance != .asRecorded, appearance != .clicksOnly else { return nil }
        let rounded = Int(size.rounded())
        guard rounded > 1 else { return nil }
        let ink = appearance.usesColour ? color : ColorValue.white
        let shape = appearance.isSystemPointer ? shape : .arrow
        let key = Key(appearance: appearance, shape: shape, size: rounded, r: ink.r, g: ink.g, b: ink.b, a: ink.a)
        return cache.value(for: key) { draw(appearance, shape: shape, size: Double(rounded), color: ink) }
    }

    /// Empties it, so a test can draw one cold.
    static func clearCache() { cache.removeAll() }


    // MARK: - Drawing

    /// A context whose y runs down, which is how anybody describes a pointer.
    private static func context(width: Int, height: Int) -> CGContext? {
        guard width > 1, height > 1,
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.setShouldAntialias(true)
        return context
    }

    private static func draw(_ appearance: CursorStyle.Appearance, shape: CursorShapeKind,
                             size: Double, color: ColorValue) -> Drawing? {
        if let ink = SystemPointerArtwork.ink(for: appearance, color: color) {
            return SystemPointerArtwork.drawing(ink.generation, shape: shape, size: size,
                                                body: ink.body, outline: ink.outline)
        }
        switch appearance {
        case .largeArrow: return arrow(size: size)
        case .dot: return dot(size: size, color: color)
        case .minimal: return minimal(size: size)
        case .asRecorded, .clicksOnly, .macOS26, .macOS14, .macOS26White, .macOS14White, .macOS26Colour:
            return nil
        }
    }

    /// The classic tilted arrow, as offsets from its tip in units of the arrow's width
    /// scale: the same proportions `CursorArtwork` draws, so the large arrow is the
    /// familiar one a size up rather than a new shape.
    private static let arrowOutline: [CGPoint] = [
        CGPoint(x: 0, y: 0),
        CGPoint(x: 0, y: 1.036),
        CGPoint(x: 0.22, y: 0.784),
        CGPoint(x: 0.36, y: 1.232),
        CGPoint(x: 0.52, y: 1.134),
        CGPoint(x: 0.38, y: 0.70),
        CGPoint(x: 0.66, y: 0.672),
    ]

    private static func path(_ points: [CGPoint], unit: Double, tip: CGPoint) -> CGPath {
        let path = CGMutablePath()
        path.addLines(between: points.map { CGPoint(x: tip.x + $0.x * unit, y: tip.y + $0.y * unit) })
        path.closeSubpath()
        return path
    }

    /// White with a dark outline and a shadow. The outline is stroked first and the fill
    /// laid over its inner half, so the white reaches exactly to the path — and the
    /// path's first corner is the point. What the viewer sees as the tip of the arrow is
    /// where the pointer is.
    private static func arrow(size: Double) -> Drawing? {
        let unit = size * largeArrowScale
        let outline = max(1, unit * 0.045)
        let shadow = unit * 0.07
        let margin = outline + shadow
        let width = Int((margin * 2 + 0.66 * unit).rounded(.up))
        let height = Int((margin * 2 + 1.232 * unit + unit * 0.03).rounded(.up))
        guard let context = context(width: width, height: height) else { return nil }
        let tip = CGPoint(x: margin, y: margin)
        let shape = path(arrowOutline, unit: unit, tip: tip)

        context.setShadow(offset: CGSize(width: 0, height: -unit * 0.025), blur: shadow,
                          color: CGColor(gray: 0, alpha: 0.4))
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.addPath(shape)
        context.setStrokeColor(CGColor(gray: 0, alpha: 1))
        context.setLineWidth(outline * 2)
        context.setLineJoin(.round)
        context.strokePath()
        context.addPath(shape)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fillPath()
        context.endTransparencyLayer()

        guard let image = context.makeImage() else { return nil }
        return Drawing(image: CIImage(cgImage: image),
                       hotspot: CGPoint(x: tip.x / Double(width), y: tip.y / Double(height)))
    }

    /// A small arrowhead, outline only: a dark line with a white one under it so it shows
    /// on anything, and a light shadow.
    ///
    /// Its point is the outer edge of the white line at the tip — the round end the line
    /// makes there reaches half a line beyond the corner, up and to the left, and that is
    /// the part of the drawing a viewer reads as its tip.
    private static func minimal(size: Double) -> Drawing? {
        let unit = size * minimalScale
        let halo = max(2, unit * 0.12)
        let line = max(1, unit * 0.055)
        let shadow = unit * 0.06
        let margin = halo / 2 + shadow + 1
        let head: [CGPoint] = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 0, y: 0.92),
            CGPoint(x: 0.25, y: 0.69),
            CGPoint(x: 0.66, y: 0.65),
        ]
        let width = Int((margin * 2 + 0.66 * unit).rounded(.up))
        let height = Int((margin * 2 + 0.92 * unit).rounded(.up))
        guard let context = context(width: width, height: height) else { return nil }
        let tip = CGPoint(x: margin, y: margin)
        let shape = path(head, unit: unit, tip: tip)

        context.setShadow(offset: CGSize(width: 0, height: -unit * 0.02), blur: shadow,
                          color: CGColor(gray: 0, alpha: 0.25))
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.setLineJoin(.round)
        context.addPath(shape)
        context.setStrokeColor(CGColor(gray: 1, alpha: 1))
        context.setLineWidth(halo)
        context.strokePath()
        context.addPath(shape)
        context.setStrokeColor(CGColor(gray: 0.08, alpha: 1))
        context.setLineWidth(line)
        context.strokePath()
        context.endTransparencyLayer()

        guard let image = context.makeImage() else { return nil }
        let point = CGPoint(x: tip.x - halo / 2, y: tip.y - halo / 2)
        return Drawing(image: CIImage(cgImage: image),
                       hotspot: CGPoint(x: point.x / Double(width), y: point.y / Double(height)))
    }

    /// A filled circle in the chosen colour with a thin white rim, inside a soft ring of
    /// the same colour. Symmetrical about its middle, which is its point; no shadow, which
    /// would be the one thing about it that was not.
    private static func dot(size: Double, color: ColorValue) -> Drawing? {
        let core = size * 0.2
        let ringRadius = size * 0.36
        let ringWidth = max(1, size * 0.05)
        let glow = ringRadius + ringWidth
        let side = Int((glow * 2 + 2).rounded(.up))
        guard let context = context(width: side, height: side) else { return nil }
        let middle = CGPoint(x: Double(side) / 2, y: Double(side) / 2)
        func colour(_ alpha: Double) -> CGColor {
            CGColor(srgbRed: color.r, green: color.g, blue: color.b, alpha: max(0, min(1, color.a * alpha)))
        }
        func circle(_ radius: Double) -> CGRect {
            CGRect(x: middle.x - radius, y: middle.y - radius, width: radius * 2, height: radius * 2)
        }

        // The soft light between the dot and its ring.
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     colors: [colour(0.35), colour(0)] as CFArray,
                                     locations: [0, 1]) {
            context.drawRadialGradient(gradient, startCenter: middle, startRadius: core,
                                       endCenter: middle, endRadius: glow, options: [])
        }
        context.setStrokeColor(colour(0.55))
        context.setLineWidth(ringWidth)
        context.strokeEllipse(in: circle(ringRadius))

        context.setFillColor(colour(1))
        context.fillEllipse(in: circle(core))
        let rim = max(1, size * 0.035)
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
        context.setLineWidth(rim)
        context.strokeEllipse(in: circle(core + rim / 2))

        guard let image = context.makeImage() else { return nil }
        return Drawing(image: CIImage(cgImage: image), hotspot: CGPoint(x: 0.5, y: 0.5))
    }
}

/// A small picture of a pointer style, for the Pointer panel's picker.
///
/// Drawn by the code that draws the video, so the tile shows what the export will.
/// `asRecorded` is shown as the drawn system arrow; "Invisible but clicks" has no pointer
/// to show, and gets `nil`.
public enum PointerStylePreview {
    private static let context = CIContext(options: [.cacheIntermediates: false])

    public static func image(_ appearance: CursorStyle.Appearance, size: Double, color: ColorValue) -> CGImage? {
        let image: CIImage? = switch appearance {
        case .asRecorded: CursorArtwork.image(.arrow, size: size)
        case .clicksOnly: nil
        default: PointerStyleArtwork.drawing(appearance, size: size, color: color)?.image
        }
        guard let image else { return nil }
        return context.createCGImage(image, from: image.extent)
    }
}
