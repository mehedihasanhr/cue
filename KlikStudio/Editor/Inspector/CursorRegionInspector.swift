import CoreMedia
import SwiftUI
import TimelineKit

/// One stretch where the pointer behaves differently from the rest of the recording.
///
/// The Pointer panel next door is about the whole take — how big the cursor is, whether it
/// bounces on a click. This is about a moment, and the three things it offers are the three
/// a demo actually asks for: get out of the way, calm down, hold still.
///
/// Addressed by id rather than by index, unlike the zoom and blur sections of
/// `SelectionInspector`: the lane is kept sorted by start time, so dragging this region
/// past its neighbour renumbers the array while this panel is open on it, and an index
/// would quietly start editing the wrong one.
struct CursorRegionInspector: View {
    let model: EditorModel
    let id: UUID

    private var region: CursorRegion? {
        model.timeline.cursorRegions.first { $0.id == id }
    }

    var body: some View {
        if let region {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Hide the pointer", isOn: toggle(\.isHidden, "Hide Pointer"))
                Toggle("Hold it still", isOn: toggle(\.isHeld, "Hold Pointer"))
                    .help("Keeps the pointer where it was when this stretch began, so it stops wandering while something else is being read.")

                InspectorSlider(model: model, "Calm", systemImage: "scribble",
                                value: slider(\.smoothing, "Calm Pointer"), range: 0...1)
                InspectorSlider(model: model, "Ramp", systemImage: "timelapse",
                                value: seconds(\.transition, "Pointer Ramp"), range: 0...1)

                // What the region does is a fade, a slide and an averaging, all over the
                // ramp — so a stretch with no ramp is the one case where the pointer really
                // does change between two frames, and that is worth saying rather than
                // leaving someone to discover it in an export.
                if region.transition.seconds <= 0 {
                    note("With no ramp the pointer changes on a single frame, which reads as a cut.")
                } else if region.isHidden {
                    note("The pointer fades out and back over the ramp, and the camera stops following it while it is gone.")
                }
                if region.isInert {
                    note("This stretch is not doing anything yet — hide the pointer, hold it, or give it some calm.")
                }

                LabeledContent("Starts", value: Timecode.short(region.start))
                LabeledContent("Lasts", value: Timecode.length(region.duration))
                Text("Drag it along the Pointer lane to move it, or take an edge to change what it covers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 12))
            .inspectorSection("Pointer over time", systemImage: "cursorarrow.slash")
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Plumbing

    /// A toggle: one undo entry, named for what it changed.
    private func toggle(_ path: WritableKeyPath<CursorRegion, Bool> & Sendable,
                        _ name: String) -> Binding<Bool> {
        Binding {
            region?[keyPath: path] ?? false
        } set: { value in
            model.restyleCursorRegion(id, name) { $0[keyPath: path] = value }
        }
    }

    /// A slider. The coalescing into one undo entry per drag comes from `InspectorSlider`.
    private func slider(_ path: WritableKeyPath<CursorRegion, Double> & Sendable,
                        _ name: String) -> Binding<Double> {
        Binding {
            region?[keyPath: path] ?? 0
        } set: { value in
            model.restyleCursorRegion(id, name) { $0[keyPath: path] = value }
        }
    }

    /// A duration, shown to the user in seconds because that is what a ramp is measured in.
    private func seconds(_ path: WritableKeyPath<CursorRegion, CMTime> & Sendable,
                         _ name: String) -> Binding<Double> {
        Binding {
            region?[keyPath: path].seconds ?? 0
        } set: { value in
            model.restyleCursorRegion(id, name) {
                $0[keyPath: path] = CMTime(seconds: value, preferredTimescale: 600)
            }
        }
    }
}
