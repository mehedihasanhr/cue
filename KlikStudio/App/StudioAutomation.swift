import AppKit

/// Being tested without being in the way.
///
/// The app is operated by a tool while somebody is using the Mac for something else. An
/// editor that comes to the front every time a recording is opened is right for a person
/// who asked for it and wrong for a test that did not: it pulls them out of whatever they
/// were doing. With `KLIK_STUDIO_QUIET` set, windows open behind everything and the app
/// does not make itself active.
///
/// Debug builds only. A shipped app has no such switch to find.
enum StudioAutomation {
    static let isQuiet: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.environment["KLIK_STUDIO_QUIET"] != nil
        #else
        false
        #endif
    }()

    /// Puts the app in the appearance a test asked for, for this process only.
    ///
    /// Both appearances have to be looked at, and the only other way to see the second
    /// one is to change the whole Mac's, under the person using it.
    @MainActor
    static func applyAppearance() {
        #if DEBUG
        switch ProcessInfo.processInfo.environment["KLIK_STUDIO_APPEARANCE"] {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
        #endif
    }

    /// Shows a window the way the moment calls for: in front and active for a person,
    /// behind everything and inactive for a test.
    @MainActor
    static func present(_ controller: NSWindowController) {
        if isQuiet {
            controller.window?.orderBack(nil)
        } else {
            controller.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
