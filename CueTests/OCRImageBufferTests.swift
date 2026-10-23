import AppKit
import XCTest

/// Preparing an image for Tesseract. Pure pixel work — no engine, no language pack.
final class OCRImageBufferTests: XCTestCase {
    private func image(_ width: Int, _ height: Int, gray: CGFloat = 0.5, alpha: CGFloat = 1) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        context.setFillColor(CGColor(gray: gray, alpha: alpha))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    // MARK: - Shape

    /// CoreGraphics pads rows for alignment. Tesseract must be told the padded
    /// stride, not the width; handing it the width shears the image diagonally and
    /// the output is gibberish.
    func testTheStrideIsTheRealOneAndIsNeverSmallerThanTheWidth() throws {
        let buffer = try XCTUnwrap(OCRImageBuffer.make(from: image(1003, 700)))
        XCTAssertGreaterThanOrEqual(buffer.bytesPerRow, buffer.width)
        XCTAssertEqual(buffer.pixels.count, buffer.bytesPerRow * buffer.height)
    }

    func testASmallRegionIsEnlargedAndALargeOneIsNot() {
        // A cropped label: worth enlarging, because its glyphs are small.
        XCTAssertEqual(OCRImageBuffer.upscale(width: 300, height: 80), OCRImageBuffer.maximumUpscale)
        // A middling window.
        XCTAssertEqual(OCRImageBuffer.upscale(width: 1200, height: 600), 2)
        // A full Retina screen is already dense enough.
        XCTAssertEqual(OCRImageBuffer.upscale(width: 3024, height: 1890), 1)
    }

    func testNothingIsEnlargedPastThePixelCeiling() {
        let factor = OCRImageBuffer.upscale(width: 500, height: 400)
        let pixels = 500.0 * 400.0 * Double(factor * factor)
        XCTAssertLessThanOrEqual(pixels, Double(OCRImageBuffer.maximumPixels))
    }

    func testTheBufferMatchesTheScaleItReports() throws {
        let source = image(300, 80)
        let buffer = try XCTUnwrap(OCRImageBuffer.make(from: source))
        XCTAssertEqual(buffer.width, Int((300 * buffer.scaleFactor).rounded()))
        XCTAssertEqual(buffer.height, Int((80 * buffer.scaleFactor).rounded()))
    }

    func testAnEmptyImageIsRefusedRatherThanCrashing() {
        // A zero-sized CGImage cannot be made, so this stands in for the guard.
        XCTAssertEqual(OCRImageBuffer.upscale(width: 0, height: 0), 1)
    }

    // MARK: - Pixels

    /// A grayscale context has no alpha channel, so a transparent source — a window
    /// capture with rounded corners, a dropped PNG — would composite onto zero and
    /// arrive as black text on black. It has to be filled white first.
    func testATransparentSourceDoesNotComeOutBlack() throws {
        let transparent = image(1200, 800, gray: 0, alpha: 0)
        let buffer = try XCTUnwrap(OCRImageBuffer.make(from: transparent))
        let sample = buffer.pixels[buffer.bytesPerRow * (buffer.height / 2) + buffer.width / 2]
        XCTAssertEqual(sample, 255, "a fully transparent image should read as white, not black")
    }

    // MARK: - Contrast

    func testContrastIsStretchedToTheFullRange() {
        // A low-contrast gradient between 100 and 160.
        var pixels = (0..<256).map { UInt8(100 + ($0 * 60) / 255) }
        OCRImageBuffer.stretchContrast(&pixels, width: 256, height: 1, bytesPerRow: 256)
        XCTAssertEqual(pixels.first, 0)
        XCTAssertEqual(pixels.last, 255)
    }

    /// A near-flat region — a solid background, a blurred area — is left alone.
    /// Stretching it would turn its noise into phantom letters.
    func testANearlyFlatImageIsLeftAlone() {
        var pixels = [UInt8](repeating: 128, count: 256)
        pixels[10] = 140
        let before = pixels
        OCRImageBuffer.stretchContrast(&pixels, width: 256, height: 1, bytesPerRow: 256)
        XCTAssertEqual(pixels, before)
    }

    func testStretchingRespectsThePaddedStride() {
        // Two rows of 4 pixels in a buffer whose rows are 8 bytes wide; the padding
        // bytes must not be read as image data or counted in the histogram.
        var pixels: [UInt8] = [0, 60, 200, 255, 9, 9, 9, 9,
                               0, 60, 200, 255, 9, 9, 9, 9]
        OCRImageBuffer.stretchContrast(&pixels, width: 4, height: 2, bytesPerRow: 8)
        XCTAssertEqual(Array(pixels[4..<8]), [9, 9, 9, 9], "padding must be untouched")
        XCTAssertEqual(pixels[0], 0)
        XCTAssertEqual(pixels[3], 255)
    }
}
