import ImageIO
import PDFKit
import XCTest

/// Transform's actions, each on a picture made for the test.
final class TransformEngineTests: XCTestCase {
    private var folder: URL!

    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A noisy 1200 × 800 JPEG (noise so compression has something to do), with a GPS tag.
    private func picture(width: Int = 1200, height: Int = 800) -> URL {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<4000 {
            context.setFillColor(red: .random(in: 0...1, using: &generator), green: .random(in: 0...1, using: &generator),
                                 blue: .random(in: 0...1, using: &generator), alpha: 1)
            context.fill(CGRect(x: .random(in: 0..<CGFloat(width)), y: .random(in: 0..<CGFloat(height)), width: 24, height: 24))
        }
        let url = folder.appendingPathComponent("photo.jpg")
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)!
        let gps: [CFString: Any] = [kCGImagePropertyGPSLatitude: 23.8, kCGImagePropertyGPSLatitudeRef: "N",
                                    kCGImagePropertyGPSLongitude: 90.4, kCGImagePropertyGPSLongitudeRef: "E"]
        CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 1.0,
                                                                       kCGImagePropertyGPSDictionary: gps] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func size(of url: URL) -> (Int, Int) {
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
        let size = TransformEngine.pixelSize(source)!
        return (size.width, size.height)
    }

    func testCompressByQualityMakesItSmaller() throws {
        let url = picture()
        var options = TransformEngine.CompressOptions()
        options.quality = 0.4
        let made = try XCTUnwrap(TransformEngine.compress(url, options, into: folder))
        XCTAssertLessThan(TransformEngine.fileSize(made), TransformEngine.fileSize(url))
    }

    func testCompressByFileSizeStaysUnderTheTarget() throws {
        let url = picture()
        var options = TransformEngine.CompressOptions()
        options.by = .fileSize
        options.targetBytes = 120_000
        let (data, _) = try XCTUnwrap(TransformEngine.compressed(url, options))
        XCTAssertLessThanOrEqual(data.count, 120_000)
    }

    func testResizeKeepsTheLongestSide() throws {
        let made = try XCTUnwrap(TransformEngine.resize(picture(), .init(by: .side, maxSide: 600), into: folder))
        let (width, height) = size(of: made)
        XCTAssertEqual(max(width, height), 600)
        XCTAssertEqual(height, 400)
    }

    func testRotateAQuarterTurnSwapsTheSides() throws {
        let made = try XCTUnwrap(TransformEngine.rotate(picture(), .init(quarterTurns: 1), into: folder))
        let (width, height) = size(of: made)
        XCTAssertEqual(width, 800)
        XCTAssertEqual(height, 1200)
    }

    func testRemoveMetadataTakesOutTheLocation() throws {
        let url = picture()
        let before = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, nil) as? [CFString: Any]
        XCTAssertNotNil(before?[kCGImagePropertyGPSDictionary])
        let made = try XCTUnwrap(TransformEngine.removeMetadata(url, into: folder))
        let after = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(made as CFURL, nil)!, 0, nil) as? [CFString: Any]
        XCTAssertNil(after?[kCGImagePropertyGPSDictionary])
    }

    func testCombineMakesOnePageAPicture() throws {
        let first = picture()
        let second = folder.appendingPathComponent("second.jpg")
        try FileManager.default.copyItem(at: first, to: second)
        let made = try XCTUnwrap(TransformEngine.combine([first, second], named: "Both", into: folder))
        XCTAssertEqual(made.lastPathComponent, "Both.pdf")
        XCTAssertEqual(PDFDocument(url: made)?.pageCount, 2)
    }

    func testConvertToAVIF() throws {
        try XCTSkipUnless(TransformEngine.Format.available.contains(.avif), "This Mac can't write AVIF")
        let made = try XCTUnwrap(TransformEngine.convert(picture(), to: .avif, quality: 0.6, into: folder))
        XCTAssertEqual(made.pathExtension, "avif")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(made as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.avif")
    }

    func testRenameNumbersTheFiles() {
        let urls = [URL(fileURLWithPath: "/a/one.jpg"), URL(fileURLWithPath: "/a/two.png")]
        XCTAssertEqual(TransformEngine.newNames(for: urls, .init(base: "Trip", numbered: true, start: 1)), ["Trip 1.jpg", "Trip 2.png"])
        XCTAssertEqual(TransformEngine.newNames(for: [urls[0]], .init(base: "Cover", numbered: false, start: 1)), ["Cover.jpg"])
    }
}
