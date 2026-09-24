import CoreMedia
import SwiftUI
import TimelineKit

/// The editor's menu bar.
///
/// Shortcuts used to live as `.keyboardShortcut` on buttons, where nothing lists them
/// and nothing says what they will do — and where ⌘Z simply did not exist, because there
/// was no button to hang it on. Real menu items fix all of that.
///
/// Which editor they act on comes from `EditorWindows` rather than from `@FocusedValue`.
/// The focused-value route reads the front *scene*, and the editor is no longer a scene —
/// it is an `NSWindow` this app owns, which knows when it becomes main and says so. That
/// is a fact rather than an inference, and it is the same object the recorder bar asks
/// whether any editor is open.
struct EditorCommands: SwiftUI.Commands {
    let windows: EditorWindows

    private var editor: EditorModel? { windows.front?.model }

    var body: some SwiftUI.Commands {
        CommandGroup(after: .saveItem) {
            Button("Export…") { windows.front?.isExporting = true }
                .keyboardShortcut("e")
                .disabled(editor == nil)
        }

        CommandGroup(replacing: .undoRedo) {
            Button(editor?.document.undoName.map { "Undo \($0)" } ?? "Undo") { editor?.undo() }
                .keyboardShortcut("z")
                .disabled(editor?.document.canUndo != true)
            Button(editor?.document.redoName.map { "Redo \($0)" } ?? "Redo") { editor?.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(editor?.document.canRedo != true)
        }

        CommandGroup(after: .pasteboard) {
            Button("Delete") { editor?.deleteSelection() }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(editor?.canDeleteSelection != true)
            Button("Select All") { editor?.selectAll() }
                .keyboardShortcut("a")
                .disabled(editor == nil)
            Divider()
            Button("Split at Playhead") { editor?.splitAtPlayhead() }
                .keyboardShortcut("b")
                .disabled(editor == nil)
            Button("Add Zoom at Playhead") { editor?.addZoomAtPlayhead() }
                .keyboardShortcut("k")
                .disabled(editor == nil)
            Button("Auto-Zoom from Clicks and Focus") { editor?.suggestZooms() }
                .disabled(editor == nil)
            // Acts on the selected range when there is one and on a few seconds at the
            // playhead when there is not, which is why it is not disabled without a
            // selection — see `EditorModel.hidePointerOverSelection`.
            // No shortcut: ⌘⇧H is the note editor's Heading elsewhere in this app, and a
            // key that means two things depending on which window is front is worse than
            // one that means nothing.
            Button("Hide Pointer over Selection") { editor?.hidePointerOverSelection() }
                .disabled(editor == nil)
            Divider()
            Button("Add Sound…") { editor?.addSound() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(editor == nil)
            Button(editor?.timeline.sound.isMuted == true
                   ? "Unmute the Recording" : "Mute the Recording") { editor?.toggleRecordedSound() }
                .disabled(editor == nil)
        }

        CommandMenu("Playback") {
            Button(editor?.isPlaying == true ? "Pause" : "Play") { editor?.togglePlayback() }
                .keyboardShortcut(.space, modifiers: [])
            Divider()
            Button("Previous Frame") { editor?.step(-1 / 30) }
                .keyboardShortcut(.leftArrow, modifiers: [])
            Button("Next Frame") { editor?.step(1 / 30) }
                .keyboardShortcut(.rightArrow, modifiers: [])
            Button("Back a Second") { editor?.step(-1) }
                .keyboardShortcut(.leftArrow, modifiers: .shift)
            Button("Forward a Second") { editor?.step(1) }
                .keyboardShortcut(.rightArrow, modifiers: .shift)
            Button("Previous Cut") { editor?.stepToBoundary(forward: false) }
                .keyboardShortcut(.leftArrow, modifiers: .option)
            Button("Next Cut") { editor?.stepToBoundary(forward: true) }
                .keyboardShortcut(.rightArrow, modifiers: .option)
            Divider()
            Button("Go to Start") { editor?.scrub(to: .zero) }
                .keyboardShortcut(.home, modifiers: [])
            Button("Go to End") { editor?.scrub(to: editor?.duration ?? .zero) }
                .keyboardShortcut(.end, modifiers: [])
        }

        CommandGroup(after: .sidebar) {
            Button("Zoom Timeline In") {
                guard let editor else { return }
                editor.viewport.zoom(by: 2, anchoring: editor.playhead, duration: editor.duration)
            }
            .keyboardShortcut("=")
            Button("Zoom Timeline Out") {
                guard let editor else { return }
                editor.viewport.zoom(by: 0.5, anchoring: editor.playhead, duration: editor.duration)
            }
            .keyboardShortcut("-")
            Button("Fit Timeline") {
                guard let editor else { return }
                editor.viewport.fit(editor.duration)
            }
            .keyboardShortcut("0")
        }
    }
}
