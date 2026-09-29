import Accelerate
import CoreGraphics
import CoreImage
import Foundation

/// One frame as brightness alone, top-left origin, 0…255 — what following a mask looks at.
///
/// Brightness because colour adds nothing to *where* something is on a screen and triples
/// the work; floats because every comparison below is a `vDSP` call over a row, which is
/// what keeps following fast in a debug build as well as a release one.
struct LumaPlane: Sendable {
    let width: Int
    let height: Int
    var pixels: [Float]

    init(width: Int, height: Int, pixels: [Float]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// A frame drawn at `scale` of its size.
    ///
    /// Brightness by the Rec. 601 weights, worked out before rendering so the one channel
    /// written is the grey itself, whatever a one-channel format would otherwise take.
    init?(_ image: CIImage, scale: CGFloat, context: CIContext) {
        let extent = image.extent
        guard extent.width >= 1, extent.height >= 1, extent.width.isFinite, extent.height.isFinite else { return nil }
        let width = max(1, Int((extent.width * scale).rounded()))
        let height = max(1, Int((extent.height * scale).rounded()))
        let grey = CIVector(x: 0.299, y: 0.587, z: 0.114, w: 0)
        let placed = image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(width) / extent.width,
                                               y: CGFloat(height) / extent.height))
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": grey, "inputGVector": grey, "inputBVector": grey,
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ])
        var bytes = [UInt8](repeating: 0, count: width * height)
        bytes.withUnsafeMutableBytes { raw in
            // A bitmap's first row is the top of the picture, which is the model's
            // convention for a mask's rect — so nothing below has to flip.
            context.render(placed, toBitmap: raw.baseAddress!, rowBytes: width,
                           bounds: CGRect(x: 0, y: 0, width: width, height: height),
                           format: .L8, colorSpace: nil)
        }
        var floats = [Float](repeating: 0, count: width * height)
        vDSP.convertElements(of: bytes, to: &floats)
        self.init(width: width, height: height, pixels: floats)
    }

    var bounds: PixelRect { PixelRect(x: 0, y: 0, width: width, height: height) }

    /// The pixels under `rect`, which must lie inside the plane.
    func patch(_ rect: PixelRect) -> LumaPatch {
        var out = [Float](repeating: 0, count: rect.width * rect.height)
        pixels.withUnsafeBufferPointer { source in
            out.withUnsafeMutableBufferPointer { target in
                for row in 0..<rect.height {
                    let from = (rect.y + row) * width + rect.x
                    for column in 0..<rect.width { target[row * rect.width + column] = source[from + column] }
                }
            }
        }
        return LumaPatch(width: rect.width, height: rect.height, pixels: out)
    }

    /// `rect` as an eight-bit grey image, for Vision.
    func image(_ rect: PixelRect) -> CGImage? {
        guard let rect = rect.clipped(to: bounds), rect.width >= 8, rect.height >= 8 else { return nil }
        let patch = self.patch(rect)
        var bytes = [UInt8](repeating: 0, count: patch.pixels.count)
        vDSP.convertElements(of: patch.pixels, to: &bytes, rounding: .towardNearestInteger)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: rect.width, height: rect.height, bitsPerComponent: 8, bitsPerPixel: 8,
                       bytesPerRow: rect.width, space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// The plane at a whole fraction of its size, each pixel the average of the block it
    /// stands for — so a coarse search still sees text as texture rather than as aliasing.
    func reduced(by factor: Int) -> LumaPlane {
        guard factor > 1 else { return self }
        let w = width / factor, h = height / factor
        guard w > 0, h > 0 else { return self }
        var out = [Float](repeating: 0, count: w * h)
        let scale = 1 / Float(factor * factor)
        pixels.withUnsafeBufferPointer { source in
            for y in 0..<h {
                for x in 0..<w {
                    var sum: Float = 0
                    for dy in 0..<factor {
                        let row = (y * factor + dy) * width + x * factor
                        for dx in 0..<factor { sum += source[row + dx] }
                    }
                    out[y * w + x] = sum * scale
                }
            }
        }
        return LumaPlane(width: w, height: h, pixels: out)
    }

    /// The mean absolute difference between `patch` and the plane with the patch's
    /// top-left at `origin`, over the part of the patch that is inside the plane.
    ///
    /// `nil` when less than `minimumVisible` of the patch is inside — too little of it
    /// left to say whether it matches. Every `rowStep`th row is compared: a mask's worth
    /// of rows says the same thing at half of them, and the search asks this dozens of
    /// times a frame.
    func difference(_ patch: LumaPatch, at origin: (x: Int, y: Int), rowStep: Int = 1,
                    minimumVisible: Double = 1) -> Float? {
        let x0 = max(0, origin.x), y0 = max(0, origin.y)
        let x1 = min(width, origin.x + patch.width), y1 = min(height, origin.y + patch.height)
        let columns = x1 - x0, rows = y1 - y0
        guard columns > 0, rows > 0,
              Double(columns * rows) >= minimumVisible * Double(patch.width * patch.height) - 0.5 else { return nil }
        let step = max(1, rowStep)
        var total: Float = 0
        var counted = 0
        var scratch = [Float](repeating: 0, count: columns)
        pixels.withUnsafeBufferPointer { plane in
            patch.pixels.withUnsafeBufferPointer { template in
                scratch.withUnsafeMutableBufferPointer { diff in
                    var y = y0
                    while y < y1 {
                        let planeRow = plane.baseAddress! + y * width + x0
                        let templateRow = template.baseAddress! + (y - origin.y) * patch.width + (x0 - origin.x)
                        vDSP_vsub(templateRow, 1, planeRow, 1, diff.baseAddress!, 1, vDSP_Length(columns))
                        var sum: Float = 0
                        vDSP_svemg(diff.baseAddress!, 1, &sum, vDSP_Length(columns))
                        total += sum
                        counted += columns
                        y += step
                    }
                }
            }
        }
        return counted > 0 ? total / Float(counted) : nil
    }
}

/// A patch of a `LumaPlane`: what is being followed.
struct LumaPatch: Sendable {
    let width: Int
    let height: Int
    let pixels: [Float]

    /// How much there is in it to recognise: the standard deviation of its brightness.
    var texture: Float {
        guard !pixels.isEmpty else { return 0 }
        var mean: Float = 0
        var deviation: Float = 0
        vDSP_normalize(pixels, 1, nil, 1, &mean, &deviation, vDSP_Length(pixels.count))
        return deviation
    }

    func reduced(by factor: Int) -> LumaPatch {
        let plane = LumaPlane(width: width, height: height, pixels: pixels).reduced(by: factor)
        return LumaPatch(width: plane.width, height: plane.height, pixels: plane.pixels)
    }
}

/// A rectangle in whole pixels of a `LumaPlane`, top-left origin. May hang off the plane.
struct PixelRect: Equatable, Sendable {
    var x: Int
    var y: Int
    var width: Int
    var height: Int

    func offset(_ dx: Int, _ dy: Int) -> PixelRect {
        PixelRect(x: x + dx, y: y + dy, width: width, height: height)
    }

    func isInside(_ bounds: PixelRect) -> Bool {
        x >= bounds.x && y >= bounds.y && x + width <= bounds.x + bounds.width && y + height <= bounds.y + bounds.height
    }

    func clipped(to bounds: PixelRect) -> PixelRect? {
        let x0 = max(x, bounds.x), y0 = max(y, bounds.y)
        let x1 = min(x + width, bounds.x + bounds.width), y1 = min(y + height, bounds.y + bounds.height)
        guard x1 > x0, y1 > y0 else { return nil }
        return PixelRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}
