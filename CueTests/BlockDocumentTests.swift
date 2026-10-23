import AppKit
import XCTest

/// Markdown ⇄ blocks for the description editor: nothing typed may be lost or
/// changed by opening a description and saving it again.
final class BlockDocumentTests: XCTestCase {
    private func kinds(_ markdown: String) -> [DocBlock.Kind] { BlockMarkdown.parse(markdown).map(\.kind) }

    /// Parsing and writing back gives the same Markdown (for Markdown already in the
    /// shape the editor writes).
    private func assertRoundTrip(_ markdown: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(BlockMarkdown.serialize(BlockMarkdown.parse(markdown)), markdown, file: file, line: line)
    }

    func testTextLinesAreBlocksEach() {
        XCTAssertEqual(kinds("# Title\n\nA paragraph with **bold**\n\n> quoted"), [
            .text("# Title"), .text("A paragraph with **bold**"), .text("> quoted"),
        ])
    }

    func testListsStayTogetherAndNumbersRecount() {
        let blocks = BlockMarkdown.parse("1. one\n1. two\n7. three\n\n- a\n- b\n- [ ] do\n- [x] done")
        XCTAssertEqual(BlockMarkdown.serialize(blocks), "1. one\n2. two\n3. three\n\n- a\n- b\n\n- [ ] do\n- [x] done")
    }

    func testCodeAndMermaidKeepEveryLineAsWritten() {
        let markdown = "```swift\nfunc a() {\n    return 1\n\n}\n```\n\n```mermaid\ngraph TD\n  A --> B\n```"
        XCTAssertEqual(kinds(markdown), [
            .code(language: "swift", code: "func a() {\n    return 1\n\n}"),
            .code(language: "mermaid", code: "graph TD\n  A --> B"),
        ])
        assertRoundTrip(markdown)
    }

    func testTablesParseIntoRowsAndCells() {
        let markdown = "| Feature | Description |\n| --- | --- |\n| **Creator Profile** | Bio, photo |\n| Social Links | a \\| b |"
        guard case .table(let table) = kinds(markdown).first else { return XCTFail("not a table") }
        XCTAssertEqual(table.rows, [["Feature", "Description"], ["**Creator Profile**", "Bio, photo"], ["Social Links", "a | b"]])
        XCTAssertTrue(table.headerRow)
        assertRoundTrip(markdown)
    }

    func testTablesWithoutLeadingBarsOrWithAlignmentStillParse() {
        guard case .table(let table) = kinds("| a | b |\n|:---|---:|\n| 1 | 2 |").first else { return XCTFail("not a table") }
        XCTAssertEqual(table.rows, [["a", "b"], ["1", "2"]])
    }

    func testRaggedTablesArePadded() {
        guard case .table(let table) = kinds("| a | b | c |\n| --- | --- | --- |\n| 1 |").first else { return XCTFail("not a table") }
        XCTAssertEqual(table.rows[1], ["1", "", ""])
    }

    func testTableOptionsSurviveTheirComment() {
        var table = DocTable(rows: [["a", "b"], ["1", "2"]])
        table.headerColumn = true
        table.headerRow = false
        let markdown = BlockMarkdown.serialize([DocBlock(.table(table))])
        XCTAssertTrue(markdown.hasPrefix("<!-- cue:table header-column no-header-row -->\n"))
        guard case .table(let back) = kinds(markdown).first else { return XCTFail("not a table") }
        XCTAssertTrue(back.headerColumn)
        XCTAssertFalse(back.headerRow)
        XCTAssertEqual(back.rows, table.rows)
    }

    func testDividersImagesAndFiles() {
        let markdown = "Intro\n\n---\n\n![image](cue://A.png)\n\n[spec.pdf](cue-file://123/spec.pdf)"
        XCTAssertEqual(kinds(markdown), [
            .text("Intro"), .divider, .image(alt: "image", source: "cue://A.png"), .file(name: "spec.pdf", source: "cue-file://123/spec.pdf"),
        ])
        assertRoundTrip(markdown)
    }

    func testEmptyTextBlocksAreNotWritten() {
        let blocks = [DocBlock(.text("a")), DocBlock(.text("")), DocBlock(.text("b"))]
        XCTAssertEqual(BlockMarkdown.serialize(blocks), "a\n\nb")
    }

    func testAnEmptyListItemIsKeptAsAPlaceToType() {
        XCTAssertEqual(BlockMarkdown.serialize([DocBlock(.text("- [ ] "))]), "- [ ] ")
    }

    func testANotionExportRoundTrips() {
        let markdown = """
        ## Description

        Build comprehensive creator/author pages that serve as a central hub.

        ---

        ## Feature Overview

        | Feature | Description |
        | --- | --- |
        | **Creator Profile** | Detailed author bio, profile photo, header image, brand color |
        | **Social Links** | Connect to Instagram, Twitter/X, TikTok |

        ## User Flow

        ```mermaid
        flowchart TD
            A[User clicks author] --> B[Author page loads]
        ```
        """
        assertRoundTrip(markdown)
        XCTAssertEqual(BlockMarkdown.parse(markdown).map(\.kind).count, 7, "heading, paragraph, divider, heading, table, heading, diagram")
    }

    // MARK: Table edits

    func testTableRowAndColumnEdits() {
        var table = DocTable(rows: [["A", "B"], ["1", "2"]])
        table.insertRow(at: 1)
        XCTAssertEqual(table.rows, [["A", "B"], ["", ""], ["1", "2"]])
        table.duplicateRow(2)
        XCTAssertEqual(table.rows.last, ["1", "2"])
        XCTAssertEqual(table.rows.count, 4)
        table.insertColumn(at: 1)
        XCTAssertEqual(table.rows[0], ["A", "", "B"])
        table.duplicateColumn(0)
        XCTAssertEqual(table.rows[0], ["A", "A", "", "B"])
        table.clearColumn(0)
        XCTAssertEqual(table.rows.map { $0[0] }, ["", "", "", ""])
        table.deleteColumn(0)
        table.deleteColumn(0)
        XCTAssertEqual(table.rows[0], ["", "B"])
        table.moveColumn(1, to: 0)
        XCTAssertEqual(table.rows[0], ["B", ""])
        table.clearRow(0)
        XCTAssertEqual(table.rows[0], ["", ""])
        table.moveRow(3, to: 0)
        XCTAssertEqual(table.rows[0], ["2", ""])
    }

    func testWidthsHeightsAndColorsSurviveTheOptionsComment() {
        var table = DocTable(rows: [["a", "b", "c"], ["1", "2", "3"]])
        table.setWidth(220, of: 0)
        table.setWidth(180, of: 2)
        table.setHeight(64, of: 1)
        table.setColor("yellow", row: 1)
        table.setColor("blue", column: 2)
        table.setColor("red", row: 0, column: 1)
        let markdown = BlockMarkdown.serialize([DocBlock(.table(table))])
        XCTAssertTrue(markdown.hasPrefix("<!-- cue:table widths=220,,180 heights=,64 colors=0.1:red;c2:blue;r1:yellow -->\n"), markdown)
        guard case .table(let back) = kinds(markdown).first else { return XCTFail("not a table") }
        XCTAssertEqual(back.width(of: 0), 220)
        XCTAssertNil(back.width(of: 1))
        XCTAssertEqual(back.width(of: 2), 180)
        XCTAssertEqual(back.height(of: 1), 64)
        XCTAssertEqual(back.color(row: 0, column: 1), "red", "a cell's own colour first")
        XCTAssertEqual(back.color(row: 1, column: 0), "yellow", "then its row's")
        XCTAssertEqual(back.color(row: 0, column: 2), "blue", "then its column's")
        XCTAssertNil(back.color(row: 0, column: 0))
    }

    func testAPlainTableHasNoOptionsComment() {
        XCTAssertFalse(BlockMarkdown.serialize([DocBlock(.table(DocTable(rows: [["a"], ["1"]])))]).contains("<!--"))
    }

    func testSizesAndColorsFollowTheirRowsAndColumns() {
        var table = DocTable(rows: [["a", "b"], ["1", "2"], ["x", "y"]])
        table.setWidth(200, of: 1)
        table.setHeight(50, of: 1)
        table.setColor("green", row: 1)
        table.setColor("pink", column: 1)
        table.setColor("red", row: 2, column: 1)

        table.insertColumn(at: 0)
        XCTAssertEqual(table.width(of: 2), 200)
        XCTAssertEqual(table.color(row: 0, column: 2), "pink")
        XCTAssertEqual(table.color(row: 2, column: 2), "red")

        table.insertRow(at: 0)
        XCTAssertEqual(table.height(of: 2), 50)
        XCTAssertEqual(table.color(row: 2, column: 0), "green")
        XCTAssertEqual(table.color(row: 3, column: 2), "red")

        table.deleteRow(2)
        XCTAssertNil(table.height(of: 2))
        XCTAssertNil(table.colors["r2"], "the coloured row went with it")
        XCTAssertEqual(table.color(row: 2, column: 2), "red", "the row below moved up with its colour")

        table.deleteColumn(2)
        XCTAssertTrue(table.columnWidths.isEmpty)
        XCTAssertFalse(table.colors.values.contains("pink"))
    }

    func testDuplicatingCopiesSizeAndColor() {
        var table = DocTable(rows: [["a", "b"], ["1", "2"]])
        table.setWidth(150, of: 0)
        table.setColor("blue", column: 0)
        table.duplicateColumn(0)
        XCTAssertEqual(table.width(of: 1), 150)
        XCTAssertEqual(table.color(row: 0, column: 1), "blue")
        table.setColor("orange", row: 1)
        table.duplicateRow(1)
        XCTAssertEqual(table.colors["r2"], "orange")
    }

    func testMovingAColumnMovesItsWidthAndColor() {
        var table = DocTable(rows: [["a", "b", "c"]])
        table.setWidth(300, of: 0)
        table.setColor("purple", column: 0)
        table.moveColumn(0, to: 2)
        XCTAssertEqual(table.rows[0], ["b", "c", "a"])
        XCTAssertEqual(table.width(of: 2), 300)
        XCTAssertEqual(table.color(row: 0, column: 2), "purple")
        XCTAssertNil(table.color(row: 0, column: 0))
    }

    func testATableKeepsOneRowAndOneColumn() {
        var table = DocTable(rows: [["only"]])
        table.deleteRow(0)
        table.deleteColumn(0)
        XCTAssertEqual(table.rows, [["only"]])
    }

    func testSpaceLeftAtTheEndOfALineIsNotKept() {
        XCTAssertEqual(BlockMarkdown.serialize([DocBlock(.text("Pages. ")), DocBlock(.text("## Goals  "))]), "Pages.\n\n## Goals")
    }

    // MARK: Slash menu

    func testEverySlashMenuSymbolDraws() {
        let missing = BlockChoice.allCases.map(\.symbol).filter { NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil }
        XCTAssertEqual(missing, [], "every block in the menu has an icon that exists")
    }


    func testSlashChoicesFilterByNameKeywordAndShortcut() {
        XCTAssertEqual(BlockChoice.allCases.filter { $0.matches("head") }, [.heading1, .heading2, .heading3])
        XCTAssertTrue(BlockChoice.mermaid.matches("flow"))
        XCTAssertTrue(BlockChoice.heading2.matches("##"))
        XCTAssertEqual(BlockChoice.allCases.filter { $0.matches("") }.count, BlockChoice.allCases.count)
    }

    func testTheKindOfABlockIsKnownForTurnInto() {
        XCTAssertEqual(BlockChoice.of(DocBlock(.text("- [x] done"))), .todo)
        XCTAssertEqual(BlockChoice.of(DocBlock(.text("### small"))), .heading3)
        XCTAssertEqual(BlockChoice.of(DocBlock(.code(language: "mermaid", code: ""))), .mermaid)
        XCTAssertEqual(BlockChoice.of(DocBlock(.text("plain"))), .text)
    }
}
