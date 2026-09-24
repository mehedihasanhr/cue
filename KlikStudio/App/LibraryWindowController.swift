import AppKit
import SwiftUI

/// The window Recordings lives in.
///
/// An `NSWindowController` rather than a SwiftUI `Window` scene, for the same reason the
/// editor is one. A `Window` scene opens itself at launch whether or not the app wants it,
/// and — once the editors stopped being scenes, so SwiftUI could see none of its own
/// windows on screen — opened itself again on every activation. Three separate attempts to
/// dismiss it from the outside each worked until the next thing SwiftUI did.
///
/// The app is the floating bar. Recordings is somewhere you go, so it exists when it is
/// asked for and not before.
@MainActor
final class LibraryWindowController: NSWindowController {
    init(model: RecorderModel?, studio: StudioService, settings: StudioSettings) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered,
                              defer: false)
        window.title = "Recordings"
        window.isReleasedWhenClosed = false
        window.contentMinSize = CGSize(width: 440, height: 420)
        // macOS must not bring this back by itself.
        //
        // An AppKit window is restorable by default, so having taken Recordings out of
        // SwiftUI — which reopened it on every activation — it promptly started reopening
        // itself at launch instead, from saved window state. The app is the bar; this is
        // somewhere you go. It appears when it is asked for, and at no other time.
        window.isRestorable = false

        let hosting = NSHostingController(rootView: LibraryWindow(model: model)
            .environment(studio)
            .environment(settings))
        // The window's size is the window's business — the same reason the editor says so.
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(CGSize(width: 520, height: 620))
        window.setFrameAutosaveName("KlikStudioRecordings")

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
