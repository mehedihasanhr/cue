import AppKit

/// Which way a comparison lays its images out.
enum CompareAxis: String, Codable, CaseIterable, Sendable {
    /// Side by side or stacked, whichever gives the more usable shape.
    case auto
    case horizontal
    case vertical

    var title: String {
        switch self {
        case .auto: "Auto"
        case .horizontal: "Side by Side"
        case .vertical: "Stacked"
        }
    }
}

/// Puts several images into one picture — a capture beside the mock-up it was built
/// from, two runs of the same screen, a before and an after. Every piece is scaled to
/// the same cross-axis size and keeps its aspect ratio; the gap between them is left
/// transparent, so a background added afterwards in the editor shows through.
nonisolated enum CompareComposer {
    struct Piece {
        var image: CGImage
        /// Pixels per point of that image.
        var scale: CGFloat

        init(image: CGImage, scale: CGFloat = 1) {
            self.image = image
            self.scale = max(scale, 0.01)
        }

        init(_ captured: CapturedImage) {
            self.init(image: captured.cgImage, scale: captured.scale)
        }

        var pixelSize: CGSize { CGSize(width: CGFloat(image.width), height: CGFloat(image.height)) }
    }

    /// The shape a comparison aims at when it picks its own axis: a little wider than
    /// tall, which is what a document, a chat and a pull request all read best.
    static let preferredAspect: CGFloat = 16 / 9
    /// Gap between pieces, in points of the output.
    static let defaultGap: CGFloat = 16
    /// Nothing is composed larger than this on either side; the whole sheet is scaled
    /// down to fit instead, so ten 5K captures still produce an image apps can open.
    static let maxPixels: CGFloat = 12_000
    /// How far a small piece is blown up to match the others. Past this it is centred
    /// in its slot instead: a 100 px icon beside a 4K screenshot stays an icon rather
    /// than a wall of mush.
    static let maxUpscale: CGFloat = 2

    /// The layout of one axis: where each piece lands, in pixels, and how big the
    /// result is. The origin is bottom-left, which is what `CGContext` draws in.
    struct Layout {
        var rects: [CGRect]
        var size: CGSize

        var aspect: CGFloat { size.height > 0 ? size.width / size.height : 1 }
    }

    /// Lays `pieces` out along `axis`. Pieces are scaled to share a cross-axis size —
    /// the largest one's, so the sharpest piece is never thrown away.
    static func layout(_ pieces: [Piece], axis: CompareAxis, gap: CGFloat) -> Layout {
        let horizontal = axis != .vertical
        let sizes = pieces.map(\.pixelSize)
        let cross = sizes.map { horizontal ? $0.height : $0.width }.max() ?? 0
        guard cross > 0 else { return Layout(rects: [], size: .zero) }

        var scaled: [CGSize] = []
        for size in sizes {
            let fit = horizontal ? cross / max(size.height, 1) : cross / max(size.width, 1)
            let factor = min(fit, maxUpscale)
            scaled.append(CGSize(width: (size.width * factor).rounded(), height: (size.height * factor).rounded()))
        }
        let along = scaled.reduce(0) { $0 + (horizontal ? $1.width : $1.height) } + gap * CGFloat(max(0, pieces.count - 1))
        let total = horizontal ? CGSize(width: along, height: cross) : CGSize(width: cross, height: along)

        var rects: [CGRect] = []
        var cursor: CGFloat = 0
        for size in scaled {
            if horizontal {
                // A piece that stayed smaller than the row is centred in its slot.
                rects.append(CGRect(x: cursor, y: ((cross - size.height) / 2).rounded(), width: size.width, height: size.height))
                cursor += size.width + gap
            } else {
                // Top-down reading order: the first piece sits at the top of the sheet,
                // and the context's origin is at the bottom.
                rects.append(CGRect(x: ((cross - size.width) / 2).rounded(),
                                    y: total.height - cursor - size.height, width: size.width, height: size.height))
                cursor += size.height + gap
            }
        }
        return Layout(rects: rects, size: total)
    }

    /// The axis `auto` resolves to: whichever layout comes out closer to
    /// `preferredAspect`. Portrait pieces end up side by side, wide ones stacked.
    static func resolvedAxis(_ axis: CompareAxis, for pieces: [Piece], gap: CGFloat = defaultGap) -> CompareAxis {
        guard axis == .auto else { return axis }
        let horizontal = layout(pieces, axis: .horizontal, gap: gap)
        let vertical = layout(pieces, axis: .vertical, gap: gap)
        guard horizontal.size.height > 0, vertical.size.height > 0 else { return .horizontal }
        func distance(_ layout: Layout) -> CGFloat { abs(log(max(layout.aspect, 0.0001) / preferredAspect)) }
        return distance(horizontal) <= distance(vertical) ? .horizontal : .vertical
    }

    /// One image holding them all. `nil` only if there is nothing to draw or the
    /// bitmap cannot be made. A single piece comes back unchanged.
    static func compose(_ pieces: [Piece], axis: CompareAxis = .auto, gap: CGFloat = defaultGap,
                        capturedAt: Date = .now) -> CapturedImage? {
        let pieces = pieces.filter { $0.image.width > 0 && $0.image.height > 0 }
        guard let first = pieces.first else { return nil }
        guard pieces.count > 1 else {
            return CapturedImage(cgImage: first.image, scale: first.scale, displayID: 0, capturedAt: capturedAt)
        }

        // The output keeps the density of the piece that set the cross-axis size, so
        // its pixels map 1:1 and the point size stays meaningful in the editor.
        let resolved = resolvedAxis(axis, for: pieces, gap: gap)
        let horizontal = resolved == .horizontal
        let leader = pieces.max { a, b in
            (horizontal ? a.pixelSize.height : a.pixelSize.width) < (horizontal ? b.pixelSize.height : b.pixelSize.width)
        } ?? first
        let scale = leader.scale

        var plan = layout(pieces, axis: resolved, gap: (gap * scale).rounded())
        // Something enormous is scaled down whole rather than refused.
        let overshoot = max(plan.size.width, plan.size.height) / maxPixels
        if overshoot > 1 {
            let factor = 1 / overshoot
            plan = Layout(rects: plan.rects.map { $0.applying(CGAffineTransform(scaleX: factor, y: factor)) },
                          size: CGSize(width: (plan.size.width * factor).rounded(), height: (plan.size.height * factor).rounded()))
        }

        let width = Int(plan.size.width.rounded()), height = Int(plan.size.height.rounded())
        guard width > 0, height > 0, plan.rects.count == pieces.count,
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              )
        else { return nil }

        context.interpolationQuality = .high
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        for (piece, rect) in zip(pieces, plan.rects) {
            context.draw(piece.image, in: rect)
        }
        guard let image = context.makeImage() else { return nil }
        return CapturedImage(cgImage: image, scale: scale, displayID: 0, capturedAt: capturedAt)
    }
}
