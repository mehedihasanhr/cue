import XCTest

/// Reading-order and line/paragraph handling, independent of Vision.
/// Boxes use Vision's normalised space: y grows upwards, so "top" lines have larger y.
final class TextLayoutTests: XCTestCase {
    private func item(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat = 0.3, height: CGFloat = 0.04) -> RecognizedTextItem {
        RecognizedTextItem(text: text, confidence: 1, boundingBox: CGRect(x: x, y: y, width: width, height: height))
    }

    func testLinesAreOrderedTopToBottom() {
        // Regular line spacing (gap of a quarter line), shuffled on input.
        let items = [
            item("620 ml cold water", x: 0.1, y: 0.80),
            item("Pizza Margherita", x: 0.1, y: 0.90),
            item("1 kg tipo 00 flour", x: 0.1, y: 0.85),
        ]
        XCTAssertEqual(TextLayout.compose(items), "Pizza Margherita\n1 kg tipo 00 flour\n620 ml cold water")
    }

    func testItemsOnTheSameLineJoinLeftToRight() {
        let items = [
            item("San Marzano", x: 0.4, y: 0.5),
            item("800 g", x: 0.1, y: 0.505), // slightly offset, still the same line
            item("tomatoes", x: 0.7, y: 0.498),
        ]
        XCTAssertEqual(TextLayout.compose(items), "800 g San Marzano tomatoes")
    }

    func testLargeVerticalGapBecomesParagraphBreak() {
        let items = [
            item("Pizza Margherita", x: 0.1, y: 0.90),
            item("1 kg tipo 00 flour", x: 0.1, y: 0.70), // gap ≈ 4 line heights
            item("800 g San Marzano tomatoes", x: 0.1, y: 0.65), // tight line spacing
        ]
        XCTAssertEqual(TextLayout.compose(items), "Pizza Margherita\n\n1 kg tipo 00 flour\n800 g San Marzano tomatoes")
    }

    func testEmptyInputGivesEmptyString() {
        XCTAssertEqual(TextLayout.compose([]), "")
    }

    func testPixelRectFlipsToTopLeftOrigin() {
        // A box hugging the top-left corner of a 200×100 image.
        let box = RecognizedTextItem(text: "x", confidence: 1, boundingBox: CGRect(x: 0, y: 0.8, width: 0.5, height: 0.2))
        let rect = box.pixelRect(in: CGSize(width: 200, height: 100))
        XCTAssertEqual(rect, CGRect(x: 0, y: 0, width: 100, height: 20), accuracy: 0.001)
    }

    // MARK: - Direction

    /// Arabic, Hebrew, Persian and Urdu put the first word on the right. Joining a
    /// line's fragments left to right would reverse it.
    func testARightToLeftLineIsJoinedFromTheRight() {
        let fragments = [item("\u{0627}\u{0644}\u{0623}\u{0648}\u{0644}", x: 0.6, y: 0.5),
                         item("\u{0627}\u{0644}\u{062B}\u{0627}\u{0646}\u{064A}", x: 0.3, y: 0.5)]
        XCTAssertEqual(TextLayout.compose(fragments, direction: .rightToLeft),
                       "\u{0627}\u{0644}\u{0623}\u{0648}\u{0644} \u{0627}\u{0644}\u{062B}\u{0627}\u{0646}\u{064A}")
        // Left to right it comes out the other way round, which is the bug being avoided.
        XCTAssertEqual(TextLayout.compose(fragments, direction: .leftToRight),
                       "\u{0627}\u{0644}\u{062B}\u{0627}\u{0646}\u{064A} \u{0627}\u{0644}\u{0623}\u{0648}\u{0644}")
    }

    /// Leading spaces on a right-to-left line would appear on the wrong side, so
    /// indentation is skipped there entirely.
    func testARightToLeftLineTakesNoIndent() {
        let lines = [item("a", x: 0.0, y: 0.8), item("b", x: 0.5, y: 0.5)]
        let indented = TextLayout.compose(lines, keepIndentation: true, direction: .rightToLeft)
        XCTAssertFalse(indented.contains("  "), "got: \(indented)")
    }

    func testTheDefaultDirectionIsUnchanged() {
        let fragments = [item("one", x: 0.1, y: 0.5), item("two", x: 0.5, y: 0.5)]
        XCTAssertEqual(TextLayout.compose(fragments), "one two")
    }
}

private func XCTAssertEqual(_ a: CGRect, _ b: CGRect, accuracy: CGFloat, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a.minX, b.minX, accuracy: accuracy, file: file, line: line)
    XCTAssertEqual(a.minY, b.minY, accuracy: accuracy, file: file, line: line)
    XCTAssertEqual(a.width, b.width, accuracy: accuracy, file: file, line: line)
    XCTAssertEqual(a.height, b.height, accuracy: accuracy, file: file, line: line)
}
