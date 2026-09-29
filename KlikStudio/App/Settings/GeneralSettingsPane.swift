import AppKit
import ServiceManagement
import SwiftUI

/// Where recordings go, what happens when one stops, and how the app presents itself.
struct GeneralSettingsPane: View {
    @Environment(StudioSettings.self) private var settings
    @State private var login = StudioLoginItem.state
    @State private var loginError: String?

    var body: some View {
        @Bindable var settings = settings
        @Bindable var app = settings.app
        @Bindable var recorder = settings.recorder

        SettingsPane(.general) {
            SettingsGroup("Recordings",
                          footer: "Klik can ask for a different folder per recording. If Klik Studio can't write there, it keeps the recording here instead.") {
                SettingsRow(settings.isUsingDefaultLibrary ? "Movies › Klik Studio" : settings.library.lastPathComponent,
                            subtitle: settings.library.path(percentEncoded: false),
                            symbol: "folder.fill", tint: .orange) {
                    HStack(spacing: 8) {
                        Button("Choose…") { chooseLibrary() }
                        RevealButton(help: "Show in Finder") { revealLibrary() }
                    }
                }
                if !settings.isUsingDefaultLibrary {
                    SettingsRow("Default folder", subtitle: "Movies › Klik Studio") {
                        Button("Use Default Folder") { settings.resetLibrary() }
                    }
                }
                SettingsToggleRow("Open in the editor when a recording stops",
                                  subtitle: "Off, a finished take waits in Recordings.",
                                  isOn: $settings.opensEditorAfterRecording)
            }

            SettingsGroup("Startup") {
                SettingsToggleRow("Open Klik Studio at login",
                                  subtitle: "Ready with its shortcuts the moment you log in, instead of when Klik first asks for it.",
                                  isOn: loginBinding)
                if login == .requiresApproval {
                    SettingsRow("Approval needed", subtitle: "System Settings › General › Login Items",
                                symbol: "exclamationmark.triangle.fill", tint: .orange) {
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                if let loginError {
                    SettingsRow(loginError, symbol: "xmark.octagon.fill", tint: .red)
                }
            }

            SettingsGroup("Menu bar and Dock", footer: dockFooter) {
                SettingsToggleRow("Show in the menu bar",
                                  subtitle: "Whether you are recording and for how long, with a menu to start, pause, mark and stop. Never in the recording.",
                                  isOn: $recorder.showsMenuBarIcon)
                SettingsToggleRow("Show in the Dock",
                                  subtitle: "Off, Klik Studio keeps to the menu bar — and comes back to the Dock while a recording is open for editing, so its menus are there.",
                                  isOn: dockBinding)
                    // Without either there would be no way back to the app but the bar.
                    .disabled(!recorder.showsMenuBarIcon)
            }

            SettingsGroup("Appearance", footer: "The recorder bar keeps its dark glass either way: it sits over whatever is being recorded.") {
                SettingsRow("Theme", subtitle: "Settings, Recordings and the editor.") {
                    Picker("Theme", selection: $app.appearance) {
                        ForEach(StudioAppPreferences.Appearance.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Somebody may have just approved the login item in System Settings.
            login = StudioLoginItem.state
        }
    }

    private var dockFooter: String? {
        settings.recorder.showsMenuBarIcon
            ? nil
            : "With the menu bar icon off, the Dock icon stays — otherwise the recorder bar would be the only way back to the app."
    }

    /// Shown on while the menu bar icon is off, because it is on then whatever was stored.
    private var dockBinding: Binding<Bool> {
        Binding {
            settings.app.showsInDock || !settings.recorder.showsMenuBarIcon
        } set: {
            settings.app.showsInDock = $0
        }
    }

    private var loginBinding: Binding<Bool> {
        Binding {
            login != .disabled
        } set: { isOn in
            do {
                try StudioLoginItem.setEnabled(isOn)
                loginError = nil
            } catch {
                loginError = error.localizedDescription
            }
            login = StudioLoginItem.state
        }
    }

    private func chooseLibrary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = settings.library
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.setLibrary(url)
    }

    private func revealLibrary() {
        // The default folder is made by the first recording; before then there is
        // nothing to show, so it is made here rather than the button doing nothing.
        try? FileManager.default.createDirectory(at: settings.library, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([settings.library])
    }
}

/// Registration as a login item, through `SMAppService` — which works from inside the
/// sandbox and asks for nothing the app does not already have.
enum StudioLoginItem {
    enum State {
        case enabled
        case disabled
        /// Registered, but waiting on System Settings › General › Login Items.
        case requiresApproval
    }

    static var state: State {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        default: .disabled
        }
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
