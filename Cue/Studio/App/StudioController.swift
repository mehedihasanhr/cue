import AppKit
import RecordKit
import SwiftUI

/// Screen recording and the video editor, inside Cue: the recorder bar, Recordings, the
/// editor windows and their settings. Cue's `AppDelegate` owns one and hands it the
/// application events that concern it — opening a recording, quitting mid-take.
@MainActor
final class StudioController {
    private(set) var bar: RecorderBarPanel?
    /// See `RecorderCenter`.
    private(set) var recorder: RecorderCenter?
    /// Kept so AppKit-level callbacks — opening a document, in particular — can reach
    /// the service without going through a scene that may not exist yet.
    private(set) var studio: StudioService?
    /// Held for the windows that are built on demand — the library, and any editor.
    private var settings: StudioSettings?

    /// Recordings that arrived before there was anything to hand them to.
    private var pendingOpens: [URL] = []

    /// The editor windows, and which one the menu bar acts on.
    let editors = EditorWindows()

    /// The one controller, for the statics below — which views with no route to Cue's
    /// app delegate use to reach the bar, Recordings and the editor.
    private(set) static weak var shared: StudioController?

    /// Builds the bar, the shortcuts and the rest. The bar itself stays put away until
    /// somebody asks to record: Cue is a screenshot app first.
    func start(settings: StudioSettings, studio: StudioService) {
        StudioAutomation.applyAppearance()
        StudioAutomation.listenForPointer()
        Self.shared = self
        configure(settings: settings, studio: studio)
        DriveStorage.shared.resumeAtLaunch()
    }

    /// Told whenever an editor opens or closes, for the Dock rule: while one is open Cue
    /// is a regular app, because the editor's commands live in the menu bar.
    var onEditorsChange: () -> Void = {}

    func configure(settings: StudioSettings, studio: StudioService) {
        guard bar == nil else { return }
        self.studio = studio
        self.settings = settings

        editors.configure(settings: settings)
        // "Is an editor on screen?" decides whether the bar may be: it steps aside for an
        // editor, and comes back when the last one closes if it was up before.
        editors.onChange = { [weak self] in
            self?.syncBar()
            self?.onEditorsChange()
        }
        // Set before anything is drained below, so a recording that launched the app has
        // somewhere to go the moment it is read.
        studio.openEditor = { [weak self] url in self?.editors.open(url) }

        let panel = RecorderBarPanel(settings: settings, studio: studio)
        panel.showLibrary = { [weak self] in self?.showLibrary() }
        panel.openSettings = { Self.openSettings() }
        bar = panel

        // The shortcuts, the menu bar icon, the speaker notes, the camera preview and the
        // microphone meter — everything around a take that is not the bar.
        let center = RecorderCenter(studio: studio, settings: settings, bar: panel)
        center.showLibrary = { [weak self] in self?.showLibrary() }
        center.openSettings = { Self.openSettings() }
        center.restoreBar = { [weak self] in self?.syncBar() }
        recorder = center

        // Anything that arrived before there was something to hand it to — a recording
        // double-clicked with Cue shut.
        for url in pendingOpens { studio.open(url) }
        pendingOpens.removeAll()

        // A take the last run of the app never finished. Asked after everything above, so
        // a take that launched the app is already starting and the question waits.
        let showLibrary: @MainActor () -> Void = { [weak self] in self?.showLibrary() }
        Task {
            await TakeRecoveryCenter.shared.offerAtLaunch(library: settings.library,
                                                          isBusy: { studio.session.state.isBusy },
                                                          live: { studio.session.packageURL },
                                                          showLibrary: showLibrary)
        }
    }

    /// Whether the bar went away for an editor, and so comes back when the editors close.
    private var barHiddenForEditor = false

    /// The bar never shares the screen with an editor. It comes back after the last one
    /// closes only if it was up before — a take that ended in the editor, say — and
    /// otherwise stays away: Cue's menu is how it is asked for.
    private func syncBar() {
        if editors.isEmpty {
            if barHiddenForEditor { bar?.show() }
            barHiddenForEditor = false
        } else if bar?.isVisible == true {
            barHiddenForEditor = true
            bar?.hide()
        }
    }

    /// Shows the recorder bar and brings Cue forward — Record Video.
    func showRecorder() {
        bar?.show()
        NSApp.activate()
    }

    /// The Window menu's Recorder Bar: shows it, or puts it away.
    func toggleBar() {
        bar?.toggle()
    }

    /// The recording service, once started — for Cue's menu, which shows a take's controls.
    var service: StudioService? { studio }

    /// Whether a URL is a recording, for Cue's `application(_:open:)` to hand over.
    static func handles(_ url: URL) -> Bool {
        url.isFileURL && url.pathExtension.lowercased() == RecordingPackage.fileExtension
    }

    /// Recordings opened from Finder, or from anywhere else in the system.
    func open(_ urls: [URL]) {
        // A cold launch can deliver the document before the scene that builds the
        // service has run, so anything that arrives early waits rather than vanishing.
        guard let studio else {
            pendingOpens.append(contentsOf: urls)
            return
        }
        for url in urls { studio.open(url) }
    }

    /// An export in progress is worth interrupting a Quit for.
    ///
    /// The whole point of moving exports off the window is that closing an editor no longer
    /// loses one — which makes ⌘Q the only remaining way to throw minutes of encoding away
    /// by accident, and the one place left that has to ask. Answered here rather than by
    /// blocking the quit outright: somebody who means it should still be able to leave.
    func shouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // A take under way is stopped and saved first. Quitting used to take the app down
        // with the writer still open, which left a file nothing could play: ⌘Q, a log-out
        // or a restart threw the whole take away. Then the rest is asked as usual.
        if let studio, studio.session.state.isBusy {
            Task {
                await studio.finishBeforeQuitting()
                // The rest may itself answer later — a sheet asking about unsaved edits —
                // and then it is that sheet that replies, not this.
                let answer = self.shouldTerminate(sender)
                if answer != .terminateLater {
                    NSApp.reply(toApplicationShouldTerminate: answer == .terminateNow)
                }
            }
            return .terminateLater
        }
        // Unsaved edits next: written, or asked about — see `EditorWindows.readyToQuit`.
        guard editors.exports.isBusy else { return editors.readyToQuit() }

        let alert = NSAlert()
        alert.messageText = "An export is still being written."
        // Deliberately not promising a clean-up. A cancel is honoured at the next frame
        // boundary, and a process that is quitting may not be alive for it — so the file
        // it was writing may be left where it is, unfinished.
        alert.informativeText = "Quitting now stops it, and leaves the file it was writing unfinished."
        alert.addButton(withTitle: "Keep Exporting")
        alert.addButton(withTitle: "Quit Anyway")
        // Destructive, so it is not the one the Return key presses.
        alert.buttons.last?.hasDestructiveAction = true

        if alert.runModal() == .alertFirstButtonReturn { return .terminateCancel }
        // Cancelled rather than abandoned: the exporters delete what they had half written,
        // which is the difference between quitting and leaving a broken file behind.
        editors.exports.cancelAll()
        return editors.readyToQuit()
    }

    /// A click on the Dock icon: an open editor is what it brings back.
    var handlesReopen: Bool { !editors.isEmpty }

    /// Brings the bar back from anywhere in the app.
    ///
    /// Static because the library window is a SwiftUI view with no route to the
    /// controller; there is only ever one, so this is the honest version of what the view
    /// already assumes.
    static func showBar() {
        shared?.bar?.show()
    }

    /// Starts choosing an area or a window, from the Record menu.
    static func beginRecording(_ mode: RecorderModel.Mode) {
        shared?.bar?.begin(mode)
    }

    /// Recordings, made the first time somebody asks for it and kept so it remembers where
    /// it was.
    private var library: LibraryWindowController?

    /// Shows Recordings because somebody asked — Cue's menu, the bar's, or the Window menu.
    func showLibrary() {
        guard let studio, let settings else { return }
        if library == nil {
            library = LibraryWindowController(model: bar?.model, studio: studio, settings: settings)
        }
        library?.present()
        NSApp.activate()
    }

    /// Opens a recording for editing, from anywhere in the app.
    ///
    /// Static for the same reason `showBar()` is.
    static func openEditor(_ url: URL) {
        shared?.editors.open(url)
    }

    // MARK: - Settings

    /// Opens Cue Settings on a recording page — `section`, or the first one. Set by Cue's
    /// app delegate, which owns the Settings window.
    var showSettings: (StudioSettingsSection?) -> Void = { _ in }

    static func openSettings(_ section: StudioSettingsSection? = nil) {
        shared?.showSettings(section)
    }

    /// What the recording pages of Cue Settings read: the settings, the service, and the
    /// bar's model for the camera and microphone lists.
    var settingsObjects: (settings: StudioSettings, studio: StudioService, recorder: RecorderModel?)? {
        guard let settings, let studio else { return nil }
        return (settings, studio, bar?.model)
    }
}
