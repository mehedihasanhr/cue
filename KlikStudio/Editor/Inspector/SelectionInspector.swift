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
                    clip(model.timeline.clips[index], at: index)
                }
            case .zoom(let id):
                if let index = model.timeline.zooms.firstIndex(where: { $0.id == id }) {
                    ZoomInspector(model: model, index: index)
                }
            case .blur(let id):
                if let index = model.timeline.blurs.firstIndex(where: { $0.id == id }) {
                    blur(index: index)
                }
            case .annotation(let id):
                AnnotationInspector(model: model, id: id)
            case .cursorRegion(let id):
                CursorRegionInspector(model: model, id: id)
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
                .controlSize(.small)
                .padding(.top, SidebarSpacing.sectionPadding)
                .help("Remove this from the timeline")
            }
        }
        .font(.system(size: 12))
    }

    // MARK: - A run of the detached sound

    /// Both clocks at once, which is the only way to read a detached run.
    ///
    /// "Where it plays" and "which second of the recording it is" are the same number on an
    /// attached lane and different numbers the instant anything is dragged — and the gap
    /// between them *is* the edit. A panel showing only one of them would leave the user
    /// guessing at which, so it shows both and says which is which.
    private func soundRun(_ run: SoundRun) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Plays at", value: Timecode.short(run.start))
            LabeledContent("Length", value: Timecode.length(run.duration))
            LabeledContent("From", value: Timecode.short(run.sourceStart))
            LabeledContent("To", value: Timecode.short(run.sourceEnd))
            if run.speed != 1 {
                LabeledContent("Speed", value: TimelineClipRow.speedLabel(run.speed))
            }
            Text("This is the recording's own sound, detached from the picture. Drag it to slide it, or its edges to trim — the picture does not move.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Re-attach Audio") { model.requestSoundReattach() }
                .controlSize(.small)
        }
    }

    // MARK: - Clip

    private func clip(_ clip: Clip, at index: Int) -> some View {
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
            InspectorRow(title: "Starts", value: Timecode.short(model.timeline.start(ofClipAt: index)))
            InspectorRow(title: "Length", value: Timecode.length(clip.duration))

            InspectorField(title: "Speed") {
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
                .font(.system(size: 12))
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

            InspectorRow(title: "Starts", value: Timecode.short(region.start))
            InspectorRow(title: "Lasts", value: Timecode.length(region.duration))
            Text("Drag it along the timeline to move it, or take an edge to trim it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .inspectorSection("Sound", systemImage: "music.note")
    }

    /// A zoom's start or length, with a pair of nudges either side of it.
    private func timing(_ zoom: ZoomRegion, title: String, value: String,
                        _ nudge: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
            Text(value)
                .font(.system(size: 12))
                .monospacedDigit()
            Spacer(minLength: 4)
            Button { nudge(-0.1) } label: {
                Image(systemName: "minus").font(.system(size: 9, weight: .semibold))
                    .frame(width: 18, height: 16)
            }
            .buttonStyle(.bordered).controlSize(.mini)
            Button { nudge(0.1) } label: {
                Image(systemName: "plus").font(.system(size: 9, weight: .semibold))
                    .frame(width: 18, height: 16)
            }
            .buttonStyle(.bordered).controlSize(.mini)
        }
    }

    /// One end of one clip, with the source time it sits at and a pair of nudges.
    ///
    /// Source time rather than timeline time, because that is what a trim actually moves:
    /// the clip keeps its place in the edit and shows different footage. Showing the
    /// timeline position here would be showing a number the buttons do not change.
    private func trim(_ clip: Clip, edge: EditorModel.ClipEdge, title: String, value: CMTime) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)
            Text(Timecode.short(value))
                .font(.system(size: 12))
                .monospacedDigit()
            Spacer(minLength: 4)
            nudge("minus", clip: clip, edge: edge, by: -1 / 30)
            nudge("plus", clip: clip, edge: edge, by: 1 / 30)
        }
    }

    private func nudge(_ symbol: String, clip: Clip, edge: EditorModel.ClipEdge, by seconds: Double) -> some View {
        Button {
            model.nudgeTrim(clip, edge: edge, by: seconds)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .frame(width: 18, height: 16)
        }
        .buttonStyle(.bordered)
        .controlSize(.mini)
        .help("\(seconds < 0 ? "Earlier" : "Later") by a frame")
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
            Button(role: .destructive) {
                model.deleteSelection()
            } label: {
                Image(systemName: "trash")
            }
            .disabled(model.timeline.clips.count < 2)
            .help(model.timeline.clips.count < 2
                  ? "An edit has to keep one piece"
                  : "Remove this piece and close the gap")
        }
        .controlSize(.small)
        .padding(.top, 2)
    }

    // MARK: - Blur

    private func blur(index: Int) -> some View {
        let blur = model.timeline.blurs[index]
        return VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
            Picker("Style", selection: Binding(
                get: { blur.style },
                set: { style in change("Blur Style") { $0.blurs[index].style = style } }
            )) {
                Text("Blur").tag(BlurRegion.Style.gaussian)
                Text("Pixelate").tag(BlurRegion.Style.pixelate)
            }
            .pickerStyle(.segmented)

            InspectorSlider(model: model, "Strength", systemImage: "drop",
                            value: binding(index, \.radius, "Blur Strength", on: \.blurs),
                            range: 4...80)
        }
        .inspectorSection("Blur", systemImage: "drop.halffull")
    }

    // MARK: - Range

    private func range(_ range: CMTimeRange) -> some View {
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
            InspectorRow(title: "From", value: Timecode.short(range.start))
            InspectorRow(title: "Length", value: Timecode.length(range.duration))
            Menu("Set Speed") {
                ForEach([0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 4.0, 8.0], id: \.self) { speed in
                    Button(TimelineClipRow.speedLabel(speed)) {
                        model.apply(Commands.SetSpeed(range, speed: speed))
                    }
                }
            }
            .controlSize(.small)
        }
        .inspectorSection("Selection", systemImage: "selection.pin.in.out")
    }

    // MARK: - Plumbing

    private func change(_ name: String, _ mutate: @escaping @Sendable (inout Timeline) -> Void) {
        model.apply(Commands.Restyle(name, mutate))
    }

    private func binding(_ index: Int,
                         _ path: WritableKeyPath<ZoomRegion, Double> & Sendable,
                         _ name: String) -> Binding<Double> {
        Binding {
            model.timeline.zooms.indices.contains(index) ? model.timeline.zooms[index][keyPath: path] : 0
        } set: { value in
            model.apply(Commands.Restyle(name) { timeline in
                guard timeline.zooms.indices.contains(index) else { return }
                timeline.zooms[index][keyPath: path] = value
            })
        }
    }

    private func binding(_ index: Int,
                         _ path: WritableKeyPath<BlurRegion, Double> & Sendable,
                         _ name: String,
                         on regions: WritableKeyPath<Timeline, [BlurRegion]> & Sendable) -> Binding<Double> {
        Binding {
            model.timeline[keyPath: regions].indices.contains(index)
                ? model.timeline[keyPath: regions][index][keyPath: path] : 0
        } set: { value in
            model.apply(Commands.Restyle(name) { timeline in
                guard timeline[keyPath: regions].indices.contains(index) else { return }
                timeline[keyPath: regions][index][keyPath: path] = value
            })
        }
    }
}
