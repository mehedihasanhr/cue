import XCTest

/// Ending a "Hey Cue" dictation by voice, and finding what came after "Hey Cue".
final class VoiceCommandTests: XCTestCase {
    func testDoneTypesWhatCameBefore() {
        XCTAssertEqual(VoiceCommand("The meeting is at three. Done."), .done("The meeting is at three")) // re-punctuated by the formatter
        XCTAssertEqual(VoiceCommand("Send the report to Sam, that's all"), .done("Send the report to Sam"))
        XCTAssertEqual(VoiceCommand("ship it on Tuesday okay done"), .done("ship it on Tuesday"))
        XCTAssertEqual(VoiceCommand("ship it on Tuesday stop listening"), .done("ship it on Tuesday"))
    }

    func testDoneInsideASentenceIsJustWords() {
        XCTAssertNil(VoiceCommand("I'm done"))
        XCTAssertNil(VoiceCommand("We are almost done with it"))
    }

    func testCancelDropsEverything() {
        XCTAssertEqual(VoiceCommand("Write to Sam about the. Never mind."), .cancel)
        XCTAssertEqual(VoiceCommand("cancel"), .cancel)
    }

    @MainActor
    func testWhatFollowsHeyCue() {
        XCTAssertEqual(WakeWordListener.after("Hey Cue, the meeting is at three"), "the meeting is at three")
        XCTAssertEqual(WakeWordListener.after("so hey queue write this"), "write this")
        XCTAssertEqual(WakeWordListener.after("Hey Q."), "")
        XCTAssertNil(WakeWordListener.after("a queue of people"))
    }
}
