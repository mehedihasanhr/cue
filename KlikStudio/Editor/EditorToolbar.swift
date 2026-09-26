import AppKit
import SwiftUI
import TimelineKit

/// The editor's own title bar.
///
/// The system toolbar put Undo, Redo, Save and Export in a row of identical grey glyphs,
/// which says that exporting the video is the same size of decision as undoing a drag. It
/// is not: it is the reason the window is open. So the bar is drawn here instead — the
/// document's name in the middle where a document's name belongs, the small reversible
/// things as quiet glyphs, and Export as the one filled control on the screen.
///
/// It sits *under* the window's own title bar, which `EditorWindowChrome` makes
/// transparent, so the traffic lights float over the left end of it. `trafficLightInset`
/// is the room they need.
struct EditorToolbar: View {
    let model: EditorModel
    let export: () -> Void

    /// The width of the three system buttons plus the breathing room either side of them.
    ///
    /// Nothing of ours is drawn inside it. The traffic lights are the system's, they do
    /// not line up with the tool rail below them, and a control of ours squeezed into the
    /// gap lines up with neither — so the left end of the bar is left to them alone and
    /// every control this bar owns is in one cluster at the other end.
    private static let trafficLightInset: CGFloat = 78
    /// As tall as it has to be for the traffic lights and a row of 26-point controls,
    /// and no taller: this bar is the frame around the work, not part of it.
    static let height: CGFloat = 40

    var body: some View {
        ZStack {
            // Laid over the row rather than between two spacers, so the name sits in the
            // middle of the *window* however wide the controls on either side grow.
            title
            HStack(spacing: 8) {
                Spacer(minLength: 40)
                trailing
            }
        }
        .padding(.leading, Self.trafficLightInset)
        .padding(.trailing, 12)
        .frame(height: Self.height)
        .background {
            // Flat and dark, the way an editor's chrome is: the picture is the bright
            // thing in this window and everything around it should recede from it.
            Color.clear
                .studioSurface()
                .overlay(alignment: .bottom) { StudioDivider() }
        }
        // The whole bar drags the window, the way a real title bar does — minus the
        // controls, which `Button` already claims.
        .background(WindowDragArea())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Editor toolbar")
    }

    // MARK: - The name

    /// One line, quietly. The "Edited / Saved" line under it is gone: the Save button
    /// says both of those things now, and a two-line title made this bar half again as
    /// tall as it needed to be to say what file is open.
    private var title: some View {
        HStack(spacing: 0) {
            Text(model.name)
                .font(.system(size: 12))
            // The extension dimmed rather than dropped: it says what kind of thing
            // this is, without competing with what it is called.
            Text(".\(model.packageURL.pathExtension)")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
        .lineLimit(1)
        .truncationMode(.middle)
        .allowsHitTesting(false)
    }

    // MARK: - Trailing

    @ViewBuilder
    private var trailing: some View {
        GlyphButton(symbol: "folder", help: "Show this recording in the Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([model.packageURL])
        }

        StudioDivider(axis: .vertical, length: 16).padding(.horizontal, 2)

        GlyphButton(symbol: "arrow.uturn.backward",
                    help: model.document.undoName.map { "Undo \($0)" } ?? "Undo",
                    isEnabled: model.document.canUndo) { model.undo() }

        GlyphButton(symbol: "arrow.uturn.forward",
                    help: "Redo",
                    isEnabled: model.document.canRedo) { model.redo() }

        StudioDivider(axis: .vertical, length: 16).padding(.horizontal, 2)

        // Spelled out rather than left as a glyph. The edits live in the recording and
        // come back when it is opened again, which is worth a word: a downward arrow in
        // a row of grey icons reads as "download" to most people, and the one control
        // that keeps your work should not have to be guessed at.
        Button { model.save() } label: {
            Text(model.isDirty ? "Save" : "Saved")
                .font(.system(size: 12))
                .foregroundStyle(model.isDirty ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                .padding(.horizontal, 11)
                .frame(height: 26)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(.white.opacity(model.isDirty ? 0.1 : 0.04))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(BarButtonStyle())
        .disabled(!model.isDirty)
        .keyboardShortcut("s")
        .animation(StudioMotion.state, value: model.isDirty)
        .help(model.isDirty
              ? "Save these edits into the recording, so you can open it and carry on later (⌘S)"
              : "Every edit is saved in the recording")

        Button(action: export) {
            HStack(spacing: 5) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 11))
                Text("Export")
                    .font(.system(size: 12))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 11)
            .frame(height: 26)
            .background(StudioPalette.brand, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(BarButtonStyle())
        .help("Export this as a video or a GIF")
    }
}

/// One quiet control: a glyph that lights up under the pointer and dims when it cannot
/// be used. The same square as the tool rail's tiles, so the two rows of icons in this
/// window are one size.
private struct GlyphButton: View {
    let symbol: String
    let help: String
    var isEnabled = true
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .frame(width: 26, height: 26)
                .foregroundStyle(isEnabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.quaternary))
                .background {
                    if isHovering, isEnabled {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(.white.opacity(0.08))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(BarButtonStyle())
        .disabled(!isEnabled)
        .onHover { isHovering = $0 }
        .animation(StudioMotion.state, value: isHovering)
        .help(help)
    }
}

/// Lets the bar be dragged like the title bar it replaces.
///
/// `isMovableByWindowBackground` is not enough on its own: SwiftUI's hosting view takes
/// the mouse-down before AppKit can read it as a window drag. The same trick the recorder
/// bar uses, for the same reason.
private struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            // Double-click still does what the system does to a title bar — zoom, or
            // whatever the user set in Desktop & Dock.
            if event.clickCount == 2 {
                window?.performZoom(nil)
                return
            }
            window?.performDrag(with: event)
        }
    }
}
