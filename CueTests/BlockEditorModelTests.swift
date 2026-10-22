import AppKit
import XCTest

/// The editor's edits, as the keys, the slash menu, the handles and dragging make
/// them — checked through the Markdown each one saves.
@MainActor
final class BlockEditorModelTests: XCTestCase {
    private func model(_ markdown: String) -> (BlockEditorModel, () -> String) {
        let model = BlockEditorModel()
        var saved = markdown
        model.onChange = { saved = $0 }
        model.load(markdown)
        return (model, { saved })
    }

    func testReturnSplitsALineIntoTwoBlocks() {
        let (model, saved) = model("Hello world")
        model.split(model.blocks[0].id, before: "Hello", after: "world")
        XCTAssertEqual(saved(), "Hello\n\nworld")
        XCTAssertEqual(model.blocks.count, 2)
    }

    func testBackspaceAtTheStartJoinsTheLineAbove() {
        let (model, saved) = model("one\n\ntwo")
        model.backspaceAtStart(model.blocks[1].id, line: "two")
        XCTAssertEqual(saved(), "onetwo")
    }

    func testBackspaceAfterADividerTakesTheDividerAway() {
        let (model, saved) = model("one\n\n---\n\ntwo")
        model.backspaceAtStart(model.blocks[2].id, line: "two")
        XCTAssertEqual(saved(), "one\n\ntwo")
    }

    func testJoiningOntoAnEmptyHeadingKeepsItAHeading() {
        let (model, saved) = model("x")
        model.load("")
        model.blocks = [DocBlock(.text("## ")), DocBlock(.text("words"))]
        model.backspaceAtStart(model.blocks[1].id, line: "words")
        XCTAssertEqual(saved(), "## words")
    }

    func testDraggingABlockAboveOrBelowAnother() {
        let (model, saved) = model("a\n\nb\n\nc")
        let a = model.blocks[0].id, c = model.blocks[2].id
        model.move(a, to: .init(id: c, below: true))
        XCTAssertEqual(saved(), "b\n\nc\n\na")
        model.move(a, to: .init(id: model.blocks[0].id, below: false))
        XCTAssertEqual(saved(), "a\n\nb\n\nc")
    }

    func testMoveUpAndDownFromTheHandleMenu() {
        let (model, saved) = model("a\n\nb")
        model.move(model.blocks[1].id, by: -1)
        XCTAssertEqual(saved(), "b\n\na")
        model.move(model.blocks[0].id, by: -1)
        XCTAssertEqual(saved(), "b\n\na", "the first block cannot go further up")
    }

    func testTurnIntoKeepsTheWords() {
        let (model, saved) = model("- [ ] Ship it")
        let id = model.blocks[0].id
        model.turn(id, into: .heading2)
        XCTAssertEqual(saved(), "## Ship it")
        model.turn(id, into: .code)
        XCTAssertEqual(saved(), "```\nShip it\n```")
        model.turn(id, into: .quote)
        XCTAssertEqual(saved(), "> Ship it")
    }

    func testDuplicateAndDelete() {
        let (model, saved) = model("a\n\nb")
        model.duplicate(model.blocks[0].id)
        XCTAssertEqual(saved(), "a\n\na\n\nb")
        model.delete(model.blocks[1].id)
        XCTAssertEqual(saved(), "a\n\nb")
        XCTAssertNotEqual(model.blocks[0].id, model.blocks[1].id)
    }

    func testDeletingTheLastBlockLeavesALineToTypeIn() {
        let (model, _) = model("only")
        model.delete(model.blocks[0].id)
        XCTAssertEqual(model.blocks.count, 1)
        XCTAssertEqual(model.blocks[0].kind, .text(""))
    }

    func testAChoiceOnAnEmptyLineTakesItsPlaceWithALineAfter() {
        let (model, saved) = model("Intro")
        model.blocks.append(DocBlock(.text("")))
        let empty = model.blocks[1].id
        model.make(.table, at: empty, replacing: true)
        guard case .table = model.blocks[1].kind else { return XCTFail("not a table") }
        XCTAssertEqual(model.blocks.count, 3, "a line after the table to go on typing in")
        XCTAssertTrue(saved().hasPrefix("Intro\n\n| "))
    }

    func testAChoiceOnALineWithTextGoesBelowIt() {
        let (model, saved) = model("Intro\n\nNext")
        model.make(.divider, at: model.blocks[0].id, replacing: false)
        XCTAssertEqual(saved(), "Intro\n\n---\n\nNext")
        XCTAssertEqual(model.blocks.count, 4, "an empty line between the divider and the next text, for the caret")
    }

    func testATextChoiceMarksTheLine() {
        let (model, saved) = model("Ship it")
        model.make(.todo, at: model.blocks[0].id, replacing: true)
        XCTAssertEqual(saved(), "- [ ] Ship it")
    }

    func testPastingSeveralLinesMakesTheBlocksTheySay() {
        let (model, saved) = model("start")
        model.textChanged(model.blocks[0].id, line: "start\n- one\n- two")
        XCTAssertEqual(model.blocks.count, 3)
        XCTAssertEqual(saved(), "start\n\n- one\n- two")
    }

    func testTypingThreeDashesMakesADivider() {
        let (model, _) = model("x")
        model.textChanged(model.blocks[0].id, line: "---")
        XCTAssertEqual(model.blocks.first?.kind, .divider)
    }

    func testNumberedItemsKnowTheirNumber() {
        let (model, _) = model("1. a\n2. b\n3. c\n\nbreak\n\n1. again")
        XCTAssertEqual(model.listNumber(of: model.blocks[2].id), 3)
        XCTAssertEqual(model.listNumber(of: model.blocks[4].id), 1)
    }

    func testTableEditsSave() {
        let (model, saved) = model("| a | b |\n| --- | --- |\n| 1 | 2 |")
        model.updateTable(model.blocks[0].id) { $0.insertColumn(at: 2); $0.rows[0][2] = "c" }
        XCTAssertEqual(saved(), "| a | b | c |\n| --- | --- | --- |\n| 1 | 2 |  |")
    }

    func testAnEditFromElsewhereReloads() {
        let (model, _) = model("a")
        model.load("# changed")
        XCTAssertEqual(model.blocks.map(\.kind), [.text("# changed")])
    }

    // MARK: Slash menu

    private func textView(_ string: String) -> NSTextView {
        let view = NSTextView()
        view.string = string
        view.setSelectedRange(NSRange(location: (string as NSString).length, length: 0))
        return view
    }

    func testTheSlashMenuSearchesWhatFollowsTheSlash() {
        let (model, _) = model("Intro /hea")
        let id = model.blocks[0].id
        model.slashTyped(in: id, at: 6)
        model.slashTextChanged(in: id, view: textView("Intro /hea"))
        XCTAssertEqual(model.slash?.query, "hea")
        XCTAssertEqual(model.slashChoices, [.heading1, .heading2, .heading3])
        model.slashKey(.down)
        model.slashKey(.down)
        model.slashKey(.down)
        XCTAssertEqual(model.slash?.highlighted, 0, "the highlight wraps around")
        model.slashKey(.up)
        XCTAssertEqual(model.slash?.highlighted, 2)
    }

    func testTheSlashMenuClosesWhenTheSlashGoesOrOnEscape() {
        let (model, _) = model("/")
        let id = model.blocks[0].id
        model.slashTyped(in: id, at: 0)
        model.slashTextChanged(in: id, view: textView(""))
        XCTAssertNil(model.slash, "the slash deleted")
        model.slashTyped(in: id, at: 0)
        model.slashKey(.cancel)
        XCTAssertNil(model.slash)
    }
}
