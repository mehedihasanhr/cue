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
        let typeface: CaptionStyle.Typeface
        let fontFamily: String
        /// Which word is lit, and in what colour. A line with a word lit is a different
        /// picture for every word of it.
        let spokenWord: Int?
        /// The highlight's colour, as numbers: `ColorValue` is not something to hash by.
        let hr: Double, hg: Double, hb: Double, ha: Double
    }

    /// A line's worth of words, twice over. With a word lit up a line is one picture per
    /// word, and scrubbing back and forth across it asks for all of them again; the second
    /// line's worth covers the preview and an export running at different sizes at once.
    private static let plates = ArtworkCache<Key, CGImage>(capacity: 32)

    static func image(_ caption: CaptionLayer, outputSize: CGSize) -> CIImage? {
        let trimmed = caption.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, outputSize.width > 1, outputSize.height > 1 else { return nil }

        let fontSize = max(8, outputSize.height * caption.fontSize)
        let key = Key(text: trimmed,
                      fontSize: fontSize,
                      r: caption.color.r, g: caption.color.g, b: caption.color.b, a: caption.color.a,
                      backgroundOpacity: caption.backgroundOpacity,
                      width: Int(outputSize.width.rounded()),
                      height: Int(outputSize.height.rounded()),
                      typeface: caption.typeface,
                      fontFamily: caption.fontFamily,
                      spokenWord: caption.spokenWord,
                      // Only part of what the picture is when a word is lit; otherwise
                      // changing the colour would redraw lines it does not appear in.
                      hr: caption.spokenWord == nil ? 0 : caption.highlightColor.r,
                      hg: caption.spokenWord == nil ? 0 : caption.highlightColor.g,
                      hb: caption.spokenWord == nil ? 0 : caption.highlightColor.b,
                      ha: caption.spokenWord == nil ? 0 : caption.highlightColor.a)
        guard let cgImage = plates.value(for: key, make: {
            plate(trimmed, caption: caption, outputSize: outputSize, fontSize: fontSize)
        }) else { return nil }

        // Placed in the output, bottom-left origin — Core Image's convention, and the
        // renderer's.
        let margin = outputSize.height * caption.margin
        let x = (outputSize.width - Double(cgImage.width)) / 2
        let rest = switch caption.position {
        case .bottom: margin
        case .top: outputSize.height - margin - Double(cgImage.height)
        }
        // Lower while it is arriving, when the project has it rise into place.
        let y = max(0, rest) - caption.drop * outputSize.height

        var image = CIImage(cgImage: cgImage)
        if caption.scale != 1 {
            // About its own middle, so a line that swells stays where it is.
            let middle = CGPoint(x: Double(cgImage.width) / 2, y: Double(cgImage.height) / 2)
            image = image.transformed(by: CGAffineTransform(translationX: middle.x, y: middle.y)
                .scaledBy(x: caption.scale, y: caption.scale)
                .translatedBy(x: -middle.x, y: -middle.y), highQualityDownsample: true)
        }
        image = image.transformed(by: CGAffineTransform(translationX: x, y: y))
        if caption.opacity < 1 {
            image = image.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: caption.opacity),
            ])
        }
        return image
    }

    /// Empties the plate cache, so a test can draw one cold.
    static func clearCache() { plates.removeAll() }

    /// The type a caption is set in: the family it names, when this Mac has it, and
    /// otherwise the system's type in the design the caption asked for, at the weight
    /// captions are set in. A design this Mac cannot supply falls back to the standard one
    /// rather than to no caption.
    static func font(_ typeface: CaptionStyle.Typeface, family: String = "", size: Double) -> NSFont {
        if let chosen = FontFamilies.font(family: family, size: size, weight: .semibold) { return chosen }
        let base = NSFont.systemFont(ofSize: size, weight: .semibold)
        let design: NSFontDescriptor.SystemDesign = switch typeface {
        case .standard: .default
        case .rounded: .rounded
        case .serif: .serif
        case .monospaced: .monospaced
        }
        guard let descriptor = base.fontDescriptor.withDesign(design),
              let font = NSFont(descriptor: descriptor, size: size) else { return base }
        return font
    }

    /// Where the word at a position is in a line, counting words the way `CaptionCue`
    /// does: whatever is between two stretches of white space.
    static func wordRange(_ index: Int, in text: String) -> Range<String.Index>? {
        guard index >= 0 else { return nil }
        var count = 0
        var cursor = text.startIndex
        while cursor < text.endIndex {
            guard let start = text[cursor...].firstIndex(where: { !$0.isWhitespace }) else { return nil }
            let end = text[start...].firstIndex(where: \.isWhitespace) ?? text.endIndex
            if count == index { return start..<end }
            count += 1
            cursor = end
        }
        return nil
    }

    private static func plate(_ trimmed: String,
                              caption: CaptionLayer,
                              outputSize: CGSize,
                              fontSize: Double) -> CGImage? {
        let inset = fontSize * padding

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font(caption.typeface, family: caption.fontFamily, size: fontSize),
            .foregroundColor: NSColor(srgbRed: caption.color.r, green: caption.color.g,
                                      blue: caption.color.b, alpha: caption.color.a),
            .paragraphStyle: paragraph,
        ]
        let text = NSMutableAttributedString(string: trimmed, attributes: attributes)
        // The word being said, in the colour that says so. The colour alone changes — not
        // the weight and not the size — so the line is the same width whichever word is
        // lit and nothing in it moves as the highlight goes along.
        if let spoken = caption.spokenWord, let range = wordRange(spoken, in: trimmed) {
            let highlight = caption.highlightColor
            text.addAttribute(.foregroundColor,
                              value: NSColor(srgbRed: highlight.r, green: highlight.g,
                                             blue: highlight.b, alpha: highlight.a),
                              range: NSRange(range, in: trimmed))
        }

        // Measured before anything is drawn: the plate is sized to the words, so the
        // words have to be laid out first.
        let limit = CGSize(width: outputSize.width * maximumTextWidth, height: .greatestFiniteMagnitude)
        let measured = text.boundingRect(with: limit, options: [.usesLineFragmentOrigin, .usesFontLeading])
        let textSize = CGSize(width: ceil(measured.width), height: ceil(measured.height))
        guard textSize.width > 1, textSize.height > 1 else { return nil }

        let plate = CGSize(width: textSize.width + inset * 2, height: textSize.height + inset * 2)
        // Rounded up, never to the nearest: the words are drawn into the plate less its
        // inset, and a plate rounded *down* leaves that a fraction of a pixel narrower than
        // the words were measured at. Text laid out in less room than it measured wraps, and
        // the line it wraps onto falls below the plate and is never drawn. At the default
        // size a 360p, 720p or 4K plate rounds down, so any line whose width fell close
        // enough below a whole pixel lost its last word; a one-line caption at 360p and 6%
        // of the height lost "step 2." off the end of "…the button that says step 2.".
        let width = Int(min(outputSize.width, plate.width).rounded(.up))
        let height = Int(min(outputSize.height, plate.height).rounded(.up))

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
