import AppKit
import SwiftUI

/// Klik is a menu-bar agent (`LSUIElement`). Every window is opened programmatically
/// from the AppDelegate; SwiftUI is here for the menu bar, which the video editor's
/// commands are written for — the one scene is an empty Settings scene nothing opens.
@main
struct KlikApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var studioSettings: StudioSettings
    @State private var studio: StudioService

    init() {
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
        // Made here, before the delegate exists, because the menu bar below reads them:
        // the recorder, the library, the editor and their settings share this one pair.
        let settings = StudioSettings()
        let studio = StudioService(settings: settings)
        _studioSettings = State(initialValue: settings)
        _studio = State(initialValue: studio)
        AppDelegate.studioHandOff = (settings, studio)
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            // Klik's own Settings window, which SwiftUI's scene cannot be; recording and the
            // video editor keep theirs, beside it.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { delegate.showSettings(nil) }
                    .keyboardShortcut(",")
                Button("Recording & Video Settings…") { StudioController.openSettings() }
            }
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .windowList) {
                Button("Recorder Bar") { delegate.studio.toggleBar() }
                    .keyboardShortcut("0", modifiers: [.command, .shift])
                Button("Recordings") { delegate.studio.showLibrary() }
                    .keyboardShortcut("l")
                Divider()
                // Every command in the menu bar, by name. See `CommandMenuController`.
                Button("Command Menu…") { CommandMenuController.shared.toggle() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
            }
        }
        .commands { EditorCommands(windows: delegate.studio.editors, shortcuts: studioSettings.editorShortcuts) }
        .commands { RecorderCommands(studio: studio, settings: studioSettings) }
    }
}
