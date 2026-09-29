import AddOnKit
import AppKit
import SwiftUI

/// The Studio page: the recorder, and what Klik asks it for.
///
/// Named for what it is rather than `StudioSettingsView`, which is the add-on's *own*
/// settings window in the other target. Two apps, two pages, and only one of them is this.
///
/// Klik Studio is a separate application, so this page is the whole of Klik's relationship
/// with it: a way in when it is installed, a way to get it when it is not, and the handful
/// of settings that travel in the `RecordingRequest` each time you press Record. Add-ons
/// keeps the list; the recorder gets a page, because it is the feature people came for.
struct StudioAddOnSettingsView: View {
    @Environment(AddOnRegistry.self) private var registry
    @Environment(StudioPreferences.self) private var studio

    private var addOn: AddOn { AddOnCatalog.studio }
    private var availability: AddOnAvailability { registry.availability(of: addOn) }

    var body: some View {
        SettingsPane(.studio) {
            // No title over it: the row carries the app's own name and icon, and a group
            // called "Klik Studio" above a row called "Klik Studio" says it twice.
            SettingsGroup(footer: footer) {
                AddOnRow(addOn: addOn)
            }

            if availability.isUsable {
                recordingSettings
            }

            developerSettings
        }
        .task { await registry.refresh() }
    }

    private var footer: String {
        if let error = registry.feedError {
            return "Klik couldn't check for a newer Klik Studio: \(error)"
        }
        if availability.isUsable {
            return "Klik Studio records the screen, edits the take and exports it. Opening it brings up its recorder bar; what it records lands in its own library."
        }
        return "Screen recording is its own app, so an install that only takes screenshots downloads none of it. Klik finds it, checks it was signed by the same developer, and launches it."
    }

    // MARK: - What Klik asks for

    @ViewBuilder
    private var recordingSettings: some View {
        @Bindable var studio = studio

        SettingsGroup("Recording", footer: "Klik hands these to Klik Studio each time you record.") {
            SettingsRow("Countdown", subtitle: "Seconds before the first frame", symbol: "timer", tint: .orange) {
                Picker("Countdown", selection: $studio.countdownSeconds) {
                    Text("None").tag(0)
                    ForEach([3, 5, 10], id: \.self) { Text("\($0)s").tag($0) }
                }
                .fixedSize()
            }
            SettingsRow("System audio", subtitle: "What the Mac is playing", symbol: "speaker.wave.2.fill", tint: .blue) {
                Toggle("System audio", isOn: $studio.recordsSystemAudio)
            }
            SettingsRow("Microphone", subtitle: "Asks for permission the first time", symbol: "mic.fill", tint: .red) {
                Toggle("Microphone", isOn: $studio.recordsMicrophone)
            }
            SettingsRow("Open the editor when a recording stops", symbol: "slider.horizontal.below.rectangle", tint: .purple) {
                Toggle("Open editor", isOn: $studio.opensEditorAfterRecording)
            }
            SettingsRow("Save recordings to",
                        subtitle: studio.recordingsFolder?.path(percentEncoded: false) ?? "Klik Studio's own library, in Movies",
                        symbol: "folder.fill", tint: .teal) {
                HStack(spacing: 8) {
                    if studio.recordingsFolder != nil {
                        Button("Reset") { studio.clearRecordingsFolder() }
                    }
                    Button("Choose…") { studio.chooseRecordingsFolder() }
                }
            }
        }
    }

    // MARK: - Pointing Klik at a build

    @ViewBuilder
    private var developerSettings: some View {
        SettingsGroup("Advanced",
                      footer: "Use this to run a build of Klik Studio from Xcode, or a copy kept outside Applications. It is signature-checked like any other.") {
            SettingsRow("Klik Studio build",
                        subtitle: studio.localBuildURL?.path(percentEncoded: false) ?? "Wherever it is installed",
                        symbol: "hammer.fill", tint: .gray) {
                HStack(spacing: 8) {
                    if studio.localBuildURL != nil {
                        Button("Forget") {
                            studio.clearLocalBuild()
                            registry.localBuildChanged()
                        }
                    }
                    Button("Choose…") {
                        studio.chooseLocalBuild()
                        registry.localBuildChanged()
                    }
                }
            }
        }
    }
}
