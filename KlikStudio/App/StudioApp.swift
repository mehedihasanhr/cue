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
    @Environment(\.openWindow) private var openWindow
    @State private var settings: StudioSettings
    @State private var studio: StudioService

    init() {
        // Both are made here and handed down, so the bar, the library, the editor and
        // Settings are looking at one set of preferences rather than four copies.
        let settings = StudioSettings()
        let studio = StudioService(settings: settings)
        _settings = State(initialValue: settings)
        _studio = State(initialValue: studio)
    }

    var body: some Scene {
        // The library, not the recorder: what the app opens with is the floating bar,
        // and this is where you come back to find what you recorded.
        Window("Recordings", id: "library") {
            LibraryWindow(model: delegate.bar?.model)
                .environment(studio)
                .environment(settings)
                .onOpenURL { studio.open($0) }
                .task { delegate.configure(settings: settings, studio: studio) }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 520, height: 620)
        .commands {
            // A recorder has nothing to make with ⌘N; the bar is the whole app.
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .windowList) {
                Button("Recorder Bar") { delegate.bar?.toggle() }
                    .keyboardShortcut("0", modifiers: [.command, .shift])
            }
        }
        // Stopping a take opens it for editing, and this is the only place that can
        // reliably hear about it. It used to be watched from inside the library window —
        // which the app closes at launch, because the app is the bar — so recording from
        // the bar with Recordings shut set `pendingEditorURL` and nothing ever read it.
        // A scene outlives its window; the view inside it does not.
        .onChange(of: studio.pendingEditorURL) { _, url in
            guard let url else { return }
            openWindow(id: "editor", value: url)
            studio.editorWindowOpened()
        }

        // One window per recording, keyed by its package, so two takes can be open at
        // once and reopening the same one brings its window forward instead of making a
        // second editor for the same file.
        WindowGroup("Editor", id: "editor", for: URL.self) { $url in
            if let url {
                EditorView(packageURL: url)
                    .environment(settings)
                    .frame(minWidth: 960, minHeight: 680)
            }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1_280, height: 860)
        // Real menu items rather than shortcuts hidden on buttons: nothing lists those,
        // nothing says what they do, and ⌘Z had nowhere to live at all.
        .commands { EditorCommands() }

        Settings {
            StudioSettingsView()
                .environment(settings)
                .environment(studio)
        }
    }
}

/// Everything the app needs AppKit for: the floating bar, and closing the window macOS
/// insists on opening at launch.
@MainActor
final class StudioAppDelegate: NSObject, NSApplicationDelegate {
    private(set) var bar: RecorderBarPanel?
    /// Kept so AppKit-level callbacks — opening a document, in particular — can reach
    /// the service without going through a scene that may not exist yet.
    private(set) var studio: StudioService?

    /// Recordings that arrived before there was anything to hand them to.
    private var pendingOpens: [URL] = []

    func configure(settings: StudioSettings, studio: StudioService) {
        self.studio = studio
        for url in pendingOpens { studio.open(url) }
        pendingOpens.removeAll()
        guard bar == nil else { return }
        let panel = RecorderBarPanel(settings: settings, studio: studio)
        panel.showLibrary = { Self.openWindow(id: "library") }
        panel.openSettings = { Self.openSettings() }
        bar = panel
        panel.show()

        // The library window opens because a `Window` scene always does; the app is the
        // bar, so it goes away until it is asked for. Closing it here rather than
        // suppressing the scene keeps ⇧⌘0 and the menu item working on macOS 14.
        Self.closeWindow(id: "library")
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
        (NSApp.delegate as? StudioAppDelegate)?.bar?.show()
    }

    // MARK: - Reaching SwiftUI's scenes from AppKit

    private static func window(id: String) -> NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.contains(id) == true }
    }

    static func closeWindow(id: String) {
        window(id: id)?.close()
    }

    static func openWindow(id: String) {
        if let window = window(id: id) {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            // SwiftUI recreates a closed `Window` scene when its command is invoked.
            NSApp.sendAction(Selector(("showWindow:")), to: nil, from: nil)
        }
    }

    static func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        // The selector changed name in macOS 14; both are tried so neither version is a
        // menu item that does nothing.
        if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }
}
