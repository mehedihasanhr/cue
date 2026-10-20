import SwiftUI

/// The Recording & Video page: a way into the recorder's and the video editor's own
/// settings, which keep their window — recording, the editor, captions, export and
/// storage are pages enough for one of their own.
struct RecordingSettingsLinkView: View {
    var body: some View {
        SettingsPane(.studio) {
            SettingsGroup(footer: "Countdown, camera and microphone, the editor's shortcuts, captions, export and where recordings are kept.") {
                SettingsRow("Recording & Video Settings", subtitle: "Opens in its own window", symbol: "record.circle.fill", tint: .red) {
                    Button("Open…") { StudioController.openSettings() }
                }
            }
            SettingsGroup {
                SettingsRow("Recorder", subtitle: "Choose a screen, window or area and record it", symbol: "video.fill", tint: .orange) {
                    Button("Show") { StudioController.showBar() }
                }
                SettingsRow("Recordings", subtitle: "Everything recorded, to play, edit or export", symbol: "film.stack.fill", tint: .purple) {
                    Button("Open") { StudioController.shared?.showLibrary() }
                }
            }
        }
    }
}
