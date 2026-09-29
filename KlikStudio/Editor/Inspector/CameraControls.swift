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
            Text("Camera Motion")
                .font(.system(size: 12.5))
                .foregroundStyle(Color.primary.opacity(0.82))
            Group {
                InspectorSlider(model: model, "Steadiness", systemImage: "hand.raised",
                                value: style.binding(\.camera.steadiness, "Steadiness"), range: 0...2)
                InspectorSlider(model: model, "Follow", systemImage: "scope",
                                value: style.binding(\.camera.follow, "Follow Strength"), range: 0...1)
                InspectorSlider(model: model, "Stray", systemImage: "arrow.left.and.right",
                                value: style.binding(\.camera.safeArea, "Safe Area"), range: 0.05...1)
            }
            .opacity(isFollowing ? 1 : 0.5)

            Text(isFollowing
                 ? "Steadiness smooths the pointer before the camera follows it. Stray is how far the pointer may wander from the middle before the frame has to move — the pointer never leaves the frame."
                 : "This zoom is not following the pointer, so these have nothing to move.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .opacity(isFollowing ? 1 : 0.5)

            Divider()

            // Not about following, so it sits below the rule and outside the dimming that
            // the three sliders above take when a zoom holds its aim. It applies to every
            // zoom in the project.
            Toggle("Zoom the whole picture", isOn: style.binding(\.camera.zoomsWholeFrame, "Zoom Scope"))
            Text(model.timeline.camera.zoomsWholeFrame
                 ? "The frame grows and travels with the zoom — corners, shadow and all — and the padding closes up as the camera pushes in. The background stays put."
                 : "The frame stays where the padding put it and only its contents magnify, so the padding, corners and shadow never move.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Camera motion")
    }
}
