import CoreGraphics
import ImageIO
import WebPKit
import XCTest

final class WebPTests: XCTestCase {
    /// A 64 × 48 image, half red and half see-through blue.
    private func sample() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 48))
        context.setFillColor(red: 0, green: 0, blue: 1, alpha: 0.5)
        context.fill(CGRect(x: 32, y: 0, width: 32, height: 48))
        return try XCTUnwrap(context.makeImage())
    }

    /// What ImageIO reads back: the WebP is a real one, the right size.
    private func decoded(_ data: Data) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "org.webmproject.webp")
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    func testLossyRoundTrips() throws {
        let data = try XCTUnwrap(WebP.encode(try sample(), quality: 0.8))
        XCTAssertEqual(data.prefix(4), Data("RIFF".utf8))
        let image = try decoded(data)
        XCTAssertEqual(image.width, 64)
        XCTAssertEqual(image.height, 48)
    }

    func testLosslessKeepsTransparency() throws {
        let image = try decoded(try XCTUnwrap(WebP.encode(try sample(), lossless: true)))
        XCTAssertEqual(image.width, 64)
        XCTAssertNotEqual(image.alphaInfo, .none)
    }
}
