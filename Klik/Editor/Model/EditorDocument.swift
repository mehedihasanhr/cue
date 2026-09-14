import AppKit

enum BackgroundFill: Hashable, Codable {
    case solid(RGBA)
    case gradient(GradientPreset)
    case image(Wallpaper)
}

/// A background picture: one of the system desktop pictures (by file name) or a
/// user file (security-scoped bookmark).
struct Wallpaper: Hashable, Codable {
    var name: String
    var bookmark: Data?

    var title: String { (name as NSString).deletingPathExtension }
}

enum GradientPreset: String, Hashable, Codable, CaseIterable {
    case ocean, sunset, aurora, candy, peach, lime, lavender, flame, mint, rose, sky, dusk,
         forest, gold, berry, steel, midnight, graphite, mono, snow

    var colors: [RGBA] {
        switch self {
        case .ocean: [RGBA(r: 0.27, g: 0.65, b: 1), RGBA(r: 0.36, g: 0.32, b: 0.9)]
        case .sunset: [RGBA(r: 1, g: 0.55, b: 0.35), RGBA(r: 0.98, g: 0.29, b: 0.53)]
        case .aurora: [RGBA(r: 0.2, g: 0.85, b: 0.7), RGBA(r: 0.3, g: 0.45, b: 0.95)]
        case .candy: [RGBA(r: 1, g: 0.6, b: 0.85), RGBA(r: 0.65, g: 0.5, b: 1)]
        case .peach: [RGBA(r: 1, g: 0.8, b: 0.6), RGBA(r: 1, g: 0.5, b: 0.55)]
        case .lime: [RGBA(r: 0.75, g: 0.95, b: 0.45), RGBA(r: 0.2, g: 0.75, b: 0.55)]
        case .lavender: [RGBA(r: 0.85, g: 0.8, b: 1), RGBA(r: 0.55, g: 0.45, b: 0.95)]
        case .flame: [RGBA(r: 1, g: 0.85, b: 0.3), RGBA(r: 1, g: 0.35, b: 0.2), RGBA(r: 0.6, g: 0.05, b: 0.3)]
        case .mint: [RGBA(r: 0.7, g: 1, b: 0.9), RGBA(r: 0.25, g: 0.8, b: 0.75)]
        case .rose: [RGBA(r: 1, g: 0.75, b: 0.8), RGBA(r: 0.9, g: 0.3, b: 0.5)]
        case .sky: [RGBA(r: 0.75, g: 0.9, b: 1), RGBA(r: 0.3, g: 0.6, b: 1)]
        case .dusk: [RGBA(r: 0.98, g: 0.6, b: 0.4), RGBA(r: 0.55, g: 0.3, b: 0.65), RGBA(r: 0.15, g: 0.15, b: 0.4)]
        case .forest: [RGBA(r: 0.35, g: 0.7, b: 0.45), RGBA(r: 0.05, g: 0.3, b: 0.25)]
        case .gold: [RGBA(r: 1, g: 0.9, b: 0.55), RGBA(r: 0.85, g: 0.6, b: 0.15)]
        case .berry: [RGBA(r: 0.8, g: 0.3, b: 0.7), RGBA(r: 0.3, g: 0.1, b: 0.5)]
        case .steel: [RGBA(r: 0.75, g: 0.8, b: 0.88), RGBA(r: 0.35, g: 0.42, b: 0.55)]
        case .midnight: [RGBA(r: 0.13, g: 0.15, b: 0.3), RGBA(r: 0.05, g: 0.05, b: 0.12)]
        case .graphite: [RGBA(r: 0.35, g: 0.36, b: 0.4), RGBA(r: 0.12, g: 0.12, b: 0.14)]
        case .mono: [RGBA(r: 0.2, g: 0.2, b: 0.22), RGBA(r: 0.02, g: 0.02, b: 0.03)]
        case .snow: [RGBA(r: 1, g: 1, b: 1), RGBA(r: 0.85, g: 0.88, b: 0.93)]
        }
    }
}

/// Solid colours offered for backgrounds (the annotation palette plus a few neutrals).
enum BackgroundPalette {
    static let colors: [RGBA] = [
        .white, RGBA(r: 0.93, g: 0.93, b: 0.95), RGBA(r: 0.75, g: 0.76, b: 0.8), .gray, RGBA(r: 0.2, g: 0.2, b: 0.22), .black,
        RGBA(r: 0.055, g: 0.31, b: 0.925), .blue, RGBA(r: 0.35, g: 0.78, b: 0.98), RGBA(r: 0.2, g: 0.78, b: 0.7), .green, RGBA(r: 0.85, g: 0.95, b: 0.55),
        .yellow, .orange, .red, .pink, .purple, RGBA(r: 0.5, g: 0.35, b: 0.25),
    ]
}

/// Where the image card sits inside a canvas that is larger than it (fixed ratios).
struct CardAlignment: Hashable, Codable {
    /// 0 = leading / top, 0.5 = centre, 1 = trailing / bottom.
    var horizontal: CGFloat = 0.5
    var vertical: CGFloat = 0.5

    static let all: [[CardAlignment]] = [0, 0.5, 1].map { v in [0, 0.5, 1].map { h in CardAlignment(horizontal: h, vertical: v) } }
}

/// Output aspect ratio; the canvas grows (never crops) to reach it.
enum OutputRatio: String, Hashable, Codable, CaseIterable {
    case auto, square, r4x3, r3x2, r16x9, r16x10, r9x16, r3x4, r2x3, r4x5

    var title: String {
        switch self {
        case .auto: "Auto"
        case .square: "1:1"
        case .r4x3: "4:3"
        case .r3x2: "3:2"
        case .r16x9: "16:9"
        case .r16x10: "16:10"
        case .r9x16: "9:16"
        case .r3x4: "3:4"
        case .r2x3: "2:3"
        case .r4x5: "4:5"
        }
    }

    var value: CGFloat? {
        switch self {
        case .auto: nil
        case .square: 1
        case .r4x3: 4 / 3
        case .r3x2: 3 / 2
        case .r16x9: 16 / 9
        case .r16x10: 16 / 10
        case .r9x16: 9 / 16
        case .r3x4: 3 / 4
        case .r2x3: 2 / 3
        case .r4x5: 4 / 5
        }
    }
}

/// Padding and backdrop drawn around the (cropped) image for sharing.
struct BackgroundStyle: Hashable, Codable {
    var padding: CGFloat = 48
    /// Padding derived from the image size instead of the slider.
    var autoBalance = false
    /// Border inside the card, between the image and the rounded edge, filled with the
    /// image's own edge colour.
    var inset: CGFloat = 0
    var cornerRadius: CGFloat = 12
    var fill: BackgroundFill = .gradient(.ocean)
    /// 0 = no shadow … 1 = strongest.
    var shadowStrength: CGFloat = 0.45
    var alignment = CardAlignment()
    var ratio: OutputRatio = .auto
    /// Gradient direction in degrees, clockwise from "top → bottom" (0). Diagonal by default.
    var gradientAngle: CGFloat = 45
    /// Blur applied to wallpaper fills (0 = sharp), for a softer backdrop.
    var imageBlur: CGFloat = 0

    /// The padding actually applied around the card.
    func effectivePadding(for contentSize: CGSize) -> CGFloat {
        autoBalance ? (max(contentSize.width, contentSize.height) * 0.08).rounded() : padding
    }
}

/// Resolved geometry of the output: where the card and the image land.
struct OutputLayout {
    var size: CGSize
    /// The rounded, shadowed card (image plus inset border), in output space.
    var card: CGRect
    /// The image itself, in output space.
    var image: CGRect
}

/// One value = one undo state. The base image is a reference but never mutated.
struct EditorDocument {
    let base: CGImage
    /// Pixels per point of the source; annotations and crop are in points.
    let scale: CGFloat
    var annotations: [Annotation] = []
    /// In image points; `nil` = whole image.
    var crop: CGRect?
    var background: BackgroundStyle?
    var nextCounter = 1

    init(image: CapturedImage) {
        base = image.cgImage
        scale = image.scale
    }

    var imageSize: CGSize {
        CGSize(width: CGFloat(base.width) / scale, height: CGFloat(base.height) / scale)
    }

    var imageRect: CGRect { CGRect(origin: .zero, size: imageSize) }

    /// The part of the image that ends up in the output.
    var contentRect: CGRect { crop ?? imageRect }

    /// Output size in points including background padding.
    var layout: OutputLayout {
        let content = contentRect.size
        guard let background else {
            let rect = CGRect(origin: .zero, size: content)
            return OutputLayout(size: content, card: rect, image: rect)
        }
        let padding = background.effectivePadding(for: content)
        let inset = background.inset
        let card = CGSize(width: content.width + inset * 2, height: content.height + inset * 2)
        var output = CGSize(width: card.width + padding * 2, height: card.height + padding * 2)
        if let ratio = background.ratio.value {
            if output.width / output.height < ratio {
                output.width = (output.height * ratio).rounded()
            } else {
                output.height = (output.width / ratio).rounded()
            }
        }
        let slackX = output.width - card.width - padding * 2
        let slackY = output.height - card.height - padding * 2
        let origin = CGPoint(x: (padding + slackX * background.alignment.horizontal).rounded(),
                             y: (padding + slackY * background.alignment.vertical).rounded())
        let cardRect = CGRect(origin: origin, size: card)
        return OutputLayout(size: output, card: cardRect, image: cardRect.insetBy(dx: inset, dy: inset))
    }

    var outputSize: CGSize { layout.size }

    /// Offset from output space to image space: image point p draws at p + contentOffset.
    var contentOffset: CGPoint {
        let image = layout.image
        return CGPoint(x: image.minX - contentRect.minX, y: image.minY - contentRect.minY)
    }

    func annotation(id: UUID) -> Annotation? {
        annotations.first { $0.id == id }
    }

    mutating func update(_ annotation: Annotation) {
        if let index = annotations.firstIndex(where: { $0.id == annotation.id }) {
            annotations[index] = annotation
        }
    }

    mutating func remove(id: UUID) {
        annotations.removeAll { $0.id == id }
    }
}
