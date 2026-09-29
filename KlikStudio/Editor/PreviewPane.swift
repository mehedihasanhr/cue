import AVFoundation
import SwiftUI

/// The frame under the playhead, rendered exactly as it will be exported.
///
/// Also the canvas: a tool that works by direct manipulation — crop today, blur and
/// annotation later — draws its handles here, over the stage rect rather than over the
/// laid-out image.
struct PreviewPane: View {
    let model: EditorModel

    /// Room around the picture, so a shadow has somewhere to fall and a crop handle at
    /// the very edge is still grabbable.
    private let inset: CGFloat = 30

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                // The same surface as the panels and the timeline around it. The stage
                // used to be a grey gradient of its own, which made the middle of the
                // window a third colour competing with the frame standing on it — and
                // the frame carries its own background, which is the thing that is
                // supposed to be judged here.
                Color.clear.studioSurface()

                if let preview = model.preview {
                    Image(nsImage: preview)
                        .resizable()
                        // The frame is composed at export size and shown at about a
                        // third of it. Said out loud rather than left to a default,
                        // because this is the scale the rounded corners are judged at.
                        .interpolation(.high)
                        .antialiased(true)
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: model.tool.flattensPreview ? 0 : 10, style: .continuous))
                        .shadow(color: .black.opacity(model.tool.flattensPreview ? 0 : 0.5), radius: 18, y: 8)
                        .padding(inset)
                        .transition(.opacity)
                } else {
                    ProgressView().controlSize(.large)
                }

                switch model.tool {
                case .crop:
                    CropOverlay(model: model, stage: stage(in: proxy.size))
                case .blur, .annotate:
                    RegionCanvas(model: model, stage: stage(in: proxy.size))
                case .webcam:
                    // Drawn over the preview without being an `isCanvasTool`: that flag says
                    // the tool's *inspector* is a selection rather than settings, and the
                    // webcam panel is settings. What it needs here is a handle on the picture.
                    WebcamBubbleOverlay(model: model, stage: stage(in: proxy.size))
                default:
                    // Not a tool, and no mode to enter: selecting a zoom on the timeline is
                    // already an unambiguous statement about which zoom you mean, so its
                    // framing box is simply here. See `EditorModel.framedZoom`.
                    if model.isFramingZoom {
                        ZoomFramingOverlay(model: model, stage: stage(in: proxy.size))
                        ZoomFramingHint(model: model)
                    }
                }

                // The one control that says which question this surface is answering. It
                // sits on the picture rather than in the inspector because it is about the
                // picture, and it is the last thing in the stack so the framing handles
                // never end up underneath it.
                if model.canChooseZoomPreview {
                    ZoomPreviewSwitch(model: model)
                }
            }
            // How big the picture is allowed to be, told to the thing that renders it.
            //
            // While playing, the model composites at the pane's size rather than at the
            // project's: a 4K frame filling a pane this size is seven eighths of its pixels
            // thrown away by the window server. Reported from here because this is the only
            // place that knows the answer, and reported as the *stage* rather than the whole
            // pane so the inset and the aspect fit are already accounted for.
            //
            // `onChange` rather than `onGeometryChange`, which wants macOS 15 and this app
            // ships to 14 — and there is no need for it here, since the enclosing
            // `GeometryReader` has already measured the pane. `initial: true` so the first
            // playback after a window opens is not rendered against a pane size of zero.
            .onChange(of: stage(in: proxy.size).size, initial: true) { _, size in
                model.previewPaneResized(to: size)
            }
        }
    }

    /// Where the picture actually lands.
    ///
    /// Computed from the aspect ratio rather than measured off the laid-out `Image`,
    /// because the overlay's arithmetic has to be exact and because `NSImage` is being
    /// given a pixel size as a point size — true enough for `.resizable()`, which only
    /// needs the ratio, but not something to build a coordinate mapping on.
    private func stage(in size: CGSize) -> CGRect {
        let available = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
        guard available.width > 0, available.height > 0 else { return available }
        let ratio = model.previewSize
        guard ratio.width > 0, ratio.height > 0 else { return available }
        return AVMakeRect(aspectRatio: ratio, insideRect: available)
    }
}


