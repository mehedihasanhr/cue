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
///
/// The kit's segmented row, so it is the same control as every other either-or in the
/// window — the chosen reading lifted out of a squircle trough — set on a plate of glass
/// because it floats over the picture rather than sitting on a panel.
struct ZoomPreviewSwitch: View {
    let model: EditorModel

    var body: some View {
        StudioSegmented(selection: mode,
                        items: EditorModel.ZoomPreview.allCases,
                        title: \.title,
                        systemImage: \.symbol,
                        help: { mode in
                            mode == .framing
                                ? "Show the whole recording with this zoom's framing box on it"
                                : "Show this zoom as it will play and as it will export"
                        })
            // Its own width, not the picture's: the segmented row stretches its segments
            // across whatever it is offered, and here it is offered the whole preview.
            .fixedSize()
            .padding(Self.plateInset)
            .background(.regularMaterial, in: StudioTheme.squircle(StudioTheme.Radius.panel))
            .overlay(StudioTheme.squircle(StudioTheme.Radius.panel).strokeBorder(StudioTheme.Palette.stroke))
            .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Zoom preview")
    }

    /// The glass around the trough: the panel's radius less the trough's own, so the two
    /// corners run parallel.
    private static let plateInset: CGFloat = StudioTheme.Radius.panel - StudioTheme.Radius.inner - 2

    /// Through the model's own verbs rather than by assigning: each parks the playhead
    /// inside the zoom when it is outside it, and a Result that shows an unzoomed frame
    /// because the playhead is elsewhere is the exact confusion this control exists to end.
    private var mode: Binding<EditorModel.ZoomPreview> {
        Binding {
            model.zoomPreview
        } set: { mode in
            if mode == .framing { model.frameSelectedZoom() } else { model.previewZoomResult() }
        }
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
