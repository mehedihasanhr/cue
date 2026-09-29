import SwiftUI
import TimelineKit

/// The Keyboard menu: the shortcuts drawn over the picture.
///
/// Its own menu, beside Captions, for the reason Captions is one: these are verbs about
/// one lane, and a lane's verbs listed inside Edit are verbs nobody finds. Its own file
/// so the menu bar's main file stays the list of menus rather than the menus themselves.
extension EditorCommands {
    private var frontEditor: EditorModel? { windows.front?.model }

    @CommandsBuilder
    var keyboard: some SwiftUI.Commands {
        CommandMenu("Keyboard") {
            // ⌥⌘K beside Add Zoom's ⌘K and Add Caption's ⌥⌘C: the same "put one here" aimed
            // at a different lane. ⌥⌘K is otherwise unused in this app.
            Button("Add Shortcut at Playhead") { frontEditor?.addKeyCueAtPlayhead() }
                .keyboardShortcut("k", modifiers: [.command, .option])
                .disabled(frontEditor == nil)
            // Acts on the selected shortcut, or — with nothing selected — the one under
            // the playhead, which is why it is enabled by `activeKeyCue`.
            Button(frontEditor?.activeKeyCue?.isHidden == true ? "Show Shortcut" : "Hide Shortcut") {
                if let cue = frontEditor?.activeKeyCue { frontEditor?.toggleKeyCueHidden(cue.id) }
            }
            .disabled(frontEditor?.activeKeyCue == nil)
            Divider()
            Button(frontEditor?.timeline.keyStyle.isVisible == false ? "Show Keys in the Video" : "Hide Keys in the Video") {
                frontEditor?.toggleKeysOverlay()
            }
            .disabled(frontEditor?.timeline.keyCues.isEmpty != false)
            Divider()
            // Only for a recording that has shortcuts to give back: greyed for one made
            // with the setting off, which the Keyboard panel explains.
            Button("Restore Recorded Shortcuts") { frontEditor?.restoreRecordedKeys() }
                .disabled(frontEditor?.hasRecordedKeys != true)
            Button("Remove All Shortcuts") { frontEditor?.removeAllKeyCues() }
                .disabled(frontEditor?.timeline.keyCues.isEmpty != false)
        }
    }
}
