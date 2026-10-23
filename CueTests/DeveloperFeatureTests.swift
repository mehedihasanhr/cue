import XCTest

/// Code detection on the clipboard, the cue:// URL commands, and the snippet
/// built-ins added for developers.
final class DeveloperFeatureTests: XCTestCase {
    // MARK: - Code detection

    func testDetectsCommonLanguages() {
        XCTAssertEqual(CodeSnippet.detect("func greet(name: String) -> String {\n    let text = \"Hi \\(name)\"\n    return text\n}"), .swift)
        XCTAssertEqual(CodeSnippet.detect("const add = (a, b) => a + b;\nconsole.log(add(1, 2));"), .javascript)
        XCTAssertEqual(CodeSnippet.detect("interface User {\n  name: string;\n  age: number;\n}"), .typescript)
        XCTAssertEqual(CodeSnippet.detect("def greet(name):\n    print(f\"Hi {name}\")\n"), .python)
        XCTAssertEqual(CodeSnippet.detect("{\"a\": 1, \"b\": [1, 2]}"), .json)
        XCTAssertEqual(CodeSnippet.detect("<div class=\"x\"><p>Hello</p></div>"), .html)
        XCTAssertEqual(CodeSnippet.detect("SELECT id, name FROM users WHERE age > 21 ORDER BY name"), .sql)
        XCTAssertEqual(CodeSnippet.detect("#!/bin/sh\necho hello"), .shell)
        XCTAssertEqual(CodeSnippet.detect(".card {\n  margin: 8px;\n  color: red;\n}"), .css)
    }

    func testProseIsNotCode() {
        XCTAssertNil(CodeSnippet.detect("Hi there, this is a normal sentence about nothing in particular."))
        XCTAssertNil(CodeSnippet.detect("https://example.com/some/path?x=1"))
        XCTAssertNil(CodeSnippet.detect("short"))
        XCTAssertNil(CodeSnippet.detect("Meeting at 5pm.\nBring the slides, the printouts and coffee."))
    }

    func testFenceAndHighlight() {
        XCTAssertEqual(CodeSnippet.fenced("let x = 1", as: .swift), "```swift\nlet x = 1\n```")
        XCTAssertEqual(CodeSnippet.fenced("plain", as: nil), "```\nplain\n```")
        let highlighted = CodeSnippet.highlighted("let x = \"a\" // note", as: .swift)
        XCTAssertEqual(String(highlighted.characters), "let x = \"a\" // note")
    }

    // MARK: - URL commands

    func testURLCommands() {
        XCTAssertEqual(URLCommand(URL(string: "cue://capture/area")!), .captureArea)
        XCTAssertEqual(URLCommand(URL(string: "cue://capture")!), .captureArea)
        XCTAssertEqual(URLCommand(URL(string: "cue://capture/full")!), .captureFullScreen)
        XCTAssertEqual(URLCommand(URL(string: "cue://color/pick")!), .pickColor)
        XCTAssertEqual(URLCommand(URL(string: "cue://palette")!), .palette)
        XCTAssertEqual(URLCommand(URL(string: "cue://update")!), .checkForUpdates)
        XCTAssertEqual(URLCommand(URL(string: "cue://task/new?title=Fix%20it&priority=high&project=Cue")!),
                       .newTask(title: "Fix it", notes: "", priority: .high, project: "Cue"))
        XCTAssertEqual(URLCommand(URL(string: "cue://task/new")!), .newTask(title: nil, notes: "", priority: .medium, project: nil))
        XCTAssertEqual(URLCommand(URL(string: "cue://snippet/add?keyword=%3Bsig&text=Cheers")!), .addSnippet(keyword: ";sig", name: "", text: "Cheers"))
        XCTAssertNil(URLCommand(URL(string: "cue://snippet/add?keyword=;sig")!), "a snippet needs text")
        XCTAssertEqual(URLCommand(URL(string: "cue://clipboard/copy?text=hi%20there")!), .copy("hi there"))
        XCTAssertNil(URLCommand(URL(string: "cue://nonsense")!))
        XCTAssertNil(URLCommand(URL(string: "https://example.com/capture/area")!))
    }

    // MARK: - Snippet built-ins

    func testSnippetBuiltIns() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertTrue(SnippetTemplate.isBuiltIn("uuid"))
        XCTAssertTrue(SnippetTemplate.isBuiltIn("date:yyyy-MM-dd"))
        XCTAssertTrue(SnippetTemplate.isBuiltIn("shell:echo hi"))
        XCTAssertFalse(SnippetTemplate.isBuiltIn("Name"))
        XCTAssertNotNil(UUID(uuidString: SnippetTemplate.expand("{{uuid}}", values: [:])))
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"
        XCTAssertEqual(SnippetTemplate.expand("{{date:yyyy-MM-dd}}", values: [:], now: now), formatter.string(from: now))
        XCTAssertEqual(SnippetTemplate.expand("{{shell:echo hi}}", values: [:]), "hi")
        XCTAssertEqual(SnippetTemplate.expand("{{shell:sleep 5}}", values: [:]), "", "a slow command is given up on")
        let expansion = SnippetTemplate.expansion("Dear {{Name}},{{cursor}}\nBye", values: ["Name": "Ada"])
        XCTAssertEqual(expansion.text, "Dear Ada,\nBye")
        XCTAssertEqual(expansion.caretBack, 4)
        XCTAssertNil(SnippetTemplate.expansion("no cursor", values: [:]).caretBack)
        XCTAssertEqual(Snippet(keyword: ";x", text: "{{Name}} {{uuid}} {{date:HH}}").placeholders, ["Name"])
    }
}
