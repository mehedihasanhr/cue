import AppKit
import XCTest

/// End-to-end recognition on images rendered in the test itself, so nothing depends
/// on files or services. Vision is fully on-device.
final class OCRServiceTests: XCTestCase {
    private let service = OCRService()

    func testRecognizesRenderedLines() async throws {
        let lines = ["Pizza Margherita", "1 kg tipo 00 flour", "800 g San Marzano tomatoes"]
        let image = Self.render(lines: lines, lineSpacing: 12)

        let result = try await service.recognize(image)

        XCTAssertFalse(result.isEmpty)
        for line in lines {
            XCTAssertTrue(result.text.contains(line), "Missing “\(line)” in:\n\(result.text)")
        }
        // Rendered top-to-bottom, so the composed text must keep that order.
        let first = try XCTUnwrap(result.text.range(of: lines[0]))
        let last = try XCTUnwrap(result.text.range(of: lines[2]))
        XCTAssertLessThan(first.lowerBound, last.lowerBound)
        XCTAssertGreaterThanOrEqual(result.text.components(separatedBy: "\n").count, 3, "lines should stay separate")
        XCTAssertEqual(result.items.count, lines.count)
        XCTAssertTrue(result.items.allSatisfy { CGRect(x: 0, y: 0, width: 1, height: 1).contains($0.boundingBox) })
    }

    func testWideGapBecomesParagraphBreak() async throws {
        let image = Self.render(lines: ["Pizza Margherita", "", "", "1 kg tipo 00 flour"], lineSpacing: 12)
        let result = try await service.recognize(image)
        XCTAssertTrue(result.text.contains("Pizza Margherita\n\n1 kg tipo 00 flour"), "Got:\n\(result.text)")
    }

    func testBlankImageYieldsNoText() async throws {
        let image = Self.render(lines: [], lineSpacing: 0)
        let result = try await service.recognize(image)
        XCTAssertTrue(result.isEmpty)
        XCTAssertTrue(result.items.isEmpty)
    }

    @MainActor
    func testCapturedImageConvenience() async throws {
        let cgImage = Self.render(lines: ["Hello Klik"], lineSpacing: 0)
        let captured = CapturedImage(cgImage: cgImage, scale: 2, displayID: 0, capturedAt: .now)
        let text = try await service.recognizeText(from: captured)
        XCTAssertTrue(text.contains("Hello Klik"))
        let items = try await service.recognizeTextWithBounds(from: captured)
        XCTAssertEqual(items.count, 1)
    }

    // MARK: - Helpers

    /// Black text on white at 2× so Vision sees crisp, screen-like glyphs.
    private static func render(lines: [String], lineSpacing: CGFloat) -> CGImage {
        let scale: CGFloat = 2
        let font = NSFont.systemFont(ofSize: 20, weight: .regular)
        let lineHeight = font.ascender - font.descender + lineSpacing
        let size = CGSize(width: 480, height: max(60, CGFloat(lines.count) * lineHeight + 40))
        let image = NSImage(size: size, flipped: true) { rect in
            NSColor.white.setFill()
            rect.fill()
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
            var y: CGFloat = 20
            for line in lines {
                line.draw(at: CGPoint(x: 20, y: y), withAttributes: attributes)
                y += lineHeight
            }
            return true
        }
        var proposed = CGRect(origin: .zero, size: CGSize(width: size.width * scale, height: size.height * scale))
        guard let cgImage = image.cgImage(forProposedRect: &proposed, context: nil, hints: [.ctm: AffineTransform(scale: scale)]) else {
            preconditionFailure("could not rasterise test image")
        }
        return cgImage
    }
}
