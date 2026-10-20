import SwiftUI
import TimelineKit

/// The Audio menu's voice switches and music ducking.
///
/// Ticked items, like the Frame menu's, because each is a setting that stays on rather
/// than an action. The voice switches act on the source selected on the timeline, or on
/// the voice when none is; ducking on the selected added sound, or on every added sound.
extension EditorCommands {
    private var voiceEditor: EditorModel? { windows.menuTarget?.model }

    @ViewBuilder
    var voiceFinish: some View {
        Divider()
        Toggle("Clean Up Voice", isOn: Binding(
            get: { voiceEditor?.menuCleansVoice ?? false },
            set: { voiceEditor?.setMenuCleansVoice($0) }
        ))
        .disabled(voiceEditor?.canTreatVoice != true)
        Toggle("Even Out Volume", isOn: Binding(
            get: { voiceEditor?.menuEvensVolume ?? false },
            set: { voiceEditor?.setMenuEvensVolume($0) }
        ))
        .disabled(voiceEditor?.canTreatVoice != true)
        Toggle("Lower Music Under Speech", isOn: Binding(
            get: { voiceEditor?.menuDucksMusic ?? false },
            set: { voiceEditor?.setMenuDucksMusic($0) }
        ))
        .disabled(voiceEditor?.timeline.audio.isEmpty != false)
    }
}
