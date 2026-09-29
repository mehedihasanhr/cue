import AppKit
import CoreGraphics
import CoreImage
import Foundation
import TimelineKit

/// Draws the keys being pressed.
///
/// Its own artwork rather than a caption with different words, because a shortcut is not
/// a line of text: it is a row of keys, each one a thing with an edge, and "⌘ ⇧ K" set in
/// a sentence reads as a typo. The keys are dark with a light rim and a white legend, so
/// they read over a white document and over a dark terminal alike — a white-on-white
/// shortcut is the one failure a viewer cannot forgive, because it is invisible exactly
/// when it is needed.
///
/// Drawn once per shortcut and cached, like the caption plate: a press is on screen for
/// thirty-odd frames and nothing about the bitmap changes between them. Placement,
/// scale and opacity are applied outside the cache, where they are a transform and a
/// colour matrix rather than a redraw.
enum KeycapArtwork {
    /// How far the keys sit in from the edges, as a fraction of the shorter side. The
    /// same neighbourhood as the camera bubble's margin, so the two corners match.
    static let margin = 0.04
    /// The gap kept between the keys and a caption they share an edge with, in key
    /// heights.
    static let clearance = 0.35

    /// Everything the bitmap depends on and nothing else. Not the position, the scale or
    /// the opacity — those are applied outside.
    private struct Key: Hashable {
        let caps: [String]
        let count: Int
        let look: KeyStyle.Look
        /// The key height in whole pixels: the same shortcut at 1080p and at 4K is two
        /// pictures.
        let height: Int
        let maximumWidth: Int
    }

    private static let plates = ArtworkCache<Key, CGImage>(capacity: 16)

    /// - Parameter avoiding: anything else on the finished frame the keys must not sit on —
    ///   the camera bubble — in output pixels, bottom-left origin.
    static func image(_ layer: KeyLayer, outputSize: CGSize, avoiding: [CGRect] = []) -> CIImage? {
        guard !layer.caps.isEmpty, outputSize.width > 1, outputSize.height > 1 else { return nil }
        let shorter = min(outputSize.width, outputSize.height)
        let height = max(6, (shorter * layer.size).rounded())
        let key = Key(caps: layer.caps, count: layer.count, look: layer.look,
                      height: Int(height), maximumWidth: Int(outputSize.width.rounded()))
        guard let plate = plates.value(for: key, make: {
            draw(layer, capHeight: height, maximumWidth: outputSize.width)
        }) else { return nil }

        let size = CGSize(width: plate.width, height: plate.height)
        // Where each caption on this edge comes to rest, whatever it is doing right now,
        // so the keys stand still while a line rises or pops into place under them.
        let lines = layer.clears.compactMap { CaptionArtwork.restingExtent($0, outputSize: outputSize) }
        let frame = frame(for: size, layer: layer, outputSize: outputSize, clearing: lines + avoiding)

        var image = CIImage(cgImage: plate)
        if layer.scale != 1 {
            // About its own middle, so keys that swell stay where they are.
            let middle = CGPoint(x: size.width / 2, y: size.height / 2)
            image = image.transformed(by: CGAffineTransform(translationX: middle.x, y: middle.y)
                .scaledBy(x: layer.scale, y: layer.scale)
                .translatedBy(x: -middle.x, y: -middle.y), highQualityDownsample: true)
        }
        image = image.transformed(by: CGAffineTransform(translationX: frame.minX, y: frame.minY))
        if layer.opacity < 1 {
            image = image.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: layer.opacity),
            ])
        }
        return image
    }

    /// Empties the cache, so a test can draw cold.
    static func clearCache() { plates.removeAll() }

    // MARK: - Where they go

    /// Where a plate of this size sits in the output — bottom-left origin, Core Image's
    /// convention and the renderer's.
    ///
    /// Against the chosen edge and corner, a margin in from it, and moved along the edge's
    /// normal until it is clear of every caption it would otherwise sit on. Kept inside
    /// the frame last, so a plate that is too big for its corner is still all in shot.
    static func frame(for plate: CGSize, layer: KeyLayer, outputSize: CGSize, clearing: [CGRect]) -> CGRect {
        let shorter = min(outputSize.width, outputSize.height)
        let inset = shorter * margin
        let gap = shorter * layer.size * clearance

        let x: Double = switch layer.position.horizontal {
        case 0: inset
        case 1: outputSize.width - inset - plate.width
        default: (outputSize.width - plate.width) / 2
        }
        let y = layer.position.isTop ? outputSize.height - inset - plate.height : inset
        var rect = CGRect(x: x, y: y, width: plate.width, height: plate.height)

        // Only the lines the keys would actually be over: a narrow caption in the middle
        // does not move keys parked in a corner.
        let inTheWay = clearing.filter { $0.maxX > rect.minX && $0.minX < rect.maxX }
        if !inTheWay.isEmpty {
            if layer.position.isTop {
                let lowest = inTheWay.map(\.minY).min()!
                rect.origin.y = min(rect.minY, lowest - gap - plate.height)
            } else {
                let highest = inTheWay.map(\.maxY).max()!
                rect.origin.y = max(rect.minY, highest + gap)
            }
        }

        rect.origin.x = min(max(0, rect.minX), max(0, outputSize.width - plate.width))
        rect.origin.y = min(max(0, rect.minY), max(0, outputSize.height - plate.height))
        return rect
    }

    // MARK: - Drawing

    private static func draw(_ layer: KeyLayer, capHeight: Double, maximumWidth: Double) -> CGImage? {
        switch layer.look {
        case .keycaps: drawKeycaps(layer, capHeight: capHeight, maximumWidth: maximumWidth)
        case .pill: drawPill(layer, capHeight: capHeight, maximumWidth: maximumWidth)
        case .text: drawText(layer, capHeight: capHeight, maximumWidth: maximumWidth)
        }
    }

    private static func font(_ size: Double, weight: NSFont.Weight = .semibold) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: weight)
    }

    private static func legend(_ text: String, size: Double, weight: NSFont.Weight = .semibold,
                               stroke: Bool = false) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font(size, weight: weight),
            .foregroundColor: NSColor(white: 0.97, alpha: 1),
        ]
        if stroke {
            // A negative width strokes *and* fills, which is how words get a dark edge
            // without a plate behind them.
            attributes[.strokeColor] = NSColor(white: 0, alpha: 0.85)
            attributes[.strokeWidth] = -3
        }
        return NSAttributedString(string: text, attributes: attributes)
    }

    /// Words with a solid dark outline under a solid light face: two passes, so
    /// neither eats the other however small the words are.
    private static func drawEdged(_ words: String, size: Double, weight: NSFont.Weight, in rect: CGRect) {
        let face = legend(words, size: size, weight: weight)
        var edge = face.attributes(at: 0, effectiveRange: nil)
        edge[.strokeColor] = NSColor(white: 0, alpha: 0.9)
        edge[.strokeWidth] = 14 // positive: outline only, about a seventh of the size each side
        drawCentred(NSAttributedString(string: words, attributes: edge), in: rect)
        drawCentred(face, in: rect)
    }

    /// A bitmap of the size asked for, and a way of drawing text into it.
    private static func canvas(width: Double, height: Double,
                               _ draw: (CGContext) -> Void) -> CGImage? {
        let pixelWidth = Int(max(1, width.rounded()))
        let pixelHeight = Int(max(1, height.rounded()))
        guard let context = CGContext(data: nil,
                                      width: pixelWidth,
                                      height: pixelHeight,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        draw(context)
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    private static func drawCentred(_ text: NSAttributedString, in rect: CGRect) {
        let size = text.size()
        text.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
    }

    /// The count, "×3", after the keys. The one piece of every look that is words rather
    /// than keys, so it is edged the way the text look is.
    private static func countLegend(_ layer: KeyLayer, capHeight: Double) -> NSAttributedString? {
        guard layer.count > 1 else { return nil }
        return legend("×\(layer.count)", size: capHeight * 0.42, stroke: true)
    }

    /// One key per key: a dark cap with a lighter face, a light rim and a shadow under
    /// it, and the legend in the middle of the face.
    private static func drawKeycaps(_ layer: KeyLayer, capHeight: Double, maximumWidth: Double) -> CGImage? {
        let height = capHeight
        let pad = height * 0.25
        let gap = height * 0.12
        let radius = height * 0.2
        let legends = layer.caps.map { cap in
            legend(cap, size: cap.count > 1 ? height * 0.36 : height * 0.5)
        }
        // Square for a symbol or a letter, wider for a word like "Space" or "F12".
        let widths = legends.map { max(height, ceil($0.size().width) + height * 0.5) }
        let count = countLegend(layer, capHeight: height)
        let countWidth = count.map { ceil($0.size().width) + height * 0.25 } ?? 0
        let width = min(maximumWidth, widths.reduce(0, +) + gap * Double(max(0, widths.count - 1)) + countWidth + pad * 2)

        return canvas(width: width, height: height + pad * 2) { context in
            var x = pad
            for (index, text) in legends.enumerated() {
                let base = CGRect(x: x, y: pad, width: widths[index], height: height)
                let basePath = CGPath(roundedRect: base, cornerWidth: radius, cornerHeight: radius, transform: nil)

                // The cap and its shadow: a dark body that reads on white.
                context.saveGState()
                context.setShadow(offset: CGSize(width: 0, height: -height * 0.05), blur: height * 0.12,
                                  color: CGColor(gray: 0, alpha: 0.5))
                context.setFillColor(CGColor(gray: 0.12, alpha: 0.97))
                context.addPath(basePath)
                context.fillPath()
                context.restoreGState()

                // The face, set up from the bottom of the cap so the lip reads as depth.
                let face = CGRect(x: base.minX + height * 0.06, y: base.minY + height * 0.15,
                                  width: base.width - height * 0.12, height: base.height - height * 0.2)
                let facePath = CGPath(roundedRect: face, cornerWidth: radius * 0.8, cornerHeight: radius * 0.8, transform: nil)
                context.saveGState()
                context.addPath(facePath)
                context.clip()
                if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             colors: [CGColor(gray: 0.34, alpha: 1), CGColor(gray: 0.22, alpha: 1)] as CFArray,
                                             locations: [0, 1]) {
                    context.drawLinearGradient(gradient,
                                               start: CGPoint(x: face.midX, y: face.maxY),
                                               end: CGPoint(x: face.midX, y: face.minY),
                                               options: [])
                }
                context.restoreGState()

                // The rim: what separates a dark key from a dark screen.
                context.setStrokeColor(CGColor(gray: 1, alpha: 0.3))
                context.setLineWidth(max(1, height * 0.025))
                context.addPath(basePath)
                context.strokePath()

                drawCentred(text, in: face)
                x += widths[index] + gap
            }
            if let count {
                let rect = CGRect(x: x - gap + height * 0.25, y: pad, width: countWidth, height: height)
                drawCentred(count, in: rect)
            }
        }
    }

    /// One plate for the whole shortcut, like the caption's, with the keys on it.
    private static func drawPill(_ layer: KeyLayer, capHeight: Double, maximumWidth: Double) -> CGImage? {
        let height = capHeight
        let pad = height * 0.25
        var words = layer.caps.joined(separator: " ")
        if layer.count > 1 { words += "  ×\(layer.count)" }
        let text = legend(words, size: height * 0.5)
        let width = min(maximumWidth, ceil(text.size().width) + height * 0.7 + pad * 2)

        return canvas(width: width, height: height + pad * 2) { context in
            let plate = CGRect(x: pad, y: pad, width: width - pad * 2, height: height)
            let path = CGPath(roundedRect: plate, cornerWidth: height * 0.32, cornerHeight: height * 0.32, transform: nil)
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -height * 0.05), blur: height * 0.12,
                              color: CGColor(gray: 0, alpha: 0.45))
            context.setFillColor(CGColor(gray: 0.08, alpha: 0.72))
            context.addPath(path)
            context.fillPath()
            context.restoreGState()
            context.setStrokeColor(CGColor(gray: 1, alpha: 0.25))
            context.setLineWidth(max(1, height * 0.025))
            context.addPath(path)
            context.strokePath()
            drawCentred(text, in: plate)
        }
    }

    /// The words alone, with a dark edge and a shadow so they read on anything.
    private static func drawText(_ layer: KeyLayer, capHeight: Double, maximumWidth: Double) -> CGImage? {
        let height = capHeight
        let pad = height * 0.25
        var words = layer.caps.joined(separator: " ")
        if layer.count > 1 { words += "  ×\(layer.count)" }
        let size = height * 0.66
        let text = legend(words, size: size, weight: .heavy)
        let width = min(maximumWidth, ceil(text.size().width) + pad * 2 + height * 0.2)

        return canvas(width: width, height: height + pad * 2) { context in
            context.setShadow(offset: CGSize(width: 0, height: -height * 0.04), blur: height * 0.1,
                              color: CGColor(gray: 0, alpha: 0.6))
            drawEdged(words, size: size, weight: .heavy,
                      in: CGRect(x: pad, y: pad, width: width - pad * 2, height: height))
        }
    }
}

extension CaptionArtwork {
    /// Where a line sits once it has arrived, whatever it is doing at this moment.
    ///
    /// The keys are kept clear of this rather than of the line as drawn, so a line that
    /// rises or pops into place does not carry the keys about with it.
    static func restingExtent(_ caption: CaptionLayer, outputSize: CGSize) -> CGRect? {
        var resting = caption
        resting.scale = 1
        resting.drop = 0
        resting.opacity = 1
        resting.spokenWord = nil
        return image(resting, outputSize: outputSize)?.extent
    }
}
