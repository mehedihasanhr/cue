import AppKit

/// Klik is a menu-bar agent (`LSUIElement`). Every window is opened programmatically
/// from the AppDelegate, so the app runs on a plain AppKit lifecycle with a
/// programmatic main menu (see `MainMenu`) — no storyboard, no SwiftUI `App` scene.
@main
enum KlikApp {
    static func main() {
        // Diagnostics: `--env KLIK_DEBUG_DEFAULTS="clock.enabled=false,color.enabled=true"`
        // sets those defaults before anything reads them.
        if let spec = ProcessInfo.processInfo.environment["KLIK_DEBUG_DEFAULTS"] {
            for pair in spec.split(separator: ",") {
                let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                guard parts.count == 2 else { continue }
                switch parts[1] {
                case "": UserDefaults.standard.removeObject(forKey: parts[0])
                case "true", "false": UserDefaults.standard.set(parts[1] == "true", forKey: parts[0])
                default: UserDefaults.standard.set(Int(parts[1]) ?? parts[1], forKey: parts[0])
                }
            }
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // `NSApplication.delegate` is unowned; keep the delegate alive for the whole run.
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
