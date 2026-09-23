import CoreMedia
import SwiftUI
import TimelineKit

/// The editor's menu bar.
///
/// Shortcuts used to live as `.keyboardShortcut` on buttons, where nothing lists them
/// and nothing says what they will do — and where ⌘Z simply did not exist, because there
/// was no button to hang it on. Real menu items fix all of that, and `@FocusedValue` is
/// what lets a menu act on whichever editor window is in front.
struct EditorModelKey: FocusedValueKey {
    typealias Value = EditorModel
}

extension FocusedValues {
    var editor: EditorModel? {
        get { self[EditorModelKey.self] }
        set { self[EditorModelKey.self] = newValue }
    }

    /// Opens the front editor's export sheet.
    ///
    /// An action rather than the sheet's own binding: whether the sheet is up is the
    /// window's business, and the menu only needs to be able to ask for it.
    var exportAction: (() -> Void)? {
        get { self[ExportActionKey.self] }
        set { self[ExportActionKey.self] = newValue }
    }
}

struct ExportActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

struct EditorCommands: SwiftUI.Commands {
    @FocusedValue(\.editor) private var editor
    @FocusedValue(\.exportAction) private var exportAction

    var body: some SwiftUI.Commands {
        CommandGroup(after: .saveItem) {
            Button("Export…") { exportAction?() }
                .keyboardShortcut("e")
                .disabled(exportAction == nil)
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
