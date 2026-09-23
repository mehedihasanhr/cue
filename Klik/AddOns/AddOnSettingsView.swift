import AddOnKit
import AppKit
import SwiftUI

/// The Add-ons page: what Klik can do that it does not carry.
///
/// One row per add-on, saying plainly what it is, what it costs to download and what
/// state it is in — then, once the recorder is installed, the settings Klik sends it
/// when you press Record.
struct AddOnSettingsView: View {
    @Environment(AddOnRegistry.self) private var registry
    @Environment(StudioPreferences.self) private var studio

    var body: some View {
        SettingsPane(.addOns) {
            SettingsGroup("Available", footer: footer) {
                ForEach(AddOnCatalog.all) { addOn in
                    AddOnRow(addOn: addOn)
                }
            }

            if registry.availability(of: AddOnCatalog.studio).isUsable {
                recordingSettings
            }

            developerSettings
        }
        .task { await registry.refresh() }
    }

    private var footer: String {
        if let error = registry.feedError {
            return "Klik couldn't check for add-ons: \(error)"
        }
        return "Add-ons are separate apps. Klik stays small because they aren't part of it, and removing one is removing an app."
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

/// One add-on, with the actions its current state allows.
private struct AddOnRow: View {
    let addOn: AddOn
    @Environment(AddOnRegistry.self) private var registry

    var body: some View {
        SettingsRow(addOn.name, subtitle: subtitle, symbol: addOn.symbol, tint: .red) {
            action
        }
    }

    private var state: AddOnRegistry.State { registry.state(of: addOn) }

    private var subtitle: String {
        switch state {
        case .unknown:
            addOn.summary
        case .downloading(let progress):
            "Downloading… \(Int(progress * 100))%"
        case .readyToInstall:
            "Downloaded. Finish installing it, then come back."
        case .failed(let message):
            message
        case .resolved(let availability):
            Self.describe(availability, addOn: addOn)
        }
    }

    private static func describe(_ availability: AddOnAvailability, addOn: AddOn) -> String {
        switch availability {
        case .ready(let installed):
            "Installed — version \(installed)"
        case .updatable(let installed, let release):
            "Version \(installed) installed, \(release.version) available"
        case .tooOld(let installed, let required, _):
            "Version \(installed) installed. Klik needs \(required) or later."
        case .untrusted(let reason):
            "Found, but not signed by Klik's developer (\(reason)). Klik won't use it."
        case .notInstalled(let release):
            if let release {
                "\(addOn.summary) · \(Self.size(release.bytes))"
            } else {
                "\(addOn.summary) — not published yet"
            }
        }
    }

    private static func size(_ bytes: Int) -> String {
        ByteCountFormatStyle(style: .file).format(Int64(bytes))
    }

    @ViewBuilder
    private var action: some View {
        switch state {
        case .downloading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Button("Cancel") { registry.cancelInstall(addOn) }
            }
        case .readyToInstall:
            Button("Open Installer") { registry.openDownload(addOn) }
        case .failed:
            Button("Try Again") { registry.install(addOn) }
        case .unknown:
            EmptyView()
        case .resolved(let availability):
            resolvedAction(availability)
        }
    }

    @ViewBuilder
    private func resolvedAction(_ availability: AddOnAvailability) -> some View {
        switch availability {
        case .ready:
            HStack(spacing: 8) {
                Button("Show in Finder") { registry.revealInstalled(addOn) }
                Button("Open") { registry.launch(addOn) }
            }
        case .updatable:
            HStack(spacing: 8) {
                Button("Open") { registry.launch(addOn) }
                Button("Update") { registry.install(addOn) }
            }
        case .tooOld(_, _, let release):
            Button("Update") { registry.install(addOn) }
                .disabled(release == nil)
        case .untrusted:
            Button("Show in Finder") { registry.revealInstalled(addOn) }
        case .notInstalled(let release):
            Button("Install") { registry.install(addOn) }
                .disabled(release == nil)
                .help(release == nil ? "This add-on hasn't been published yet — point Klik at a build under Advanced." : "Download and install \(addOn.name)")
        }
    }
}
