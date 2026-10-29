import AppIntents

/// "Hey Siri, talk to Cue": voice typing, started by Siri.
///
/// Siri hears its own wake word on hardware made for it, so nothing of Cue's listens until
/// Siri hands over: no microphone open, and no orange dot, between dictations. Cue starts
/// listening once Siri's panel has gone, and pastes into the app that was in front, as when
/// the talk key is held. The same action is in the Shortcuts app, for a shortcut of one's own.
struct TalkToCueIntent: AppIntent {
    static let title: LocalizedStringResource = "Talk to Cue"
    static let description = IntentDescription("Cue listens, then types what you say where the cursor is.")
    /// Cue works from the menu bar; nothing needs to come to the front.
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        VoiceTyping.shared.startFromSiri()
        return .result()
    }
}

/// The phrases Siri knows without any setting up; each must name the app.
struct CueShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: TalkToCueIntent(),
                    phrases: [
                        "Talk to \(.applicationName)",
                        "Dictate with \(.applicationName)",
                        "Start \(.applicationName) talk",
                        "\(.applicationName) listen",
                    ],
                    shortTitle: "Talk to Cue",
                    systemImageName: "mic")
    }
}
