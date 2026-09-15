import XCTest

/// The Markdown subset used by task descriptions.
final class MarkdownTests: XCTestCase {
    func testBlocks() {
        let markdown = """
        # Title
        Some **bold** text
        that continues.

        - one
        - two
        1. first
        2. second
        > a quote
        ![shot](klik://abc.png)
        ## Sub
        """
        XCTAssertEqual(MarkdownBlock.parse(markdown), [
            .heading(level: 1, text: "Title"),
            .paragraph("Some **bold** text that continues."),
            .bullets(["one", "two"]),
            .numbered(["first", "second"]),
            .quote("a quote"),
            .image(alt: "shot", source: "klik://abc.png"),
            .heading(level: 2, text: "Sub"),
        ])
    }

    func testEdgeCases() {
        XCTAssertEqual(MarkdownBlock.parse(""), [])
        XCTAssertEqual(MarkdownBlock.parse("   \n\n"), [])
        XCTAssertEqual(MarkdownBlock.parse("#### deep"), [.heading(level: 3, text: "deep")])
        XCTAssertEqual(MarkdownBlock.parse("3.14 is pi"), [.paragraph("3.14 is pi")])
        XCTAssertEqual(MarkdownBlock.parse("![no close"), [.paragraph("![no close")])
        XCTAssertEqual(MarkdownBlock.parse("> a\n> b"), [.quote("a b")])
    }
}
