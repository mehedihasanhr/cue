import AppKit

/// What the open editor needs before the app may quit.
///
/// Quitting does not close windows the way the close button does — `windowShouldClose`
/// is never asked — so until this, ⌘Q with unsaved edits simply lost them. Now the edits
/// are written first when autosave is on, and asked about when it is off, and the quit
/// waits for the answer.
extension EditorWindows {
    /// Whether the app may quit now, may not, or should wait to be told.
    ///
    /// Waits whenever there is something to write or to ask, and answers the application
    /// through `reply(toApplicationShouldTerminate:)` once the write has landed or the
    /// person has chosen. A write that fails cancels the quit and leaves the window up
    /// with the failure showing, which is the only honest thing to do with work that is
    /// not on disk.
    func readyToQuit() -> NSApplication.TerminateReply {
        guard let model = front?.model, model.isDirty else { return .terminateNow }

        if model.autosaver.isEnabled {
            Task { @MainActor in
                let saved = await model.autosaver.flush()
                if !saved, let failure = model.autosaver.failure { model.report(EditorProblem(failure)) }
                NSApp.reply(toApplicationShouldTerminate: saved)
            }
            return .terminateLater
        }

        let alert = NSAlert()
        alert.messageText = "Save the changes to “\(model.name)”?"
        alert.informativeText = "Your edits are kept inside the recording, so you can open it and carry on. If you don't save them, they are lost."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Task { @MainActor in
                let saved = await model.autosaver.flush()
                if !saved, let failure = model.autosaver.failure { model.report(EditorProblem(failure)) }
                NSApp.reply(toApplicationShouldTerminate: saved)
            }
            return .terminateLater
        case .alertSecondButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }
}
