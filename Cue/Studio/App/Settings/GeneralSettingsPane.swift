import AppKit
import SwiftUI

/// Where recordings go, and what happens when one stops. Login, the Dock and the theme
/// are Cue's own settings.
struct GeneralSettingsPane: View {
    @Environment(StudioSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings

        StudioSettingsPane(.general) {
            StudioSettingsGroup("Recordings") {
                StudioSettingsRow(settings.isUsingDefaultLibrary ? "Movies › Cue Studio" : settings.library.lastPathComponent,
                            // The container's Movies is a link to the real one; show where the files really are.
                            subtitle: settings.library.resolvingSymlinksInPath().path(percentEncoded: false),
                            symbol: "folder.fill", tint: .orange) {
                    HStack(spacing: 8) {
                        Button("Choose") { chooseLibrary() }
                        RevealButton(help: "Show in Finder") { revealLibrary() }
                    }
                }
                if !settings.isUsingDefaultLibrary {
                    StudioSettingsRow("Default folder", subtitle: "Movies › Cue Studio") {
                        Button("Use Default Folder") { settings.resetLibrary() }
                    }
                }
                StudioSettingsRow("When a recording stops",
                                  subtitle: "Copy and Save export with the last export settings; Quick share offers Edit, Save, Copy and Share.") {
                    Picker("", selection: $settings.afterRecording) {
                        ForEach(AfterRecording.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
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
