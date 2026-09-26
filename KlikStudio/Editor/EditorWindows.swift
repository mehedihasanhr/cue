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

    /// One window per recording, so opening the same one twice brings it forward rather
    /// than making a second editor for one file.
    private var controllers: [URL: EditorWindowController] = [:]

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

    var isEmpty: Bool { controllers.isEmpty }

    func configure(settings: StudioSettings) {
        self.settings = settings
        // An export that lands while an editor is open announces itself in that window's
        // toolbar. One that lands after the last editor has closed has nowhere to do that,
        // so it shows itself the only way left: the file, selected in the Finder. Same
        // rule a download finishing has followed on this platform for twenty years.
        exports.onFinish = { [weak self] job in
            guard let self, self.isEmpty else { return }
            job.reveal()
        }
    }

    /// Opens a recording for editing, or brings its window forward if it is already open.
    func open(_ url: URL) {
        let key = Self.key(for: url)
        if let existing = controllers[key] {
            existing.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
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
        controllers[key] = controller
        // Offset from the last one so a second take does not land exactly on the first.
        if let window = controller.window {
            if let previous = controllers.values.first(where: { $0 !== controller })?.window {
                window.setFrameTopLeftPoint(previous.frame.origin.applying(.init(translationX: 24, y: -24)))
                window.cascadeTopLeft(from: previous.frame.origin)
            } else {
                window.center()
            }
        }
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        onChange?()
    }

    /// Closes every editor. Used at launch, when anything still open is left over rather
    /// than asked for.
    func closeAll() {
        for controller in controllers.values { controller.close() }
    }

    // MARK: - Told by the windows

    func becameFront(_ session: EditorSession) {
        front = session
    }

    func closed(_ controller: EditorWindowController) {
        controllers[Self.key(for: controller.session.packageURL)] = nil
        // The menu must not keep acting on a window that has gone.
        if front === controller.session { front = controllers.values.first?.session }

        // Told on the next turn of the run loop, not this one.
        //
        // This is reached from `windowWillClose`, which fires *while* the window is going:
        // it is still in the window list, still visible, and AppKit has not yet handed key
        // and main to whatever is left. Bringing the recorder bar up inside that moment
        // puts it in front of a reshuffle that is still happening, and it loses — the bar
        // is ordered front and then ordered straight back out, so closing the last editor
        // left the app with nothing on screen at all.
        Task { @MainActor in self.onChange?() }
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

    init(session: EditorSession, settings: StudioSettings, exports: ExportJobs, windows: EditorWindows) {
        self.session = session
        self.windows = windows

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
        guard !isClosingDeliberately, let model = session.model, model.isDirty else { return true }

        let alert = NSAlert()
        alert.messageText = "Save the changes to “\(model.name)”?"
        alert.informativeText = "Your edits are kept inside the recording, so you can open it and carry on. If you don't save them, they are lost."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: sender) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                model.save()
                // Still dirty means the save failed, and `model.errorMessage` is about
                // to say why. Closing anyway would throw the work away on the way past
                // the explanation.
                guard !model.isDirty else { return }
                self.isClosingDeliberately = true
                sender.close()
            case .alertSecondButtonReturn:
                self.isClosingDeliberately = true
                sender.close()
            default:
                break
            }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
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
