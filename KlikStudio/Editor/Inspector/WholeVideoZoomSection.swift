import SwiftUI
import TimelineKit

/// The whole video held zoomed in, with the camera panning after the pointer — see
/// `CameraStyle.wholeVideoZoom`.
///
/// In the Frame panel, beside the frame's shape, rather than among a zoom's settings:
/// what it is for is framing — a vertical cut of a wide recording, a close crop of a big
/// display — and it is set before there is any zoom to select. The zooms themselves carry
/// on inside it, going further in.
struct WholeVideoZoomSection: View {
    let model: EditorModel

    private var style: StyleBinding { StyleBinding(model: model) }
    private var camera: CameraStyle { model.timeline.camera }

    /// Where the switch starts the level: in close enough to be seen as a choice, not so
    /// far that the first thing the switch does is lose most of the picture.
    private static let firstLevel = 1.5

    var body: some View {
        let isOn = camera.holdsWholeVideoZoomed
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
            InspectorSwitch("Keep the whole video zoomed in", isOn: Binding(
                get: { isOn },
                set: { on in
                    style.set(\.camera.wholeVideoZoom, to: on ? Self.firstLevel : 1, "Whole Video Zoom")
                }
            ))
            .help("For a vertical or square cut of a wide recording: the picture is held zoomed in and the camera follows the pointer across it, instead of showing the whole recording between zooms.")
            InspectorSlider(model: model, "Level", systemImage: "plus.magnifyingglass",
                            value: style.binding(\.camera.wholeVideoZoom, "Whole Video Zoom"),
                            range: 1.1...CameraStyle.wholeVideoZoomRange.upperBound,
                            format: { String(format: "%.1f×", $0) })
                .disabled(!isOn)
                .help("The camera stays at \(String(format: "%.1f×", camera.sanitised.wholeVideoZoom)) from the first frame to the last and pans after the pointer. A zoom goes further in from there — a 2× zoom here is \(String(format: "%.1f×", camera.sanitised.wholeVideoZoom * 2)). Follow, Steadiness and Stray in a zoom's Camera Motion set how it pans.")
        }
        .inspectorSection("Zoom", systemImage: "plus.magnifyingglass")
    }
}
