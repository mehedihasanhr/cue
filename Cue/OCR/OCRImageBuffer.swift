import CoreGraphics
import Foundation

/// An 8-bit grayscale raster, ready to hand to Tesseract.
///
/// Grayscale rather than colour on purpose: Tesseract converts to gray immediately
/// anyway, one byte per pixel is a quarter of the copying, and it avoids the 32-bit
/// path's byte-order trap, where the wrong channel order silently produces plausible
/// nonsense instead of an error.
nonisolated struct OCRImageBuffer: Sendable {
    var pixels: [UInt8]
    var width: Int
    var height: Int
    /// CoreGraphics pads rows for alignment, so this is usually larger than `width`.
    /// It is what Tesseract must be given as `bytes_per_line`; passing `width` against
    /// a padded stride shears the image diagonally and yields gibberish.
    var bytesPerRow: Int
    /// How much the source was enlarged, so boxes can be mapped back.
    var scaleFactor: CGFloat

    /// Nothing is ever enlarged past this, however small it is.
    static let maximumUpscale: CGFloat = 3
    /// Nor past this many pixels; a 40 MP grayscale buffer is already 40 MB.
    static let maximumPixels = 40_000_000
    /// Below this, a region is assumed to hold small text worth enlarging.
    static let smallImageSide = 400
    static let mediumImageSide = 900

    /// Renders `image` for recognition: enlarged if it is small, flattened to gray,
    /// and contrast-stretched.
    static func make(from image: CGImage) -> OCRImageBuffer? {
        let sourceWidth = image.width, sourceHeight = image.height
        guard sourceWidth > 0, sourceHeight > 0 else { return nil }

        let factor = upscale(width: sourceWidth, height: sourceHeight)
        let width = Int((CGFloat(sourceWidth) * factor).rounded())
        let height = Int((CGFloat(sourceHeight) * factor).rounded())

        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        // A gray context has no alpha channel, so a transparent source — a window
        // capture with rounded corners, a dropped PNG — would composite onto zero and
        // come out as black text on black. Fill first.
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let data = context.data else { return nil }
        let bytesPerRow = context.bytesPerRow
        let count = bytesPerRow * height
        var pixels = [UInt8](UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: count))
        stretchContrast(&pixels, width: width, height: height, bytesPerRow: bytesPerRow)

        return OCRImageBuffer(pixels: pixels, width: width, height: height,
                              bytesPerRow: bytesPerRow, scaleFactor: factor)
    }

    /// Small regions get enlarged; a screenshot that is already large does not.
    ///
    /// Tesseract's line recogniser wants glyphs around 30 px tall and a crop of a
    /// non-Retina window can be half that. Measured on Bangla screenshots, enlarging
    /// made no difference to an already-crisp 2× capture, so this only lifts the
    /// cases that need it rather than quadrupling everything.
    static func upscale(width: Int, height: Int) -> CGFloat {
        guard width > 0, height > 0 else { return 1 }
        let shortest = min(width, height)
        var factor: CGFloat = 1
        if shortest < smallImageSide {
            factor = maximumUpscale
        } else if shortest < mediumImageSide {
            factor = 2
        }
        // Never past the pixel ceiling.
        let pixels = CGFloat(width) * CGFloat(height)
        if pixels * factor * factor > CGFloat(maximumPixels) {
            factor = max(1, (CGFloat(maximumPixels) / pixels).squareRoot())
        }
        return factor
    }

    /// Pulls the darkest and lightest 1% out to black and white, through a lookup
    /// table. It helps Tesseract's own thresholding find an edge on low-contrast UI
    /// text; a near-flat region is left alone rather than having its noise amplified
    /// into phantom letters.
    static func stretchContrast(_ pixels: inout [UInt8], width: Int, height: Int, bytesPerRow: Int) {
        guard width > 0, height > 0 else { return }
        var histogram = [Int](repeating: 0, count: 256)
        for row in 0..<height {
            let start = row * bytesPerRow
            for column in 0..<width { histogram[Int(pixels[start + column])] += 1 }
        }

        let total = width * height
        let tail = max(1, total / 100)
        var low = 0, high = 255, seen = 0
        for value in 0..<256 {
            seen += histogram[value]
            if seen >= tail { low = value; break }
        }
        seen = 0
        for value in stride(from: 255, through: 0, by: -1) {
            seen += histogram[value]
            if seen >= tail { high = value; break }
        }

        guard high - low >= 40 else { return }
        let span = CGFloat(high - low)
        let table: [UInt8] = (0..<256).map { value in
            let scaled = (CGFloat(value) - CGFloat(low)) / span * 255
            return UInt8(max(0, min(255, scaled.rounded())))
        }
        for row in 0..<height {
            let start = row * bytesPerRow
            for column in 0..<width {
                pixels[start + column] = table[Int(pixels[start + column])]
            }
        }
    }
}
