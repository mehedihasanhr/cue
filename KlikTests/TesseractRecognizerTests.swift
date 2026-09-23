import AppKit
import XCTest

/// Reading Bangla, which is the whole point.
///
/// Needs the language model, so it fetches one the first time and then skips if that
/// is not possible — a machine with no network still runs the rest of the suite.
final class TesseractRecognizerTests: XCTestCase {
    private let lines = [
        "আমি বাংলায় গান গাই",
        "ক্লিক সেটিংস খুলুন এবং ভাষা নির্বাচন করুন",
        "ছবি থেকে টেক্সট বের করার সহজ উপায়",
    ]

    /// Draws text the way a screenshot of a Bangla interface looks: a Retina-density
    /// buffer, modest point size, anti-aliased, dark on white.
    private func render(_ lines: [String], fontName: String = "Kohinoor Bangla",
                        pointSize: CGFloat = 15, scale: CGFloat = 2) throws -> CGImage {
        let font = try XCTUnwrap(NSFont(name: fontName, size: pointSize * scale), "\(fontName) is not installed")
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let sizes = lines.map { ($0 as NSString).size(withAttributes: attributes) }
        let lineHeight = (sizes.map(\.height).max() ?? 20) * 1.45
        let width = Int((sizes.map(\.width).max() ?? 100) + 40 * scale)
        let height = Int(lineHeight * CGFloat(lines.count) + 40 * scale)

        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        for (index, line) in lines.enumerated() {
            let y = CGFloat(height) - 20 * scale - lineHeight * CGFloat(index + 1)
            (line as NSString).draw(at: NSPoint(x: 20 * scale, y: y), withAttributes: attributes)
        }
        NSGraphicsContext.restoreGraphicsState()
        return try XCTUnwrap(rep.cgImage)
    }

    /// Fetches the Bengali model once, or skips the test if it cannot.
    @MainActor
    private static func requireBengaliPack() async throws {
        guard !TessdataFiles.isInstalled("ben") else { return }
        do {
            try await LanguagePackStore().ensure("ben")
        } catch {
            throw XCTSkip("the Bengali language pack isn't available here: \(error.localizedDescription)")
        }
    }

    // MARK: - Recognition

    func testItReadsBangla() async throws {
        try await Self.requireBengaliPack()
        let image = try render(lines)
        let buffer = try XCTUnwrap(OCRImageBuffer.make(from: image))
        let items = try await TesseractEngine.shared.recognize(
            buffer, language: "ben", datapath: TessdataFiles.folder, minimumConfidence: 0.3)

        XCTAssertFalse(items.isEmpty, "Tesseract found no text at all")
        let text = TextLayout.compose(items)
        // The whole feature in one assertion: Bangla in, Bangla out.
        XCTAssertEqual(OCRScript.dominant(in: text), .bengali)
        XCTAssertGreaterThan(OCRScript.bengali.share(in: text), OCRScript.minimumShare)
        XCTAssertTrue(text.contains("বাংলায়"), "expected the first line's words; got:\n\(text)")
    }

    func testItFindsOneBoxPerLineAndTheyAreInTheImage() async throws {
        try await Self.requireBengaliPack()
        let image = try render(lines)
        let buffer = try XCTUnwrap(OCRImageBuffer.make(from: image))
        let items = try await TesseractEngine.shared.recognize(
            buffer, language: "ben", datapath: TessdataFiles.folder, minimumConfidence: 0.3)

        XCTAssertEqual(items.count, lines.count)
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        for item in items {
            XCTAssertTrue(unit.contains(item.boundingBox), "box escaped the image: \(item.boundingBox)")
            XCTAssertGreaterThan(item.confidence, 0)
            XCTAssertLessThanOrEqual(item.confidence, 1)
        }
        // Reading order: the first line drawn is the one nearest the top, and the
        // y axis points up, so it has the largest minY.
        let tops = items.map(\.boundingBox.minY)
        XCTAssertEqual(tops, tops.sorted(by: >), "lines should come back top to bottom")
    }

    /// The coordinate flip, checked against the composer that depends on it. Tesseract
    /// counts pixels down from the top left; a mistake here reverses the lines.
    func testTheFirstLineComposesFirst() async throws {
        try await Self.requireBengaliPack()
        let image = try render(lines)
        let buffer = try XCTUnwrap(OCRImageBuffer.make(from: image))
        let items = try await TesseractEngine.shared.recognize(
            buffer, language: "ben", datapath: TessdataFiles.folder, minimumConfidence: 0.3)
        let composed = TextLayout.compose(items).components(separatedBy: "\n").filter { !$0.isEmpty }
        XCTAssertEqual(composed.count, lines.count)
        XCTAssertTrue(composed.first?.contains("বাংলায়") ?? false,
                      "the top line should compose first; got \(composed)")
    }

    // MARK: - Through OCRService

    func testTheServiceRoutesBanglaToTesseractAndKeepsTheScript() async throws {
        try await Self.requireBengaliPack()
        let packs = await LanguagePackStore()
        var settings = OCRSettings()
        settings.selection = .languages([OCRLanguage("bn-BD")])
        let service = OCRService(settings: settings,
                                 engines: OCREngineSet(tesseract: TesseractOCREngine(packs: packs)))

        let recognized = try await service.recognize(try render(lines))
        XCTAssertEqual(recognized.engine, .tesseract)
        XCTAssertEqual(recognized.language, OCRLanguage("bn-BD"))
        XCTAssertEqual(OCRScript.dominant(in: recognized.text), .bengali)
    }
}
