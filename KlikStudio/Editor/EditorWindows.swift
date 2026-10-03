import os
import AppKit
import Observation
import SwiftUI

/// The editor windows, and which of them is in front.
///
/// The editor used to be a SwiftUI `WindowGroup` opened through `openWindow`, which meant
/// three things nobody chose. Opening one depended on a scene modifier firing, and the
/// scene it was attached to is closed at launch — so a recording opened from the Finder,
/// or a take that had just stopped, often opened nothing at all. SwiftUI also opened a
/// window of its own at launch, sometimes blank and sometimes carrying a recording it had
/// remembered. And the app could not say how many editors were open, which is what the
/// recorder bar needs to know to get out of the way.
///
/// Owning the windows in AppKit answers all three. Opening one is a method call with a
/// result, the count is a fact rather than an inference, and nothing opens that was not
/// asked for.
@MainActor
@Observable
final class EditorWindows {
    /// The editor the menu bar acts on. Set as windows become main, so ⌘Z goes to the
    /// window you are looking at.
    private(set) var front: EditorSession?

    /// The one editor. Opening the recording it already shows brings it forward; opening
    /// another replaces it, so every take does not leave a window behind it.
    private(set) var current: EditorWindowController?

    /// A recording waiting for `current` to finish closing — it may be asking whether to
    /// save first — before it takes the window's place.
    private var pendingOpen: URL?
    /// Where the replaced editor sat, so its successor lands on the same spot.
    private var replacedFrame: NSRect?

    /// Every export the app has going, owned here rather than by a window.
    ///
    /// This is the object that decides that an export outlives its editor. It used to live
    /// in `EditorView`'s `@State`, behind a modal sheet: closing the window left a task
    /// writing to a file with no way to watch it or stop it, and a stray ⌘W during a
    /// ten-minute encode was simply a lost ten minutes. Windows come and go; this does not,
    /// so a job filed here finishes whatever happens to the editor that asked for it.
    let exports = ExportJobs()

    @ObservationIgnored private var settings: StudioSettings?

    /// Told whenever an editor opens or closes. The bar listens, because "is an editor on
    /// screen?" is the whole of its visibility rule.
    @ObservationIgnored var onChange: (() -> Void)?

    var isEmpty: Bool { current == nil }

    func configure(settings: StudioSettings) {
        self.settings = settings
        // An export that lands while an editor is open announces itself in that window's
        // toolbar. One that lands after the last editor has closed has nowhere to do that,
        // so it shows itself the only way left: the file, selected in the Finder. Same
        // rule a download finishing has followed on this platform for twenty years.
        //
        // Settings › Export can ask for more than that: the Finder every time, or the file
        // opened. Read when the export lands rather than when it started, so changing it
        // mid-encode applies to the file that is still coming.
        exports.onFinish = { [weak self] job in
            guard let self else { return }
            switch self.settings?.app.afterExport ?? .announce {
            case .announce: if self.isEmpty { job.reveal() }
            case .reveal: job.reveal()
            case .open: job.open()
            }
        }
    }

    /// Opens a recording for editing, or brings its window forward if it is already open.
    /// A different recording replaces the open one rather than opening beside it.
    func open(_ url: URL) {
        if let current {
            if Self.key(for: current.session.packageURL) == Self.key(for: url) {
                // Asked for the one on screen: whatever replacement was waiting is off.
                pendingOpen = nil
                replacedFrame = nil
                StudioAutomation.present(current)
                return
            }
            // Closed the way the close button closes it, so unsaved edits still get their
            // Save / Discard / Cancel sheet. The new editor opens from `closed(_:)`.
            // A close already under way — its sheet still up — just gets a new successor,
            // not a second sheet.
            let closing = pendingOpen != nil
            pendingOpen = url
            if closing { return }
            replacedFrame = current.window?.frame
            StudioAutomation.present(current)
            current.window?.performClose(nil)
            return
        }
        guard let settings else {
            StudioLog.app.error("An editor was asked for before the app had finished starting")
            return
        }

        let controller = EditorWindowController(session: EditorSession(packageURL: url),
                                                settings: settings,
                                                exports: exports,
                                                windows: self)
        current = controller
        // The menu bar's editor from the moment there is one, rather than from the moment
        // its window becomes main. There is only ever one editor, so there is nothing to
        // wait to find out — and a window that opens without coming to the front, behind
        // the Recordings list or while another app is in use, never becomes main at all:
        // every command in the menu bar was disabled with the editor plainly open.
        front = controller.session
        if let window = controller.window {
            if let replacedFrame {
                window.setFrame(replacedFrame, display: false)
            } else {
                window.center()
            }
        }
        replacedFrame = nil
        StudioAutomation.present(controller)
        onChange?()
    }

    /// Closes every editor. Used at launch, when anything still open is left over rather
    /// than asked for.
    func closeAll() {
        pendingOpen = nil
        replacedFrame = nil
        current?.close()
    }

    // MARK: - Told by the windows

    func becameFront(_ session: EditorSession) {
        front = session
    }

    func closed(_ controller: EditorWindowController) {
        if current === controller { current = nil }
        // The menu must not keep acting on a window that has gone.
        if front === controller.session { front = nil }
        let next = pendingOpen
        pendingOpen = nil

        // Told on the next turn of the run loop, not this one.
        //
        // This is reached from `windowWillClose`, which fires *while* the window is going:
        // it is still in the window list, still visible, and AppKit has not yet handed key
        // and main to whatever is left. Bringing the recorder bar up inside that moment
        // puts it in front of a reshuffle that is still happening, and it loses — the bar
        // is ordered front and then ordered straight back out, so closing the last editor
        // left the app with nothing on screen at all.
        //
        // A replacement waiting on this close opens first, so the bar sees an editor on
        // screen and never flashes up between the two.
        Task { @MainActor in
            if let next { self.open(next) }
            self.onChange?()
        }
    }

    /// The editor stayed open — Cancel on its save sheet, or a save that failed — so the
    /// recording that was going to replace it does not.
    func closeCancelled() {
        pendingOpen = nil
        replacedFrame = nil
    }

    /// The same recording reached by two different paths — a Finder open and a row in the
    /// library — must be one window, so the key is the resolved path rather than whatever
    /// spelling arrived.
    private static func key(for url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
}

/// The window one recording is edited in.
@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    let session: EditorSession
    private let windows: EditorWindows
    private let exports: ExportJobs

    init(session: EditorSession, settings: StudioSettings, exports: ExportJobs, windows: EditorWindows) {
        self.session = session
        self.windows = windows
        self.exports = exports

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_280, height: 860),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered,
                              defer: false)
        // The editor draws its own title bar (`EditorToolbar`), so the system's is emptied
        // and the content runs to the top of the window with the traffic lights over it.
        // Safe to say here, unlike on a window SwiftUI is managing, because this one is
        // ours from the moment it is made.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // Still set: it is the name the Window menu and Mission Control read.
        window.title = session.packageURL.deletingPathExtension().lastPathComponent
        window.isReleasedWhenClosed = false
        // Nor an editor: a recording is something you open, and one restored at launch is
        // a window in front of the recorder that nobody asked for. This was the SwiftUI
        // `WindowGroup`'s worst habit and it is not worth inheriting in AppKit.
        window.isRestorable = false

        let hosting = NSHostingController(rootView: EditorView(session: session)
            .environment(settings)
            .environment(exports))
        // The window decides its own size, not the view.
        //
        // A hosting controller reports its SwiftUI content's ideal size as a preferred
        // content size, and AppKit resizes the window to match. While a recording is still
        // loading that content is a progress spinner, so the editor opened as a 926 × 444
        // window and then stayed that size. Nothing here wants that: an editor opens at a
        // size worth editing in.
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(CGSize(width: 1_280, height: 860))
        window.contentMinSize = CGSize(width: 960, height: 680)

        super.init(window: window)
        window.delegate = self
        session.presentationHandler = { [weak self] on in self?.setPresenting(on) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func windowDidBecomeMain(_ notification: Notification) {
        windows.becameFront(session)
    }

    /// Whether the unsaved-changes sheet has already been answered for this close.
    private var isClosingDeliberately = false

    /// Closing an edited recording asks first.
    ///
    /// The edits are a file inside the package, not something the window holds, so
    /// "carry on later" only works if they were written. Until this, closing the window
    /// silently threw away everything since the last ⌘S — which is the one thing an
    /// editor is not allowed to do.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !isClosingDeliberately, let model = session.model else { return true }
        if model.isUnsaved {
            askToKeep(model, before: sender)
            return false
        }
        guard model.isDirty else { return true }

        // With autosave on, the edits are written now and the window closes on its own
        // once they are; the sheet below is only for a write that failed, which is the
        // one time somebody has to be told and asked.
        if model.autosaver.isEnabled {
            Task { @MainActor [weak self] in
                guard let self else { return }
                if await model.autosaver.flush() {
                    self.isClosingDeliberately = true
                    sender.close()
                } else {
                    self.askToSave(model, before: sender)
                }
            }
            return false
        }

        askToSave(model, before: sender)
        return false
    }

    /// Closes the window with no more questions, for a caller that has already settled
    /// what happens to the recording.
    func closeDeliberately() {
        isClosingDeliberately = true
        window?.close()
    }

    /// Save / Don't Save / Cancel for a fresh take nobody has kept: kept with its edits,
    /// or deleted for good.
    private func askToKeep(_ model: EditorModel, before sender: NSWindow) {
        RecordingKeep.ask(about: model.name, over: sender) { [weak self] answer in
            guard let self else { return }
            switch answer {
            case .save:
                Task { @MainActor in
                    guard await model.autosaver.flush() else {
                        if let failure = model.autosaver.failure { model.report(EditorProblem(failure)) }
                        self.windows.closeCancelled()
                        return
                    }
                    model.keep()
                    self.closeDeliberately()
                }
            case .delete:
                let package = model.packageURL
                self.closeDeliberately()
                RecordingKeep.discard(package, after: self.exports)
            case .cancel:
                self.windows.closeCancelled()
            }
        }
    }

    /// The Save / Discard / Cancel sheet, for edits that are not on disk.
    private func askToSave(_ model: EditorModel, before sender: NSWindow) {
        let alert = NSAlert()
        alert.messageText = "Save the changes to “\(model.name)”?"
        alert.informativeText = model.autosaver.failure
            ?? "Your edits are kept inside the recording, so you can open it and carry on. If you don't save them, they are lost."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: sender) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                Task { @MainActor in
                    // Still dirty means the save failed, and the toolbar is now saying
                    // why. Closing anyway would throw the work away on the way past the
                    // explanation.
                    guard await model.autosaver.flush() else {
                        if let failure = model.autosaver.failure {
                            model.report(EditorProblem(failure))
                        }
                        self.windows.closeCancelled()
                        return
                    }
                    self.isClosingDeliberately = true
                    sender.close()
                }
            case .alertSecondButtonReturn:
                self.isClosingDeliberately = true
                sender.close()
            default:
                self.windows.closeCancelled()
            }
        }
    }

    // MARK: - Full-screen preview

    /// Whether this window went full screen *for* the preview, and so should come back out
    /// of it when the preview ends. An editor somebody had already made full screen stays
    /// that way: leaving the preview is not asking to leave full screen.
    private var enteredFullScreenToPresent = false
    private var escapeMonitor: Any?

    private func setPresenting(_ on: Bool) {
        guard let window else { return }
        let isFullScreen = window.styleMask.contains(.fullScreen)
        session.presentationChanged(on)
        if on {
            watchForEscape()
            // Quiet automation must not carry the user off to a new Space: there the
            // preview is shown in the window as it is.
            if !isFullScreen, !StudioAutomation.isQuiet {
                enteredFullScreenToPresent = true
                window.toggleFullScreen(nil)
            }
        } else {
            stopWatchingForEscape()
            if enteredFullScreenToPresent, isFullScreen { window.toggleFullScreen(nil) }
            enteredFullScreenToPresent = false
        }
    }

    /// Leaving full screen some other way — the green button, ⌃⌘F, Mission Control — ends
    /// the preview too, so the window never comes back as a bare picture with no editor.
    func windowDidExitFullScreen(_ notification: Notification) {
        enteredFullScreenToPresent = false
        guard session.isPresenting else { return }
        stopWatchingForEscape()
        session.presentationChanged(false)
    }

    /// Esc leaves the preview, as it leaves every full-screen player. A local monitor
    /// rather than a key handler on the view, so it answers whatever in the window has the
    /// keyboard — and only while the preview is up, so Esc keeps its other meanings.
    private func watchForEscape() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53, event.window === self.window,
                  self.window?.attachedSheet == nil, self.session.isPresenting else { return event }
            self.setPresenting(false)
            return nil
        }
    }

    private func stopWatchingForEscape() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
    }

    func windowWillClose(_ notification: Notification) {
        stopWatchingForEscape()
        // Silenced here rather than left to deallocation: a window that is closing has
        // stopped being something you are listening to, and the sound should go with the
        // picture rather than a moment after it.
        session.model?.silence()
        // Nothing here touches the exports, and that is the point. `silence()` stops the
        // things that only make sense while you are looking at the window — playback, the
        // preview's audio, a waveform being drawn. An export is not one of those: it is
        // work the user asked for, it holds everything it needs by value, and it belongs
        // to `EditorWindows` precisely so that closing this window cannot end it.
        windows.closed(self)
    }
}
