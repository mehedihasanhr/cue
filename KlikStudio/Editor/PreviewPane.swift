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
    private let inset: CGFloat = 22

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                // A neutral stage rather than flat black: the frame itself carries a
                // background, and judging that background against pure black is the one
                // lighting condition it will never be watched in.
                LinearGradient(colors: [Color(white: 0.16), Color(white: 0.09)],
                               startPoint: .top, endPoint: .bottom)

                if let preview = model.preview {
                    Image(nsImage: preview)
                        .resizable()
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
                case .zoom:
                    ZoomAimOverlay(model: model, stage: stage(in: proxy.size))
                default:
                    EmptyView()
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
