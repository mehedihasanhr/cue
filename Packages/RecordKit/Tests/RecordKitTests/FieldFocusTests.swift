import Foundation
import Testing
@testable import RecordKit

@Suite("Text-field focus follows its own switch")
struct FieldFocusTests {
    private func configuration() -> RecordingConfiguration {
        RecordingConfiguration(target: .display(1), destination: URL(filePath: "/tmp"), name: "Demo")
    }

    @Test("Fields are tracked with the keyboard off, which is the default")
    func notTiedToKeys() {
        var configuration = configuration()
        configuration.capturesKeystrokes = false
        #expect(RecordingSession.tracksTextFields(for: configuration))
    }

    @Test("Turning focus off, or fields off, stops fields being watched")
    func ownSwitches() {
        var configuration = configuration()
        configuration.capturesKeystrokes = true
        configuration.capturesFieldFocus = false
        #expect(!RecordingSession.tracksTextFields(for: configuration))
        configuration.capturesFieldFocus = true
        configuration.capturesFocus = false
        #expect(!RecordingSession.tracksTextFields(for: configuration))
    }
}
