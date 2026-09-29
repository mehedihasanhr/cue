import AppKit
import Carbon.HIToolbox
import RecordKit
import SwiftUI

/// The recorder's global shortcuts: start and stop, pause, restart, marker.
struct ShortcutSettingsPane: View {
    @Environment(StudioSettings.self) private var settings

    var body: some View {
        @Bindable var preferences = settings.recorder

        SettingsPane(.shortcuts) {
            SettingsGroup(footer: preferences.usesGlobalShortcuts
                          ? "Pause, restart and marker only listen while you record, so they don\u{2019}t take keys from other apps the rest of the time."
                          : "Turned off. The buttons on the bar, the menu bar icon and the Record menu still work.") {
                SettingsToggleRow("Use shortcuts from any app",
                                  subtitle: "Reach the recorder without switching to it.",
                                  isOn: $preferences.usesGlobalShortcuts)
            }

            SettingsGroup("Recorder shortcuts", footer: "Click a shortcut and press the new keys. Escape keeps the old one; Delete removes it.") {
                ForEach(RecorderAction.allCases) { action in
                    ShortcutRow(action: action, preferences: preferences)
                }
            }
            .disabled(!preferences.usesGlobalShortcuts)

            SettingsGroup {
                SettingsRow("Defaults", subtitle: "⌃⌥⌘ with R, P, T and M.") {
                    Button("Restore Defaults") { preferences.shortcuts = .defaults }
                        .disabled(preferences.shortcuts == .defaults)
                }
            }
            .disabled(!preferences.usesGlobalShortcuts)
        }
    }
}

/// One action, its shortcut, whether it is working, and what is wrong with it if anything is.
private struct ShortcutRow: View {
    let action: RecorderAction
    @Bindable var preferences: RecorderPreferences
    @State private var rejected: ShortcutProblem?

    var body: some View {
        SettingsRow(action.title, subtitle: note, symbol: symbol, tint: tint) {
            HStack(spacing: 10) {
                ShortcutField(title: action.title, combo: preferences.shortcuts[action]) { combo in
                    guard let combo else {
                        preferences.shortcuts[action] = nil
                        rejected = nil
                        return
                    }
                    if let problem = preferences.shortcuts.problem(with: combo, for: action) {
                        rejected = problem
                    } else {
                        rejected = nil
                        preferences.shortcuts[action] = combo
                    }
                }
                statusIcon.frame(width: 18)
            }
        }
    }

    private var symbol: String {
        switch action {
        case .record: "record.circle"
        case .pause: "pause.fill"
        case .restart: "arrow.counterclockwise"
        case .marker: "bookmark.fill"
        }
    }

    private var tint: Color {
        switch action {
        case .record: .red
        case .pause: .orange
        case .restart: .indigo
        case .marker: .yellow
        }
    }

    /// Said under the title, in the words the problem has for itself.
    private var note: String? {
        if let rejected { return rejected.message }
        if let problem = preferences.shortcuts.problems[action] { return problem.message }
        if isRefused { return "Another app is using this. Choose a different one." }
        return nil
    }

    private var isRefused: Bool {
        guard let refused = RecorderCenter.shared?.hotkeys.refused[action] else { return false }
        return refused == preferences.shortcuts[action]
    }

    @ViewBuilder
    private var statusIcon: some View {
        if preferences.shortcuts[action] == nil {
            Image(systemName: "minus.circle").foregroundStyle(.tertiary)
                .help("No shortcut")
        } else if rejected != nil || preferences.shortcuts.problems[action] != nil || isRefused {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                .help(note ?? "This shortcut has a problem")
        } else {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                .help("Ready")
        }
    }
}

/// A shortcut, and the way to change it: click, then press the keys.
///
/// Listens with a local monitor, which sees keys only while this window has them and needs
/// no permission. Escape gives up, Delete clears.
struct ShortcutField: View {
    let title: String
    let combo: KeyCombo?
    let change: (KeyCombo?) -> Void
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 4) {
            Button {
                isRecording ? stop() : start()
            } label: {
                Text(isRecording ? "Press keys\u{2026}" : (combo?.displayString ?? "None"))
                    .font(.system(.body, design: .rounded).monospacedDigit())
                    .foregroundStyle(isRecording ? Color.accentColor : (combo == nil ? .secondary : .primary))
                    .frame(minWidth: 96)
            }
            .help(isRecording ? "Press the new shortcut, or Escape to keep the old one" : "Click to change")
            .accessibilityLabel(title)
            .accessibilityValue(combo?.displayString ?? "None")
            if combo != nil, !isRecording {
                Button { change(nil) } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("No shortcut")
                .accessibilityLabel("Remove \(title) shortcut")
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch Int(event.keyCode) {
            case kVK_Escape:
                stop()
            case kVK_Delete, kVK_ForwardDelete:
                change(nil)
                stop()
            default:
                change(KeyCombo(keyCode: UInt32(event.keyCode), modifiers: Self.carbon(event.modifierFlags)))
                stop()
            }
            return nil
        }
    }

    private func stop() {
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    static func carbon(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers = 0
        if flags.contains(.command) { modifiers |= cmdKey }
        if flags.contains(.option) { modifiers |= optionKey }
        if flags.contains(.control) { modifiers |= controlKey }
        if flags.contains(.shift) { modifiers |= shiftKey }
        return UInt32(modifiers)
    }
}
