import AppKit
import XCTest

/// A task is one text: its title is the first line that says anything, shown plain.
final class TaskTextTests: XCTestCase {
    func testTitleIsFirstMeaningfulLinePlain() {
        XCTAssertEqual(TaskText.title(of: "\n\n## Fix the **login** flow\nmore"), "Fix the login flow")
        XCTAssertEqual(TaskText.title(of: "- [ ] *Ship* `v2` ~~soon~~"), "Ship v2 soon")
        XCTAssertEqual(TaskText.title(of: "See [the spec](https://x.y) first"), "See the spec first")
        XCTAssertEqual(TaskText.title(of: "![](cue://a.png)\nAfter the image"), "Image")
        XCTAssertEqual(TaskText.title(of: "2 * 3 = 6"), "2 * 3 = 6")
        XCTAssertEqual(TaskText.title(of: "   "), "")
    }

    func testSummaryIsTheRestOnOneLine() {
        XCTAssertEqual(TaskText.summary(of: "Title\n\n- one\n- **two**\n> said"), "one two said")
        XCTAssertEqual(TaskText.summary(of: "Only a title"), "")
    }

    func testReplacingTitleKeepsTheMarkAndTheRest() {
        XCTAssertEqual(TaskText.replacingTitle(of: "## Old #cue\n\nbody", with: "New"), "## New\n\nbody")
        XCTAssertEqual(TaskText.replacingTitle(of: "\nOld", with: "New"), "\nNew")
        XCTAssertEqual(TaskText.replacingTitle(of: "", with: "New"), "New")
    }

    func testLegacyTitleAndNotesDecodeAsOneText() throws {
        let json = """
        {"id":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F","title":"Old task","notes":"Some notes","status":"pending","createdAt":0}
        """
        let task = try JSONDecoder().decode(TaskItem.self, from: Data(json.utf8))
        XCTAssertEqual(task.text, "Old task\n\nSome notes")
        XCTAssertEqual(task.title, "Old task")
        XCTAssertEqual(task.summary, "Some notes")
        // What is written carries the title too, for an older build reading it.
        let written = try JSONSerialization.jsonObject(with: JSONEncoder().encode(task)) as? [String: Any]
        XCTAssertEqual(written?["text"] as? String, "Old task\n\nSome notes")
        XCTAssertEqual(written?["title"] as? String, "Old task")
    }

    @MainActor
    func testEditorMarkdownRoundTrips() {
        let style = EditorStyle()
        let markdown = """
        # Heading
        Plain with **bold**, *italic*, `code` and ~~gone~~ words
        - one
        - [ ] todo
        - [x] done
        1. first
        2. second
        > quoted

        ```
        let x = 1
        ```
        """
        let attributed = EditorMarkdown.attributed(markdown, style: style, image: { _ in nil }, fileIcon: { _ in nil })
        XCTAssertEqual(EditorMarkdown.markdown(attributed), markdown)
        // The heading's characters carry the block; the bold run is bold; the todo is a todo.
        XCTAssertEqual(EditorStyle.block(of: attributed.attributes(at: 0, effectiveRange: nil)), .heading1)
        let bold = (attributed.string as NSString).range(of: "bold")
        XCTAssertTrue(EditorStyle.traits(of: attributed.attributes(at: bold.location, effectiveRange: nil), block: .paragraph).bold)
        let todo = (attributed.string as NSString).range(of: "todo")
        XCTAssertEqual(EditorStyle.block(of: attributed.attributes(at: todo.location, effectiveRange: nil)), .todo)
    }

    @MainActor
    func testAttachmentsSurviveTheRoundTrip() {
        let style = EditorStyle()
        let markdown = "Before\n![shot](cue://a.png)\n[notes.pdf](cue-file://id/notes.pdf)\nAfter"
        let image = NSImage(size: NSSize(width: 40, height: 30))
        let attributed = EditorMarkdown.attributed(markdown, style: style, image: { _ in image }, fileIcon: { _ in image })
        XCTAssertEqual(EditorMarkdown.markdown(attributed), markdown)
    }

    @MainActor
    func testTypingMarksBecomesStyle() {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 300, height: CGFloat.greatestFiniteMagnitude))
        layout.addTextContainer(container)
        let view = RichTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200), textContainer: container)
        view.isRichText = true
        view.load(markdown: "")

        for character in "## Title" { view.insertText(String(character), replacementRange: view.selectedRange()) }
        XCTAssertEqual(view.block(at: 0), .heading2)
        XCTAssertEqual(view.markdown, "## Title")

        view.insertNewline(nil)
        XCTAssertEqual(view.block(at: view.selectedRange().location), .paragraph, "Enter leaves a heading for a paragraph")
        for character in "- item with *some words* here" { view.insertText(String(character), replacementRange: view.selectedRange()) }
        XCTAssertEqual(view.markdown, "## Title\n- item with *some words* here")

        view.insertNewline(nil)
        XCTAssertEqual(view.block(at: view.selectedRange().location), .bullet, "Enter continues a list")
        view.insertNewline(nil)
        XCTAssertEqual(view.block(at: view.selectedRange().location), .paragraph, "Enter on an empty item ends it")
        for character in "**bold**" { view.insertText(String(character), replacementRange: view.selectedRange()) }
        XCTAssertEqual(view.markdown, "## Title\n- item with *some words* here\n**bold**")
    }
}
