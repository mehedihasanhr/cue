import SwiftUI
import TimelineKit

/// What a new recording's voice and clicks sound like, and how the editor plays them.
struct AudioSettingsPane: View {
    @Environment(StudioSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        @Bindable var newProjects = settings.newProjects

        StudioSettingsPane(.audio) {
            StudioSettingsGroup("Voice in new recordings") {
                SettingsToggleRow("Clean up voice",
                                  subtitle: "Takes out rumble and the hiss between words, and evens out loud syllables.",
                                  symbol: "waveform.badge.magnifyingglass", tint: .pink,
                                  isOn: $newProjects.cleansVoice)
                SettingsToggleRow("Even out volume",
                                  subtitle: "Brings each microphone to one loudness, so a quiet one and a loud one come out alike.",
                                  symbol: "slider.vertical.3", tint: .orange,
                                  isOn: $newProjects.evensVolume)
            }

            StudioSettingsGroup("Clicks in new recordings") {
                SettingsToggleRow("Play a sound on each click", symbol: "speaker.wave.2.fill", tint: .blue,
                                  isOn: $newProjects.clickSound)
                Group {
                    StudioSettingsRow("Sound") {
                        Picker("Click sound", selection: $newProjects.clickSoundKind) {
                            ForEach(CursorStyle.ClickSound.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                    }
                    StudioSettingsRow("Volume") {
                        SettingsSlider("Click volume", value: $newProjects.clickSoundVolume, in: 0...1,
                                       format: SettingsSlider.percent)
                    }
                }
                .disabled(!newProjects.clickSound)
            }

            StudioSettingsGroup("Voiceover") {
                StudioSettingsRow("Count in", symbol: "mic.badge.plus", tint: .red) {
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
