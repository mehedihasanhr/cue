import CoreMedia
import SwiftUI
import TimelineKit

/// What is selected on the timeline, and what can be done to it.
struct SelectionInspector: View {
    let model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch model.selection {
            case .clip(let id):
                if let index = model.timeline.clips.firstIndex(where: { $0.id == id }) {
                    clip(model.timeline.clips[index], at: index)
                }
            case .zoom(let id):
                if let index = model.timeline.zooms.firstIndex(where: { $0.id == id }) {
                    zoom(index: index)
                    // How the camera moves, next to the zoom whose movement you are watching.
                    CameraInspector(model: model,
                                    isFollowing: model.timeline.zooms[index].followsCursor)
                }
            case .blur(let id):
                if let index = model.timeline.blurs.firstIndex(where: { $0.id == id }) {
                    blur(index: index)
                }
            case .annotation(let id):
                AnnotationInspector(model: model, id: id)
            case .range(let range):
                self.range(range)
            default:
                EmptyView()
            }

            if model.canDeleteSelection {
                Button("Delete", role: .destructive) { model.deleteSelection() }
                    .controlSize(.small)
            }
            Button("Done") { model.clearSelection() }
                .controlSize(.small)
        }
        .font(.system(size: 12))
    }

    // MARK: - Clip

    private func clip(_ clip: Clip, at index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Length", value: Timecode.length(clip.duration))
            LabeledContent("From", value: Timecode.short(clip.sourceStart))
            LabeledContent("To", value: Timecode.short(clip.sourceEnd))

            Picker("Speed", selection: Binding(
                get: { clip.speed },
                set: { model.setSpeed($0, of: clip.id) }
            )) {
                ForEach([0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 4.0, 8.0], id: \.self) { speed in
                    Text(TimelineClipRow.speedLabel(speed)).tag(speed)
                }
            }
        }
        .inspectorSection("Clip", systemImage: "film")
    }

    // MARK: - Zoom

    private func zoom(index: Int) -> some View {
        let zoom = model.timeline.zooms[index]
        return VStack(alignment: .leading, spacing: 10) {
            InspectorSlider(model: model, "Scale", systemImage: "plus.magnifyingglass",
                            value: binding(index, \.scale, "Zoom Scale"), range: 1...8)
            InspectorSlider(model: model, "Ramp", systemImage: "timelapse",
                            value: Binding(
                                get: { zoom.transition.seconds },
                                set: { seconds in
                                    change("Zoom Ramp") { $0.zooms[index].transition = CMTime(seconds: seconds, preferredTimescale: 600) }
                                }
                            ),
                            range: 0...2)

            Picker("Easing", selection: Binding(
                get: { zoom.easing },
                set: { easing in change("Zoom Easing") { $0.zooms[index].easing = easing } }
            )) {
                ForEach(Easing.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }

            Toggle("Follow the pointer", isOn: Binding(
                get: { zoom.followsCursor },
                set: { follows in change("Follow Cursor") { $0.zooms[index].followsCursor = follows } }
            ))

            LabeledContent("Starts", value: Timecode.short(zoom.start))
            LabeledContent("Lasts", value: Timecode.length(zoom.duration))
            // Why this zoom is here. A suggestion someone can see the reason for is one
            // they adjust; one that appeared from nowhere is one they delete.
            if let source = zoom.source, source != .manual {
                LabeledContent("Suggested by", value: source.title)
                    .foregroundStyle(.secondary)
            }
        }
        .inspectorSection("Zoom", systemImage: "plus.magnifyingglass")
    }

    // MARK: - Blur

    private func blur(index: Int) -> some View {
        let blur = model.timeline.blurs[index]
        return VStack(alignment: .leading, spacing: 10) {
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
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("From", value: Timecode.short(range.start))
            LabeledContent("Length", value: Timecode.length(range.duration))
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
