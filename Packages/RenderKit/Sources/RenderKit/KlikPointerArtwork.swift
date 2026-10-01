import CoreGraphics
import CoreImage
import Foundation

/// Klik's own classic pointer — a crisp arrow and a pointing hand — drawn from the vector
/// artwork Klik keeps, at the size the frame asks for.
///
/// Only the arrow and the hand are Klik's; for the pointer's other shapes the style uses the
/// classic system artwork, which is drawn in the same black-and-white manner.
enum KlikPointerArtwork {
    /// One drawing: what is filled white, what is inked black, on a canvas of `box` points,
    /// and the point it points with.
    // Unchecked because `CGPath` is not marked `Sendable`; these are built once, never
    // changed, and only read — drawing a path from several threads is safe.
    private struct Artwork: @unchecked Sendable {
        let box: CGSize
        /// Each piece filled on its own, in order, as the artwork stacks them: in one path,
        /// two pieces that overlap with opposite windings cancel, and the arrow's tail came
        /// out cut off from its body by a white sliver.
        let white: [CGPath]
        let black: [CGPath]
        /// Lines drawn in black at a width of their own.
        let strokes: CGPath?
        let strokeWidth: Double
        let hotspot: CGPoint
    }

    /// The classic arrow, on a 28-point canvas: a white arrow and tail, a black arrow
    /// inside them, and the black tail turned to lie along it.
    private static let arrow: Artwork = {
        func polygon(_ points: [CGPoint]) -> CGPath {
            let path = CGMutablePath()
            path.addLines(between: points)
            path.closeSubpath()
            return path
        }
        let white = [
            polygon([CGPoint(x: 8.2, y: 20.9), CGPoint(x: 8.2, y: 4.9), CGPoint(x: 19.8, y: 16.5),
                     CGPoint(x: 13, y: 16.5), CGPoint(x: 12.6, y: 16.6)]),
            polygon([CGPoint(x: 17.3, y: 21.6), CGPoint(x: 13.7, y: 23.1), CGPoint(x: 9, y: 12),
                     CGPoint(x: 12.7, y: 10.5)]),
        ]
        let tail = CGMutablePath()
        tail.addRect(CGRect(x: 12.5, y: 13.6, width: 2, height: 8),
                     transform: CGAffineTransform(a: 0.9221, b: -0.3871, c: 0.3871, d: 0.9221, tx: -5.7605, ty: 6.5909))
        let black = [
            tail,
            polygon([CGPoint(x: 9.2, y: 7.3), CGPoint(x: 9.2, y: 18.5), CGPoint(x: 12.2, y: 15.6),
                     CGPoint(x: 12.6, y: 15.5), CGPoint(x: 17.4, y: 15.5)]),
        ]
        // The tip of the black arrow, as the system places its own.
        return Artwork(box: CGSize(width: 28, height: 28), white: white, black: black,
                       strokes: nil, strokeWidth: 0, hotspot: CGPoint(x: 9.2, y: 7.3))
    }()

    /// The pointing hand, on a 32-point canvas: white, outlined in black, with three
    /// lines across the fingers.
    private static let hand: Artwork = {
        let outline = SVGPath.parse("""
            M11.3,20.4c-0.3-0.4-0.6-1.1-1.2-2c-0.3-0.5-1.2-1.5-1.5-1.9c-0.2-0.4-0.2-0.6-0.1-1c0.1-0.6,0.7-1.1,1.4-1.1\
            c0.5,0,1,0.4,1.4,0.7c0.2,0.2,0.5,0.6,0.7,0.8c0.2,0.2,0.2,0.3,0.4,0.5c0.2,0.3,0.3,0.5,0.2,0.1\
            c-0.1-0.5-0.2-1.3-0.4-2.1c-0.1-0.6-0.2-0.7-0.3-1.1c-0.1-0.5-0.2-0.8-0.3-1.3c-0.1-0.3-0.2-1.1-0.3-1.5\
            c-0.1-0.5-0.1-1.4,0.3-1.8c0.3-0.3,0.9-0.4,1.3-0.2c0.5,0.3,0.8,1,0.9,1.3c0.2,0.5,0.4,1.2,0.5,2\
            c0.2,1,0.5,2.5,0.5,2.8c0-0.4-0.1-1.1,0-1.5c0.1-0.3,0.3-0.7,0.7-0.8c0.3-0.1,0.6-0.1,0.9-0.1\
            c0.3,0.1,0.6,0.3,0.8,0.5c0.4,0.6,0.4,1.9,0.4,1.8c0.1-0.4,0.1-1.2,0.3-1.6c0.1-0.2,0.5-0.4,0.7-0.5\
            c0.3-0.1,0.7-0.1,1,0c0.2,0,0.6,0.3,0.7,0.5c0.2,0.3,0.3,1.3,0.4,1.7c0,0.1,0.1-0.4,0.3-0.7\
            c0.4-0.6,1.8-0.8,1.9,0.6c0,0.7,0,0.6,0,1.1c0,0.5,0,0.8,0,1.2c0,0.4-0.1,1.3-0.2,1.7\
            c-0.1,0.3-0.4,1-0.7,1.4c0,0-1.1,1.2-1.2,1.8c-0.1,0.6-0.1,0.6-0.1,1c0,0.4,0.1,0.9,0.1,0.9\
            s-0.8,0.1-1.2,0c-0.4-0.1-0.9-0.8-1-1.1c-0.2-0.3-0.5-0.3-0.7,0c-0.2,0.4-0.7,1.1-1.1,1.1\
            c-0.7,0.1-2.1,0-3.1,0c0,0,0.2-1-0.2-1.4c-0.3-0.3-0.8-0.8-1.1-1.1L11.3,20.4z
            """)
        let lines = CGMutablePath()
        lines.move(to: CGPoint(x: 19.6, y: 20.7)); lines.addLine(to: CGPoint(x: 19.6, y: 17.3))
        lines.move(to: CGPoint(x: 17.6, y: 20.7)); lines.addLine(to: CGPoint(x: 17.5, y: 17.3))
        lines.move(to: CGPoint(x: 15.6, y: 17.3)); lines.addLine(to: CGPoint(x: 15.6, y: 20.7))
        let strokes = CGMutablePath()
        strokes.addPath(outline)
        strokes.addPath(lines)
        // The top of the pointing finger, across its middle.
        return Artwork(box: CGSize(width: 32, height: 32), white: [outline], black: [],
                       strokes: strokes, strokeWidth: 0.75, hotspot: CGPoint(x: 12.55, y: 8.0))
    }()

    /// Whether this style has a drawing of its own for the shape; the rest are the
    /// classic system artwork's.
    static func draws(_ shape: CursorShapeKind) -> Bool {
        shape == .arrow || shape == .pointingHand
    }

    /// The arrow or the hand at a pointer size in output pixels, with a soft shadow, or
    /// `nil` for a shape this artwork does not have.
    static func drawing(_ shape: CursorShapeKind, size: Double) -> PointerStyleArtwork.Drawing? {
        let artwork: Artwork
        switch shape {
        case .arrow: artwork = arrow
        case .pointingHand: artwork = hand
        default: return nil
        }
        let unit = size / SystemPointerArtwork.pointsAcross
        let blur = 2 * unit
        let margin = blur + unit
        // Only what is drawn, not the whole canvas: most of it is empty, and a drawing that
        // kept it would sit in the corner of its own picture.
        var content = (artwork.white + artwork.black).reduce(CGRect.null) { $0.union($1.boundingBoxOfPath) }
        if let strokes = artwork.strokes {
            content = content.union(strokes.boundingBoxOfPath.insetBy(dx: -artwork.strokeWidth, dy: -artwork.strokeWidth))
        }
        content = content.intersection(CGRect(origin: .zero, size: artwork.box))
        let width = Int((content.width * unit + margin * 2).rounded(.up))
        let height = Int((content.height * unit + margin * 2).rounded(.up))
        guard width > 1, height > 1,
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // The artwork is described with y running down, as SVG is.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: margin, y: margin)
        context.scaleBy(x: unit, y: unit)
        context.translateBy(x: -content.minX, y: -content.minY)
        context.setShouldAntialias(true)

        context.setShadow(offset: CGSize(width: 0, height: -unit), blur: blur, color: CGColor(gray: 0, alpha: 0.45))
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        for piece in artwork.white {
            context.addPath(piece)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fillPath()
        }
        for piece in artwork.black {
            context.addPath(piece)
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fillPath()
        }
        if let strokes = artwork.strokes {
            context.addPath(strokes)
            context.setStrokeColor(CGColor(gray: 0, alpha: 1))
            context.setLineWidth(artwork.strokeWidth)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.strokePath()
        }
        context.endTransparencyLayer()

        guard let image = context.makeImage() else { return nil }
        let point = CGPoint(x: margin + (artwork.hotspot.x - content.minX) * unit,
                            y: margin + (artwork.hotspot.y - content.minY) * unit)
        return PointerStyleArtwork.Drawing(image: CIImage(cgImage: image),
                                           hotspot: CGPoint(x: point.x / Double(width),
                                                            y: point.y / Double(height)))
    }
}

/// Just enough of SVG's path language for the artwork above: moves, lines, curves and
/// their smooth shorthand, absolute and relative, and closing.
enum SVGPath {
    static func parse(_ data: String) -> CGPath {
        let path = CGMutablePath()
        var tokens = tokenize(data)[...]
        var current = CGPoint.zero
        var start = CGPoint.zero
        var lastControl: CGPoint?
        var command: Character = "M"

        func number() -> Double? {
            guard case .number(let value)? = tokens.first else { return nil }
            tokens.removeFirst()
            return value
        }
        func point(relative: Bool) -> CGPoint? {
            guard let x = number(), let y = number() else { return nil }
            return relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
        }

        while let token = tokens.first {
            if case .command(let letter) = token {
                command = letter
                tokens.removeFirst()
            }
            let relative = command.isLowercase
            switch command.uppercased() {
            case "M":
                guard let to = point(relative: relative) else { return path }
                path.move(to: to)
                current = to; start = to; lastControl = nil
                // Coordinates after a move are lines.
                command = relative ? "l" : "L"
            case "L":
                guard let to = point(relative: relative) else { return path }
                path.addLine(to: to)
                current = to; lastControl = nil
            case "H":
                guard let x = number() else { return path }
                current = CGPoint(x: relative ? current.x + x : x, y: current.y)
                path.addLine(to: current); lastControl = nil
            case "V":
                guard let y = number() else { return path }
                current = CGPoint(x: current.x, y: relative ? current.y + y : y)
                path.addLine(to: current); lastControl = nil
            case "C":
                guard let c1 = point(relative: relative), let c2 = point(relative: relative),
                      let to = point(relative: relative) else { return path }
                path.addCurve(to: to, control1: c1, control2: c2)
                current = to; lastControl = c2
            case "S":
                // The first control mirrors the last curve's second one.
                let c1 = lastControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                guard let c2 = point(relative: relative), let to = point(relative: relative) else { return path }
                path.addCurve(to: to, control1: c1, control2: c2)
                current = to; lastControl = c2
            case "Z":
                path.closeSubpath()
                current = start; lastControl = nil
                if case .number? = tokens.first { command = "L" }
            default:
                tokens.removeFirst()
            }
        }
        return path
    }

    private enum Token {
        case command(Character)
        case number(Double)
    }

    private static func tokenize(_ data: String) -> [Token] {
        var tokens: [Token] = []
        var buffer = ""
        func flush() {
            if let value = Double(buffer) { tokens.append(.number(value)) }
            buffer = ""
        }
        for character in data {
            if character.isLetter, character != "e", character != "E" {
                flush()
                tokens.append(.command(character))
            } else if character == "-" {
                // A minus starts a new number unless it follows an exponent.
                if let last = buffer.last, last == "e" || last == "E" { buffer.append(character) } else {
                    flush(); buffer.append(character)
                }
            } else if character == "." {
                // A second point starts a new number: "0.5.3" is 0.5 then .3.
                if buffer.contains(".") { flush() }
                buffer.append(character)
            } else if character.isNumber || character == "e" || character == "E" {
                buffer.append(character)
            } else {
                flush()
            }
        }
        flush()
        return tokens
    }
}
