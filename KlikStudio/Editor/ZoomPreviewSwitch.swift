import SwiftUI
import TimelineKit

// Which reading of the preview is on screen — the framing or the result — is chosen on
// the canvas bar (`CanvasToolBar`) while a zoom is selected.

/// What the box does, under the picture, while a zoom is being framed.
///
/// One line, and only when it is worth reading: it fades out while a drag is running,
/// because by then the user is doing the thing the sentence describes.
struct ZoomFramingHint: View {
    let model: EditorModel

    var body: some View {
        if let zoom = model.framedZoom {
            VStack(spacing: 2) {
                Text("Drag the box to move the shot · a handle to change how much is in it · arrow keys to nudge")
                if zoom.followsCursor {
                    Text("It follows the pointer at the moment — framing it will stop that.")
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.white.opacity(0.85))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.bottom, 62)
            .allowsHitTesting(false)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .opacity(model.isGesturing ? 0 : 1)
            .animation(StudioMotion.state, value: model.isGesturing)
        }
    }
}
