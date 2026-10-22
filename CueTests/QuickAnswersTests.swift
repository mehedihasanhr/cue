import XCTest

/// What the search field works out on the spot, and the clipboard's text transforms.
final class QuickAnswersTests: XCTestCase {
    private func values(_ query: String) -> [String] { QuickAnswers.answers(for: query).map(\.value) }

    func testColorInEveryFormat() {
        let answers = QuickAnswers.answers(for: "#0E4FEC")
        XCTAssertEqual(answers.first?.value, "#0E4FEC")
        XCTAssertTrue(answers.contains { $0.label == "RGB" && $0.value.contains("14") })
        XCTAssertNotNil(answers.first?.color)
        XCTAssertFalse(QuickAnswers.answers(for: "123456").contains { $0.color != nil }, "six digits without # is a number")
        XCTAssertNotNil(QuickAnswers.answers(for: "ff8800").first?.color)
    }

    func testUnixTimestamps() {
        let seconds = QuickAnswers.answers(for: "1700000000")
        XCTAssertEqual(seconds.count, 3)
        XCTAssertTrue(seconds[1].value.hasPrefix("2023-11-14T22:13:20"))
        let millis = QuickAnswers.answers(for: "1700000000000")
        XCTAssertEqual(millis[1].value, seconds[1].value)
    }

    func testNumberBases() {
        XCTAssertEqual(values("0x1F"), ["31", "0b11111", "0o37"])
        XCTAssertEqual(values("255"), ["0xFF", "0b11111111", "0o377"])
        XCTAssertTrue(values("0b1010").contains("10"))
    }

    func testLengths() {
        XCTAssertEqual(values("256px"), ["16rem", "16em", "192pt"])
        XCTAssertTrue(values("1.5rem").contains("24px"))
    }

    func testBase64() {
        XCTAssertEqual(values("b64 hello"), ["aGVsbG8="])
        XCTAssertEqual(values("aGVsbG8gd29ybGQ="), ["hello world"])
        XCTAssertEqual(values("decode aGVsbG8="), ["hello"])
    }

    func testArithmetic() {
        XCTAssertEqual(values("12*8"), ["96"])
        XCTAssertEqual(values("(3+4)/2"), ["3.5"])
        XCTAssertEqual(values("2^10"), ["1024"])
        XCTAssertEqual(values("17 % 5"), ["2"])
        XCTAssertEqual(values("-3 + 5"), ["2"])
        XCTAssertEqual(values("2+"), [], "a broken sum is no answer, not a crash")
        XCTAssertEqual(values("1/0"), [])
        XCTAssertEqual(values("hello"), [])
    }

    func testUUIDAndNow() {
        let ids = values("uuid")
        XCTAssertEqual(ids.count, 2)
        XCTAssertNotNil(UUID(uuidString: ids[0]))
        XCTAssertEqual(ids[1], ids[0].lowercased())
        XCTAssertEqual(values("now").count, 4)
    }

    // MARK: - Transforms

    func testCaseTransforms() {
        XCTAssertEqual(TextTransform.camelCase.apply(to: "user first name"), "userFirstName")
        XCTAssertEqual(TextTransform.snakeCase.apply(to: "userFirstName"), "user_first_name")
        XCTAssertEqual(TextTransform.kebabCase.apply(to: "User First-Name"), "user-first-name")
        XCTAssertEqual(TextTransform.sentenceCase.apply(to: "HELLO THERE\nsecond LINE"), "Hello there\nSecond line")
        XCTAssertEqual(TextTransform.oneLine.apply(to: "  a\n  b\tc "), "a b c")
    }

    func testJSONAndURL() {
        XCTAssertEqual(TextTransform.jsonMinified.apply(to: "{ \"b\": 1,\n \"a\": [1, 2] }"), "{\"a\":[1,2],\"b\":1}")
        XCTAssertEqual(TextTransform.jsonPretty.apply(to: "{\"a\":1}"), "{\n  \"a\" : 1\n}")
        XCTAssertNil(TextTransform.jsonPretty.apply(to: "not json"))
        XCTAssertEqual(TextTransform.urlEncoded.apply(to: "a b&c"), "a%20b%26c")
        XCTAssertEqual(TextTransform.urlDecoded.apply(to: "a%20b+c"), "a b c")
        XCTAssertNil(TextTransform.urlDecoded.apply(to: "plain"))
    }

    func testMarkdownAndApplicable() {
        XCTAssertEqual(TextTransform.markdownPlain.apply(to: "# Title\n\nSome **bold** text"), "Title\nSome bold text")
        let applicable = TextTransform.applicable(to: "hello")
        XCTAssertTrue(applicable.contains(.plain))
        XCTAssertTrue(applicable.contains(.uppercased))
        XCTAssertFalse(applicable.contains(.lowercased), "already lowercase: nothing would change")
        XCTAssertFalse(applicable.contains(.jsonPretty))
    }
}
