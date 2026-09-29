import AppKit
import CoreGraphics
import CoreImage
import CoreText
import Foundation
import TimelineKit

/// Text, arrows, boxes and the rest, drawn with Core Text and Core Graphics.
///
/// The one place any annotation is drawn: the preview and the export both come here, so
/// what the one shows is what the other writes.
///
/// **The bitmap can be bigger than the box.** A shadow falls outside what casts it, a
/// callout's tail points away from its bubble, and a thick line's rounded end sticks out
/// past the point it ends at. Each of those grows the bitmap by a margin on the side it
/// needs, and the bitmap is placed so that the box inside it lands exactly where the box
/// is — so turning, scaling and sliding, which all work about the box's centre, are
/// unaffected by how much hangs off it.
enum AnnotationArtwork {
    /// What the bitmap depends on, and not a thing more.
    ///
    /// The rectangle contributes its *size* only: where the label lands is an affine
    /// transform applied below, so an annotation dragged across the frame redraws nothing
    /// until it is also resized. Opacity is absent for the same reason — the renderer fades
    /// annotations with a colour matrix, so the fade at each end of an item costs lookups
    /// rather than layouts. The style is there whole, rather than field by field, so a
    /// setting added to it later is in the key without anybody remembering to put it there.
    private struct Key: Hashable {
        let kind: String
        let width: Int
        let height: Int
        let r: Double, g: Double, b: Double, a: Double
        let fontSize: Double
        let outputHeight: Double
        let style: AnnotationStyle
    }

    /// Enough for every annotation on screen at once, several times over. Bounded because
    /// dragging an annotation's handle walks through a new size on every mouse event, and a
    /// cache with no ceiling would keep all of them.
    private static let drawings = ArtworkCache<Key, CGImage>(capacity: 16)

    /// A kind, as a string that changes whenever the drawing would.
    private static func signature(_ kind: AnnotationItem.Kind) -> String {
        switch kind {
        case .rectangle: "rectangle"
        case .text(let string): "text:\(string)"
        case .arrow(let from, let to): "arrow:\(from.x),\(from.y),\(to.x),\(to.y)"
        // The path, not the file's contents: an annotation pointing at a picture that
        // changes under it is the same staleness `BackgroundCache` already accepts for a
        // wallpaper, and re-reading and decoding the file on every frame of an export is
        // the cost that buys freshness nobody asked for.
        case .image(let path): "image:\(path)"
        case .ellipse: "ellipse"
        case .line(let from, let to): "line:\(from.x),\(from.y),\(to.x),\(to.y)"
        case .highlight: "highlight"
        case .step(let number): "step:\(number)"
        // The tail before the words, so no words can be mistaken for a different tail.
        case .callout(let text, let tail): "callout:\(tail.x),\(tail.y):\(text)"
        }
    }

    /// Empties the cache, so a test can draw one cold.
    static func clearCache() { drawings.removeAll() }

    static func image(_ annotation: AnnotationLayer, in rect: CGRect, outputHeight: Double) -> CIImage? {
        let width = Int(rect.width.rounded())
        let height = Int(rect.height.rounded())
        guard width > 1, height > 1 else { return nil }

        let key = Key(kind: signature(annotation.kind),
                      width: width, height: height,
                      r: annotation.color.r, g: annotation.color.g,
                      b: annotation.color.b, a: annotation.color.a,
                      fontSize: annotation.fontSize,
                      outputHeight: outputHeight,
                      style: annotation.style)
        // Worked out from the same inputs as the key, so a cached bitmap and the margins
        // it is placed by can never disagree.
        let margins = margins(annotation, width: width, height: height, outputHeight: outputHeight)
        guard let cgImage = drawings.value(for: key, make: {
            draw(annotation, width: width, height: height, margins: margins, outputHeight: outputHeight)
        }) else { return nil }

        return CIImage(cgImage: cgImage)
            .transformed(by: CGAffineTransform(translationX: rect.minX - Double(margins.left),
                                               y: rect.minY - Double(margins.bottom)))
    }

    // MARK: - Measurements

    /// How far the bitmap reaches past the box on each side, in whole pixels. Top and
    /// bottom as seen on the picture.
    struct Margins: Equatable {
        var left = 0, bottom = 0, right = 0, top = 0

        mutating func grow(_ amount: Double) {
            let pixels = Int(ceil(max(0, amount)))
            left += pixels; bottom += pixels; right += pixels; top += pixels
        }

        /// Nothing hangs further off than this, whatever the numbers say: a bitmap is
        /// memory, and a tail pointing across a 4K frame is already a large one.
        mutating func limit(_ most: Int) {
            left = min(left, most); bottom = min(bottom, most); right = min(right, most); top = min(top, most)
        }
    }

    static func margins(_ annotation: AnnotationLayer, width: Int, height: Int, outputHeight: Double) -> Margins {
        var margins = Margins()
        let style = annotation.style
        let w = Double(width), h = Double(height)
        switch annotation.kind {
        case .arrow:
            let line = lineWidth(annotation.kind, outputHeight: outputHeight, thickness: style.thickness)
            // A head is as wide as it is long, near enough, and sits across the end.
            margins.grow(max(line / 2, arrowHead(lineWidth: line, outputHeight: outputHeight) * 0.45) + 1)
        case .line:
            margins.grow(lineWidth(annotation.kind, outputHeight: outputHeight, thickness: style.thickness) / 2 + 1)
        case .callout(_, let tail):
            // The tip, counted from the box's top-left like the model counts it.
            let x = tail.x * w, y = tail.y * h
            margins.left = Int(ceil(max(0, -x)))
            margins.right = Int(ceil(max(0, x - w)))
            margins.top = Int(ceil(max(0, -y)))
            margins.bottom = Int(ceil(max(0, y - h)))
            margins.grow(lineWidth(annotation.kind, outputHeight: outputHeight, thickness: style.thickness) + 1)
        case .text where style.outlinesText:
            margins.grow(max(8, outputHeight * annotation.fontSize) * outlineShare + 1)
        default:
            break
        }
        if style.hasShadow {
            margins.grow(shadowBlur(outputHeight) * 2 + shadowDrop(outputHeight))
        }
        margins.limit(4_096)
        return margins
    }

    /// The width of an outline or a line at the standard thickness, times `thickness`.
    ///
    /// The standards are the numbers every box and arrow was drawn with before thickness
    /// could be set, so 1 draws what it always drew.
    static func lineWidth(_ kind: AnnotationItem.Kind, outputHeight: Double, thickness: Double) -> Double {
        let standard: Double = switch kind {
        case .arrow, .line: max(2, outputHeight * 0.006)
        case .callout: max(1.5, outputHeight * 0.0035)
        default: max(2, outputHeight * 0.005)
        }
        return standard * thickness
    }

    /// How long an arrow's head is. Never less than it always was, and never so small next
    /// to a thick line that the line hides it.
    static func arrowHead(lineWidth: Double, outputHeight: Double) -> Double {
        max(max(8, outputHeight * 0.02), lineWidth * 3.3)
    }

    static func shadowBlur(_ outputHeight: Double) -> Double { max(3, outputHeight * 0.012) }
    static func shadowDrop(_ outputHeight: Double) -> Double { max(1, outputHeight * 0.004) }

    /// A highlight's strength: a marker pen, which the words under it must show through.
    static let highlightStrength = 0.35
    /// A translucent fill's strength inside its own outline.
    static let translucentFill = 0.3
    /// How wide the ring round outlined letters is, as a share of the type size. Half of
    /// it is outside the letter.
    static let outlineShare = 0.22

    // MARK: - Drawing

    private static func draw(_ annotation: AnnotationLayer,
                             width: Int,
                             height: Int,
                             margins: Margins,
                             outputHeight: Double) -> CGImage? {
        guard let context = CGContext(data: nil,
                                      width: width + margins.left + margins.right,
                                      height: height + margins.bottom + margins.top,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        let bounds = CGRect(x: Double(margins.left), y: Double(margins.bottom),
                            width: Double(width), height: Double(height))
        // Everything is drawn into one layer and the shadow cast by the whole, so an arrow's
        // head and its shaft cast one shadow rather than two that darken where they cross.
        if annotation.style.hasShadow {
            context.setShadow(offset: CGSize(width: 0, height: -shadowDrop(outputHeight)),
                              blur: shadowBlur(outputHeight),
                              color: CGColor(gray: 0, alpha: 0.5))
            context.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        let drawn = drawContent(annotation, in: bounds, context: context, outputHeight: outputHeight)
        if annotation.style.hasShadow {
            context.endTransparencyLayer()
        }
        guard drawn else { return nil }
        return context.makeImage()
    }

    /// Draws the annotation inside `bounds`, or reports that there is nothing to draw.
    private static func drawContent(_ annotation: AnnotationLayer,
                                    in bounds: CGRect,
                                    context: CGContext,
                                    outputHeight: Double) -> Bool {
        let style = annotation.style
        let colour = cgColour(annotation.color)

        switch annotation.kind {
        case .rectangle, .ellipse:
            let isEllipse = annotation.kind == .ellipse
            let width = lineWidth(annotation.kind, outputHeight: outputHeight, thickness: style.thickness)
            // Inset by half the line, so the whole of it is inside the box. It used to be
            // inset by two pixels whatever the width, which cut the outer part of a line off
            // at the bitmap's edge — a third of it at 4K.
            let inner = bounds.insetBy(dx: min(width / 2, bounds.width / 2 - 0.5),
                                       dy: min(width / 2, bounds.height / 2 - 0.5))
            func shape(_ rect: CGRect) -> CGPath {
                isEllipse ? CGPath(ellipseIn: rect, transform: nil) : CGPath(rect: rect, transform: nil)
            }
            switch style.fill {
            case .solid:
                // The fill is the whole shape: an outline on top of it in the same colour
                // would only show where a see-through colour doubled up.
                context.addPath(shape(bounds))
                context.setFillColor(colour)
                context.fillPath()
                return true
            case .translucent:
                let inside = inner.insetBy(dx: min(width / 2, inner.width / 2), dy: min(width / 2, inner.height / 2))
                context.addPath(shape(inside))
                context.setFillColor(cgColour(annotation.color, alpha: annotation.color.a * translucentFill))
                context.fillPath()
            case .none:
                break
            }
            context.addPath(shape(inner))
            context.setStrokeColor(colour)
            context.setLineWidth(width)
            context.strokePath()

        case .highlight:
            let radius = min(min(bounds.width, bounds.height) * 0.25, max(2, outputHeight * 0.006))
            context.addPath(CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.setFillColor(cgColour(annotation.color, alpha: annotation.color.a * highlightStrength))
            context.fillPath()

        case .arrow(let from, let to), .line(let from, let to):
            let isArrow = annotation.kind.name == .arrow
            let start = point(from, in: bounds)
            let end = point(to, in: bounds)
            let width = lineWidth(annotation.kind, outputHeight: outputHeight, thickness: style.thickness)
            // Drawn opaque inside a layer that carries the colour's alpha, so a see-through
            // arrow is one even tint rather than darker where the shaft runs into the head.
            context.saveGState()
            context.setAlpha(annotation.color.a)
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            let solid = cgColour(annotation.color, alpha: 1)
            context.setStrokeColor(solid)
            context.setFillColor(solid)
            context.setLineWidth(width)
            context.setLineCap(.round)
            let angle = atan2(end.y - start.y, end.x - start.x)
            let head = arrowHead(lineWidth: width, outputHeight: outputHeight)
            // The shaft stops inside the head rather than at the tip, where its round end
            // used to poke out past the point.
            let back = isArrow ? min(head * 0.5, hypot(end.x - start.x, end.y - start.y)) : 0
            context.move(to: start)
            context.addLine(to: CGPoint(x: end.x - back * cos(angle), y: end.y - back * sin(angle)))
            context.strokePath()
            if isArrow {
                context.move(to: end)
                context.addLine(to: CGPoint(x: end.x - head * cos(angle - .pi / 7),
                                            y: end.y - head * sin(angle - .pi / 7)))
                context.addLine(to: CGPoint(x: end.x - head * cos(angle + .pi / 7),
                                            y: end.y - head * sin(angle + .pi / 7)))
                context.closePath()
                context.fillPath()
            }
            context.endTransparencyLayer()
            context.restoreGState()

        case .step(let number):
            drawStep(number, colour: annotation.color, in: bounds, context: context)

        case .text(let string):
            drawLabel(string, annotation, in: bounds, context: context, outputHeight: outputHeight)

        case .callout(let string, let tail):
            drawCallout(string, tail: tail, annotation, in: bounds, context: context, outputHeight: outputHeight)

        case .image(let path):
            guard let image = NSImage(contentsOfFile: path),
                  let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            else { return false }
            // Fitted inside its box rather than stretched to it, so dragging a corner can
            // never squash a logo: the box is where the picture may go, and the picture
            // keeps its own shape inside it.
            let shape = CGFloat(cgImage.width) / CGFloat(max(1, cgImage.height))
            var fitted = bounds
            if bounds.width / max(1, bounds.height) > shape {
                fitted.size.width = bounds.height * shape
                fitted.origin.x = bounds.midX - fitted.width / 2
            } else {
                fitted.size.height = bounds.width / shape
                fitted.origin.y = bounds.midY - fitted.height / 2
            }
            context.interpolationQuality = .high
            context.draw(cgImage, in: fitted)
        }
        return true
    }

    // MARK: - Steps

    /// A round badge with a number centred in it — centred on the ink of the figures, not on
    /// the line they sit on, which would put every number visibly low.
    private static func drawStep(_ number: Int, colour: ColorValue, in bounds: CGRect, context: CGContext) {
        let diameter = min(bounds.width, bounds.height)
        let circle = CGRect(x: bounds.midX - diameter / 2, y: bounds.midY - diameter / 2,
                            width: diameter, height: diameter)
        context.addPath(CGPath(ellipseIn: circle, transform: nil))
        context.setFillColor(cgColour(colour))
        context.fillPath()

        let figures = String(number)
        let share: Double = switch figures.count {
        case 1: 0.56
        case 2: 0.48
        default: 0.38
        }
        let ink = AnnotationStyle.contrasting(colour)
        let font = NSFont.monospacedDigitSystemFont(ofSize: max(4, diameter * share), weight: .bold)
        let text = NSAttributedString(string: figures, attributes: [
            .font: font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): cgColour(ink, alpha: colour.a),
        ])
        let line = CTLineCreateWithAttributedString(text)
        let glyphs = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        context.textPosition = CGPoint(x: circle.midX - glyphs.midX, y: circle.midY - glyphs.midY)
        CTLineDraw(line, context)
    }

    // MARK: - Words

    /// The type a label or callout is set in: the family its style names, at the nearest
    /// weight the family has, or the system's own when there is no family or this Mac does
    /// not have it. `AnnotationFit` measures with this too, so a box fits the words drawn.
    static func font(size: Double, weight: AnnotationStyle.Weight, family: String = "") -> NSFont {
        let weight: NSFont.Weight = switch weight {
        case .regular: .regular
        case .semibold: .semibold
        case .bold: .bold
        }
        return FontFamilies.font(family: family, size: size, weight: weight)
            ?? NSFont.systemFont(ofSize: size, weight: weight)
    }

    static func words(_ string: String, font: NSFont, colour: ColorValue,
                              alignment: AnnotationStyle.Alignment) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        // Left is the language's own start, which is what every label was set with before
        // alignment could be chosen — and what a label in Arabic means by "left".
        paragraph.alignment = switch alignment {
        case .left: .natural
        case .center: .center
        case .right: .right
        }
        return NSAttributedString(string: string, attributes: [
            .font: font,
            .foregroundColor: NSColor(cgColor: cgColour(colour)) ?? .white,
            .paragraphStyle: paragraph,
        ])
    }

    /// How much room the words take when wrapped to `width`.
    static func measured(_ text: NSAttributedString, width: Double) -> CGSize {
        let used = text.boundingRect(with: CGSize(width: max(1, width), height: .greatestFiniteMagnitude),
                                     options: [.usesLineFragmentOrigin])
        return CGSize(width: ceil(used.width), height: ceil(used.height))
    }

    /// The words, with a ring round each letter first when there is one.
    private static func draw(_ text: NSAttributedString, outline: ColorValue?, in rect: CGRect,
                             fontSize: Double, context: CGContext) {
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        if let outline {
            // Stroked alone, underneath, then the letters filled on top: a ring drawn over
            // them would eat half of every stroke of every letter.
            let ringed = NSMutableAttributedString(attributedString: text)
            ringed.addAttributes([.strokeColor: NSColor(cgColor: cgColour(outline)) ?? .black,
                                  .strokeWidth: outlineShare * 100],
                                 range: NSRange(location: 0, length: ringed.length))
            context.setLineJoin(.round)
            ringed.draw(with: rect, options: [.usesLineFragmentOrigin])
        }
        text.draw(with: rect, options: [.usesLineFragmentOrigin])
        NSGraphicsContext.restoreGraphicsState()
    }

    /// The ring's colour: black round light letters, white round dark ones.
    private static func ring(for ink: ColorValue, style: AnnotationStyle) -> ColorValue? {
        guard style.outlinesText else { return nil }
        var ring = AnnotationStyle.contrasting(ink)
        ring.a = ink.a
        return ring
    }

    /// A label: the words where the box says, on a plate when it has one.
    private static func drawLabel(_ string: String, _ annotation: AnnotationLayer, in bounds: CGRect,
                                  context: CGContext, outputHeight: Double) {
        let style = annotation.style
        // Font size is a fraction of the output height, so a label keeps its weight at any
        // export size.
        let size = max(8, outputHeight * annotation.fontSize)
        let ink = style.textColour(for: annotation.color)
        let text = words(string, font: font(size: size, weight: style.weight, family: style.fontFamily),
                         colour: ink, alignment: style.alignment)
        guard let plate = style.plate(for: annotation.color) else {
            // Exactly what a label drew before it could have a plate: laid out from the top
            // of its box.
            draw(text, outline: ring(for: ink, style: style), in: bounds, fontSize: size, context: context)
            return
        }

        // The plate hugs the words rather than filling the box: a box drawn roomy should
        // not become a slab. The words move in by the plate's padding so the plate fits
        // inside the box — nothing of a label is ever drawn outside what was drawn for it.
        let padX = min(size * 0.35, bounds.width / 4)
        let padY = min(size * 0.2, bounds.height / 4)
        let layout = bounds.insetBy(dx: padX, dy: padY)
        let used = measured(text, width: layout.width)
        let textWidth = min(used.width, layout.width)
        let left: Double = switch style.alignment {
        case .left: layout.minX
        case .center: layout.midX - textWidth / 2
        case .right: layout.maxX - textWidth
        }
        let plateRect = CGRect(x: left - padX, y: layout.maxY - used.height - padY,
                               width: textWidth + padX * 2, height: used.height + padY * 2)
            .intersection(bounds)
        if !plateRect.isNull, plateRect.width > 0, plateRect.height > 0 {
            let radius = min(size * 0.3, plateRect.height / 2, plateRect.width / 2)
            context.addPath(CGPath(roundedRect: plateRect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.setFillColor(cgColour(plate))
            context.fillPath()
        }
        draw(text, outline: ring(for: ink, style: style),
             in: CGRect(x: layout.minX, y: layout.maxY - used.height, width: layout.width, height: used.height),
             fontSize: size, context: context)
    }

    /// Words in a rounded bubble with a tail out to a point.
    private static func drawCallout(_ string: String, tail: CGPoint, _ annotation: AnnotationLayer,
                                    in bounds: CGRect, context: CGContext, outputHeight: Double) {
        let style = annotation.style
        let size = max(8, outputHeight * annotation.fontSize)
        let plate = style.plate(for: annotation.color)
        // Drawn as an outline in the annotation's colour when it has no plate, and the
        // outline is as thick as the thickness says.
        let stroke = plate == nil
            ? lineWidth(annotation.kind, outputHeight: outputHeight, thickness: style.thickness) : 0
        let bubble = bounds.insetBy(dx: min(stroke / 2, bounds.width / 4), dy: min(stroke / 2, bounds.height / 4))
        let radius = min(size * 0.55, bubble.height / 2, bubble.width / 2)
        var shape = CGPath(roundedRect: bubble, cornerWidth: radius, cornerHeight: radius, transform: nil)
        if let pointer = tailPath(from: bubble, radius: radius, to: point(tail, in: bounds), size: size) {
            shape = shape.union(pointer)
        }
        context.addPath(shape)
        if let plate {
            context.setFillColor(cgColour(plate))
            context.fillPath()
        } else {
            context.setStrokeColor(cgColour(annotation.color))
            context.setLineWidth(stroke)
            context.setLineJoin(.round)
            context.strokePath()
        }

        let ink = style.textColour(for: annotation.color)
        let text = words(string, font: font(size: size, weight: style.weight, family: style.fontFamily),
                         colour: ink, alignment: style.alignment)
        let inner = bubble.insetBy(dx: min(size * 0.5, bubble.width / 4), dy: min(size * 0.3, bubble.height / 4))
        let used = measured(text, width: inner.width)
        // In the middle of the bubble while the words fit, from its top once they do not —
        // so a long callout runs off the bottom rather than off both ends.
        let top = used.height < inner.height ? inner.midY + used.height / 2 : inner.maxY
        draw(text, outline: ring(for: ink, style: style),
             in: CGRect(x: inner.minX, y: top - used.height, width: inner.width, height: used.height),
             fontSize: size, context: context)
    }

    /// The pointer from a bubble's nearest side to `tip`, or `nil` when the tip is inside
    /// the bubble and there is nothing to point across.
    ///
    /// The base sits on the side facing the tip, as near to straight under it as the
    /// rounded corners allow, and starts a little inside the bubble so the two join
    /// without a seam once they are made one shape.
    static func tailPath(from bubble: CGRect, radius: Double, to tip: CGPoint, size: Double) -> CGPath? {
        guard !bubble.insetBy(dx: -1, dy: -1).contains(tip) else { return nil }
        let across = (tip.x - bubble.midX) / max(1, bubble.width / 2)
        let down = (tip.y - bubble.midY) / max(1, bubble.height / 2)
        let path = CGMutablePath()
        if abs(down) >= abs(across) {
            let half = max(2, min(bubble.width * 0.22, bubble.height * 0.4, size * 0.8))
            let edge = down > 0 ? bubble.maxY : bubble.minY
            let depth = (down > 0 ? -1.0 : 1.0) * min(radius, bubble.height / 2)
            let low = bubble.minX + radius + half, high = bubble.maxX - radius - half
            let x = low <= high ? min(high, max(low, tip.x)) : bubble.midX
            path.move(to: CGPoint(x: x - half, y: edge + depth))
            path.addLine(to: tip)
            path.addLine(to: CGPoint(x: x + half, y: edge + depth))
        } else {
            let half = max(2, min(bubble.height * 0.22, bubble.width * 0.4, size * 0.8))
            let edge = across > 0 ? bubble.maxX : bubble.minX
            let depth = (across > 0 ? -1.0 : 1.0) * min(radius, bubble.width / 2)
            let low = bubble.minY + radius + half, high = bubble.maxY - radius - half
            let y = low <= high ? min(high, max(low, tip.y)) : bubble.midY
            path.move(to: CGPoint(x: edge + depth, y: y - half))
            path.addLine(to: tip)
            path.addLine(to: CGPoint(x: edge + depth, y: y + half))
        }
        path.closeSubpath()
        return path
    }

    // MARK: - Small things

    /// A point normalised to the box, top-left origin like the model, in the bitmap's
    /// bottom-left space.
    private static func point(_ local: CGPoint, in bounds: CGRect) -> CGPoint {
        CGPoint(x: bounds.minX + local.x * bounds.width, y: bounds.minY + (1 - local.y) * bounds.height)
    }

    private static func cgColour(_ colour: ColorValue, alpha: Double? = nil) -> CGColor {
        CGColor(red: colour.r, green: colour.g, blue: colour.b, alpha: alpha ?? colour.a)
    }
}
