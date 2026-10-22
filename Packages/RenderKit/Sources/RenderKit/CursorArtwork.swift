import AppKit
import CoreGraphics
import CoreImage
import Foundation
import os
import TimelineKit

/// The pointers Cue draws.
///
/// Its own artwork, on purpose: the system cursors are Apple's, and a video file that
/// bakes them in is a question nobody wants to answer. These are the familiar silhouettes
/// — a tilted arrow with a white outline, an I-beam, a hand — which is what a viewer
/// needs to follow a demo.
///
/// Each shape is drawn once per size and kept: a pointer is redrawn on every frame of
/// every preview, and a `CGContext` per frame is a cost that shows up immediately.
enum CursorArtwork {
    /// Bounded, where it used to be a dictionary that only grew.
    ///
    /// Seven shapes and one integer size each, so in practice it settled at a handful of
    /// entries — but a click bounce and a zoom that magnifies the pointer both walk the
    /// size through a range, and at 4K a pointer bitmap is 120 kB. Thirty-two entries covers
    /// every shape at several sizes at once, which is more than any one frame can ask for,
    /// and puts a ceiling on a per-frame path that had none.
    private static let cache = ArtworkCache<Key, CIImage>(capacity: 32)

    private struct Key: Hashable {
        let shape: CursorShapeKind
        /// Rounded, so a spring animating a scale does not miss the cache every frame.
        let size: Int
    }

    static func image(_ shape: CursorShapeKind, size: Double) -> CIImage? {
        let key = Key(shape: shape, size: Int(size.rounded()))
        return cache.value(for: key) { draw(shape, size: Double(key.size)) }
    }

    /// Empties it, so a test can draw one cold.
    static func clearCache() { cache.removeAll() }

    /// Where each drawing's point is, as a fraction of the drawing from its top-left.
    ///
    /// The same numbers the paths below are drawn with, which is the whole reason it lives
    /// beside them: the arrow's tip is the first vertex of its path, and everything else
    /// is drawn about its own middle. Every shape used to be placed by its top-left
    /// corner, which was nearly right for the arrow and wrong by half a pointer for an
    /// I-beam — the text cursor was drawn below and to the right of the text it was in.
    static func hotspot(of shape: CursorShapeKind) -> CGPoint {
        switch shape {
        case .arrow:
            CGPoint(x: 0.06, y: 0.04)
        case .pointingHand:
            // The tip of the finger that is doing the pointing.
            CGPoint(x: 0.44, y: 0.05)
        case .openHand, .iBeam, .crosshair, .resizeHorizontal, .resizeVertical:
            CGPoint(x: 0.5, y: 0.5)
        }
    }

    private static func draw(_ shape: CursorShapeKind, size: Double) -> CIImage? {
        let width = Int(size.rounded())
        let height = Int((size * 1.4).rounded())
        guard width > 1, height > 1,
              let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        // Core Graphics here is bottom-left; the shapes below are described top-down
        // because that is how anyone thinks about a pointer.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)

        let path = path(for: shape, in: CGSize(width: Double(width), height: Double(height)))
        context.setShadow(offset: CGSize(width: 0, height: -size * 0.03), blur: size * 0.08,
                          color: CGColor(gray: 0, alpha: 0.45))
        context.addPath(path)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fillPath()

        context.addPath(path)
        context.setStrokeColor(CGColor(gray: 0, alpha: 1))
        context.setLineWidth(max(1, size * 0.045))
        context.setLineJoin(.round)
        context.strokePath()

        guard let cgImage = context.makeImage() else { return nil }
        return CIImage(cgImage: cgImage)
    }

    private static func path(for shape: CursorShapeKind, in size: CGSize) -> CGPath {
        let path = CGMutablePath()
        let w = size.width
        let h = size.height

        switch shape {
        case .pointingHand:
            // A hand over a link is how a viewer knows the thing is a link. It used to be
            // drawn as the arrow, which made every hover look like nothing had changed.
            return hand(in: size, fingers: [
                // The one doing the pointing, and three curled beside it.
                CGRect(x: 0.36, y: 0.03, width: 0.16, height: 0.62),
                CGRect(x: 0.52, y: 0.36, width: 0.14, height: 0.32),
                CGRect(x: 0.66, y: 0.40, width: 0.13, height: 0.30),
                CGRect(x: 0.79, y: 0.45, width: 0.12, height: 0.27),
            ], palm: CGRect(x: 0.36, y: 0.52, width: 0.55, height: 0.41),
               thumb: CGRect(x: 0.13, y: 0.50, width: 0.32, height: 0.17), thumbTurn: 38)

        case .openHand:
            return hand(in: size, fingers: [
                CGRect(x: 0.24, y: 0.16, width: 0.13, height: 0.48),
                CGRect(x: 0.37, y: 0.07, width: 0.13, height: 0.55),
                CGRect(x: 0.50, y: 0.09, width: 0.13, height: 0.53),
                CGRect(x: 0.63, y: 0.18, width: 0.13, height: 0.46),
            ], palm: CGRect(x: 0.24, y: 0.50, width: 0.52, height: 0.43),
               thumb: CGRect(x: 0.04, y: 0.50, width: 0.30, height: 0.16), thumbTurn: 42)

        case .arrow:
            // The classic tilted arrow.
            path.move(to: CGPoint(x: w * 0.06, y: h * 0.04))
            path.addLine(to: CGPoint(x: w * 0.06, y: h * 0.78))
            path.addLine(to: CGPoint(x: w * 0.28, y: h * 0.60))
            path.addLine(to: CGPoint(x: w * 0.42, y: h * 0.92))
            path.addLine(to: CGPoint(x: w * 0.58, y: h * 0.85))
            path.addLine(to: CGPoint(x: w * 0.44, y: h * 0.54))
            path.addLine(to: CGPoint(x: w * 0.72, y: h * 0.52))
            path.closeSubpath()

        case .iBeam:
            // Every shape below is pieces that overlap, made into one outline. Stroking
            // the pieces as they are draws the outline of each, and the lines where they
            // cross show through the fill: an I-beam with a box drawn at each end of it.
            let stem = w * 0.1
            return united([
                CGPath(rect: CGRect(x: w * 0.5 - stem / 2, y: h * 0.12, width: stem, height: h * 0.76), transform: nil),
                CGPath(roundedRect: CGRect(x: w * 0.27, y: h * 0.1, width: w * 0.46, height: h * 0.07),
                       cornerWidth: h * 0.03, cornerHeight: h * 0.03, transform: nil),
                CGPath(roundedRect: CGRect(x: w * 0.27, y: h * 0.83, width: w * 0.46, height: h * 0.07),
                       cornerWidth: h * 0.03, cornerHeight: h * 0.03, transform: nil),
            ])

        case .crosshair:
            let thickness = w * 0.1
            return united([
                CGPath(rect: CGRect(x: w * 0.5 - thickness / 2, y: h * 0.5 - w * 0.4, width: thickness, height: w * 0.8),
                       transform: nil),
                CGPath(rect: CGRect(x: w * 0.1, y: h * 0.5 - thickness / 2, width: w * 0.8, height: thickness),
                       transform: nil),
            ])

        case .resizeHorizontal:
            return united([
                triangle(CGPoint(x: w * 0.04, y: h * 0.5), CGPoint(x: w * 0.3, y: h * 0.34), CGPoint(x: w * 0.3, y: h * 0.66)),
                triangle(CGPoint(x: w * 0.96, y: h * 0.5), CGPoint(x: w * 0.7, y: h * 0.34), CGPoint(x: w * 0.7, y: h * 0.66)),
                CGPath(rect: CGRect(x: w * 0.28, y: h * 0.46, width: w * 0.44, height: h * 0.08), transform: nil),
            ])

        case .resizeVertical:
            return united([
                triangle(CGPoint(x: w * 0.5, y: h * 0.06), CGPoint(x: w * 0.27, y: h * 0.3), CGPoint(x: w * 0.73, y: h * 0.3)),
                triangle(CGPoint(x: w * 0.5, y: h * 0.94), CGPoint(x: w * 0.27, y: h * 0.7), CGPoint(x: w * 0.73, y: h * 0.7)),
                CGPath(rect: CGRect(x: w * 0.44, y: h * 0.28, width: w * 0.12, height: h * 0.44), transform: nil),
            ])
        }
        return path
    }

    private static func united(_ pieces: [CGPath]) -> CGPath {
        guard var outline = pieces.first else { return CGMutablePath() }
        for piece in pieces.dropFirst() { outline = outline.union(piece) }
        return outline
    }

    private static func triangle(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGPath {
        let path = CGMutablePath()
        path.move(to: a)
        path.addLine(to: b)
        path.addLine(to: c)
        path.closeSubpath()
        return path
    }

    /// A hand, as one outline.
    ///
    /// Built from rounded rectangles — four fingers, a palm, a thumb turned outwards — and
    /// then made into a single shape, so the outline goes round the hand rather than round
    /// each finger. The rectangles are fractions of the drawing, which is what keeps the
    /// hand a hand at any size.
    private static func hand(in size: CGSize, fingers: [CGRect], palm: CGRect,
                             thumb: CGRect, thumbTurn: Double) -> CGPath {
        func scaled(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX * size.width, y: rect.minY * size.height,
                   width: rect.width * size.width, height: rect.height * size.height)
        }
        func rounded(_ rect: CGRect, radius: Double) -> CGPath {
            let rect = scaled(rect)
            let corner = min(radius * size.width, min(rect.width, rect.height) / 2)
            return CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)
        }

        var outline = rounded(palm, radius: 0.12)
        for finger in fingers {
            outline = outline.union(rounded(finger, radius: 0.08))
        }

        // Turned about its own middle, so the angle can be changed without the thumb
        // leaving the hand.
        let rect = scaled(thumb)
        var turn = CGAffineTransform(translationX: rect.midX, y: rect.midY)
            .rotated(by: thumbTurn * .pi / 180)
            .translatedBy(x: -rect.midX, y: -rect.midY)
        let corner = min(rect.width, rect.height) / 2
        if let turned = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: &turn)
            .copy() {
            outline = outline.union(turned)
        }
        return outline
    }
}

/// The pointer pictures a recording kept, opened once each.
///
/// Separate from `CursorArtwork`'s cache because the two are keyed on different things:
/// that one caches a *drawing* at a size, this caches a *file*. The size is applied as a
/// transform afterwards, so one read serves every size the preview and the exporter ask
/// for — and there are only ever a handful of files in a recording.
enum RecordedCursorArtwork {
    private static let cache = ArtworkCache<URL, CIImage>(capacity: 12)

    static func image(_ artwork: RecordedCursor) -> CIImage? {
        cache.value(for: artwork.url) { CIImage(contentsOf: artwork.url) }
    }

    /// Empties it, so a test can read one cold.
    static func clearCache() { cache.removeAll() }
}
