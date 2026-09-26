import SwiftUI
import TimelineKit

/// The settings column: whatever the current tool — or the current selection — is about.
///
/// It sits at the left of the window, next to the rail that drives it, and it is the one
/// surface in the editor that changes wholesale. So it says what it is showing. Without a
/// heading, picking a tool swapped one unlabelled stack of sliders for another and the
/// only evidence of what happened was a chip moving in the rail.
struct InspectorPanel: View {
    let model: EditorModel
    @State private var state = InspectorState()

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: SidebarSpacing.betweenSections) {
                    content
                }
                .padding(.horizontal, SidebarMetrics.contentInset)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // No scroller. The panel is a column of controls, not a document: the bar
            // appears over the right-hand end of every slider in it, and the length of
            // the panel is not something anybody needs reporting.
            .scrollIndicators(.never)
            .studioScrollEdges()
        }
        .studioSurface()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(heading.title) settings")
    }

    // MARK: - What is showing

    @ViewBuilder
    private var content: some View {
        switch model.tool {
        case .crop:
            // Crop is a mode, not a place the selection can speak over: the handles are
            // on the picture and the way out of them has to be on the panel.
            CropInspector(model: model)
        case .frame:
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

    // MARK: - Heading

    /// The name of what is on screen, and — while something is selected — a way back out
    /// of it. Derived rather than stored: the panel already decides this in `content`,
    /// and a second source for the same answer is a second thing to keep in step.
    private var heading: (title: String, symbol: String) {
        guard selectionOwnsPanel, let name = model.selection.panelName else {
            return (model.tool.title, model.tool.symbol)
        }
        return name
    }

    /// Whether the panel is showing the selection rather than the tool — which is also
    /// when clearing the selection is the way back, and so when the header offers it.
    private var selectionOwnsPanel: Bool {
        guard !model.selection.isEmpty else { return false }
        switch model.tool {
        case .frame, .blur, .annotate, .zoom: return true
        case .crop, .cursor, .webcam, .captions, .audio: return false
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: heading.symbol)
                .font(.system(size: 12))
                .foregroundStyle(Color.accentColor)
                .frame(width: 18)
            Text(heading.title)
                .font(.system(size: 13))
                .lineLimit(1)
            Spacer(minLength: 8)
            if selectionOwnsPanel {
                Button {
                    model.clearSelection()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(BarButtonStyle())
                .foregroundStyle(.secondary)
                .help("Stop editing this and go back to the frame")
                .accessibilityLabel("Clear selection")
            }
        }
        .padding(.horizontal, SidebarMetrics.contentInset)
        .frame(height: SidebarMetrics.headerHeight)
        .animation(StudioMotion.state, value: heading.title)
    }

    // MARK: - Nothing to show yet

    /// What a canvas tool is waiting for you to do.
    ///
    /// Not the same thing as `unavailable`: the tool works, there is simply nothing
    /// selected yet, and an empty panel reads as a feature that is broken rather than
    /// one that is ready.
    private func canvasHint(_ tool: EditorTool) -> some View {
        VStack(spacing: 14) {
            hint(hint(for: tool), symbol: tool.symbol)
            // Only the annotate tool offers a way in that is not a drag. A blur is a
            // rectangle over a particular thing on the picture, so putting one in the
            // middle of the frame and asking the user to drag it onto that thing is a worse
            // gesture than drawing it there, not a second one.
            if tool == .annotate {
                AddAnnotationButton(model: model, isCompact: false)
                    .padding(.horizontal, 6)
            }
        }
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
            "Drag on the picture to place a label, an arrow or a box — or add one below and drag it where it belongs. Either way it stays where you put it in the finished frame."
        }
    }

    /// What a tool is waiting for, when one is.
    ///
    /// Nothing reaches this today — the webcam was the last tool with an
    /// `unavailableReason` — and it is kept rather than deleted for the same reason the
    /// reason itself is: the next feature that lands model-first needs a panel that says so,
    /// and writing it again from memory would be writing it worse.
    private func unavailable(_ tool: EditorTool) -> some View {
        hint(tool.unavailableReason ?? "", symbol: tool.symbol)
    }

    /// A sentence where controls would be. Centred and quiet, so an empty panel reads as
    /// a waiting room rather than a page that failed to load.
    private func hint(_ text: String, symbol: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 22))
                .foregroundStyle(.quaternary)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 6)
        .padding(.top, 28)
        .frame(maxWidth: .infinity)
    }
}

private extension Selection {
    /// What the panel calls this selection, when it is the thing the panel is about.
    var panelName: (title: String, symbol: String)? {
        switch self {
        case .none: nil
        case .clip: ("Clip", "film")
        case .zoom: ("Zoom", "plus.magnifyingglass")
        case .blur: ("Blur", "drop.halffull")
        case .annotation: ("Annotation", "character.textbox")
        case .caption: ("Caption", "captions.bubble")
        case .audio: ("Sound", "music.note")
        case .sound: ("Recorded Sound", "waveform")
        case .soundTrack: ("Sound Source", "waveform.badge.mic")
        // Both lanes arrived after this heading did, and a panel that names what it is
        // showing must name these too — a nil here is a header that says "Pointer" while
        // the panel below it is about one stretch of pointer.
        case .cursorRegion: ("Pointer over time", "cursorarrow.slash")
        case .soundRun: ("Sound Run", "waveform.path")
        case .range: ("Range", "selection.pin.in.out")
        case .headTrim: ("Trimmed Start", "arrow.left.to.line")
        case .tailTrim: ("Trimmed End", "arrow.right.to.line")
        }
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
    var showsAllSystemWallpapers = false
}
