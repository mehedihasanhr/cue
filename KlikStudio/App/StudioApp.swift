import AddOnKit
import AppKit
import RecordKit
import SwiftUI

/// Klik Studio — the recording add-on.
///
/// A separate application on purpose: everything heavy about recording a screen (the
/// encoder, the GPU renderer, the caption model) lives here, so Klik itself stays an
/// 11 MB screenshot tool for the people who only want one. It runs when asked and
/// exits after, and Klik links none of it — only `AddOnKit`, which is types.
@main
struct StudioApp: App {
    @NSApplicationDelegateAdaptor(StudioAppDelegate.self) private var delegate
    @State private var settings: StudioSettings
    @State private var studio: StudioService

    init() {
        // Both are made here and handed down, so the bar, the library, the editor and
        // Settings are looking at one set of preferences rather than four copies.
        let settings = StudioSettings()
        let studio = StudioService(settings: settings)
        _settings = State(initialValue: settings)
        _studio = State(initialValue: studio)
        // Handed to the delegate here, so the bar can be built from
        // `applicationDidFinishLaunching` rather than from a window that may never open.
        StudioAppDelegate.handOff = (settings, studio)
    }

    var body: some Scene {
        // Neither the recorder bar, the library, the editor nor Settings is a scene: they
        // are `NSWindow`s this app owns, for the reasons written on `EditorWindows`,
        // `LibraryWindowController` and `StudioSettingsWindowController`. What is left for
        // SwiftUI is the menu bar — and an `App` must have a scene to hang that on, so this
        // is an empty one whose menu item is replaced below and which nothing ever opens.
        Settings {
            EmptyView()
        }
        .commands {
            // Settings… opens the app's own window, which SwiftUI's scene cannot be.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { StudioAppDelegate.openSettings() }
                    .keyboardShortcut(",")
            }
            // A recorder has nothing to make with ⌘N; the bar is the whole app.
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .windowList) {
                Button("Recorder Bar") { delegate.bar?.toggle() }
                    .keyboardShortcut("0", modifiers: [.command, .shift])
                Button("Recordings") { delegate.showLibrary() }
                    .keyboardShortcut("l")
                Divider()
                // Every command in the menu bar, by name. See `CommandMenuController`.
                Button("Command Menu…") { CommandMenuController.shared.toggle() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
            }
        }
        // Real menu items rather than shortcuts hidden on buttons: nothing lists those,
        // nothing says what they do, and ⌘Z had nowhere to live at all. Attached to this
        // scene because `.commands` builds the app's one menu bar wherever it is written,
        // and the editor is no longer a scene to hang it on.
        .commands { EditorCommands(windows: delegate.editors, shortcuts: settings.editorShortcuts) }
        // Start, hold, restart, mark and stop, with the global shortcuts written beside
        // them — the same verbs as the menu bar icon, for when that is turned off.
        .commands { RecorderCommands(studio: studio, settings: settings) }
    }
}

/// Everything the app needs AppKit for — which, now that the bar, the library and the
/// editors are all `NSWindow`s it owns, is nearly all of the app's window management.
@MainActor
final class StudioAppDelegate: NSObject, NSApplicationDelegate {
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

    /// The two objects `StudioApp.init()` makes, parked where a delegate can reach them.
    ///
    /// The bar used to be built from the library window's `task`, on the reasoning that the
    /// window opens at launch and so the task always runs. It does not always run. SwiftUI
    /// decides for itself what to open at launch, and when it chose to bring back an editor
    /// instead, the library was never built, the task never fired, and the app came up with
    /// no recorder bar at all — the one thing it is. Launching is the application's event,
    /// not a view's, so it is handled where the application reports it.
    static var handOff: (settings: StudioSettings, studio: StudioService)?

    /// The one delegate, for the statics below.
    ///
    /// `NSApp.delegate as? StudioAppDelegate` is the obvious way to write this, and it
    /// does not work: `@NSApplicationDelegateAdaptor` does not put this object there, so
    /// the cast fails and every static below becomes a method that silently does nothing
    /// — which is exactly what clicking a recording in Recordings did. AppKit hands this
    /// object its own launch notification, so that is where the reference is taken from:
    /// a fact, rather than an assumption about what SwiftUI installed.
    private(set) static weak var shared: StudioAppDelegate?

    func applicationDidFinishLaunching(_ notification: Notification) {
        StudioAutomation.applyAppearance()
        StudioAutomation.listenForPointer()
        Self.shared = self
        guard let handOff = Self.handOff else { return }
        configure(settings: handOff.settings, studio: handOff.studio)
        DriveStorage.shared.resumeAtLaunch()
    }

    /// Settings, made the first time somebody asks for it and kept, so it opens where it
    /// was and on the page it was left on.
    private var settingsWindow: StudioSettingsWindowController?

    // MARK: - Appearance and the Dock

    /// Follows Settings › General: the theme, and whether the app has a Dock icon.
    ///
    /// Watched rather than pushed from the settings object, because the Dock rule reads
    /// three things — the switch, the menu bar icon, and whether an editor is open — and
    /// any of them changing is a reason to look again.
    private func followAppPreferences() {
        withObservationTracking { [weak self] in
            self?.applyAppPreferences()
        } onChange: { [weak self] in
            Task { @MainActor in self?.followAppPreferences() }
        }
    }

    private func applyAppPreferences() {
        guard let settings else { return }
        NSApp.appearance = settings.app.appearance.nsAppearance
        // A test's appearance, in a debug build, over the user's.
        StudioAutomation.applyAppearance()

        // In the Dock when asked to be; always while an editor is open, because an app
        // without a Dock icon has no menu bar and the editor's commands live there; and
        // always while the menu bar icon is off, or there would be no way back but the bar.
        let wantsDock = settings.app.showsInDock || !settings.recorder.showsMenuBarIcon || !editors.isEmpty
        let policy: NSApplication.ActivationPolicy = wantsDock ? .regular : .accessory
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
        }
    }

    func configure(settings: StudioSettings, studio: StudioService) {
        guard bar == nil else { return }
        self.studio = studio
        self.settings = settings

        editors.configure(settings: settings)
        followAppPreferences()
        // "Is an editor on screen?" is the whole of the bar's visibility rule, and now it
        // is a fact the app owns rather than a guess about what SwiftUI has opened.
        editors.onChange = { [weak self] in self?.syncBar() }
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
        // double-clicked with the app shut, or a request from Klik.
        for url in pendingOpens { studio.open(url) }
        pendingOpens.removeAll()

        // Last, because only now is what is on screen what was actually asked for. A
        // recording opened from the Finder has its editor by this point and the bar should
        // not come up in front of it; a recording *request* has no editor and the bar is
        // how that take gets stopped, so it does.
        syncBar()

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

    /// The bar is on screen exactly when no editor is.
    ///
    /// One rule in one place, rather than a hide here and a show there: every earlier
    /// version of this had two call sites that disagreed with each other at launch.
    private func syncBar() {
        editors.isEmpty ? bar?.show() : bar?.hide()
    }

    /// Recordings opened from Finder, or from anywhere else in the system.
    ///
    /// Handled here rather than with `onOpenURL` on a scene: the library window is
    /// closed at launch, and a modifier on a view that does not exist hears nothing — so
    /// double-clicking a recording with the app shut did nothing at all.
    func application(_ application: NSApplication, open urls: [URL]) {
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
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // A take under way is stopped and saved first. Quitting used to take the app down
        // with the writer still open, which left a file nothing could play: ⌘Q, a log-out
        // or a restart threw the whole take away. Then the rest is asked as usual.
        if let studio, studio.session.state.isBusy {
            Task {
                await studio.finishBeforeQuitting()
                // The rest may itself answer later — a sheet asking about unsaved edits —
                // and then it is that sheet that replies, not this.
                let answer = self.applicationShouldTerminate(sender)
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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // The bar is not an `NSWindow` anyone thinks of as a window: quitting because the
        // library was closed would take the recorder with it.
        false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Not while an editor is open, even one that has not been ordered onto a screen
        // yet: for that moment every window in the app answers "not visible", and the
        // activation that opened the editor would put the bar straight back in front of it.
        guard editors.isEmpty else { return }

        // Switching to the app with everything closed should bring the recorder back.
        if bar?.isVisible == false, !hasWindowOnScreen {
            bar?.show()
        }
    }

    /// A click on the Dock icon — which, when the app is already in front, is the only
    /// thing that happens: there is no activation to hear.
    ///
    /// Without this a click did nothing at all whenever the bar had been put away. The
    /// activation check above never ran for an app that was already active, and when it
    /// did run, the menu bar icon's own window counts as visible, so "everything closed"
    /// was never true.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // An editor open — perhaps minimised: AppKit brings it back, which is what the
        // click means.
        guard editors.isEmpty else { return true }
        // Recordings or Settings on screen: the click brings them forward, as usual.
        if hasWindowOnScreen { return true }
        // Nothing else is the app's to show: the bar is the whole of it.
        bar?.show()
        NSApp.activate()
        return false
    }

    /// Whether a window of the app's own — Recordings, Settings — is on screen. Counts only
    /// titled windows: the menu bar icon and the bar are windows too, and are not what
    /// "nothing is open" means.
    private var hasWindowOnScreen: Bool {
        NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) && $0 !== bar?.window }
    }

    /// Brings the bar back from anywhere in the app.
    ///
    /// Static because the library window is a SwiftUI scene with no route to the
    /// delegate; the delegate is a singleton in practice, so this is the honest version
    /// of what the view already assumes.
    static func showBar() {
        shared?.bar?.show()
    }

    /// Starts choosing an area or a window, from the Record menu.
    static func beginRecording(_ mode: RecorderModel.Mode) {
        shared?.bar?.begin(mode)
    }

    /// Recordings stays shut unless somebody asked for it.
    ///
    /// A `Window` scene opens itself at launch, and — now that the editors are AppKit
    /// windows and SwiftUI can see none of its own on screen — opens itself again every
    /// time the app is activated. The app is the bar; Recordings is somewhere you go. So
    /// rather than dismissing the launch one and hoping, each appearance has to be
    /// accounted for: an appearance that answers a request is kept, and the request is
    /// spent. Any other is a window nobody asked for, and it goes.
    /// Made the first time somebody asks for it, and kept so it remembers where it was.
    private var library: LibraryWindowController?

    /// Shows Recordings because somebody asked — the bar's menu, or the Window menu.
    func showLibrary() {
        guard let studio, let settings else { return }
        if library == nil {
            library = LibraryWindowController(model: bar?.model, studio: studio, settings: settings)
        }
        library?.present()
    }

    /// Opens a recording for editing, from anywhere in the app.
    ///
    /// Static for the same reason `showBar()` is: the library window is a SwiftUI scene
    /// with no route to the delegate.
    static func openEditor(_ url: URL) {
        shared?.editors.open(url)
    }

    // MARK: - Settings

    /// Opens Settings, on `section` when one is given.
    static func openSettings(_ section: StudioSettingsSection? = nil) {
        shared?.presentSettings(section)
    }

    private func presentSettings(_ section: StudioSettingsSection?) {
        guard let settings, let studio else { return }
        if settingsWindow == nil {
            settingsWindow = StudioSettingsWindowController(settings: settings, studio: studio, recorder: bar?.model)
        }
        settingsWindow?.present(section)
    }
}
