import AppKit
import CoreGraphics
import Foundation
import TimelineKit

/// The box a text label needs, so the frame drawn round it on the picture is the label.
///
/// A label is laid out inside its box and never outside it, so a box drawn roomy left a
/// frame much larger than the words — handles in empty space, and a label that seemed to
/// be somewhere it was not. Measured here with exactly the font, wrapping and padding the
/// renderer draws with, so the box and the words cannot disagree.
public enum AnnotationFit {
    /// The size of a label's box, as fractions of the frame: as wide as its longest line,
    /// never wider than `maxWidth`, and as tall as its lines.
    ///
    /// - Parameters:
    ///   - fontSize: a fraction of the frame's height, as `AnnotationItem.fontSize` is.
    ///   - maxWidth: the widest the box may be, as a fraction of the frame's width; the
    ///     words wrap there.
    ///   - frame: the finished frame, in pixels. Only its shape matters to the answer,
    ///     except below the smallest type the renderer draws.
    public static func labelSize(_ string: String,
                                 style: AnnotationStyle,
                                 color: ColorValue,
                                 fontSize: Double,
                                 maxWidth: Double,
                                 frame: CGSize) -> CGSize {
        guard frame.width > 0, frame.height > 0 else { return .zero }
        let size = max(8, frame.height * fontSize)
        let padded = style.plate(for: color) != nil
        let padX = padded ? size * 0.35 : 0
        let padY = padded ? size * 0.2 : 0
        let widest = max(size, maxWidth * frame.width - padX * 2)
        // A space for an empty label, so a box just drawn still has the height of a line.
        let text = AnnotationArtwork.words(string.isEmpty ? " " : string,
                                           font: AnnotationArtwork.font(size: size, weight: style.weight,
                                                                        family: style.fontFamily),
                                           colour: color, alignment: style.alignment)
        let used = AnnotationArtwork.measured(text, width: widest)
        // A pixel and a half of slack each way: a box measured to the pixel wraps its last
        // word onto a line of its own the moment the renderer rounds the other way — the
        // fault the caption plate had.
        let width = min(used.width, widest) + padX * 2 + 3
        let height = used.height + padY * 2 + 2
        return CGSize(width: min(1, width / frame.width), height: min(1, height / frame.height))
    }

    // MARK: - The rules

    // A text label's box follows its words — until it is given a size by hand.
    //
    // Left alone, the frame *is* the label: typing grows it to the right until it reaches
    // `growth` of the frame and then wraps, and its height is its lines. Pulling a side fixes
    // its width (`AnnotationItem.fixedWidth`): the words wrap there and the box stays exactly
    // as wide as it was pulled, rather than snapping back to its longest line on every move of
    // the mouse — which is what made resizing jump. Pulling the top or bottom fixes its height
    // (`fixedHeight`): the box is that tall, and taller only if its lines need it. Pulling a
    // corner scales the type.
    //
    // Only plain labels. A callout is a bubble the words wrap inside, drawn to the size it was
    // given, and the other kinds have no words at all.

    /// How wide a label may grow by being typed into, as a share of the frame's width,
    /// before it wraps instead.
    public static let growth = 0.45

    public static func isLabel(_ item: AnnotationItem) -> Bool {
        if case .text = item.kind { true } else { false }
    }

    /// Whether a change touched anything a label's size depends on.
    public static func needsFitting(_ before: AnnotationItem, _ after: AnnotationItem) -> Bool {
        guard isLabel(after) else { return false }
        return !isLabel(before)
            || before.kind.text != after.kind.text
            || before.fontSize != after.fontSize
            || before.style != after.style
            || before.rect != after.rect
            || before.fixedWidth != after.fixedWidth
            || before.fixedHeight != after.fixedHeight
    }

    /// The smallest bubble a callout's words fit in on one line each, as fractions of the
    /// frame — the words, and the room the renderer leaves round them inside the bubble.
    public static func calloutSize(_ string: String, style: AnnotationStyle, color: ColorValue,
                                   fontSize: Double, frame: CGSize) -> CGSize {
        guard frame.width > 0, frame.height > 0 else { return .zero }
        let size = max(8, frame.height * fontSize)
        let text = AnnotationArtwork.words(string.isEmpty ? " " : string,
                                           font: AnnotationArtwork.font(size: size, weight: style.weight,
                                                                        family: style.fontFamily),
                                           colour: color, alignment: style.alignment)
        let used = AnnotationArtwork.measured(text, width: .greatestFiniteMagnitude)
        // As `AnnotationArtwork.drawCallout` insets them: half a size across, three tenths
        // down, and the outline's width.
        let width = used.width + size + AnnotationArtwork.wrapRoom(size, width: used.width) + 4
        let height = used.height + size * 0.6 + 4
        return CGSize(width: min(1, width / frame.width), height: min(1, height / frame.height))
    }

    /// `item`'s box fitted to its words.
    ///
    /// - Parameter setByCaller: the caller placed the box on purpose — a side or a corner
    ///   was pulled — so the words wrap at its width. Otherwise the label may grow to
    ///   `growth` of the frame first, which is typing.
    public static func fitted(_ item: AnnotationItem, frame: CGSize, setByCaller: Bool) -> CGRect {
        let rect = item.rect
        let room = max(0.02, 1 - rect.minX)
        let widest: Double
        if item.fixedWidth {
            widest = rect.width
        } else if setByCaller {
            // A corner scaling the type: the box and the words grow together, but measured
            // type does not scale exactly with its size, and a line that fitted a moment ago
            // must not break onto a second one halfway through a drag. A little room more.
            widest = min(room, rect.width * 1.04 + 2 / max(1, frame.width))
        } else {
            widest = min(room, max(rect.width, growth))
        }
        let size = labelSize(item.kind.text ?? "", style: item.style, color: item.color,
                             fontSize: item.fontSize, maxWidth: widest, frame: frame)
        guard size.width > 0, size.height > 0 else { return rect }
        let width = item.fixedWidth ? min(1, rect.width) : size.width
        let height = item.fixedHeight ? min(1, max(rect.height, size.height)) : size.height
        // Anchored on the side the words are set from, so a label typed into grows away
        // from where it started, and a centred one stays centred. A box with a width of its
        // own stays where it was put.
        let x: Double = if item.fixedWidth {
            rect.minX
        } else {
            switch item.style.alignment {
            case .left: rect.minX
            case .center: rect.midX - width / 2
            case .right: rect.maxX - width
            }
        }
        return CGRect(x: min(max(0, x), 1 - width), y: min(max(0, rect.minY), 1 - height),
                      width: width, height: height)
    }

    /// The font a label is drawn in, at `pointSize`: exactly the renderer's, family and
    /// weight included, so text typed on the canvas is the size and shape it will export.
    public static func font(for style: AnnotationStyle, pointSize: Double) -> NSFont {
        AnnotationArtwork.font(size: max(1, pointSize), weight: style.weight, family: style.fontFamily)
    }
}
