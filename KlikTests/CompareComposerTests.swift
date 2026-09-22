import CoreGraphics
import XCTest

/// The comparison sheet: how pieces are placed, which way it lays them out, and what
/// comes back out the other end.
final class CompareComposerTests: XCTestCase {
    private func image(_ width: Int, _ height: Int, gray: CGFloat = 0.5) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private func piece(_ width: Int, _ height: Int, scale: CGFloat = 1) -> CompareComposer.Piece {
        CompareComposer.Piece(image: image(width, height), scale: scale)
    }

    // MARK: - Layout

    func testSideBySidePlacesPiecesInOrderWithAGap() {
        let layout = CompareComposer.layout([piece(200, 100), piece(200, 100)], axis: .horizontal, gap: 20)
        XCTAssertEqual(layout.size, CGSize(width: 420, height: 100))
        XCTAssertEqual(layout.rects[0], CGRect(x: 0, y: 0, width: 200, height: 100))
        XCTAssertEqual(layout.rects[1], CGRect(x: 220, y: 0, width: 200, height: 100))
    }

    func testStackedPutsTheFirstPieceOnTop() {
        let layout = CompareComposer.layout([piece(100, 50), piece(100, 50)], axis: .vertical, gap: 10)
        XCTAssertEqual(layout.size, CGSize(width: 100, height: 110))
        // The context's origin is bottom-left, so the first piece has the higher y.
        XCTAssertEqual(layout.rects[0].minY, 60)
        XCTAssertEqual(layout.rects[1].minY, 0)
    }

    func testPiecesAreScaledToShareTheCrossAxis() {
        let layout = CompareComposer.layout([piece(400, 200), piece(100, 200)], axis: .horizontal, gap: 0)
        XCTAssertEqual(layout.size.height, 200)
        XCTAssertEqual(layout.rects[0].size, CGSize(width: 400, height: 200))
        XCTAssertEqual(layout.rects[1].size, CGSize(width: 100, height: 200))

        // The smaller one is scaled up to the tallest piece, keeping its ratio.
        let mixed = CompareComposer.layout([piece(400, 200), piece(50, 100)], axis: .horizontal, gap: 0)
        XCTAssertEqual(mixed.rects[1].size, CGSize(width: 100, height: 200))
    }

    func testATinyPieceIsNotBlownUpPastTheLimitAndIsCentred() {
        let layout = CompareComposer.layout([piece(400, 200), piece(20, 20)], axis: .horizontal, gap: 0)
        // 10× would be needed to match the row; it stops at 2×.
        XCTAssertEqual(layout.rects[1].size, CGSize(width: 40, height: 40))
        XCTAssertEqual(layout.rects[1].minY, 80)
        XCTAssertEqual(layout.size, CGSize(width: 440, height: 200))
    }

    // MARK: - Axis

    func testAutoPutsPortraitPiecesSideBySide() {
        XCTAssertEqual(CompareComposer.resolvedAxis(.auto, for: [piece(400, 900), piece(400, 900)]), .horizontal)
    }

    func testAutoStacksWidePieces() {
        XCTAssertEqual(CompareComposer.resolvedAxis(.auto, for: [piece(2560, 800), piece(2560, 800)]), .vertical)
    }

    func testAnExplicitAxisIsKept() {
        XCTAssertEqual(CompareComposer.resolvedAxis(.vertical, for: [piece(400, 900), piece(400, 900)]), .vertical)
    }

    // MARK: - Composing

    func testComposedSizeMatchesTheLayout() {
        let composed = CompareComposer.compose([piece(300, 600), piece(300, 600)], axis: .horizontal, gap: 10)
        XCTAssertEqual(composed?.cgImage.width, 610)
        XCTAssertEqual(composed?.cgImage.height, 600)
        XCTAssertEqual(composed?.scale, 1)
    }

    func testTheDensestPieceSetsTheScaleAndItsPixelsAreKept() {
        let composed = CompareComposer.compose([piece(1000, 800, scale: 2), piece(250, 200, scale: 1)], axis: .horizontal, gap: 0)
        XCTAssertEqual(composed?.scale, 2)
        XCTAssertEqual(composed?.cgImage.height, 800)
        // 1000 px + the smaller piece, blown up 2× (its limit) rather than the 4× the row asks for.
        XCTAssertEqual(composed?.cgImage.width, 1500)
    }

    func testASinglePieceComesBackUnchanged() {
        let only = piece(120, 90, scale: 2)
        let composed = CompareComposer.compose([only])
        XCTAssertEqual(composed?.cgImage.width, 120)
        XCTAssertEqual(composed?.cgImage.height, 90)
        XCTAssertEqual(composed?.scale, 2)
    }

    func testNothingToComposeIsNil() {
        XCTAssertNil(CompareComposer.compose([]))
    }

    func testAnEnormousSheetIsScaledDownWhole() {
        let composed = CompareComposer.compose([piece(9000, 4000), piece(9000, 4000)], axis: .horizontal, gap: 0)
        let width = CGFloat(composed?.cgImage.width ?? 0)
        let height = CGFloat(composed?.cgImage.height ?? 0)
        XCTAssertLessThanOrEqual(width, CompareComposer.maxPixels)
        // Two 9000 × 4000 pieces side by side is 18000 × 4000; scaled to fit, the ratio survives.
        XCTAssertEqual(width / height, 18000.0 / 4000.0, accuracy: 0.01)
    }
}
