import FoundationModels
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

    func testTheRecognisersPunctuationIsTakenOffForTheModel() {
        XCTAssertEqual(VoiceFormatter.bareWords("You can, also, you can use it. Done!"), "You can also you can use it Done")
        XCTAssertEqual(VoiceFormatter.bareWords("It's 3.5 hours"), "It's 3.5 hours")
    }

    /// The stumble that came through untouched once ("You can, also, you can use"): the
    /// recogniser's commas made it look meant. With Apple Intelligence it is said once.
    func testARestartedPhraseIsSaidOnce() async throws {
        try XCTSkipUnless(Self.hasAppleIntelligence, "No Apple Intelligence on this Mac")
        let said = "You can, also, you can use the same identity for your product."
        let tidied = await VoiceFormatter.format(said, smart: true).lowercased()
        XCTAssertFalse(tidied.contains("you can, also, you can"), tidied)
        XCTAssertTrue(tidied.contains("also use"), tidied)
    }

    func testACorrectionKeepsOnlyTheCorrection() async throws {
        try XCTSkipUnless(Self.hasAppleIntelligence, "No Apple Intelligence on this Mac")
        let tidied = await VoiceFormatter.format("So, um, should we ship on Monday, no wait, Tuesday?", smart: true)
        XCTAssertTrue(tidied.contains("Tuesday"), tidied)
        XCTAssertFalse(tidied.contains("Monday"), tidied)
    }

    private static var hasAppleIntelligence: Bool {
        if #available(macOS 26, *) { return SystemLanguageModel.default.isAvailable }
        return false
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
