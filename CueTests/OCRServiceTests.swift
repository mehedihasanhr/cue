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

    // MARK: - Languages and the script check

    private func service(reading tags: [String], checksScript: Bool = true) -> OCRService {
        var settings = OCRSettings()
        settings.selection = .languages(tags.map(OCRLanguage.init))
        settings.checksScript = checksScript
        return OCRService(settings: settings)
    }

    /// Naming the language explicitly still reads it — proof that setting
    /// `recognitionLanguages` did not break the ordinary path.
    func testNamingTheLanguageStillReadsIt() async throws {
        let lines = ["Pizza Margherita", "1 kg tipo 00 flour"]
        let result = try await service(reading: ["en-US"]).recognize(Self.render(lines: lines, lineSpacing: 12))
        XCTAssertEqual(result.engine, .vision)
        XCTAssertEqual(result.language, OCRLanguage("en-US"))
        for line in lines {
            XCTAssertTrue(result.text.contains(line), "Missing “\(line)” in:\n\(result.text)")
        }
    }

    /// Asking for one alphabet and getting another is refused, not copied. This is the
    /// guard that would have caught the reported bug had Vision ever been asked for
    /// Bangla — and since it cannot be, it now catches the general case instead.
    func testAnswerInAnotherAlphabetIsRefused() async throws {
        let image = Self.render(lines: ["Pizza Margherita", "1 kg tipo 00 flour"], lineSpacing: 12)
        do {
            let result = try await service(reading: ["ru-RU"]).recognize(image)
            XCTFail("expected a refusal, got: \(result.text)")
        } catch OCRError.unavailable(.wrongScript(let expected, let found)) {
            XCTAssertEqual(expected, .cyrillic)
            XCTAssertEqual(found, .latin)
        }
    }

    func testTurningTheCheckOffLetsItThrough() async throws {
        let image = Self.render(lines: ["Pizza Margherita", "1 kg tipo 00 flour"], lineSpacing: 12)
        let result = try await service(reading: ["ru-RU"], checksScript: false).recognize(image)
        XCTAssertFalse(result.isEmpty)
    }

    /// A capture with nothing but numbers in it has no alphabet, and must not be
    /// refused for failing to have one.
    func testAPageOfNumbersIsNotRefused() async throws {
        let image = Self.render(lines: ["1024", "2048", "4096"], lineSpacing: 12)
        let result = try await service(reading: ["ru-RU"]).recognize(image)
        XCTAssertFalse(result.isEmpty, "got nothing back at all")
    }

    /// The default path reports who read it, so the HUD can say so.
    func testAutomaticStillReportsVisionAndNoLanguage() async throws {
        let result = try await service.recognize(Self.render(lines: ["Hello Cue"], lineSpacing: 12))
        XCTAssertEqual(result.engine, .vision)
        XCTAssertNil(result.language)
        XCTAssertNil(result.scriptWarning)
    }

    func testBlankImageYieldsNoText() async throws {
        let image = Self.render(lines: [], lineSpacing: 0)
        let result = try await service.recognize(image)
        XCTAssertTrue(result.isEmpty)
        XCTAssertTrue(result.items.isEmpty)
    }

    @MainActor
    func testCapturedImageConvenience() async throws {
        let cgImage = Self.render(lines: ["Hello Cue"], lineSpacing: 0)
        let captured = CapturedImage(cgImage: cgImage, scale: 2, displayID: 0, capturedAt: .now)
        let text = try await service.recognizeText(from: captured)
        XCTAssertTrue(text.contains("Hello Cue"))
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
