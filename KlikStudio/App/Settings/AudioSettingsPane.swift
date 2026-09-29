import SwiftUI
import TimelineKit

/// What a new recording's voice and clicks sound like, and how the editor plays them.
struct AudioSettingsPane: View {
    @Environment(StudioSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        @Bindable var newProjects = settings.newProjects

        SettingsPane(.audio) {
            SettingsGroup("Voice in new recordings",
                          footer: "Switched on for every microphone of a recording opened for the first time — never for system audio, where they would treat music as noise. Each can be turned off per recording in the editor's Audio menu.") {
                SettingsToggleRow("Clean up voice",
                                  subtitle: "Takes out rumble and the hiss between words, and evens out loud syllables.",
                                  symbol: "waveform.badge.magnifyingglass", tint: .pink,
                                  isOn: $newProjects.cleansVoice)
                SettingsToggleRow("Even out volume",
                                  subtitle: "Brings each microphone to one loudness, so a quiet one and a loud one come out alike.",
                                  symbol: "slider.vertical.3", tint: .orange,
                                  isOn: $newProjects.evensVolume)
            }

            SettingsGroup("Clicks in new recordings",
                          footer: "A sound the recording never made — so it is off unless you ask for it, and heard in the editor and the export alike.") {
                SettingsToggleRow("Play a sound on each click", symbol: "speaker.wave.2.fill", tint: .blue,
                                  isOn: $newProjects.clickSound)
                Group {
                    SettingsRow("Sound") {
                        Picker("Click sound", selection: $newProjects.clickSoundKind) {
                            ForEach(CursorStyle.ClickSound.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                    }
                    SettingsRow("Volume") {
                        SettingsSlider("Click volume", value: $newProjects.clickSoundVolume, in: 0...1,
                                       format: SettingsSlider.percent)
                    }
                }
                .disabled(!newProjects.clickSound)
            }

            SettingsGroup("Voiceover",
                          footer: "Time to draw breath before the timeline starts rolling. The microphone is the one chosen under Recording, and the editor's own sound is silenced while a take is recorded so it doesn't end up inside it.") {
                SettingsRow("Count in", symbol: "mic.badge.plus", tint: .red) {
                    Picker("Count in", selection: $settings.voiceoverCountInSeconds) {
                        Text("Off").tag(0)
                        ForEach([3, 5, 10], id: \.self) { Text("\($0) seconds").tag($0) }
                    }
                    .fixedSize()
                }
            }
        }
    }
}
