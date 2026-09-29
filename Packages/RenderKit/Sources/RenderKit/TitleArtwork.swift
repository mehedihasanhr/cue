import AppKit
import CoreGraphics
import CoreImage
import Foundation
import TimelineKit

/// Draws a title slide's words.
///
/// Laid out inside the frame the recording would fill, like a caption is laid out rather
/// than placed: the lines wrap before the frame's edge, and where they sit depends on how
/// many there are. Drawn once per card and size and kept, because a title stands on screen
/// for seconds and its entrance only moves and fades the drawing — it never redraws it.
enum TitleArtwork {
    /// How far in from the frame's sides the words stay, as a fraction of its width.
    static let margin = 0.08
    /// The subtitle's size, as a fraction of the title's.
    static let subtitleScale = 0.42
    /// How far the lower third sits up from the frame's bottom, as a fraction of its height.
    static let lowerThirdInset = 0.12

    /// Everything the drawing depends on and nothing else — not the opacity and not the
    /// rise, which are applied to the finished drawing, so an entrance hits the cache on
    /// every one of its frames.
    private struct Key: Hashable {
        let title: String
        let subtitle: String
        let layout: TitleCard.Layout
        let r: Double, g: Double, b: Double, a: Double
        let typeface: CaptionStyle.Typeface
        let fontFamily: String
        let size: Double
        let width: Int
        let height: Int
        /// Words on a panel need no shadow to be read; words on a wallpaper do.
        let isOnPanel: Bool
    }

    private static let cards = ArtworkCache<Key, CGImage>(capacity: 8)

    /// The words, placed in the output, bottom-left origin — Core Image's convention.
    static func image(_ layer: TitleLayer, in scene: SceneDescriptor) -> CIImage? {
        let frame = scene.videoFrame
        let width = Int(frame.width.rounded())
        let height = Int(frame.height.rounded())
        guard width > 1, height > 1, layer.opacity > 0.001 else { return nil }
        let title = layer.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let subtitle = layer.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty || !subtitle.isEmpty else { return nil }

        let size = min(TitleCard.maximumSize, max(TitleCard.minimumSize, layer.size))
        let key = Key(title: title, subtitle: subtitle, layout: layer.layout,
                      r: layer.textColor.r, g: layer.textColor.g, b: layer.textColor.b, a: layer.textColor.a,
                      typeface: layer.typeface, fontFamily: layer.fontFamily, size: size, width: width, height: height,
                      isOnPanel: layer.panelColor != nil)
        guard let drawing = cards.value(for: key, make: { draw(key) }) else { return nil }

        // Lower while it rises into place, by a share of the title's own size, so the
        // movement looks the same at every size.
        let drop = layer.drop * Double(height) * size
        var image = CIImage(cgImage: drawing)
            .transformed(by: CGAffineTransform(translationX: frame.minX, y: frame.minY - drop))
        if layer.opacity < 1 {
            image = image.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: max(0, layer.opacity)),
            ])
        }
        return image
    }

    /// Empties the cache, so a test can draw one cold.
    static func clearCache() { cards.removeAll() }

    /// The family the card names when this Mac has it, and otherwise the system's type in
    /// the card's design.
    static func font(_ typeface: CaptionStyle.Typeface, family: String = "", size: Double,
                     weight: NSFont.Weight) -> NSFont {
        if let chosen = FontFamilies.font(family: family, size: size, weight: weight) { return chosen }
        let base = NSFont.systemFont(ofSize: size, weight: weight)
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

    private static func draw(_ key: Key) -> CGImage? {
        let bounds = CGSize(width: Double(key.width), height: Double(key.height))
        let titleSize = max(6, bounds.height * key.size)
        let subtitleSize = max(5, titleSize * subtitleScale)
        let gap = titleSize * 0.3
        let inset = bounds.width * margin
        let textWidth = max(1, bounds.width - inset * 2)

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = key.layout == .centred ? .center : .left
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineHeightMultiple = 0.95

        let colour = NSColor(srgbRed: key.r, green: key.g, blue: key.b, alpha: key.a)
        var common: [NSAttributedString.Key: Any] = [.paragraphStyle: paragraph]
        if !key.isOnPanel {
            // A soft shadow under words set on a wallpaper, which can be as light as the
            // words are: without it, white on a pale gradient is not there.
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            shadow.shadowBlurRadius = titleSize * 0.15
            shadow.shadowOffset = CGSize(width: 0, height: -titleSize * 0.03)
            common[.shadow] = shadow
        }

        let title = NSAttributedString(string: key.title, attributes: common.merging([
            .font: font(key.typeface, family: key.fontFamily, size: titleSize, weight: .bold),
            .foregroundColor: colour,
        ]) { $1 })
        let subtitle = NSAttributedString(string: key.subtitle, attributes: common.merging([
            .font: font(key.typeface, family: key.fontFamily, size: subtitleSize, weight: .medium),
            .foregroundColor: colour.withAlphaComponent(key.a * 0.85),
        ]) { $1 })

        let limit = CGSize(width: textWidth, height: .greatestFiniteMagnitude)
        func measure(_ text: NSAttributedString) -> Double {
            guard text.length > 0 else { return 0 }
            return ceil(text.boundingRect(with: limit, options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
        }
        let titleHeight = measure(title)
        let subtitleHeight = measure(subtitle)
        let block = titleHeight + subtitleHeight + (titleHeight > 0 && subtitleHeight > 0 ? gap : 0)

        // Up from the bottom, in the drawing's own space.
        let bottom: Double = switch key.layout {
        case .centred, .left: (bounds.height - block) / 2
        case .lowerThird: bounds.height * lowerThirdInset
        }

        guard let context = CGContext(data: nil,
                                      width: key.width,
                                      height: key.height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        if subtitleHeight > 0 {
            subtitle.draw(with: CGRect(x: inset, y: bottom, width: textWidth, height: subtitleHeight),
                          options: [.usesLineFragmentOrigin, .usesFontLeading])
        }
        if titleHeight > 0 {
            let y = bottom + (subtitleHeight > 0 ? subtitleHeight + gap : 0)
            title.draw(with: CGRect(x: inset, y: y, width: textWidth, height: titleHeight),
                       options: [.usesLineFragmentOrigin, .usesFontLeading])
        }
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }
}
