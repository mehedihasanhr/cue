import XCTest

/// Dictated words made into typed text.
final class VoiceFormatterTests: XCTestCase {
    func testFillersGoAndASentenceIsMade() {
        XCTAssertEqual(VoiceFormatter.rules("um so I think uh we should ship it"), "So I think we should ship it.")
    }

    func testSpokenBreaksBecomeBreaks() {
        XCTAssertEqual(VoiceFormatter.rules("first point new line second point new paragraph the end"),
                       "First point\nSecond point\n\nThe end")
    }

    func testAStumbledWordIsSaidOnce() {
        XCTAssertEqual(VoiceFormatter.rules("check the the build please"), "Check the build please.")
    }

    func testEverySentenceStartsWithACapital() {
        XCTAssertEqual(VoiceFormatter.rules("it works. does it? yes it does"), "It works. Does it? Yes it does.")
    }

    func testShortWordsAreLeftWithoutAStop() {
        XCTAssertEqual(VoiceFormatter.rules("hello there"), "Hello there")
    }

    func testAReplyIsNotTakenForTheText() {
        XCTAssertFalse(VoiceFormatter.isFaithful("Sure! Here is the cleaned text: buy milk", to: "buy milk and eggs today please"))
        XCTAssertFalse(VoiceFormatter.isFaithful("", to: "anything"))
        XCTAssertTrue(VoiceFormatter.isFaithful("Buy milk and eggs today, please.", to: "buy milk and eggs today please"))
    }

    /// Apple Intelligence on this Mac, when it has it: the words come back tidied, still the speaker's.
    func testAppleIntelligenceTidiesWithoutChangingTheMeaning() async throws {
        let said = "um so for the trip we need uh tickets passports and the the charger"
        let tidied = await VoiceFormatter.format(said, smart: true)
        XCTAssertFalse(tidied.lowercased().contains(" um"), tidied)
        for word in ["tickets", "passports", "charger"] {
            XCTAssertTrue(tidied.lowercased().contains(word), tidied)
        }
        print("Apple Intelligence tidied:", tidied.debugDescription)
    }
}
