import XCTest

/// How copied text is sorted into text, links and colours.
final class ClipboardItemTests: XCTestCase {
    func testLinksAreSingleURLs() {
        XCTAssertEqual(ClipboardItem.classify("https://example.com/path?q=1").0, .link)
        XCTAssertEqual(ClipboardItem.classify("  http://example.com \n").0, .link)
        XCTAssertEqual(ClipboardItem.classify("mailto:someone@example.com").0, .link)
        XCTAssertEqual(ClipboardItem.classify("see https://example.com for details").0, .text)
        XCTAssertEqual(ClipboardItem.classify("example.com").0, .text)
        XCTAssertEqual(ClipboardItem.classify("file:///tmp").0, .text)
    }

    func testColoursAreNormalisedToHex() {
        XCTAssertEqual(ClipboardItem.classify("#d6688b").1, "#D6688B")
        XCTAssertEqual(ClipboardItem.classify("D6688B").1, "#D6688B")
        XCTAssertEqual(ClipboardItem.classify("#fff").1, "#FFFFFF")
        XCTAssertEqual(ClipboardItem.classify("rgb(214, 104, 139)").1, "#D6688B")
        XCTAssertEqual(ClipboardItem.classify("#d6688b").0, .color)
        XCTAssertEqual(ClipboardItem.classify("#12345").0, .text)   // five digits is not a colour
        XCTAssertEqual(ClipboardItem.classify("deadbeef").0, .text)
        XCTAssertEqual(ClipboardItem.classify("rgb(300, 0, 0)").0, .text)
    }

    func testColourComponents() throws {
        let item = ClipboardItem(kind: .color, text: "#D6688B")
        let components = try XCTUnwrap(item.colorComponents)
        XCTAssertEqual(components.red, 214 / 255, accuracy: 0.001)
        XCTAssertEqual(components.green, 104 / 255, accuracy: 0.001)
        XCTAssertEqual(components.blue, 139 / 255, accuracy: 0.001)
        XCTAssertNil(ClipboardItem(kind: .text, text: "#D6688B").colorComponents)
    }

    func testTitlesAndFilePaths() {
        XCTAssertEqual(ClipboardItem(kind: .text, text: "\n first line\nsecond").title, "first line")
        let files = ClipboardItem(kind: .files, text: "/Users/me/a.png\n/Users/me/b.txt")
        XCTAssertEqual(files.filePaths, ["/Users/me/a.png", "/Users/me/b.txt"])
        XCTAssertEqual(files.title, "a.png, b.txt")
        XCTAssertEqual(ClipboardItem(kind: .image, text: "Image", pixelWidth: 10, pixelHeight: 20).title, "Image 10 × 20")
        XCTAssertTrue(ClipboardItem(kind: .text, text: "x").filePaths.isEmpty)
    }

    func testRoundTripsThroughJSON() throws {
        var item = ClipboardItem(kind: .link, text: "https://example.com", sourceBundleID: "com.apple.Safari", sourceName: "Safari")
        item.pinned = true
        let data = try JSONEncoder().encode([item])
        let decoded = try JSONDecoder().decode([ClipboardItem].self, from: data)
        XCTAssertEqual(decoded, [item])
    }
}
