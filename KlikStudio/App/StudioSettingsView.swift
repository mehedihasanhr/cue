import AddOnKit
import AppKit
import AVFoundation
import RecordKit
import SwiftUI
import TimelineKit

/// Settings, in the four groups a recorder actually has: what it records with, what it
/// does afterwards, what a new project looks like, and what this build is.
///
/// Anything that changes what a recording *contains* lives here; anything that changes
/// what one *is* — the source, the button — stays in the recorder window.
struct StudioSettingsView: View {
    var body: some View {
        // The classic `tabItem` form rather than the `Tab` type: it is available back to
        // macOS 14 and renders as the system's own settings tabs on every version, so
        // there is nothing here to keep in step with two designs.
        TabView {
            RecordingSettings()
                .tabItem { Label("Recording", systemImage: "record.circle") }
            AfterwardsSettings()
                .tabItem { Label("Afterwards", systemImage: "wand.and.stars") }
            AppearanceSettings()
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
            AboutSettings()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 540, height: 460)
    }
}

// MARK: - Recording

private struct RecordingSettings: View {
    @Environment(StudioSettings.self) private var settings
    @State private var microphones: [AVCaptureDevice] = []

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section {
                Picker("Countdown", selection: $settings.countdownSeconds) {
                    Text("Off").tag(0)
                    ForEach([3, 5, 10], id: \.self) { Text("\($0) seconds").tag($0) }
                }
                Picker("Frame rate", selection: $settings.frameRate) {
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
                Picker("Quality", selection: $settings.quality) {
                    Text("Good").tag(CaptureQuality.good)
                    Text("Better").tag(CaptureQuality.better)
                    Text("Best").tag(CaptureQuality.best)
                }
                Picker("Encoder", selection: $settings.codec) {
                    Text("Automatic").tag(VideoCodec.automatic)
                    Text("HEVC").tag(VideoCodec.hevc)
                    Text("H.264").tag(VideoCodec.h264)
                }
            } footer: {
                Text("Automatic uses HEVC where this Mac has a hardware encoder — about half the file size for the same picture.")
            }

            Section("Audio") {
                Toggle("Record system audio", isOn: $settings.recordsSystemAudio)
                Toggle("Record microphone", isOn: $settings.recordsMicrophone)
                Picker("Input", selection: $settings.microphoneID) {
                    Text("System default").tag("")
                    ForEach(microphones, id: \.uniqueID) { device in
                        Text(device.localizedName).tag(device.uniqueID)
                    }
                }
                .disabled(!settings.recordsMicrophone)
            }

            Section {
                Toggle("Record clicks and scrolls", isOn: $settings.recordsClicks)
                Toggle("Record what has focus", isOn: $settings.recordsFocus)
                Toggle("Burn the pointer into the video", isOn: $settings.burnsCursorIntoVideo)
            } footer: {
                Text(settings.burnsCursorIntoVideo
                     ? "With the pointer burned in, the editor can't resize it, smooth it, or zoom to follow it — there's nothing but pixels to work with."
                     : "The pointer is recorded as data beside the video, which is what lets the editor smooth it, resize it and zoom to follow it.")
            }
        }
        .formStyle(.grouped)
        .task { microphones = Self.inputs() }
    }

    private static func inputs() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external],
                                         mediaType: .audio,
                                         position: .unspecified).devices
    }
}

// MARK: - Afterwards

private struct AfterwardsSettings: View {
    @Environment(StudioSettings.self) private var settings

    /// Says what the focus toggles will actually get you, which depends on a grant the
    /// app cannot give itself. Better here than as a dialog at the moment of recording.
    private var focusFooter: String {
        guard settings.zoomsOnFocus else {
            return "Zooms are suggested from the recorded clicks alone."
        }
        return FocusTracker.canTrackFields
            ? "Windows and apps are tracked with the permission recording already has. Text fields need Accessibility, which Klik Studio has."
            : "Text fields need Accessibility — without it, zooms come from clicks and from windows coming forward. Turn Klik Studio on in System Settings › Privacy & Security › Accessibility."
    }

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("When a recording stops") {
                Toggle("Open it in the editor", isOn: $settings.opensEditorAfterRecording)
                Toggle("Suggest zooms", isOn: $settings.suggestsZoomsOnOpen)
            }

            Section {
                LabeledContent("How far a click zooms") {
                    HStack(spacing: 10) {
                        Slider(value: $settings.zoomScale, in: 1.2...3)
                        Text(settings.zoomScale, format: .number.precision(.fractionLength(1)))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 30, alignment: .trailing)
                    }
                }
                Toggle("Zoom to text fields as they take the caret", isOn: $settings.zoomsOnFocus)
                Toggle("Zoom when a window comes forward", isOn: $settings.zoomsOnWindowChange)
                    .disabled(!settings.zoomsOnFocus)
            } header: {
                Text("Suggested zooms")
            } footer: {
                Text(focusFooter)
            }
            .disabled(!settings.suggestsZoomsOnOpen)

            Section {
                Picker("Count in", selection: $settings.voiceoverCountInSeconds) {
                    Text("Off").tag(0)
                    ForEach([3, 5, 10], id: \.self) { Text("\($0) seconds").tag($0) }
                }
            } header: {
                Text("Voiceover")
            } footer: {
                Text("Time to draw breath before the timeline starts rolling. The microphone is the one chosen under Recording, and the editor's own sound is silenced while a take is recorded so it doesn't end up inside it.")
            }

            Section {
                LabeledContent("Recordings folder") {
                    HStack(spacing: 8) {
                        Text(settings.library.path(percentEncoded: false))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                        if !settings.isUsingDefaultLibrary {
                            Button("Reset") { settings.resetLibrary() }
                        }
                        Button("Choose…") { choose(settings) }
                    }
                }
            } footer: {
                Text("Klik can ask for a different folder per recording. If Klik Studio can't write there, it keeps the recording here instead.")
            }
        }
        .formStyle(.grouped)
    }

    private func choose(_ settings: StudioSettings) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = settings.library
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.setLibrary(url)
    }
}

// MARK: - Appearance

private struct AppearanceSettings: View {
    @Environment(StudioSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section {
                Picker("Background", selection: $settings.backgroundPreset) {
                    ForEach(BackgroundPreset.allCases) { Text($0.title).tag($0) }
                }
                slider("Padding", value: $settings.padding, range: 0...0.2)
                slider("Corners", value: $settings.cornerRadius, range: 0...0.08)
                slider("Shadow", value: $settings.shadowOpacity, range: 0...1)
                slider("Softness", value: $settings.shadowRadius, range: 0...0.08)
                slider("Background blur", value: $settings.backgroundBlur, range: 0...0.04)
            } header: {
                Text("New projects")
            } footer: {
                Text("Every one of these can be changed per project in the editor. These are only what a new recording starts as.")
            }

            Section("Pointer") {
                slider("Size", value: $settings.cursorScale, range: 0.5...3)
                slider("Smoothing", value: $settings.cursorSmoothing, range: 0...1)
                Toggle("Click effect", isOn: $settings.clickEffect)
            }
        }
        .formStyle(.grouped)
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        LabeledContent(title) {
            Slider(value: value, in: range).frame(width: 190)
        }
    }
}

// MARK: - About

private struct AboutSettings: View {
    @Environment(StudioService.self) private var service

    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            Image(systemName: "record.circle")
                .font(.system(size: 48))
                .foregroundStyle(.red)
            Text("Klik Studio").font(.title2.weight(.semibold))
            Text("Version \(service.version) · contract \(StudioCapabilities.currentContract)")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("The recording add-on for Klik. It installs, updates and uninstalls on its own, and Klik works without it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            // Folded away because almost nobody needs it, and open in one click when
            // Klik says the add-on is there and nothing happens.
            DisclosureGroup("Connection with Klik") {
                BridgeStatusView()
                    .padding(.top, 8)
            }
            .frame(maxWidth: 380)
            .padding(.top, 6)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
