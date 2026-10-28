import RecordKit
import SwiftUI
import TimelineKit

/// The recording's sound: what is in it, what the export does with it, and what has been
/// laid over it.
///
/// Everything on this panel changes the exported file. How loudly *this Mac* plays the
/// preview is not here — it is the volume control in the transport bar under the picture,
/// the one place it lives. It used to be here as well, as a "Preview › Volume" slider a
/// few rows from "Level", and two sliders that look alike and mean opposite things — one
/// changes the file, one changes only what you hear while you work — is a quiet way to
/// ruin somebody's video.
struct AudioInspector: View {
    let model: EditorModel

    /// The source whose name is being typed, so only its field takes the full box.
    @FocusState private var focusedName: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenSections) {
            if model.timeline.hasSeparateSound {
                sources
            } else {
                tracks
            }
            if model.timeline.hasSeparateSound || model.waveform.state != .unavailable {
                recorded
            }
            voiceover
            added
        }
    }

    // MARK: - The recording's own sound

    /// What the finished video does with the sound that was recorded.
    ///
    /// With separate sources this is the level over all of them, and it is called that:
    /// each source above has a Level of its own, and two sliders both named "Level" under
    /// two headings was the panel saying the same word for two different things.
    @ViewBuilder
    private var recorded: some View {
        let style = StyleBinding(model: model)
        let separate = model.timeline.hasSeparateSound

        VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
            InspectorSwitch("Keep the recording's sound", isOn: Binding(
                get: { !model.timeline.sound.isMuted },
                set: { keep in
                    model.apply(Commands.Restyle(keep ? "Unmute" : "Mute") { $0.sound.isMuted = !keep })
                }
            ))
            .help("Goes into the exported video. Turn it down to sit under music, or off to keep only a voiceover.")
            InspectorSlider(model: model, separate ? "Overall level" : "Level", systemImage: "speaker.wave.2",
                            value: style.binding(\.sound.gain, "Level"), range: 0...2,
                            defaultValue: style.factory(\.sound.gain),
                            format: { "\(Int(($0 * 100).rounded()))%" })
                .disabled(model.timeline.sound.isMuted)
            // Here only for a recording with its sound inside the video: with separate
            // sources the switches are per source, in Sources above.
            if !separate {
                VoiceSwitches(model: model, id: nil,
                              unavailable: model.timeline.sound.isMuted ? "Off while the recording's sound is off." : nil)
            }
            detachment
        }
        .inspectorSection("Recording's Sound", systemImage: "waveform.badge.mic")
    }

    /// Cutting the sound loose from the picture, and putting it back.
    ///
    /// In the panel as well as in the lane's context menu and the Edit menu, because it is
    /// the sort of thing you go looking for rather than happen upon: nothing on the timeline
    /// suggests the sound *could* be moved on its own until somebody tells you, and the
    /// panel about the recording's sound is where you would look.
    @ViewBuilder
    private var detachment: some View {
        if model.isSoundDetached {
            StudioButton("Re-attach Audio", systemImage: "link", size: .small) {
                model.requestSoundReattach()
            }
            .help("The sound is on its own. Drag its runs to slide them, or their edges to trim — the picture stays where it is. Re-attaching cuts it at the picture's cuts again.")
        } else {
            StudioButton("Detach Audio", systemImage: "link.badge.plus", size: .small) {
                model.detachSound()
            }
            .help("Cut the sound loose from the picture, so you can keep talking over a cut, trim a cough out, or slide narration onto an action. Nothing changes until you move something.")
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
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
            // No recorder and an idle one are the same thing to look at: nothing is being
            // recorded, and there is a button to start.
            switch model.voiceover?.state ?? .idle {
            case .idle:
                StudioButton("Record Voiceover", systemImage: "mic", size: .small) {
                    model.startVoiceover()
                }
                .help("Talk over the edit. The timeline plays from the playhead while you talk, and the take lands where it started. The editor's own sound is silenced so it doesn't end up in the recording.")

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
        StudioButton("Stop", systemImage: "stop.fill", variant: .destructive, size: .small) { model.stopVoiceover() }
            .help("Stop recording and put the take on the sound lane")
    }

    /// Minutes and seconds, which is as much as anyone needs of a take in progress.
    private static func elapsed(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    // MARK: - What the recording holds

    /// A group per source the recording captured, each with its own switch, its own level
    /// and its own voice clean-up.
    ///
    /// This is the panel the feature exists for. Before it there was one level for
    /// "the recording", so turning the browser's music down took the voiceover with it and
    /// the only way out was to mute everything and import the voice again as a file. Each
    /// of these is a separate file on disk, so muting one costs nothing and changes
    /// nothing else.
    ///
    /// The groups are set apart by a hairline, so a source's level cannot be read as the
    /// next source's: four sliders in a column with nothing between them was four sliders
    /// for one thing.
    @ViewBuilder
    private var sources: some View {
        let tracks = model.timeline.soundTracks
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                if index > 0 {
                    StudioDivider()
                        .padding(.vertical, 2)
                }
                source(track)
            }
        }
        .inspectorSection("Sources", systemImage: "waveform") {
            if tracks.contains(where: { $0.style.isMuted }) {
                SectionButton(title: "Unmute All") { model.unmuteAllSound() }
                    .help("Bring every source back")
            }
        }
    }

    private func source(_ track: SoundTrack) -> some View {
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
            HStack(spacing: 7) {
                Image(systemName: track.style.isMuted ? "speaker.slash.fill" : track.symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(track.style.isMuted ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.accentColor))
                    .frame(width: 14)
                // Editable, because "Microphone 2" is what the system calls a device and
                // "Guest" is what the person editing calls it. Committing on return or on
                // losing focus, like every other name field on the Mac.
                // A quiet field: it reads as the source's name until it is pointed at.
                TextField("Name", text: Binding(
                    get: { track.name },
                    set: { model.renameSound(track.id, to: $0) }
                ))
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .focused($focusedName, equals: track.id)
                .studioField(isFocused: focusedName == track.id, isQuiet: true)
                .help("Rename this source")
                Spacer(minLength: 6)
                if model.timeline.soundTracks.count > 1 {
                    StudioButton("Solo", variant: .ghost, size: .small) { model.soloSound(track.id) }
                        .help("Leave only this one audible")
                }
                // The same switch as every other on-and-off in the panels, at the end of
                // the row where every other one sits.
                StudioSwitch("Include \(track.name)", isOn: Binding(
                    get: { !track.style.isMuted },
                    set: { _ in model.toggleSoundMute(track.id) }
                ))
                .help(track.style.isMuted ? "Bring \(track.name) back" : "Leave \(track.name) out")
            }
            .frame(minHeight: InspectorMetrics.rowHeight)
            InspectorSlider(model: model, "Level", systemImage: "speaker.wave.2",
                            value: Binding(
                                get: { track.style.gain },
                                set: { model.setSoundGain(track.id, to: $0) }
                            ),
                            range: 0...2,
                            format: { "\(Int(($0 * 100).rounded()))%" })
                .disabled(track.style.isMuted)
            VoiceSwitches(model: model, id: track.id,
                          unavailable: track.style.isMuted ? "Off while \(track.name) is left out." : nil)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(track.name)
    }

    private var tracks: some View {
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
            presence("Screen audio", present: model.hasTrack(.systemAudio))
            presence("Microphone", present: model.hasTrack(.microphone))

            switch model.waveform.state {
            case .loading(let done):
                HStack(spacing: 6) {
                    ProgressView(value: done).controlSize(.small).frame(width: 60)
                    InspectorNote("Reading the sound…")
                }
            case .unavailable:
                InspectorNote("This recording has no sound.")
                    .help("This recording has no sound. Turn on system audio or a microphone in Settings before the next one.")
            case .idle, .ready:
                EmptyView()
            }
        }
        .inspectorSection("In the Recording", systemImage: "waveform")
    }

    private func presence(_ title: String, present: Bool) -> some View {
        InspectorRow(title) {
            Text(present ? "Recorded" : "Not recorded")
                .font(.system(size: 12))
                .foregroundStyle(present ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
        }
    }

    // MARK: - Sound brought in

    /// Music, effects, a voiceover file: each with its own level, and the way to add more
    /// on the heading.
    ///
    /// Always shown, so Add Sound… has a home. It was a button on its own between two
    /// sections, belonging to neither — the one orphan control in the panel.
    ///
    /// Gain on an imported sound *is* a document setting — it changes the export — so it
    /// goes through the undo stack like every other edit.
    @ViewBuilder
    private var added: some View {
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
            if model.timeline.audio.isEmpty {
                InspectorNote("Music, an effect or a voiceover file, from the playhead.")
            }
            ForEach(Array(model.timeline.audio.enumerated()), id: \.element.id) { index, region in
                if index > 0 {
                    StudioDivider()
                        .padding(.vertical, 2)
                }
                VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
                    Text((region.path as NSString).lastPathComponent)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(region.path)
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
                    DuckControls(model: model, id: region.id, compact: true)
                }
            }
        }
        .inspectorSection("Added Sound", systemImage: "music.note") {
            SectionButton(title: "Add Sound") { model.addSound() }
                .help("Lay music, a voiceover or an effect over the recording, starting at the playhead")
        }
    }
}
