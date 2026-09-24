import SwiftUI
import TimelineKit

/// The right-hand panel: whatever the current tool — or the current selection — is about.
struct InspectorPanel: View {
    let model: EditorModel
    @State private var state = InspectorState()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                switch model.tool {
                case .frame, .crop:
                    // Selecting something on the timeline is a question about *that*, so
                    // it takes priority over the frame's own settings while it lasts.
                    if model.selection.isEmpty {
                        FrameInspector(model: model, state: state)
                    } else {
                        SelectionInspector(model: model)
                    }
                case .blur, .annotate:
                    // What is selected, or — with nothing drawn yet — how to draw one.
                    if model.selection.isEmpty {
                        canvasHint(model.tool)
                    } else {
                        SelectionInspector(model: model)
                    }
                case .cursor:
                    CursorInspector(model: model)
                case .captions:
                    CaptionInspector(model: model)
                case .audio:
                    AudioInspector(model: model)
                case .camera:
                    unavailable(model.tool)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .studioScrollEdges()
    }

    /// What a canvas tool is waiting for you to do.
    ///
    /// Not the same thing as `unavailable`: the tool works, there is simply nothing
    /// selected yet, and an empty panel reads as a feature that is broken rather than
    /// one that is ready.
    private func canvasHint(_ tool: EditorTool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(tool.title, systemImage: tool.symbol)
                .font(.system(size: 13, weight: .semibold))
            Text(tool == .blur
                 ? "Drag over anything on the picture to hide it — a password, a name, a face. It stays on the thing it covers when the camera moves."
                 : "Drag on the picture to place a label, an arrow or a box. It stays where you put it in the finished frame.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func unavailable(_ tool: EditorTool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(tool.title, systemImage: tool.symbol)
                .font(.system(size: 13, weight: .semibold))
            Text(tool.unavailableReason ?? "")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Panel chrome that is nobody else's business — which tab is showing, whether the
/// swatch grid is expanded.
///
/// Kept off `EditorModel` deliberately: writing to that invalidates every view reading
/// the playhead or the preview, and a disclosure triangle should not redraw the picture.
@MainActor
@Observable
final class InspectorState {
    /// Normally the tab is *derived* from the document, so undo moves it. The override
    /// exists only for "Image" with nothing chosen yet.
    var backgroundTabOverride: BackgroundTab?
    var showsAllGradients = false
}
