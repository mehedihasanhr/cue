import RecordKit
import SwiftUI
import TimelineKit

/// The recording's sound: what is in it, and how loudly the preview plays it.
///
/// The level here is the *preview's*, and the panel says so, because the alternative
/// reading — that turning it down quietens the exported file — would be a quiet way to
/// ruin somebody's video. What the export does with these tracks is what the recording
/// captured; nothing on this panel changes it.
struct AudioInspector: View {
    let model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            tracks
            if let audio = model.audio, audio.hasSound {
                level(audio)
            }
            if !model.timeline.audio.isEmpty {
                added
            }
        }
    }

    // MARK: - What the recording holds

    @ViewBuilder
    private var tracks: some View {
        VStack(alignment: .leading, spacing: 8) {
            row("Screen audio", systemImage: "speaker.wave.2",
                present: model.hasTrack(.systemAudio))
            row("Microphone", systemImage: "mic",
                present: model.hasTrack(.microphone))

            switch model.waveform.state {
            case .loading(let done):
                HStack(spacing: 6) {
                    ProgressView(value: done).controlSize(.small).frame(width: 60)
                    Text("Reading the sound…")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            case .unavailable:
                Text("This recording has no sound. Turn on system audio or a microphone in Settings before the next one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .idle, .ready:
                EmptyView()
            }
        }
        .font(.system(size: 12))
        .inspectorSection("In the Recording", systemImage: "waveform")
    }

    private func row(_ title: String, systemImage: String, present: Bool) -> some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 11))
                .frame(width: 14)
            Text(title)
            Spacer()
            Image(systemName: present ? "checkmark" : "minus")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(present ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
        }
        .foregroundStyle(present ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        .help(present ? "Recorded" : "Not recorded")
    }

    // MARK: - The preview's level

    @ViewBuilder
    private func level(_ audio: PreviewAudio) -> some View {
        @Bindable var audio = audio

        VStack(alignment: .leading, spacing: 10) {
            Toggle("Play sound while editing", isOn: Binding(
                get: { !audio.isMuted },
                set: { audio.isMuted = !$0 }
            ))
            HStack(spacing: 8) {
                Image(systemName: "speaker.wave.2")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                Text("Volume").frame(width: 74, alignment: .leading)
                Slider(value: $audio.volume, in: 0...1)
                    .disabled(audio.isMuted)
            }
            Text("How loud the editor plays. The exported video keeps the levels it was recorded at.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12))
        .inspectorSection("Preview", systemImage: "play.circle")
    }

    // MARK: - Sound brought in

    /// Gain on an imported sound *is* a document setting — it changes the export — so it
    /// goes through the undo stack like every other edit.
    @ViewBuilder
    private var added: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(model.timeline.audio.enumerated()), id: \.element.id) { index, region in
                VStack(alignment: .leading, spacing: 4) {
                    Text((region.path as NSString).lastPathComponent)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    InspectorSlider(model: model, "Level", systemImage: "waveform",
                                    value: Binding(
                                        get: { model.timeline.audio.indices.contains(index)
                                               ? model.timeline.audio[index].gain : 1 },
                                        set: { gain in
                                            model.change("Level") { timeline in
                                                guard timeline.audio.indices.contains(index) else { return }
                                                timeline.audio[index].gain = gain
                                            }
                                        }
                                    ),
                                    range: 0...2)
                }
            }
        }
        .inspectorSection("Added Sound", systemImage: "music.note")
    }
}
