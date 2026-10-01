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
            VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
                InspectorSwitch("Hide the pointer", isOn: toggle(\.isHidden, "Hide Pointer"))
                    .help(region.isHidden && region.transition.seconds > 0
                          ? "The pointer fades out and back over the ramp, and the camera stops following it while it is gone."
                          : "Hide the pointer for this stretch")
                InspectorSwitch("Hold it still", isOn: toggle(\.isHeld, "Hold Pointer"))
                    .help("Keeps the pointer where it was when this stretch began, so it stops wandering while something else is being read.")
                stretchEffect("Spotlight here", \.spotlights, "Spotlight Stretch",
                              isLimited: model.timeline.cursor.spotlight.isEnabled
                                  && model.timeline.cursor.spotlight.scope == .markedStretches,
                              why: "Turn on the Spotlight in the Pointer panel and set Where to Marked stretches.")
                stretchEffect("Magnify here", \.magnifies, "Magnifier Stretch",
                              isLimited: model.timeline.cursor.magnifier.isEnabled
                                  && model.timeline.cursor.magnifier.scope == .markedStretches,
                              why: "Turn on the Magnifier in the Pointer panel and set Where to Marked stretches.")

                InspectorSlider(model: model, "Calm", systemImage: "scribble",
                                value: slider(\.smoothing, "Calm Pointer"), range: 0...1)
                InspectorSlider(model: model, "Ramp", systemImage: "timelapse",
                                value: seconds(\.transition, "Pointer Ramp"), range: 0...1,
                                format: { String(format: "%.2fs", $0) })
                    .help("What the stretch does is a fade, a slide and an averaging, all over the ramp.")

                // What the region does happens over the ramp — so a stretch with no ramp
                // is the one case where the pointer really does change between two frames,
                // and that is worth a line rather than a discovery in an export. One line
                // at most: the stretch doing nothing at all outranks it.
                if region.isInert {
                    InspectorNote("This stretch isn't doing anything yet.")
                        .help("This stretch is not doing anything yet — hide the pointer, hold it, give it some calm, or spotlight or magnify it.")
                } else if region.transition.seconds <= 0 {
                    InspectorNote("With no ramp, the change is a cut.")
                        .help("With no ramp the pointer changes on a single frame, which reads as a cut.")
                }

                InspectorRow(title: "Starts", value: Timecode.short(region.start))
                InspectorRow(title: "Lasts", value: Timecode.length(region.duration))
                    .help("Drag it along the Pointer lane to move it, or take an edge to change what it covers.")
            }
            .inspectorSection("Pointer over Time", systemImage: "cursorarrow.slash")
        }
    }

    /// A switch for an effect limited to marked stretches, off — with its reason as the
    /// tooltip — when the effect is off or is on for the whole video, where marking a
    /// stretch would change nothing.
    private func stretchEffect(_ title: String,
                               _ path: WritableKeyPath<CursorRegion, Bool> & Sendable,
                               _ name: String,
                               isLimited: Bool,
                               why: String) -> some View {
        InspectorSwitch(title, isOn: toggle(path, name))
            .disabled(!isLimited)
            .help(isLimited ? "" : why)
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
