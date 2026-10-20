import SwiftUI
import TimelineKit

/// The Camera menu: the webcam over time — where it sits in each stretch, and what it
/// shows.
///
/// Its own menu, beside Keyboard, for the reason Keyboard is one: these are the verbs of
/// one lane and one panel, and a lane's verbs listed inside Edit are verbs nobody finds.
/// Everything here is disabled on a recording made without the camera, since there is
/// nothing for it to act on; the Webcam panel says why.
extension EditorCommands {
    private var cameraEditor: EditorModel? { windows.menuTarget?.model }

    /// Whether the front editor has a camera to act on.
    private var hasCamera: Bool { cameraEditor?.canLayOutCamera == true }

    @ViewBuilder
    var camera: some View {
        Menu("Camera") {
            // Over the selected stretch when there is one, and for a few seconds from the
            // playhead when there is not — see `EditorModel.addCameraLayout`.
            // No shortcuts: the keys near these are taken, and four more chords to learn for
            // something done a few times a video is not a trade worth making.
            Button("Camera Only at Playhead") { cameraEditor?.addCameraLayout(.cameraOnly) }
                .disabled(!hasCamera)
            Button("Side by Side at Playhead") { cameraEditor?.addCameraLayout(.sideBySide) }
                .disabled(!hasCamera)
            Button("Hide Camera at Playhead") { cameraEditor?.addCameraLayout(.hidden) }
                .disabled(!hasCamera)
            Button("Camera Bubble at Playhead") { cameraEditor?.addCameraLayout(.bubble) }
                .disabled(!hasCamera)
            // The stretch selected, or the one under the playhead.
            Menu("Layout of This Stretch") {
                ForEach(CameraLayout.allCases, id: \.self) { layout in
                    Toggle(layout.title, isOn: Binding(
                        get: { cameraEditor?.activeCameraLayout?.layout == layout },
                        set: { _ in
                            if let region = cameraEditor?.activeCameraLayout {
                                cameraEditor?.setCameraLayout(region.id, to: layout)
                            }
                        }
                    ))
                }
            }
            .disabled(cameraEditor?.activeCameraLayout == nil)
            Divider()
            Menu("Camera Background") {
                ForEach(WebcamSettings.Background.allCases, id: \.self) { background in
                    Toggle(background.title, isOn: Binding(
                        get: { cameraEditor?.timeline.webcam.background == background },
                        set: { _ in cameraEditor?.setCameraBackground(background) }
                    ))
                }
            }
            .disabled(!hasCamera)
            Button("Reset Camera Framing") { cameraEditor?.resetCameraCrop() }
                .disabled(!hasCamera || cameraEditor?.timeline.webcam.crop == WebcamCrop())
            Divider()
            Button(cameraEditor?.timeline.webcam.isEnabled == true ? "Turn Camera Off" : "Turn Camera On") {
                cameraEditor?.toggleCamera()
            }
            .disabled(!hasCamera)
            Button("Remove All Camera Layouts") { cameraEditor?.removeAllCameraLayouts() }
                .disabled(cameraEditor?.timeline.cameraLayouts.isEmpty != false)
        }
    }
}
