import RecordKit
import SwiftUI
import TimelineKit

/// The settings column: whatever the current tool — or the current selection — is about.
///
/// It sits at the right of the window, beside the picture, with the rail of tools that
/// drives it down its left edge — between the picture and the controls — so choosing a tool
/// and seeing what it opened happen side by side. It is the one surface in the editor that
/// changes wholesale, so it says what it is showing. Without a heading, picking a tool
/// swapped one unlabelled stack of sliders for another and the only evidence of what
/// happened was a highlight moving along the rail — and while a timeline selection owns
/// the panel, the heading is the only thing saying that the panel is no longer about the
/// highlighted tool.
struct InspectorPanel: View {
    let model: EditorModel
    /// Opens the export sheet. The panel's head is where Export lives: it is the end of
    /// everything the column below it sets up.
    var export: () -> Void = {}
    @State private var state = InspectorState()

    var body: some View {
        VStack(spacing: 0) {
            ExportHeadButton(action: export)
                .padding(.horizontal, SidebarMetrics.contentInset)
                .padding(.top, 10)
                .padding(.bottom, 4)
            // Named only while a selection owns the panel, because that is when the panel
            // has stopped being about the chosen tool and needs a way back out. Otherwise
            // every section names itself.
            if selectionOwnsPanel {
                header
                StudioDivider(isSection: true)
            }
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
        .background(StudioTheme.Surface.panel)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(heading.title) settings")
    }

    // MARK: - What is showing

    @ViewBuilder
    private var content: some View {
        if selectionOwnsPanel {
            SelectionInspector(model: model)
        } else {
            switch model.tool {
            case .crop:
                CropInspector(model: model)
            case .frame:
                FrameInspector(model: model, state: state)
            case .blur, .annotate:
                // How to draw one. Once one is drawn it is selected, and the panel is
                // about that instead.
                canvasHint(model.tool)
            case .cursor:
                CursorInspector(model: model)
            case .captions:
                CaptionInspector(model: model)
            case .audio:
                AudioInspector(model: model)
            case .webcam:
                WebcamInspector(model: model)
            case .keyboard:
                KeyboardInspector(model: model)
            }
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
        // A mask is named for its kind. "Blur" over a spotlight's settings would be the
        // heading saying the opposite of what the panel does.
        if case .blur = model.selection, let mask = model.selectedMask {
            return (mask.style.title, mask.style.symbol)
        }
        return name
    }

    /// Whether the panel is showing the selection rather than the tool — which is also
    /// when clearing the selection is the way back, and so when the header offers it.
    private var selectionOwnsPanel: Bool {
        guard !model.selection.isEmpty, model.panelFollowsSelection else { return false }
        // Crop is a mode, not a place the selection can speak over: the handles are on
        // the picture and the way out of them has to be on the panel.
        return model.tool != .crop
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: heading.symbol)
                .font(.system(size: 12))
                .foregroundStyle(StudioTheme.Surface.ink)
                .frame(width: 16)
            Text(heading.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(StudioTheme.Surface.ink)
                .lineLimit(1)
            Spacer(minLength: 8)
            if selectionOwnsPanel {
                StudioIconButton(systemImage: "xmark",
                                 help: "Stop editing this and go back to \(model.tool.title)",
                                 accessibilityName: "Clear selection",
                                 size: .small,
                                 iconSize: 10) {
                    model.clearSelection()
                }
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
            // The mask tool does four things, so it says which one the next drag will
            // do — and, unlike a blur, a spotlight is quite happy to start in the middle.
            if tool == .blur {
                MaskToolControls(model: model)
                    .padding(.horizontal, 6)
            }
        }
    }

    private func hint(for tool: EditorTool) -> String {
        switch tool {
        case .blur:
            "Drag over anything on the picture to hide it — a password, a name, a face — or to put a spotlight on it. A mask stays on the thing it covers when the camera moves."
        default:
            "Drag on the picture to place a label — or add an arrow, a shape, a numbered step or a callout below and drag it where it belongs. Either way it stays where you put it in the finished frame."
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
        case .blur: ("Mask", "drop.halffull")
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
        case .keyCue: ("Shortcut", "keyboard")
        case .cameraLayout: ("Camera Layout", "person.crop.rectangle")
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

/// Export, as the head of the inspector: the window's one filled button, in Klik blue,
/// with its shortcut beside the word. Everything else in the window is a neutral; the
/// one way out of it is the one thing in colour.
struct ExportHeadButton: View {
    let action: () -> Void
    @Environment(StudioSettings.self) private var settings
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 11.5, weight: .semibold))
                Text("Export")
                    .font(.system(size: 12.5, weight: .semibold))
                if let shortcut = settings.editorShortcuts[.export]?.displayString {
                    Text(shortcut)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            .background(StudioPalette.brand.opacity(isHovering ? 0.9 : 1),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.white.opacity(0.12))
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(StudioPressStyle())
        .onHover { isHovering = $0 }
        .animation(StudioMotion.hover, value: isHovering)
        .help("Export this as a video or a GIF")
        .accessibilityLabel("Export")
    }
}
