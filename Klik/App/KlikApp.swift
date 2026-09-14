import AppKit

/// Klik is a menu-bar agent (`LSUIElement`). Every window is opened programmatically
/// from the AppDelegate, so the app runs on a plain AppKit lifecycle with a
/// programmatic main menu (see `MainMenu`) — no storyboard, no SwiftUI `App` scene.
@main
enum KlikApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // `NSApplication.delegate` is unowned; keep the delegate alive for the whole run.
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
