import SwiftUI
import TimelineKit

/// Which reading of the one preview is on screen: the framing, or the result.
///
/// The control that replaced the second preview window. There were two pictures of the same
/// video on screen — the main preview, and a panel in the corner rendering the same frame
/// again through the zoom being edited — and answering "what will this zoom look like?"
/// meant looking away from the thing you were dragging to a thumbnail a fifth of its size.
///
/// One surface, and a switch that says which question it is answering. Both readings are
/// the same renderer, the same descriptor and the same camera transform the export uses;
/// framing is that pipeline with the zooms taken out, which is the whole of the difference.
///
/// It appears only while a zoom is selected and goes away during playback, because playback
/// answers the question by itself.
struct ZoomPreviewSwitch: View {
    let model: EditorModel

    @State private var hovered: EditorModel.ZoomPreview?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(EditorModel.ZoomPreview.allCases) { mode in
                button(mode)
            }
        }
        .padding(3)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Zoom preview")
    }

    private func button(_ mode: EditorModel.ZoomPreview) -> some View {
        let isOn = model.zoomPreview == mode
        return Button {
            // Through the model's own verbs rather than by assigning: each parks the
            // playhead inside the zoom when it is outside it, and a Result that shows an
            // unzoomed frame because the playhead is elsewhere is the exact confusion this
            // control exists to end.
            if mode == .framing { model.frameSelectedZoom() } else { model.previewZoomResult() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: mode.symbol).font(.system(size: 10, weight: .semibold))
                Text(mode.title)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(isOn ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background {
                Capsule().fill(isOn ? AnyShapeStyle(Color.accentColor)
                                    : AnyShapeStyle(hovered == mode ? Color.primary.opacity(0.08) : Color.clear))
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? mode : (hovered == mode ? nil : hovered) }
        .animation(StudioMotion.state, value: isOn)
        .help(mode == .framing
              ? "Show the whole recording with this zoom's framing box on it"
              : "Show this zoom as it will play and as it will export")
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}

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
            .padding(.bottom, 48)
            .allowsHitTesting(false)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .opacity(model.isGesturing ? 0 : 1)
            .animation(StudioMotion.state, value: model.isGesturing)
        }
    }
}
