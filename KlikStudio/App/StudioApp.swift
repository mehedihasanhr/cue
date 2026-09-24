import AddOnKit
import AppKit
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
        // Neither the recorder bar, the library nor the editor is a scene: they are
        // `NSWindow`s this app owns, for the reasons written on `EditorWindows` and
        // `LibraryWindowController`. What is left for SwiftUI is the Settings window, which
        // it handles well, and the menu bar.
        Settings {
            StudioSettingsView()
                .environment(settings)
                .environment(studio)
        }
        .commands {
            // A recorder has nothing to make with ⌘N; the bar is the whole app.
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .windowList) {
                Button("Recorder Bar") { delegate.bar?.toggle() }
                    .keyboardShortcut("0", modifiers: [.command, .shift])
                Button("Recordings") { delegate.showLibrary() }
                    .keyboardShortcut("l")
            }
        }
        // Real menu items rather than shortcuts hidden on buttons: nothing lists those,
        // nothing says what they do, and ⌘Z had nowhere to live at all. Attached to this
        // scene because `.commands` builds the app's one menu bar wherever it is written,
        // and the editor is no longer a scene to hang it on.
        .commands { EditorCommands(windows: delegate.editors) }
    }
}

/// Everything the app needs AppKit for — which, now that the bar, the library and the
/// editors are all `NSWindow`s it owns, is nearly all of the app's window management.
@MainActor
final class StudioAppDelegate: NSObject, NSApplicationDelegate {
    private(set) var bar: RecorderBarPanel?
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
        Self.shared = self
        guard let handOff = Self.handOff else { return }
        configure(settings: handOff.settings, studio: handOff.studio)
    }

    func configure(settings: StudioSettings, studio: StudioService) {
        guard bar == nil else { return }
        self.studio = studio
        self.settings = settings

        editors.configure(settings: settings)
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

        // Anything that arrived before there was something to hand it to — a recording
        // double-clicked with the app shut, or a request from Klik.
        for url in pendingOpens { studio.open(url) }
        pendingOpens.removeAll()

        // Last, because only now is what is on screen what was actually asked for. A
        // recording opened from the Finder has its editor by this point and the bar should
        // not come up in front of it; a recording *request* has no editor and the bar is
        // how that take gets stopped, so it does.
        syncBar()
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

        // Clicking the Dock icon with everything closed should bring the recorder back.
        if bar?.isVisible == false, NSApp.windows.allSatisfy({ !$0.isVisible }) {
            bar?.show()
        }
    }

    /// Brings the bar back from anywhere in the app.
    ///
    /// Static because the library window is a SwiftUI scene with no route to the
    /// delegate; the delegate is a singleton in practice, so this is the honest version
    /// of what the view already assumes.
    static func showBar() {
        shared?.bar?.show()
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

    // MARK: - Reaching SwiftUI's Settings window from AppKit

    static func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        // The selector changed name in macOS 14; both are tried so neither version is a
        // menu item that does nothing.
        if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }
}
