import AppKit
import CoreGraphics
import CoreImage
import Foundation
import os
import TimelineKit

/// The pointers Klik draws.
///
/// Its own artwork, on purpose: the system cursors are Apple's, and a video file that
/// bakes them in is a question nobody wants to answer. These are the familiar silhouettes
/// — a tilted arrow with a white outline, an I-beam, a hand — which is what a viewer
/// needs to follow a demo.
///
/// Each shape is drawn once per size and kept: a pointer is redrawn on every frame of
/// every preview, and a `CGContext` per frame is a cost that shows up immediately.
enum CursorArtwork {
    private static let cache = OSAllocatedUnfairLock(initialState: [Key: CIImage]())

    private struct Key: Hashable {
        let shape: CursorShapeKind
        /// Rounded, so a spring animating a scale does not miss the cache every frame.
        let size: Int
    }

    static func image(_ shape: CursorShapeKind, size: Double) -> CIImage? {
        let key = Key(shape: shape, size: Int(size.rounded()))
        if let cached = cache.withLock({ $0[key] }) { return cached }

        guard let image = draw(shape, size: Double(key.size)) else { return nil }
        cache.withLock { $0[key] = image }
        return image
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
        case .arrow, .openHand, .pointingHand:
            // The classic tilted arrow. The hand shapes fall back to it rather than to a
            // silhouette that would read as a different pointer at video size.
            path.move(to: CGPoint(x: w * 0.06, y: h * 0.04))
            path.addLine(to: CGPoint(x: w * 0.06, y: h * 0.78))
            path.addLine(to: CGPoint(x: w * 0.28, y: h * 0.60))
            path.addLine(to: CGPoint(x: w * 0.42, y: h * 0.92))
            path.addLine(to: CGPoint(x: w * 0.58, y: h * 0.85))
            path.addLine(to: CGPoint(x: w * 0.44, y: h * 0.54))
            path.addLine(to: CGPoint(x: w * 0.72, y: h * 0.52))
            path.closeSubpath()

        case .iBeam:
            let stem = w * 0.12
            path.addRect(CGRect(x: w * 0.5 - stem / 2, y: h * 0.1, width: stem, height: h * 0.8))
            path.addRect(CGRect(x: w * 0.25, y: h * 0.1, width: w * 0.5, height: h * 0.08))
            path.addRect(CGRect(x: w * 0.25, y: h * 0.82, width: w * 0.5, height: h * 0.08))

        case .crosshair:
            let thickness = w * 0.1
            path.addRect(CGRect(x: w * 0.5 - thickness / 2, y: h * 0.12, width: thickness, height: h * 0.76))
            path.addRect(CGRect(x: w * 0.12, y: h * 0.5 - thickness / 2, width: w * 0.76, height: thickness))

        case .resizeHorizontal:
            path.move(to: CGPoint(x: w * 0.05, y: h * 0.5))
            path.addLine(to: CGPoint(x: w * 0.3, y: h * 0.3))
            path.addLine(to: CGPoint(x: w * 0.3, y: h * 0.7))
            path.closeSubpath()
            path.move(to: CGPoint(x: w * 0.95, y: h * 0.5))
            path.addLine(to: CGPoint(x: w * 0.7, y: h * 0.3))
            path.addLine(to: CGPoint(x: w * 0.7, y: h * 0.7))
            path.closeSubpath()
            path.addRect(CGRect(x: w * 0.28, y: h * 0.46, width: w * 0.44, height: h * 0.08))

        case .resizeVertical:
            path.move(to: CGPoint(x: w * 0.5, y: h * 0.05))
            path.addLine(to: CGPoint(x: w * 0.3, y: h * 0.3))
            path.addLine(to: CGPoint(x: w * 0.7, y: h * 0.3))
            path.closeSubpath()
            path.move(to: CGPoint(x: w * 0.5, y: h * 0.95))
            path.addLine(to: CGPoint(x: w * 0.3, y: h * 0.7))
            path.addLine(to: CGPoint(x: w * 0.7, y: h * 0.7))
            path.closeSubpath()
            path.addRect(CGRect(x: w * 0.44, y: h * 0.28, width: w * 0.12, height: h * 0.44))
        }
        return path
    }
}

/// Text, arrows and boxes, drawn with Core Text and Core Graphics.
enum AnnotationArtwork {
    static func image(_ annotation: AnnotationLayer, in rect: CGRect, outputHeight: Double) -> CIImage? {
        let width = Int(rect.width.rounded())
        let height = Int(rect.height.rounded())
        guard width > 1, height > 1,
              let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        let colour = CGColor(red: annotation.color.r, green: annotation.color.g,
                             blue: annotation.color.b, alpha: annotation.color.a)
        let bounds = CGRect(x: 0, y: 0, width: Double(width), height: Double(height))

        switch annotation.kind {
        case .rectangle:
            context.setStrokeColor(colour)
            context.setLineWidth(max(2, outputHeight * 0.005))
            context.stroke(bounds.insetBy(dx: 2, dy: 2))

        case .text(let string):
            // Font size is a fraction of the output height, so a label keeps its weight
            // at any export size.
            let size = max(8, outputHeight * annotation.fontSize)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: size, weight: .semibold),
                .foregroundColor: NSColor(cgColor: colour) ?? .white,
            ]
            let text = NSAttributedString(string: string, attributes: attributes)
            let graphics = NSGraphicsContext(cgContext: context, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            text.draw(with: bounds, options: [.usesLineFragmentOrigin])
            NSGraphicsContext.restoreGraphicsState()

        case .arrow(let from, let to):
            let start = CGPoint(x: from.x * bounds.width, y: (1 - from.y) * bounds.height)
            let end = CGPoint(x: to.x * bounds.width, y: (1 - to.y) * bounds.height)
            context.setStrokeColor(colour)
            context.setFillColor(colour)
            context.setLineWidth(max(2, outputHeight * 0.006))
            context.setLineCap(.round)
            context.move(to: start)
            context.addLine(to: end)
            context.strokePath()

            let angle = atan2(end.y - start.y, end.x - start.x)
            let head = max(8, outputHeight * 0.02)
            context.move(to: end)
            context.addLine(to: CGPoint(x: end.x - head * cos(angle - .pi / 7),
                                        y: end.y - head * sin(angle - .pi / 7)))
            context.addLine(to: CGPoint(x: end.x - head * cos(angle + .pi / 7),
                                        y: end.y - head * sin(angle + .pi / 7)))
            context.closePath()
            context.fillPath()

        case .image(let path):
            guard let image = NSImage(contentsOfFile: path),
                  let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            else { return nil }
            context.draw(cgImage, in: bounds)
        }

        guard let cgImage = context.makeImage() else { return nil }
        return CIImage(cgImage: cgImage)
            .transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
    }
}
