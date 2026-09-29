import AppKit
import CoreGraphics
import CoreImage
import Foundation
import TimelineKit

/// Draws the spoken line.
///
/// Its own artwork rather than an annotation with fixed coordinates, because a caption
/// is laid out rather than placed: the plate has to be the width the words came out at,
/// the words have to wrap before they reach the edge, and the whole thing has to sit the
/// same distance from the bottom on every frame regardless of how long the line is.
enum CaptionArtwork {
    /// How much of the frame's width a line may use before it wraps.
    ///
    /// Not the whole width: text running edge to edge is hard to read, and on a 21:9
    /// export a full-width line is a single strip of words the eye has to track across.
    private static let maximumTextWidth = 0.8
    /// Room around the words inside the plate, as a fraction of the font size.
    private static let padding = 0.45

    /// The plate, drawn once per line rather than once per frame.
    ///
    /// Everything the bitmap depends on and nothing else: the words, the size they are set
    /// at, their colour, how dark the plate behind them is, and the frame it has to fit
    /// inside. Deliberately *not* `position`, `margin` or `opacity` — those place the plate
    /// and fade it, which happens outside, so a caption fading in for a quarter of a second
    /// still hits the same cached bitmap on all eight of those frames.
    private struct Key: Hashable {
        let text: String
        let fontSize: Double
        let r: Double, g: Double, b: Double, a: Double
        let backgroundOpacity: Double
        let width: Int
        let height: Int
    }

    /// Four lines' worth. A caption is one line at a time and the only reason to hold more
    /// than one is the moment two cues abut; the extra entries cover the preview and an
    /// export running at different sizes at once.
    private static let plates = ArtworkCache<Key, CGImage>(capacity: 4)

    static func image(_ caption: CaptionLayer, outputSize: CGSize) -> CIImage? {
        let trimmed = caption.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, outputSize.width > 1, outputSize.height > 1 else { return nil }

        let fontSize = max(8, outputSize.height * caption.fontSize)
        let key = Key(text: trimmed,
                      fontSize: fontSize,
                      r: caption.color.r, g: caption.color.g, b: caption.color.b, a: caption.color.a,
                      backgroundOpacity: caption.backgroundOpacity,
                      width: Int(outputSize.width.rounded()),
                      height: Int(outputSize.height.rounded()))
        guard let cgImage = plates.value(for: key, make: {
            plate(trimmed, caption: caption, outputSize: outputSize, fontSize: fontSize)
        }) else { return nil }

        // Placed in the output, bottom-left origin — Core Image's convention, and the
        // renderer's.
        let margin = outputSize.height * caption.margin
        let x = (outputSize.width - Double(cgImage.width)) / 2
        let y = switch caption.position {
        case .bottom: margin
        case .top: outputSize.height - margin - Double(cgImage.height)
        }

        var image = CIImage(cgImage: cgImage)
            .transformed(by: CGAffineTransform(translationX: x, y: max(0, y)))
        if caption.opacity < 1 {
            image = image.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: caption.opacity),
            ])
        }
        return image
    }

    /// Empties the plate cache, so a test can draw one cold.
    static func clearCache() { plates.removeAll() }

    private static func plate(_ trimmed: String,
                              caption: CaptionLayer,
                              outputSize: CGSize,
                              fontSize: Double) -> CGImage? {
        let inset = fontSize * padding

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: NSColor(srgbRed: caption.color.r, green: caption.color.g,
                                      blue: caption.color.b, alpha: caption.color.a),
            .paragraphStyle: paragraph,
        ]
        let text = NSAttributedString(string: trimmed, attributes: attributes)

        // Measured before anything is drawn: the plate is sized to the words, so the
        // words have to be laid out first.
        let limit = CGSize(width: outputSize.width * maximumTextWidth, height: .greatestFiniteMagnitude)
        let measured = text.boundingRect(with: limit, options: [.usesLineFragmentOrigin, .usesFontLeading])
        let textSize = CGSize(width: ceil(measured.width), height: ceil(measured.height))
        guard textSize.width > 1, textSize.height > 1 else { return nil }

        let plate = CGSize(width: textSize.width + inset * 2, height: textSize.height + inset * 2)
        let width = Int(min(outputSize.width, plate.width).rounded())
        let height = Int(min(outputSize.height, plate.height).rounded())

        guard let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        let bounds = CGRect(x: 0, y: 0, width: Double(width), height: Double(height))

        if caption.backgroundOpacity > 0 {
            // A plate, not a shadow: captions land on screen recordings, which are as
            // often white as dark, and a shadow alone disappears on both.
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: caption.backgroundOpacity))
            context.addPath(CGPath(roundedRect: bounds,
                                   cornerWidth: fontSize * 0.3,
                                   cornerHeight: fontSize * 0.3,
                                   transform: nil))
            context.fillPath()
        }

        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        text.draw(with: bounds.insetBy(dx: inset, dy: inset), options: [.usesLineFragmentOrigin, .usesFontLeading])
        NSGraphicsContext.restoreGraphicsState()

        return context.makeImage()
    }
}
