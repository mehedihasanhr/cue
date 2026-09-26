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
            // Named for what they act on, and placed *after* the system's Cut/Copy/Paste
            // rather than replacing them — both deliberate, and for the same reason.
            //
            // The editor has real text fields in it: a caption's words, an annotation's
            // label. ⌘C in one of those must copy text, and replacing the pasteboard group
            // would have taken that away. Sitting after it means AppKit offers the
            // responder chain the shortcut first, so a focused text field wins; with no
            // text responder the system's items are disabled and ours are reached instead.
            // The qualified names are what keeps one Edit menu from listing "Copy" twice.
            // "Selection" rather than "Region": these verbs now take footage as well, and a
            // menu item that names one of the two things it does is one the user has to
            // discover the rest of by accident. Still qualified rather than a bare "Copy",
            // for the responder-chain reason above — one Edit menu must not list "Copy"
            // twice.
            Button("Cut Selection") { editor?.cutSelection() }
                .keyboardShortcut("x")
                .disabled(editor?.canCopySelection != true)
            Button("Copy Selection") { editor?.copySelection() }
                .keyboardShortcut("c")
                .disabled(editor?.canCopySelection != true)
            Button("Paste at Playhead") { editor?.pasteAtPlayhead() }
                .keyboardShortcut("v")
                .disabled(editor?.canPasteRegion != true)
            Button("Duplicate") { editor?.duplicateSelection() }
                .keyboardShortcut("d")
                .disabled(editor?.canCopySelection != true)
            Divider()
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
            // The second-pass verbs. They act on the selected zoom, or — with nothing
            // selected — on the one under the playhead, which is why they are enabled by
            // `activeZoom` rather than by the selection: somebody scrubbing to the moment a
            // push-in should become two has their hands on the playhead.
            //
            // ⌥⌘B beside Split at Playhead's ⌘B, because it is the same cut aimed at a
            // different lane. Merge and the rest take no key: they are not things done often
            // enough to be worth a shortcut somebody has to remember, and they are all in the
            // zoom inspector where the hand already is.
            Button("Split Zoom at Playhead") { editor?.splitZoomAtPlayhead() }
                .keyboardShortcut("b", modifiers: [.command, .option])
                .disabled(editor?.canSplitZoom != true)
            Button("Merge Zoom with Next") { editor?.mergeZoomWithNext() }
                .disabled(editor?.zoomToMergeInto == nil)
            // Acts on every selected zoom, so a run of suggestions can be auditioned in one
            // press. ⌘⇧E because ⌘E is taken and this is the same idea as hiding a layer.
            Button(editor?.isActiveZoomEnabled == false ? "Turn Zoom On" : "Turn Zoom Off") {
                editor?.setZoomsEnabled()
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(editor?.activeZoom == nil)
            Button(editor?.activeZoom?.isLocked == true ? "Unlock Zoom" : "Lock Zoom") {
                editor?.toggleZoomLock()
            }
            .disabled(editor?.activeZoom == nil)
            Button("Aim Zoom on the Picture") { editor?.aimSelectedZoom() }
                .disabled(editor?.activeZoom == nil)
            Button("Reset Zoom") { editor?.resetZoom() }
                .disabled(editor?.activeZoom == nil)
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
            // ⇧⌘V, beside Add Sound…: the two are the same idea — sound laid over the
            // recording — and one of them is a file you already have while the other is
            // one you are about to make. ⌘V belongs to paste and every other letter in
            // this menu is taken.
            Button(editor?.isRecordingVoiceover == true
                   ? "Stop Recording Voiceover" : "Record Voiceover…") { editor?.toggleVoiceover() }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                .disabled(editor == nil)
            Button(editor?.timeline.sound.isMuted == true
                   ? "Unmute the Recording" : "Mute the Recording") { editor?.toggleRecordedSound() }
                .disabled(editor == nil)
            // One item that flips rather than two that can be pressed at the wrong time,
            // which is how Mute above reads too. No shortcut: every letter in this menu is
            // taken, and detaching is a decision made once per edit rather than a key you
            // reach for. Re-attaching asks first when it would throw an edit away — see
            // `EditorModel.requestSoundReattach`.
            Button(editor?.isSoundDetached == true ? "Re-attach Audio" : "Detach Audio") {
                guard let editor else { return }
                editor.isSoundDetached ? editor.requestSoundReattach() : editor.detachSound()
            }
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
