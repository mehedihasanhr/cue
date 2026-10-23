import XCTest

/// `{{blanks}}` in snippet templates, and keyword matching.
@MainActor
final class SnippetTests: XCTestCase {
    func testPlaceholdersInOrderWithoutDuplicates() {
        let text = "Hi {{Name}}, welcome. {{ sender }} — {{name}} again, {{date}}."
        XCTAssertEqual(SnippetTemplate.placeholders(in: text), ["Name", "sender", "date"])
        let snippet = Snippet(keyword: ";welcome", text: text)
        XCTAssertEqual(snippet.placeholders, ["Name", "sender"]) // date fills itself
    }

    func testExpansionFillsValuesCaseInsensitivelyAndBuiltIns() {
        let text = "Hi {{Name}}\nFrom {{sender}} on {{date}} · {{clipboard}} · {{missing}}"
        let now = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 9, day: 16, hour: 14))!
        let expanded = SnippetTemplate.expand(text, values: ["name": "Ada", "Sender": "Cue"], now: now, clipboard: "pasted")
        XCTAssertTrue(expanded.hasPrefix("Hi Ada\nFrom Cue on "))
        XCTAssertTrue(expanded.contains("2026"))
        XCTAssertTrue(expanded.hasSuffix(" · pasted · "))
        XCTAssertEqual(SnippetTemplate.expand("no blanks {{", values: [:]), "no blanks {{")
    }

    @MainActor
    func testKeywordsAreCleanedUniqueAndMatchedLongestFirst() {
        let store = SnippetStore()
        for snippet in store.items { store.delete(snippet) }
        XCTAssertNotNil(store.add(keyword: " ;sig ", text: "Regards"))
        XCTAssertNotNil(store.add(keyword: ";sign", text: "Signed"))
        XCTAssertNil(store.add(keyword: "", text: "x"))
        XCTAssertNil(store.add(keyword: ";empty", text: ""))
        XCTAssertEqual(Set(store.items.map(\.keyword)), [";sig", ";sign"])
        XCTAssertEqual(store.longestKeyword, 5)
        XCTAssertEqual(store.match(endOf: "hello ;sig")?.text, "Regards")
        XCTAssertEqual(store.match(endOf: "hello ;sign")?.text, "Signed")
        XCTAssertNil(store.match(endOf: "hello ;si"))
        // The same keyword again replaces the old snippet.
        store.add(keyword: ";sig", text: "Best")
        XCTAssertEqual(store.items.filter { $0.keyword == ";sig" }.count, 1)
        XCTAssertEqual(store.match(endOf: ";sig")?.text, "Best")
        for snippet in store.items { store.delete(snippet) }
    }
}
