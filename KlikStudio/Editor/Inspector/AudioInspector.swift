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
            voiceover
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
            Divider()
            detachment
        }
        .font(.system(size: 12))
        .inspectorSection("Exported Sound", systemImage: "waveform.badge.mic")
    }

    /// Cutting the sound loose from the picture, and putting it back.
    ///
    /// In the panel as well as in the lane's context menu and the Edit menu, because it is
    /// the sort of thing you go looking for rather than happen upon: nothing on the timeline
    /// suggests the sound *could* be moved on its own until somebody tells you, and the
    /// panel about the recording's sound is where you would look.
    @ViewBuilder
    private var detachment: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.isSoundDetached {
                Button {
                    model.requestSoundReattach()
                } label: {
                    Label("Re-attach Audio", systemImage: "link")
                }
                .controlSize(.small)
                Text("The sound is on its own. Drag its runs to slide them, or their edges to trim — the picture stays where it is. Re-attaching cuts it at the picture's cuts again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Button {
                    model.detachSound()
                } label: {
                    Label("Detach Audio", systemImage: "link.badge.plus")
                }
                .controlSize(.small)
                Text("Cut the sound loose from the picture, so you can keep talking over a cut, trim a cough out, or slide narration onto an action. Nothing changes until you move something.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Narration

    /// Recording a voiceover: one control that starts and stops, and the take's state
    /// while it runs.
    ///
    /// The same button does both, because arming and stopping are the two halves of one
    /// action and a second button would be one you could press at the wrong time. What it
    /// says changes with the state rather than what it does, which is also how the menu
    /// item reads.
    @ViewBuilder
    private var voiceover: some View {
        VStack(alignment: .leading, spacing: 10) {
            // No recorder and an idle one are the same thing to look at: nothing is being
            // recorded, and there is a button to start.
            switch model.voiceover?.state ?? .idle {
            case .idle:
                Button {
                    model.startVoiceover()
                } label: {
                    Label("Record Voiceover…", systemImage: "mic")
                }
                .controlSize(.small)
                .help("Talk over the edit. It plays from the playhead, and what you say lands there")
                Text("The timeline plays from the playhead while you talk, and the take lands where it started. The editor's own sound is silenced so it doesn't end up in the recording.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

            case .countingIn(let remaining):
                HStack(spacing: 10) {
                    Text("\(remaining)")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText(countsDown: true))
                    Text("Get ready…")
                        .foregroundStyle(.secondary)
                    Spacer()
                    stop
                }

            case .opening:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Opening the microphone…").foregroundStyle(.secondary)
                    Spacer()
                    stop
                }

            case .recording(let since):
                HStack(spacing: 8) {
                    Image(systemName: "record.circle.fill")
                        .foregroundStyle(.red)
                        .symbolEffect(.pulse)
                    // Driven by the clock rather than by a stored `elapsed`, so a take
                    // that runs for minutes does not mean a redraw of the panel every
                    // half second for the sake of one label.
                    TimelineView(.periodic(from: .now, by: 0.5)) { context in
                        Text(Self.elapsed(from: since, to: context.date))
                            .monospacedDigit()
                    }
                    Spacer()
                    stop
                }

            case .finishing:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Saving the take…").foregroundStyle(.secondary)
                }
            }
        }
        .font(.system(size: 12))
        .inspectorSection("Voiceover", systemImage: "mic.badge.plus")
    }

    private var stop: some View {
        Button("Stop") { model.stopVoiceover() }
            .controlSize(.small)
            .help("Stop recording and put the take on the sound lane")
    }

    /// Minutes and seconds, which is as much as anyone needs of a take in progress.
    private static func elapsed(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
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
