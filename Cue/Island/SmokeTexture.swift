import AppKit

/// A seamless tile of smoke: value noise layered into fractal noise and warped by
/// itself twice (domain warping), which turns soft blobs into curling wisps; the
/// density is then coloured from a dark shade through the main colour to a glow.
/// Every noise layer repeats across the tile, so tiles join without a seam and
/// the smoke can slide forever. Made once per palette, off the main thread.
nonisolated enum SmokeTexture {
    struct Palette: Hashable, Sendable {
        /// RGB in 0…1: the thin edges, the body, and the brightest folds.
        let deep: SIMD3<Float>
        let body: SIMD3<Float>
        let glow: SIMD3<Float>
    }

    static let size = 256

    private static let cache = Cache()

    /// The tile, if it has been made; otherwise starts making it and calls `ready`
    /// on the main queue when it is.
    static func image(for palette: Palette, ready: @escaping @MainActor @Sendable () -> Void) -> NSImage? {
        if let image = cache.image(for: palette) { return image }
        guard cache.begin(palette) else { return nil }
        DispatchQueue.global(qos: .userInitiated).async {
            let image = render(palette)
            cache.store(image, for: palette)
            DispatchQueue.main.async { MainActor.assumeIsolated { ready() } }
        }
        return nil
    }

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var images: [Palette: NSImage] = [:]
        private var pending: Set<Palette> = []

        func image(for palette: Palette) -> NSImage? {
            lock.withLock { images[palette] }
        }

        func begin(_ palette: Palette) -> Bool {
            lock.withLock { pending.insert(palette).inserted }
        }

        func store(_ image: NSImage, for palette: Palette) {
            lock.withLock {
                images[palette] = image
                pending.remove(palette)
            }
        }
    }

    // MARK: Noise

    /// The lattice repeats every `period` cells, so the noise tiles.
    private static func hash(_ x: Int, _ y: Int, period: Int) -> Float {
        let px = ((x % period) + period) % period
        let py = ((y % period) + period) % period
        var h = UInt32(truncatingIfNeeded: px &* 374_761_393 &+ py &* 668_265_263)
        h = (h ^ (h >> 13)) &* 1_274_126_177
        h ^= h >> 16
        return Float(h & 0xFFFF) / 65_535
    }

    private static func noise(_ x: Float, _ y: Float, period: Int) -> Float {
        let ix = Int(floor(x)), iy = Int(floor(y))
        let fx = x - floor(x), fy = y - floor(y)
        let ux = fx * fx * (3 - 2 * fx), uy = fy * fy * (3 - 2 * fy)
        let a = hash(ix, iy, period: period), b = hash(ix + 1, iy, period: period)
        let c = hash(ix, iy + 1, period: period), d = hash(ix + 1, iy + 1, period: period)
        return (a + (b - a) * ux) + ((c + (d - c) * ux) - (a + (b - a) * ux)) * uy
    }

    /// Fractal noise over `x, y` in tile units (0…1 is one tile).
    private static func fbm(_ x: Float, _ y: Float) -> Float {
        var value: Float = 0
        var amplitude: Float = 0.5
        var period = 2
        for _ in 0..<4 {
            value += amplitude * noise(x * Float(period), y * Float(period), period: period)
            period *= 2
            amplitude *= 0.5
        }
        return value
    }

    // MARK: Rendering

    private static func render(_ palette: Palette) -> NSImage {
        let side = size
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        for row in 0..<side {
            for column in 0..<side {
                let x = Float(column) / Float(side), y = Float(row) / Float(side)
                // fbm repeats every tile, so everything built from it does too.
                let qx = fbm(x, y), qy = fbm(x + 0.31, y + 0.57)
                let rx = fbm(x + 0.5 * qx + 0.17, y + 0.5 * qy + 0.92)
                let ry = fbm(x + 0.5 * qx + 0.83, y + 0.5 * qy + 0.28)
                let f = fbm(x + 0.45 * rx, y + 0.45 * ry)

                let mixBody = min(max((f - 0.3) * 2.2, 0), 1)
                var color = palette.deep + (palette.body - palette.deep) * mixBody
                color += (palette.glow - color) * min(max((f - 0.55) * 2.5, 0), 1) * 0.6
                // A soft haze: never fully clear, never solid, no edges.
                let t = min(max((f - 0.22) / 0.6, 0), 1)
                let density = 0.25 + 0.75 * t * t * (3 - 2 * t)

                let index = (row * side + column) * 4
                pixels[index] = UInt8(min(color.x * density, 1) * 255)
                pixels[index + 1] = UInt8(min(color.y * density, 1) * 255)
                pixels[index + 2] = UInt8(min(color.z * density, 1) * 255)
                pixels[index + 3] = UInt8(density * 255)
            }
        }
        let data = Data(pixels) as CFData
        guard let provider = CGDataProvider(data: data),
              let image = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return NSImage() }
        return NSImage(cgImage: image, size: NSSize(width: side, height: side))
    }
}
