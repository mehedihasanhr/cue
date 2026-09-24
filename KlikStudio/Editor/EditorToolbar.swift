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
    /// The app's export queue, for the pill beside the Export button. Handed in rather
    /// than read from the environment so this bar can still be built in a preview.
    let exports: ExportJobs
    let export: () -> Void

    /// The width of the three system buttons plus the breathing room either side of them.
    private static let trafficLightInset: CGFloat = 78
    static let height: CGFloat = 52

    var body: some View {
        ZStack {
            // Laid over the row rather than between two spacers, so the name sits in the
            // middle of the *window* however wide the controls on either side grow.
            title
            HStack(spacing: 8) {
                leading
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
            ZStack {
                Rectangle().fill(.bar)
                Rectangle().fill(.black.opacity(0.18))
            }
            .overlay(alignment: .bottom) { Divider() }
        }
        // The whole bar drags the window, the way a real title bar does — minus the
        // controls, which `Button` already claims.
        .background(WindowDragArea())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Editor toolbar")
    }

    // MARK: - The name

    private var title: some View {
        VStack(spacing: 1) {
            HStack(spacing: 0) {
                Text(model.name)
                    .font(.system(size: 13, weight: .medium))
                // The extension dimmed rather than dropped: it says what kind of thing
                // this is, without competing with what it is called.
                Text(".\(model.packageURL.pathExtension)")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
            }
            .lineLimit(1)

            Text(model.isDirty ? "Edited" : "Saved")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .contentTransition(.identity)
        }
        .allowsHitTesting(false)
    }

    // MARK: - Leading

    private var leading: some View {
        GlyphButton(symbol: "folder", help: "Show this recording in the Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([model.packageURL])
        }
    }

    // MARK: - Trailing

    @ViewBuilder
    private var trailing: some View {
        GlyphButton(symbol: "arrow.uturn.backward",
                    help: model.document.undoName.map { "Undo \($0)" } ?? "Undo",
                    isEnabled: model.document.canUndo) { model.undo() }

        GlyphButton(symbol: "arrow.uturn.forward",
                    help: "Redo",
                    isEnabled: model.document.canRedo) { model.redo() }

        GlyphButton(symbol: "square.and.arrow.down",
                    help: "Save (⌘S)",
                    isEnabled: model.isDirty) { model.save() }
            .keyboardShortcut("s")

        Divider().frame(height: 18).padding(.horizontal, 2)

        // Where a running export lives: in the chrome, not in a modal sheet. Nothing at
        // all when nothing is exporting.
        ExportStatusPill(jobs: exports)

        Button(action: export) {
            HStack(spacing: 5) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 11, weight: .semibold))
                Text("Export")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(StudioPalette.brand, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
                .frame(width: 28, height: 28)
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
