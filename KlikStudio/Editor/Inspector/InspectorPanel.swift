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
                case .blur, .annotate, .zoom:
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
                case .webcam:
                    WebcamInspector(model: model)
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
            Text(hint(for: tool))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func hint(for tool: EditorTool) -> String {
        switch tool {
        case .blur:
            "Drag over anything on the picture to hide it — a password, a name, a face. It stays on the thing it covers when the camera moves."
        case .zoom:
            // Reachable only from a selected zoom, so this is the state where the selection
            // was deleted or undone out from under the tool.
            "Pick a zoom on the timeline, then click the picture to say what it should be pointed at."
        default:
            "Drag on the picture to place a label, an arrow or a box. It stays where you put it in the finished frame."
        }
    }

    /// What a tool is waiting for, when one is.
    ///
    /// Nothing reaches this today — the webcam was the last tool with an
    /// `unavailableReason` — and it is kept rather than deleted for the same reason the
    /// reason itself is: the next feature that lands model-first needs a panel that says so,
    /// and writing it again from memory would be writing it worse.
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
