import AppKit
import XCTest

/// The copy path promises data and encodes in the background; a paste must still get
/// the right bytes whenever it happens — immediately, later, or at quit.
@MainActor
final class ClipboardTests: XCTestCase {
    private let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.stackrover.klik.tests"))

    override func tearDown() {
        pasteboard.releaseGlobally()
    }

    func testCopyReturnsImmediatelyAndPasteGetsThePNG() throws {
        let image = Self.image(width: 1600, height: 1200)
        let started = Date()
        Clipboard.copy(image, to: pasteboard)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.05, "copy must not wait for encoding")

        XCTAssertEqual(pasteboard.types?.contains(.png), true)
        XCTAssertEqual(pasteboard.types?.contains(.tiff), true)
        // Ask right away — before the background encode can have finished.
        let png = try XCTUnwrap(pasteboard.data(forType: .png))
        let decoded = try XCTUnwrap(NSImage(data: png)?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual(decoded.width, 1600)
        XCTAssertEqual(decoded.height, 1200)

        let tiff = try XCTUnwrap(pasteboard.data(forType: .tiff))
        XCTAssertEqual(NSBitmapImageRep(data: tiff)?.pixelsWide, 1600)
    }

    func testResolvePromisesLeavesConcreteData() throws {
        Clipboard.copy(Self.image(width: 64, height: 32), to: pasteboard)
        Clipboard.resolvePromises(on: pasteboard)
        let png = try XCTUnwrap(pasteboard.data(forType: .png))
        XCTAssertEqual(NSImage(data: png)?.cgImage(forProposedRect: nil, context: nil, hints: nil)?.width, 64)
    }

    func testResolvePromisesIgnoresAStaleCopy() {
        Clipboard.copy(Self.image(width: 64, height: 32), to: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("something else", forType: .string)
        Clipboard.resolvePromises(on: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "something else")
        XCTAssertNil(pasteboard.data(forType: .png))
    }

    private static func image(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 1, green: 0.8, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
        return context.makeImage()!
    }
}
