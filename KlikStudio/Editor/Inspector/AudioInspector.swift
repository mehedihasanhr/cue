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
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenSections) {
            tracks
            if model.waveform.state != .unavailable {
                recorded
            }
            if let audio = model.audio, audio.hasSound {
                level(audio)
            }
            addSound
            if !model.timeline.audio.isEmpty {
                added
            }
        }
    }

    // MARK: - The recording's own sound

    /// What the finished video does with the sound that was recorded.
    ///
    /// Sits above the preview level and says "exported" where that one says "preview",
    /// because these two controls look alike and mean opposite things: one changes the
    /// file, the other changes only what this Mac plays while you work.
    @ViewBuilder
    private var recorded: some View {
        let style = StyleBinding(model: model)

        VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
            Toggle("Keep the recording's sound", isOn: Binding(
                get: { !model.timeline.sound.isMuted },
                set: { keep in
                    model.apply(Commands.Restyle(keep ? "Unmute" : "Mute") { $0.sound.isMuted = !keep })
                }
            ))
            InspectorSlider(model: model, "Level", systemImage: "speaker.wave.2",
                            value: style.binding(\.sound.gain, "Level"), range: 0...2,
                            format: { "\(Int(($0 * 100).rounded()))%" })
                .disabled(model.timeline.sound.isMuted)
            Text("Goes into the exported video. Turn it down to sit under music, or off to keep only a voiceover.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12))
        .inspectorSection("Exported Sound", systemImage: "waveform.badge.mic")
    }

    // MARK: - Bringing sound in

    private var addSound: some View {
        Button {
            model.addSound()
        } label: {
            Label("Add Sound…", systemImage: "plus")
        }
        .controlSize(.small)
        .help("Lay music, a voiceover or an effect over the recording, starting at the playhead")
    }

    // MARK: - What the recording holds

    @ViewBuilder
    private var tracks: some View {
        VStack(alignment: .leading, spacing: 10) {
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
                .font(.system(size: 10))
                .foregroundStyle(present ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
        }
        .foregroundStyle(present ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        .help(present ? "Recorded" : "Not recorded")
    }

    // MARK: - The preview's level

    @ViewBuilder
    private func level(_ audio: PreviewAudio) -> some View {
        @Bindable var audio = audio

        VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
            Toggle("Play sound while editing", isOn: Binding(
                get: { !audio.isMuted },
                set: { audio.isMuted = !$0 }
            ))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text("Volume").foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text("\(Int((audio.volume * 100).rounded()))%")
                        .font(.system(size: 10, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
                StudioSlider(value: $audio.volume, in: 0...1)
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
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
            ForEach(Array(model.timeline.audio.enumerated()), id: \.element.id) { index, region in
                VStack(alignment: .leading, spacing: 4) {
                    Text((region.path as NSString).lastPathComponent)
                        .font(.system(size: 12))
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
                                    range: 0...2,
                                    format: { "\(Int(($0 * 100).rounded()))%" })
                }
            }
        }
        .inspectorSection("Added Sound", systemImage: "music.note")
    }
}
