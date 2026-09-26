import RecordKit
import SwiftUI
import TimelineKit

/// The camera bubble: whether it is there, where it sits, and what shape it is.
///
/// Named for the webcam and not for "the camera", because this editor already has a camera
/// and it is a different thing: `CameraControls`, inside the zoom inspector, tunes how the *zoomed* camera
/// follows the pointer. One panel is about a lens pointed at a face, the other is about a
/// crop drifting over a screenshot, and the two being one word apart is how somebody ends
/// up tuning steadiness to stop a bubble wobbling.
///
/// Every control here writes through `StyleBinding`, so each one is an ordinary undoable
/// style edit named for the thing it changed — the same as padding or pointer size. Nothing
/// on this panel is a preference: the bubble travels in the project, because it changes the
/// exported file.
struct WebcamInspector: View {
    let model: EditorModel

    private var style: StyleBinding { StyleBinding(model: model) }
    private var webcam: WebcamSettings { model.timeline.webcam }

    /// Whether this recording has a camera in it at all.
    ///
    /// Read from the manifest, which is what the manifest's track list is for. It changes
    /// what this panel *says* and not what it lets you do: the settings are part of the
    /// document either way, so a project opened from a take with no camera must not quietly
    /// throw them away — somebody may be building a template.
    private var hasFootage: Bool { model.hasTrack(.webcam) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Show camera", isOn: style.binding(\.webcam.isEnabled, "Camera Bubble"))

                corners
                    .disabled(!webcam.isEnabled)

                InspectorSlider(model: model, "Size", systemImage: "arrow.up.left.and.arrow.down.right",
                                value: style.binding(\.webcam.size, "Camera Size"), range: 0.08...0.5)
                InspectorSlider(model: model, "Roundness", systemImage: "circle",
                                value: style.binding(\.webcam.roundness, "Camera Roundness"), range: 0...1)
                InspectorSlider(model: model, "Shadow", systemImage: "shadow",
                                value: style.binding(\.webcam.shadowOpacity, "Camera Shadow"), range: 0...1)

                Toggle("Mirror", isOn: style.binding(\.webcam.isMirrored, "Mirror Camera"))
                Toggle("Grow while zoomed", isOn: style.binding(\.webcam.reactsToZoom, "Camera Zoom"))
            }
            .font(.system(size: 12))
            // Dimmed rather than removed when the bubble is off, so the panel does not
            // change height as the toggle is flicked — and so the settings are visibly still
            // there rather than looking lost.
            .opacity(webcam.isEnabled ? 1 : 0.5)
            .inspectorSection("Camera", systemImage: "person.crop.square")

            note
        }
    }

    /// The four corners, plus the state a drag on the picture puts it in.
    ///
    /// `.custom` is offered as a *reading* rather than as a choice: picking it from a menu
    /// would leave the bubble wherever it already was with no hint of what to do next, so
    /// the row shows it selected when it applies and the note below says how to get there.
    private var corners: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.on.square.dashed")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text("Corner")
                .frame(width: 74, alignment: .leading)
            Picker("", selection: cornerSelection) {
                ForEach(WebcamSettings.Corner.pickable, id: \.self) { corner in
                    Image(systemName: corner.symbol).tag(corner)
                }
                if webcam.corner == .custom {
                    Image(systemName: "hand.draw").tag(WebcamSettings.Corner.custom)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    /// Writes through a command so the change is undoable and named, like every other
    /// control here. A `Binding` straight at the model would skip the undo stack.
    private var cornerSelection: Binding<WebcamSettings.Corner> {
        Binding { webcam.corner } set: { style.set(\.webcam.corner, to: $0, "Camera Corner") }
    }

    /// What the panel cannot do anything about: no camera in the take, or a bubble parked
    /// somewhere by hand.
    @ViewBuilder
    private var note: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !hasFootage {
                Text("This recording has no camera in it, so there is nothing to draw. Turn the camera on in the recorder bar before the take.")
            } else if webcam.corner == .custom {
                Text("The bubble is where you put it. Drag it on the picture to move it, or pick a corner above to park it.")
            } else {
                Text("Drag the bubble on the picture to put it anywhere. The camera is cropped to the middle of its shot, so a wide camera keeps a face centred rather than squashed.")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

extension WebcamSettings.Corner {
    /// The four that can be chosen from a row of buttons. `.custom` is not one of them —
    /// it is what a drag produces, and it has no button because "put it somewhere
    /// unspecified" is not an instruction anybody can follow.
    static var pickable: [WebcamSettings.Corner] { [.topLeft, .topRight, .bottomLeft, .bottomRight] }

    var symbol: String {
        switch self {
        case .topLeft: "arrow.up.left.square"
        case .topRight: "arrow.up.right.square"
        case .bottomLeft: "arrow.down.left.square"
        case .bottomRight: "arrow.down.right.square"
        case .custom: "hand.draw"
        }
    }

    var title: String {
        switch self {
        case .topLeft: "Top Left"
        case .topRight: "Top Right"
        case .bottomLeft: "Bottom Left"
        case .bottomRight: "Bottom Right"
        case .custom: "Where you put it"
        }
    }
}
