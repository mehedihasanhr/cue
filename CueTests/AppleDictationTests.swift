import XCTest

/// macOS's recogniser, as dictation uses it: a spoken clip in, one line of text out.
final class AppleDictationTests: XCTestCase {
    func testASpokenSentenceComesBackAsText() async throws {
        // The system voice saying it, as a microphone clip would.
        let clip = FileManager.default.temporaryDirectory.appending(path: "dictation-\(UUID().uuidString).aiff")
        defer { try? FileManager.default.removeItem(at: clip) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", "Samantha", "-o", clip.path(percentEncoded: false), "The quick brown fox jumps over the lazy dog."]
        try say.run()
        say.waitUntilExit()
        try XCTSkipUnless(say.terminationStatus == 0, "No system voice to speak the sentence")

        let text = try await AppleDictation.text(in: clip, locale: Locale(identifier: "en_US"))
        XCTAssertTrue(text.lowercased().contains("fox"), text)
        XCTAssertFalse(text.contains("  "))
    }
}
