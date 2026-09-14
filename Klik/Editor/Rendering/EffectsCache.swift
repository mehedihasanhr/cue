import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics

/// Renders blur / pixelate regions from the base image. Results are cached per
/// annotation geometry so dragging other things doesn't re-run Core Image.
final class EffectsCache {
    private struct Key: Hashable {
        let rect: CGRect
        let kind: BlurKind
        let intensity: CGFloat
    }

    private var cache: [Key: CGImage] = [:]
    private let context = CIContext(options: [.cacheIntermediates: false])

    func invalidate() {
        cache.removeAll()
    }

    // MARK: - Edge colour

    private var edgeColors: [ObjectIdentifier: CGColor] = [:]

    /// Average colour of the image's outer border, so an inset frame blends with it.
    func edgeColor(of image: CGImage) -> CGColor {
        let key = ObjectIdentifier(image)
        if let cached = edgeColors[key] { return cached }
        let side = 32
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return CGColor(gray: 1, alpha: 1) }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = ctx.data else { return CGColor(gray: 1, alpha: 1) }
        let pixels = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        var r = 0, g = 0, b = 0, n = 0
        for y in 0..<side {
            for x in 0..<side where x == 0 || y == 0 || x == side - 1 || y == side - 1 {
                let i = (y * side + x) * 4
                r += Int(pixels[i]); g += Int(pixels[i + 1]); b += Int(pixels[i + 2]); n += 1
            }
        }
        let color = CGColor(red: CGFloat(r) / CGFloat(n * 255), green: CGFloat(g) / CGFloat(n * 255),
                            blue: CGFloat(b) / CGFloat(n * 255), alpha: 1)
        edgeColors[key] = color
        return color
    }

    // MARK: - Wallpapers

    private struct WallpaperKey: Hashable {
        let wallpaper: Wallpaper
        let blur: CGFloat
    }

    private var wallpapers: [WallpaperKey: CGImage] = [:]

    /// A background picture, optionally softened with a Gaussian blur (cached per blur amount).
    func wallpaper(_ wallpaper: Wallpaper, blur: CGFloat) -> CGImage? {
        let key = WallpaperKey(wallpaper: wallpaper, blur: blur.rounded())
        if let cached = wallpapers[key] { return cached }
        guard let base = WallpaperStore.shared.image(for: wallpaper) else { return nil }
        guard blur >= 1 else {
            wallpapers[key] = base
            return base
        }
        let source = CIImage(cgImage: base)
        let filter = CIFilter.gaussianBlur()
        filter.inputImage = source.clampedToExtent()
        filter.radius = Float(blur * 2)
        guard let output = filter.outputImage?.cropped(to: source.extent),
              let image = context.createCGImage(output, from: source.extent)
        else { return base }
        wallpapers[key] = image
        return image
    }

    /// The effect applied to `rect` (image points) of `base`, as a pixel-sized image.
    func image(for rect: CGRect, kind: BlurKind, intensity: CGFloat, base: CGImage, scale: CGFloat) -> CGImage? {
        let key = Key(rect: rect, kind: kind, intensity: intensity)
        if let cached = cache[key] { return cached }

        let pixelRect = CGRect(
            x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale
        ).integral.intersection(CGRect(x: 0, y: 0, width: base.width, height: base.height))
        guard !pixelRect.isEmpty else { return nil }

        // CIImage coordinates are y-up; flip the region.
        let ciRect = CGRect(
            x: pixelRect.minX, y: CGFloat(base.height) - pixelRect.maxY,
            width: pixelRect.width, height: pixelRect.height
        )
        let source = CIImage(cgImage: base)
        let output: CIImage
        switch kind {
        case .blur:
            let filter = CIFilter.gaussianBlur()
            filter.inputImage = source.cropped(to: ciRect).clampedToExtent()
            filter.radius = Float(max(2, intensity * scale))
            output = filter.outputImage?.cropped(to: ciRect) ?? source.cropped(to: ciRect)
        case .pixelate:
            let filter = CIFilter.pixellate()
            filter.inputImage = source.cropped(to: ciRect).clampedToExtent()
            filter.scale = Float(max(4, intensity * scale))
            filter.center = CGPoint(x: ciRect.minX, y: ciRect.minY)
            output = filter.outputImage?.cropped(to: ciRect) ?? source.cropped(to: ciRect)
        }
        guard let rendered = context.createCGImage(output, from: ciRect) else { return nil }
        cache[key] = rendered
        return rendered
    }
}
