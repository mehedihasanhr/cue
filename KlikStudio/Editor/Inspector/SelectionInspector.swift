import CoreMedia
import SwiftUI
import TimelineKit

/// What is selected on the timeline, and what can be done to it.
struct SelectionInspector: View {
    let model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenSections) {
            switch model.selection {
            case .clip(let id):
                if let index = model.timeline.clips.firstIndex(where: { $0.id == id }) {
                    let clip = model.timeline.clips[index]
                    if clip.isFootage {
                        self.clip(clip, at: index)
                    } else {
                        ClipHoldInspector(model: model, clip: clip, index: index)
                    }
                    if index > 0 {
                        ClipTransitionInspector(model: model, clip: clip)
                    }
                }
            case .zoom(let id):
                if let index = model.timeline.zooms.firstIndex(where: { $0.id == id }) {
                    ZoomInspector(model: model, index: index)
                }
            // Each panel made fresh for the thing it is about, `.id(id)`: kept alive across a
            // change of selection, a control holding on to the last one's binding — the colour
            // panel, a field mid-edit — went on writing to it, so styling a box recoloured the
            // label selected before it.
            case .blur(let id):
                MaskInspector(model: model, id: id)
                    .id(id)
            case .annotation(let id):
                AnnotationInspector(model: model, id: id)
                    .id(id)
            case .cursorRegion(let id):
                CursorRegionInspector(model: model, id: id)
                    .id(id)
            case .caption(let id):
                CaptionCueInspector(model: model, id: id)
                    .id(id)
            case .keyCue(let id):
                KeyCueInspector(model: model, id: id)
                    .id(id)
            case .cameraLayout(let id):
                CameraLayoutInspector(model: model, id: id)
                    .id(id)
            case .sound, .soundTrack:
                // The whole panel, because selecting the lane is how most people will
                // arrive at these settings — and because the Sources section it opens with
                // is a row per lane, so the one that was clicked is already in front of you
                // with its neighbours for comparison, which is how a level actually gets
                // set.
                AudioInspector(model: model)
            case .soundRun(let id):
                if let run = model.timeline.detachedSound?.first(where: { $0.id == id }) {
                    soundRun(run)
                }
            case .audio(let id):
                if let index = model.timeline.audio.firstIndex(where: { $0.id == id }) {
                    sound(index: index)
                }
            case .range(let range):
                self.range(range)
            default:
                EmptyView()
            }

            // No "Done" here: the panel's own heading carries the way out of a
            // selection, and two controls for one idea is how a panel gets a footer
            // nobody reads.
            if model.canDeleteSelection {
                Button(role: .destructive) { model.deleteSelection() } label: {
                    Label("Delete", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.studio(.destructive, size: .small))
                .padding(.top, SidebarSpacing.sectionPadding)
                .help("Remove this from the timeline")
            }
        }
    }

    // MARK: - A run of the detached sound

    /// Both clocks at once, which is the only way to read a detached run.
    ///
    /// "Where it plays" and "which second of the recording it is" are the same number on an
    /// attached lane and different numbers the instant anything is dragged — and the gap
    /// between them *is* the edit. A panel showing only one of them would leave the user
    /// guessing at which, so it shows both and says which is which.
    private func soundRun(_ run: SoundRun) -> some View {
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
            InspectorRow(title: "Plays at", value: Timecode.short(run.start))
            InspectorRow(title: "Length", value: Timecode.length(run.duration))
            InspectorRow(title: "From", value: Timecode.short(run.sourceStart))
                .help("Where in the recording this run's sound comes from")
            InspectorRow(title: "To", value: Timecode.short(run.sourceEnd))
            if run.speed != 1 {
                InspectorRow(title: "Speed", value: TimelineClipRow.speedLabel(run.speed))
            }
            StudioButton("Re-attach Audio", systemImage: "link", size: .small) { model.requestSoundReattach() }
                .help("This is the recording's own sound, detached from the picture. Drag it to slide it, or its edges to trim — the picture does not move.")
        }
        .inspectorSection("Sound Run", systemImage: "waveform.path")
    }

    // MARK: - Clip

    private func clip(_ clip: Clip, at index: Int) -> some View {
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
            // A movie brought in says which, so its In and Out below are read as times in
            // that file rather than in the recording.
            if let name = model.mediaName(of: clip) {
                InspectorRow(title: "Plays", value: name)
            }
            InspectorRow(title: "Starts", value: Timecode.short(model.timeline.start(ofClipAt: index)))
            InspectorRow(title: "Length", value: Timecode.length(clip.duration))

            InspectorRow("Speed") {
                InspectorPicker(selection: Binding(
                    get: { clip.speed },
                    set: { model.setSpeed($0, of: clip.id) }
                ), options: [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 4.0, 8.0]) {
                    TimelineClipRow.speedLabel($0)
                }
            }

            // Trimming by hand, not only by dragging an edge. After a split there are
            // several pieces and the interesting question moves from "where does the cut
            // go" to "what does *this* piece show" — which is a request you make after
            // watching it back, when the pointer is nowhere near the timeline.
            trim(clip, edge: .head, title: "In", value: clip.sourceStart)
            trim(clip, edge: .tail, title: "Out", value: clip.sourceEnd)

            verbs(clip, at: index)
        }
        .inspectorSection("Clip \(index + 1) of \(model.timeline.clips.count)", systemImage: "film")
    }

    // MARK: - An added sound

    private func sound(index: Int) -> some View {
        let region = model.timeline.audio[index]
        return VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
            Text((region.path as NSString).lastPathComponent)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(region.path)

            InspectorSlider(model: model, "Level", systemImage: "speaker.wave.2",
                            value: Binding(
                                get: { model.timeline.audio.indices.contains(index)
                                       ? model.timeline.audio[index].gain : 1 },
                                set: { gain in
                                    change("Level") { timeline in
                                        guard timeline.audio.indices.contains(index) else { return }
                                        timeline.audio[index].gain = gain
                                    }
                                }
                            ),
                            range: 0...2)

            // Up to half the sound each, or five seconds: past that it is not a fade but
            // the whole piece getting louder, which is a level, not an edge.
            let longest = max(0.5, min(5, region.duration.seconds / 2))
            InspectorSlider(model: model, "Fade in", systemImage: "arrow.up.right",
                            value: fade(index, \.fadeIn, "Fade In"),
                            range: 0...longest,
                            format: Self.seconds)
            InspectorSlider(model: model, "Fade out", systemImage: "arrow.down.right",
                            value: fade(index, \.fadeOut, "Fade Out"),
                            range: 0...longest,
                            format: Self.seconds)

            DuckControls(model: model, id: region.id)

            InspectorRow(title: "Starts", value: Timecode.short(region.start))
                .help("Drag it along the timeline to move it, or take an edge to trim it.")
            InspectorRow(title: "Lasts", value: Timecode.length(region.duration))
                .help("Drag it along the timeline to move it, or take an edge to trim it.")
        }
        .inspectorSection("Sound", systemImage: "music.note")
    }

    /// One end of one clip, with the source time it sits at and a pair of nudges.
    ///
    /// Source time rather than timeline time, because that is what a trim actually moves:
    /// the clip keeps its place in the edit and shows different footage. Showing the
    /// timeline position here would be showing a number the buttons do not change.
    private func trim(_ clip: Clip, edge: EditorModel.ClipEdge, title: String, value: CMTime) -> some View {
        InspectorNudgeRow(title: title, value: Timecode.short(value),
                          earlierHelp: "Earlier by a frame",
                          laterHelp: "Later by a frame",
                          earlier: { model.nudgeTrim(clip, edge: edge, by: -model.frameDuration) },
                          later: { model.nudgeTrim(clip, edge: edge, by: model.frameDuration) })
            .help(edge == .head ? "Where this piece starts in the footage" : "Where this piece ends in the footage")
    }

    /// What can be done to this piece alone.
    ///
    /// Splitting used to leave you with pieces and nowhere to act on one: the only verbs
    /// were on the menu bar and acted on the playhead or the whole edit. A piece you have
    /// selected is the thing you are thinking about, so the verbs belong beside it.
    private func verbs(_ clip: Clip, at index: Int) -> some View {
        HStack(spacing: 6) {
            Button("Split") { model.splitAtPlayhead() }
                .disabled(!model.canSplit(clip))
                .help(model.canSplit(clip)
                      ? "Cut this piece in two at the playhead (⌘B)"
                      : "Move the playhead inside this piece to cut it")
            Button("Duplicate") { model.duplicateFootage(.clip(clip.id)) }
                .help("A second copy of this piece, straight after it")
            Button("Reset Speed") { model.resetSpeed(of: clip) }
                .disabled(clip.speed == 1)
            Spacer(minLength: 0)
            ClipOrderButtons(model: model, index: index)
            Button(role: .destructive) {
                model.deleteSelection()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.studio(.destructive, size: .small, isIconOnly: true))
            .accessibilityLabel("Delete piece")
            .disabled(model.timeline.clips.count < 2)
            .help(model.timeline.clips.count < 2
                  ? "An edit has to keep one piece"
                  : "Remove this piece and close the gap")
        }
        .buttonStyle(.studio(.secondary, size: .small))
    }

    // MARK: - Range

    private func range(_ range: CMTimeRange) -> some View {
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
            InspectorRow(title: "From", value: Timecode.short(range.start))
            InspectorRow(title: "Length", value: Timecode.length(range.duration))
            InspectorRow("Speed") {
                // An action list rather than a picker: a range has no one speed to show as
                // chosen, and each choice is a command that applies to it.
                StudioActionMenu(actions: [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 4.0, 8.0].map { speed in
                    .init(TimelineClipRow.speedLabel(speed)) {
                        model.apply(Commands.SetSpeed(range, speed: speed))
                    }
                }, style: .studio(.secondary, size: .small)) {
                    HStack(spacing: 6) {
                        Text("Set Speed")
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(StudioTheme.Palette.textSecondary)
                    }
                }
                .fixedSize()
            }
        }
        .inspectorSection("Selection", systemImage: "selection.pin.in.out")
    }

    // MARK: - Plumbing

    private static func seconds(_ value: Double) -> String {
        value < 0.05 ? "Off" : String(format: "%.1fs", value)
    }

    private func fade(_ index: Int,
                      _ path: WritableKeyPath<AudioRegion, Double> & Sendable,
                      _ name: String) -> Binding<Double> {
        Binding {
            model.timeline.audio.indices.contains(index) ? model.timeline.audio[index][keyPath: path] : 0
        } set: { value in
            // Snapped to nothing at the bottom of the slider, so "Off" is off and not a
            // fade of a few milliseconds nobody asked for.
            let seconds = value < 0.05 ? 0 : value
            change(name) { timeline in
                guard timeline.audio.indices.contains(index) else { return }
                timeline.audio[index][keyPath: path] = seconds
            }
        }
    }

    private func change(_ name: String, _ mutate: @escaping @Sendable (inout Timeline) -> Void) {
        model.apply(Commands.Restyle(name, mutate))
    }
}
