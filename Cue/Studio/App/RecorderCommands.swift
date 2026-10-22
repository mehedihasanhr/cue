import RecordKit
import SwiftUI

/// The Record menu: every recorder action in the app's own menu bar, for when the menu bar
/// icon is turned off and the bar is behind an editor.
///
/// The shortcuts shown are the global ones from Settings. While they are registered,
/// macOS hands the key to the global shortcut before any menu sees it, so the two can
/// never both fire; the menu is where they are written down.
struct RecorderCommands: Commands {
    let studio: StudioService
    let settings: StudioSettings

    private var center: RecorderCenter? { RecorderCenter.shared }
    private var state: RecordingSession.State { studio.session.state }

    /// Why the recording items are off, and why the take items are.
    private var busyReason: String { state.isBusy ? "A recording is under way. Stop it first." : "" }
    private var idleReason: String { state.isTaking ? "" : "Nothing is being recorded." }

    var body: some Commands {
        CommandMenu("Record") {
            Button("Record Screen") { center?.recordScreen() }
                .disabled(state.isBusy)
                .help(busyReason)
            Button("Record Area\u{2026}") { StudioController.beginRecording(.area) }
                .disabled(state.isBusy)
                .help(busyReason)
            Button("Record Window\u{2026}") { StudioController.beginRecording(.window) }
                .disabled(state.isBusy)
                .help(busyReason)
            Divider()
            Button(studio.session.isPaused ? "Resume" : "Pause") { center?.perform(.pause) }
                .shortcut(settings.recorder, .pause)
                .disabled(!state.isTaking)
                .help(idleReason)
            if state.isStarting {
                Button("Cancel Countdown") { studio.cancel() }
            } else {
                Button("Stop") { studio.stop() }
                    .shortcut(settings.recorder, .record)
                    .disabled(!state.isTaking)
                    .help(idleReason)
            }
            Button(studio.restartPending ? "Confirm Restart" : "Restart") { center?.perform(.restart) }
                .shortcut(settings.recorder, .restart)
                .disabled(!state.isTaking)
                .help(idleReason)
            Button("Add Marker") { center?.perform(.marker) }
                .shortcut(settings.recorder, .marker)
                .disabled(!state.isTaking)
                .help(idleReason)
            Divider()
            Toggle("Speaker Notes", isOn: Binding(get: { settings.recorder.showsSpeakerNotes },
                                                  set: { settings.recorder.showsSpeakerNotes = $0 }))
        }
    }
}

private extension View {
    /// The action's global shortcut, shown on the menu item. Nothing when it has none.
    @ViewBuilder
    func shortcut(_ preferences: RecorderPreferences, _ action: RecorderAction) -> some View {
        if preferences.usesGlobalShortcuts, let combo = preferences.shortcuts[action],
           let character = combo.menuKeyEquivalent.first {
            keyboardShortcut(KeyEquivalent(character), modifiers: combo.eventModifiers)
        } else {
            self
        }
    }
}

extension KeyCombo {
    var eventModifiers: SwiftUI.EventModifiers {
        var modifiers: SwiftUI.EventModifiers = []
        if hasControl { modifiers.insert(.control) }
        if hasOption { modifiers.insert(.option) }
        if hasShift { modifiers.insert(.shift) }
        if hasCommand { modifiers.insert(.command) }
        return modifiers
    }
}
