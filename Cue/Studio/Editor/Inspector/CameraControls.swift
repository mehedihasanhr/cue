import SwiftUI
import TimelineKit

/// How the zoomed camera moves while it follows the pointer.
///
/// One set of values for the whole recording rather than one per zoom: a take where each
/// zoom drifts to its own rhythm reads as a fault, and nobody tuning this wants to tune it
/// eight times. It lives inside the selected zoom's Advanced section anyway, because that
/// is where somebody notices the movement is wrong — and behind the disclosure because a
/// project-wide setting has no business being the fourth thing you see when you click a
/// chip.
///
/// The three are deliberately separate, because they fail in different directions and the
/// fix for one is not the fix for another: a camera that jitters wants more *steadiness*,
/// one that lurches at the pointer wants less *follow*, and one that loses the pointer
/// off the edge of the frame wants a tighter *safe area*.
struct CameraControls: View {
    let model: EditorModel
    /// Whether the zoom being looked at follows the pointer at all. When it does not,
    /// none of this does anything, and saying so beats three sliders that move nothing.
    let isFollowing: Bool

    private var style: StyleBinding { StyleBinding(model: model) }

    var body: some View {
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
            InspectorSubheading("Camera Motion")
                .help("For every zoom in the project")

            // Zoom speed is not here: it sits beside the selected zoom's own Speed, in
            // front, where "too quick" is first said.

            Group {
                InspectorSlider(model: model, "Steadiness", systemImage: "hand.raised",
                                value: style.binding(\.camera.steadiness, "Steadiness"), range: 0...2)
                    .help("Steadiness smooths the pointer before the camera follows it.")
                InspectorSlider(model: model, "Follow", systemImage: "scope",
                                value: style.binding(\.camera.follow, "Follow Strength"), range: 0...1)
                    .help("How closely the camera keeps up with the pointer.")
                InspectorSlider(model: model, "Stray", systemImage: "arrow.left.and.right",
                                value: style.binding(\.camera.safeArea, "Safe Area"), range: 0.05...1)
                    .help("Stray is how far the pointer may wander from the middle before the frame has to move — the pointer never leaves the frame.")
            }
            // Dimmed rather than disabled, as before: the values are still the project's
            // and still editable, they simply have nothing to move on this zoom.
            .opacity(isFollowing ? 1 : 0.5)
            if !isFollowing {
                InspectorNote("This zoom doesn't follow the pointer, so these have nothing to move.")
            }

            // Not about following, so they sit outside the dimming that the three sliders
            // above take when a zoom holds its aim. Each applies to every zoom in the
            // project.
            InspectorSwitch("Zoom the whole picture", isOn: style.binding(\.camera.zoomsWholeFrame, "Zoom Scope"))
                .help(model.timeline.camera.zoomsWholeFrame
                      ? "The frame grows and travels with the zoom — corners, shadow and all — and the padding closes up as the camera pushes in. The background stays put."
                      : "The frame stays where the padding put it and only its contents magnify, so the padding, corners and shadow never move.")

            // What "close together" means is `ZoomGlide`'s rule; the tooltip says it in a
            // sentence.
            InspectorSwitch("Glide between close zooms", isOn: Binding(
                get: { model.glidesBetweenZooms },
                set: { model.setGlidesBetweenZooms($0) }
            ))
            .help(model.glidesBetweenZooms
                  ? "When two zooms touch, or the gap between them is shorter than their two ramps, the camera moves straight from one framing to the next instead of pulling back to the whole picture in between. An instant zoom never glides."
                  : "The camera pulls back to the whole picture at the end of every zoom, however soon the next one begins.")

            // A glide that waits, so it lives under the glide and only works while it is on.
            InspectorRow("Stay zoomed in") {
                InspectorPicker(selection: style.binding(\.camera.keepsZoomedInFor, "Stay Zoomed In"),
                                options: [0.0, 2.0, 4.0, 8.0],
                                title: { $0 == 0 ? "Never" : "Across gaps up to \(Int($0)) s" })
            }
            .disabled(!model.glidesBetweenZooms)
            .help(model.timeline.camera.keepsZoomedInFor > 0
                  ? "Between zooms up to \(Int(model.timeline.camera.keepsZoomedInFor)) seconds apart the camera holds the first framing, then travels to the next, instead of pulling out to the whole picture and back."
                  : "Hold the first framing across a short gap, then travel to the next, instead of pulling out to the whole picture and back.")

            // The level the whole video is held at lives with the frame's shape, where it
            // is set; here it is only said, because it changes what every zoom's scale means.
            if model.timeline.camera.holdsWholeVideoZoomed {
                InspectorNote("The whole video is held at \(String(format: "%.1f×", model.timeline.camera.sanitised.wholeVideoZoom)) (Frame ▸ Zoom).")
                    .help("The whole video is held at \(String(format: "%.1f×", model.timeline.camera.sanitised.wholeVideoZoom)) (Frame ▸ Zoom), so this zoom goes that much further in, and between zooms the camera pans after the pointer with these same settings.")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Camera motion")
    }
}
