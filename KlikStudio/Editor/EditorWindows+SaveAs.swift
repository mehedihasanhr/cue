import AppKit
import RecordKit
import UniformTypeIdentifiers

extension EditorWindows {
    /// Saves the recording in front under a name and in a folder of the user's choosing,
    /// keeping it.
    ///
    /// The recording is moved, not copied — Save As on a fresh take means "keep it, and
    /// call it this", not "keep two" — and its editor reopens on the new place. Closed
    /// and reopened rather than told its new address: the editor holds the package's URL
    /// in a dozen places (see `LibraryCatalog.refuseWhileOpen`), and reopening is the one
    /// way that cannot leave any of them pointing at the old folder.
    func saveAs() {
        guard let controller = current, let window = controller.window,
              let model = controller.session.model else { return }
        let original = model.packageURL
        let panel = NSSavePanel()
        panel.title = "Save Recording"
        panel.nameFieldStringValue = original.deletingPathExtension().lastPathComponent
        panel.directoryURL = original.deletingLastPathComponent()
        if let type = UTType(filenameExtension: RecordingPackage.fileExtension) {
            panel.allowedContentTypes = [type]
        }
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let target = panel.url else { return }
            Task { @MainActor in
                guard await model.autosaver.flush() else {
                    if let failure = model.autosaver.failure { model.report(EditorProblem(failure)) }
                    return
                }
                let same = target.standardizedFileURL.resolvingSymlinksInPath()
                    == original.standardizedFileURL.resolvingSymlinksInPath()
                guard !same else {
                    model.keep()
                    return
                }
                controller.closeDeliberately()
                do {
                    // The panel has already asked about replacing a recording of that name.
                    if FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) {
                        try FileManager.default.trashItem(at: target, resultingItemURL: nil)
                    }
                    try FileManager.default.moveItem(at: original, to: target)
                    RecordingKeep.keep(target)
                    try? RecordingPackage(url: target).rewriteName(target.deletingPathExtension().lastPathComponent)
                    self.open(target)
                } catch {
                    // Nothing moved: back to the recording as it was, and say why.
                    self.open(original)
                    let alert = NSAlert(error: error)
                    alert.messageText = "The recording couldn\u{2019}t be saved there."
                    alert.runModal()
                }
            }
        }
    }
}
