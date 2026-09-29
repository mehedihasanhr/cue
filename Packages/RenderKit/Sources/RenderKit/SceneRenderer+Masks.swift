import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import TimelineKit

/// The two kinds of mask that are not a blur: the cover's shape, and the spotlight.
extension SceneRenderer {
    /// Dims everything in the picture that no spotlight is on.
    ///
    /// One pass for every spotlight in the frame rather than one per region, and that is
    /// the whole of the design: two spotlights are two clear areas in *one* dimmed
    /// picture, so their clear areas are added together first and the shade is laid
    /// down once with those holes in it. Applied one at a time, each would have dimmed
    /// the other's area — a second spotlight making the first one darker.
    ///
    /// Works in the recording's own pixels, before the crop and the camera, exactly as a
    /// blur does, so a spotlight stays on the thing it was put over when either moves.
    ///
    /// The feather falls *outside* the rectangle: the area that was drawn stays fully
    /// clear, and the shade fades in beyond its edge over about four times the
    /// softness. A feather centred on the edge would have dimmed the edge of the very
    /// thing being pointed at.
    func spotlit(_ image: CIImage, by layers: [BlurLayer]) -> CIImage {
        let spots = layers.filter { $0.style == .spotlight && $0.dimming > 0 }
        guard !spots.isEmpty else { return image }

        let extent = image.extent
        guard extent.width > 1, extent.height > 1 else { return image }
        let shorter = min(extent.width, extent.height)

        var holes: CIImage?
        for spot in spots {
            let rect = Self.pixelRect(spot.rect, in: extent)
            guard rect.width > 1, rect.height > 1 else { continue }
            let sigma = min(max(spot.softness, 0), 0.2) * shorter
            let radius = Self.cornerPixels(spot.cornerRadius, of: rect)
            // Grown by two sigma, so that once blurred the clear area is still clear
            // right up to the edge that was drawn.
            let grown = rect.insetBy(dx: -2 * sigma, dy: -2 * sigma)
            var hole = Self.roundedRectangle(grown, radius: radius > 0 ? radius + 2 * sigma : 0, color: .white)
            if sigma > 0.5 {
                hole = hole.applyingGaussianBlur(sigma: sigma)
            }
            // Source-over of two white shapes is their union: where either is clear, the
            // picture is clear.
            holes = holes.map { hole.composited(over: $0) } ?? hole
        }
        guard let holes else { return image }

        // The strongest dimming in the frame, once. Two spotlights asking for different
        // amounts cannot both be honoured in one picture, and the darker one is the one
        // somebody set on purpose.
        let dimming = min(1, spots.map(\.dimming).max() ?? 0)
        let shade = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: dimming)).cropped(to: extent)
        // Source-out keeps the shade only where the holes are transparent.
        let outside = shade.applyingFilter("CISourceOutCompositing", parameters: [
            kCIInputBackgroundImageKey: holes,
        ])
        return outside.composited(over: image).cropped(to: extent)
    }

    /// The obscured patch, cut to the region's rounded corners.
    ///
    /// A mask rather than a clip, so the corners are antialiased the way the frame's own
    /// corners are. Outside the rounded shape the patch is transparent, and the picture
    /// underneath shows through unchanged.
    func maskedToRoundedRectangle(_ patch: CIImage, _ rect: CGRect, cornerRadius: Double) -> CIImage {
        let radius = Self.cornerPixels(cornerRadius, of: rect)
        guard radius > 0.5 else { return patch }
        let mask = Self.roundedRectangle(rect, radius: radius, color: .white)
        let blend = CIFilter.blendWithMask()
        blend.inputImage = patch
        blend.maskImage = mask
        blend.backgroundImage = CIImage(color: .clear).cropped(to: rect)
        return (blend.outputImage ?? patch).cropped(to: rect)
    }

    /// A region's rectangle in the picture's own pixels, bottom-left origin.
    static func pixelRect(_ normalised: CGRect, in extent: CGRect) -> CGRect {
        CGRect(x: extent.minX + normalised.minX * extent.width,
               y: extent.minY + (1 - normalised.maxY) * extent.height,
               width: normalised.width * extent.width,
               height: normalised.height * extent.height)
    }

    /// A corner radius stored as a fraction of the region's shorter side, in pixels.
    static func cornerPixels(_ fraction: Double, of rect: CGRect) -> Double {
        let shorter = min(rect.width, rect.height)
        return min(max(fraction, 0), 0.5) * shorter
    }

    /// A filled rounded rectangle with an edge. Generators are infinite; the crop is
    /// what gives the shape its bounds. A radius of zero is a plain rectangle.
    static func roundedRectangle(_ rect: CGRect, radius: Double, color: CIColor) -> CIImage {
        guard radius > 0.5 else { return CIImage(color: color).cropped(to: rect) }
        let filter = CIFilter.roundedRectangleGenerator()
        filter.extent = rect
        filter.radius = Float(min(radius, min(rect.width, rect.height) / 2))
        filter.color = color
        return (filter.outputImage ?? CIImage(color: color)).cropped(to: rect)
    }
}
