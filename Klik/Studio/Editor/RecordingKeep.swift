import AppKit
import os
import RecordKit
import SwiftUI

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
        guard isUnsaved(package) else { return }
        try? FileManager.default.removeItem(at: marker(in: package))
        // A draft kept is a recording like any other — and one Drive has been waiting for.
        DriveStorage.shared.recordingKept(package)
    }

    /// Deletes a take nobody kept — once nothing is still exporting from it, since an
    /// export carries on after its window closes and reads the package as it goes.
    @MainActor
    static func discard(_ package: URL, after exports: ExportJobs) {
        DriveStorage.shared.recordingDiscarded(package)
        Task { @MainActor in
            while exports.isBusy { try? await Task.sleep(for: .seconds(1)) }
            do {
                try FileManager.default.removeItem(at: package)
            } catch {
                StudioLog.app.error("Could not delete an unkept recording: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// The answer to "keep this take?".
    enum Answer { case save, delete, cancel }

    /// Asks over an editor window, as a sheet.
    @MainActor
    static func ask(about name: String, over parent: NSWindow, answered: @escaping (Answer) -> Void) {
        let sheet = prompt(for: name) { answer in
            parent.endSheet(parent.attachedSheet ?? NSWindow(), returnCode: answer.code)
        }
        parent.beginSheet(sheet) { code in answered(Answer(code)) }
    }

    /// Asks on its own, for quitting: waits for the answer.
    @MainActor
    static func askModally(about name: String) -> Answer {
        let window = prompt(for: name) { answer in NSApp.stopModal(withCode: answer.code) }
        window.center()
        defer { window.orderOut(nil) }
        return Answer(NSApp.runModal(for: window))
    }

    /// The question, drawn here rather than by `NSAlert`: the system alert colours its
    /// buttons itself, and would not draw Don't Save as the solid red a permanent delete
    /// should be — only red words on a red wash, which read poorly on the glass sheet.
    @MainActor
    private static func prompt(for name: String, answer: @escaping (Answer) -> Void) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        let hosting = NSHostingView(rootView: KeepPromptView(name: name, answer: answer))
        window.contentView = hosting
        window.setContentSize(hosting.fittingSize)
        return window
    }
}

extension RecordingKeep.Answer {
    var code: NSApplication.ModalResponse {
        switch self {
        case .save: .alertFirstButtonReturn
        case .delete: .alertSecondButtonReturn
        case .cancel: .alertThirdButtonReturn
        }
    }

    init(_ code: NSApplication.ModalResponse) {
        self = switch code {
        case .alertFirstButtonReturn: .save
        case .alertSecondButtonReturn: .delete
        default: .cancel
        }
    }
}

private struct KeepPromptView: View {
    let name: String
    let answer: (RecordingKeep.Answer) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 56, height: 56)
                .padding(.bottom, 4)
            Text("Do you want to keep \u{201C}\(name)\u{201D}?")
                .font(.system(size: 13, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
            Text("This recording hasn\u{2019}t been saved. If you don\u{2019}t save it, it\u{2019}s deleted permanently.")
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 8) {
                Button("Save") { answer(.save) }
                    .buttonStyle(PromptButton(fill: .accentColor))
                    .keyboardShortcut(.defaultAction)
                Button("Don\u{2019}t Save") { answer(.delete) }
                    .buttonStyle(PromptButton(fill: Color(nsColor: .systemRed)))
                Button("Cancel") { answer(.cancel) }
                    .buttonStyle(PromptButton(fill: Color.primary.opacity(0.1), label: .primary))
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.top, 6)
        }
        .padding(20)
        .frame(width: 280)
    }
}

/// A full-width capsule in one solid colour.
private struct PromptButton: ButtonStyle {
    let fill: Color
    var label: Color = .white

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(label)
            .frame(maxWidth: .infinity, minHeight: 30)
            .background(fill, in: Capsule())
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Capsule())
    }
}
