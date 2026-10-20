import AppKit
import Carbon.HIToolbox
import RecordKit
import SwiftUI

/// Every shortcut the app has that can be changed: the recorder's global ones — start and
/// stop, pause, restart, marker — and the editor's menu shortcuts, menu by menu.
///
/// One page for both because they are one keyboard. A global shortcut takes its key before
/// any menu sees it, so the two lists can only be kept apart by a page that checks each
/// against the other: a key the recorder has is refused for the editor, and the other way
/// about.
struct ShortcutSettingsPane: View {
    @Environment(StudioSettings.self) private var settings
    @State private var filter = ""

    var body: some View {
        @Bindable var preferences = settings.recorder

        StudioSettingsPane(.shortcuts) {
            StudioSettingsGroup {
                SettingsToggleRow("Use shortcuts from any app",
                                  subtitle: "Reach the recorder without switching to it.",
                                  isOn: $preferences.usesGlobalShortcuts)
            }

            StudioSettingsGroup("Recorder shortcuts") {
                ForEach(RecorderAction.allCases) { action in
                    ShortcutRow(action: action, preferences: preferences, editor: settings.editorShortcuts)
                }
            }
            .disabled(!preferences.usesGlobalShortcuts)

            StudioSettingsGroup {
                StudioSettingsRow("Defaults", subtitle: "⌃⌥⌘ with R, P, T and M.") {
                    Button("Restore Defaults") { preferences.shortcuts = .defaults }
                        .disabled(preferences.shortcuts == .defaults)
                }
            }
            .disabled(!preferences.usesGlobalShortcuts)

            editorShortcuts(recorder: preferences)
        }
    }

    // MARK: - The editor's

    /// The editor's menu shortcuts, a card per menu, in menu bar order.
    ///
    /// Seventy commands is a long page, so a field above them narrows it by name or by menu
    /// — "zoom" finds the Zoom menu and every command with zoom in its name.
    @ViewBuilder
    private func editorShortcuts(recorder: RecorderPreferences) -> some View {
        let shortcuts = settings.editorShortcuts
        StudioSettingsGroup("Editor shortcuts") {
            StudioSettingsCell(vertical: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Find a command", text: $filter)
                        .textFieldStyle(.plain)
                        .accessibilityLabel("Find an editor command")
                    if !filter.isEmpty {
                        Button { filter = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Clear the search")
                    }
                }
            }
            StudioSettingsRow("Editor defaults",
                        subtitle: shortcuts.shortcuts.isDefault
                            ? "Every editor shortcut is as it shipped."
                            : "\(shortcuts.shortcuts.overrides.count) changed.") {
                Button("Restore Editor Defaults") { shortcuts.shortcuts = .defaults }
                    .disabled(shortcuts.shortcuts.isDefault)
            }
        }

        ForEach(EditorCommand.Menu.allCases) { menu in
            let commands = menu.commands.filter { matches($0) }
            if !commands.isEmpty {
                StudioSettingsGroup(menu.title) {
                    ForEach(commands) { command in
                        EditorShortcutRow(command: command, shortcuts: shortcuts, recorder: recorder)
                    }
                }
            }
        }
        if EditorCommand.allCases.allSatisfy({ !matches($0) }) {
            Text("No editor command called \u{201C}\(filter)\u{201D}.")
                .font(StudioSettingsFont.note)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
        }
    }

    private func matches(_ command: EditorCommand) -> Bool {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return true }
        return command.title.lowercased().contains(needle)
            || command.menu.title.lowercased().contains(needle)
            || (settings.editorShortcuts[command]?.displayString.lowercased().contains(needle) ?? false)
    }
}

/// One editor command, its shortcut, a way back to the default, and what is wrong with the
/// shortcut if anything is.
private struct EditorShortcutRow: View {
    let command: EditorCommand
    @Bindable var shortcuts: EditorShortcutPreferences
    let recorder: RecorderPreferences
    @State private var rejected: EditorShortcutProblem?

    /// The recorder's shortcuts while they are on — the only time they take a key.
    private var liveRecorderShortcuts: RecorderShortcuts? {
        recorder.usesGlobalShortcuts ? recorder.shortcuts : nil
    }

    var body: some View {
        StudioSettingsRow(command.title, subtitle: note) {
            HStack(spacing: 10) {
                ShortcutField(title: command.title, combo: shortcuts[command], clearsOnDelete: false) { combo in
                    guard let combo else {
                        shortcuts[command] = nil
                        rejected = nil
                        return
                    }
                    if let problem = shortcuts.shortcuts.problem(with: combo, for: command,
                                                                 recorder: liveRecorderShortcuts) {
                        rejected = problem
                    } else {
                        rejected = nil
                        shortcuts[command] = combo
                    }
                }
                Button {
                    shortcuts.shortcuts.reset(command)
                    rejected = nil
                } label: {
                    Image(systemName: "arrow.uturn.backward.circle")
                }
                .buttonStyle(.borderless)
                .help(resetHelp)
                .accessibilityLabel("Restore the default for \(command.title)")
                .opacity(shortcuts.shortcuts.isCustomised(command) ? 1 : 0)
                .disabled(!shortcuts.shortcuts.isCustomised(command))
                statusIcon.frame(width: 18)
            }
        }
    }

    private var resetHelp: String {
        guard let original = command.defaultShortcut else { return "Back to no shortcut, as it shipped" }
        return "Back to \(original.displayString)"
    }

    private var storedProblem: EditorShortcutProblem? {
        guard let combo = shortcuts[command] else { return nil }
        return shortcuts.shortcuts.problem(with: combo, for: command, recorder: liveRecorderShortcuts)
    }

    private var note: String? {
        rejected?.message ?? storedProblem?.message
    }

    @ViewBuilder
    private var statusIcon: some View {
        if rejected != nil || storedProblem != nil {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                .help(note ?? "This shortcut has a problem")
        } else if shortcuts[command] == nil {
            Image(systemName: "minus.circle").foregroundStyle(.tertiary)
                .help("No shortcut")
        } else {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                .help("Ready")
        }
    }
}

/// One action, its shortcut, whether it is working, and what is wrong with it if anything is.
private struct ShortcutRow: View {
    let action: RecorderAction
    @Bindable var preferences: RecorderPreferences
    /// Asked before a new key is taken, so a global shortcut never lands on a key an editor
    /// menu has — it would take that key away from the editor for as long as it is set.
    let editor: EditorShortcutPreferences
    @State private var rejected: ShortcutProblem?

    var body: some View {
        StudioSettingsRow(action.title, subtitle: note, symbol: symbol, tint: tint) {
            HStack(spacing: 10) {
                ShortcutField(title: action.title, combo: preferences.shortcuts[action]) { combo in
                    guard let combo else {
                        preferences.shortcuts[action] = nil
                        rejected = nil
                        return
                    }
                    if let problem = preferences.shortcuts.problem(with: combo, for: action,
                                                                   editor: editor.shortcuts) {
                        rejected = problem
                    } else {
                        rejected = nil
                        preferences.shortcuts[action] = combo
                    }
                }
                Button {
                    preferences.shortcuts[action] = action.defaultShortcut
                    rejected = nil
                } label: {
                    Image(systemName: "arrow.uturn.backward.circle")
                }
                .buttonStyle(.borderless)
                .help("Back to \(action.defaultShortcut.displayString)")
                .accessibilityLabel("Restore the default for \(action.title)")
                .opacity(isCustomised ? 1 : 0)
                .disabled(!isCustomised)
                statusIcon.frame(width: 18)
            }
        }
    }

    private var isCustomised: Bool { preferences.shortcuts[action] != action.defaultShortcut }

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
    /// Whether Delete clears the shortcut rather than becoming it. On for the recorder,
    /// whose shortcuts always need a modifier; off for the editor, where plain Delete is
    /// Delete Selection's and has to be something a row can be given.
    var clearsOnDelete = true
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
            case kVK_Delete where clearsOnDelete, kVK_ForwardDelete where clearsOnDelete:
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
