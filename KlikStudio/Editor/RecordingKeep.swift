import AppKit
import os
import RecordKit

/// Whether a fresh take has been kept.
///
/// A take that opens straight into the editor is a draft until somebody keeps it — Save,
/// Save As…, or Save when its window closes. One that is not kept is deleted, for good:
/// a library that fills with every false start is one nobody can find anything in.
///
/// Held as an empty file inside the package rather than in the manifest, so marking and
/// keeping never rewrite the take's own description — and anything made before this, or
/// a take Klik asked for, has no marker and is simply kept.
enum RecordingKeep {
    private static func marker(in package: URL) -> URL {
        package.appendingPathComponent("unsaved")
    }

    static func markUnsaved(_ package: URL) {
        FileManager.default.createFile(atPath: marker(in: package).path(percentEncoded: false), contents: Data())
    }

    static func isUnsaved(_ package: URL) -> Bool {
        FileManager.default.fileExists(atPath: marker(in: package).path(percentEncoded: false))
    }

    static func keep(_ package: URL) {
        try? FileManager.default.removeItem(at: marker(in: package))
    }

    /// Deletes a take nobody kept — once nothing is still exporting from it, since an
    /// export carries on after its window closes and reads the package as it goes.
    @MainActor
    static func discard(_ package: URL, after exports: ExportJobs) {
        Task { @MainActor in
            while exports.isBusy { try? await Task.sleep(for: .seconds(1)) }
            do {
                try FileManager.default.removeItem(at: package)
            } catch {
                StudioLog.app.error("Could not delete an unkept recording: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// The question asked when an unkept take is closed, or the app quits with one open.
    @MainActor
    static func alert(for name: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Do you want to keep \u{201C}\(name)\u{201D}?"
        alert.informativeText = "This recording hasn\u{2019}t been saved. If you don\u{2019}t save it, it\u{2019}s deleted permanently."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don\u{2019}t Save")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[1].hasDestructiveAction = true
        return alert
    }
}
