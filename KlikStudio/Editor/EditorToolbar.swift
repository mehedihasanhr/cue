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
    /// Whether the inspector column is showing. A binding to the window's session rather
    /// than state of its own, because the View menu flips the same switch.
    @Binding var showsInspector: Bool
    let export: () -> Void

    /// The width of the three system buttons plus the breathing room either side of them.
    ///
    /// Nothing of ours is drawn inside it. The traffic lights are the system's, and a
    /// control of ours squeezed in beside them lines up with nothing below it — so the
    /// left end of the bar is left to them alone and every control this bar owns is in one
    /// cluster at the other end, over the inspector it mostly concerns.
    private static let trafficLightInset: CGFloat = 78
    /// As tall as it has to be for the traffic lights and a row of 28-point controls,
    /// and no taller: this bar is the frame around the work, not part of it. The same
    /// height as the transport bar, so the two strips of chrome either side of the picture
    /// are one size.
    static let height: CGFloat = 34

    /// The gap between two controls in a cluster, and the room either side of the short
    /// rule between two clusters. Two numbers, used everywhere in the bar, so the spacing
    /// is a rhythm rather than a run of near-misses.
    private static let gap: CGFloat = 6
    private static let clusterGap: CGFloat = 8

    var body: some View {
        ZStack {
            // Laid over the row rather than between two spacers, so the name sits in the
            // middle of the *window* however wide the controls on either side grow.
            title
            HStack(spacing: Self.gap) {
                Spacer(minLength: 40)
                trailing
            }
        }
        .padding(.leading, Self.trafficLightInset)
        .padding(.trailing, SidebarMetrics.contentInset - 4)
        .frame(height: Self.height)
        // The window's seam colour, with no rule under it: the strip is the top edge of
        // the frame the panels sit in, not a panel of its own.
        .background(StudioTheme.Surface.seam)
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
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(StudioTheme.Surface.label)
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
        // Spelled out rather than left as a glyph. The edits live in the recording and
        // come back when it is opened again, which is worth a word: a downward arrow in
        // a row of grey icons reads as "download" to most people, and the one control
        // that keeps your work should not have to be guessed at.
        //
        // It reads the autosaver's state, which is the one truth about saving: written,
        // being written, waiting to be written, or not written and why. A failure stays
        // on show — red, and pressable to try again — until a write succeeds.
        let saving = model.autosaver.state
        Button { model.save() } label: {
            Text(saveTitle(for: saving))
                .foregroundStyle(saveStyle(for: saving))
        }
        // A secondary button while there is something to save; a ghost — just the word —
        // once there is not, so "Saved" reads as a state rather than as a button waiting
        // to be pressed.
        .buttonStyle(.studio(saveIsPressable(saving) ? .secondary : .ghost, size: .small))
        .disabled(!saveIsPressable(saving))
        // ⌘S is File › Save's, in the menu bar, where it answers whatever has the keyboard.
        .animation(StudioMotion.state, value: saving)
        .help(saveHelp(for: saving))
        .accessibilityLabel("Save")
        .accessibilityValue(saveTitle(for: saving))

        // Where a running export lives: in the chrome, not in a modal sheet. Nothing at
        // all when nothing is exporting.
        ExportStatusPill(jobs: exports)

        clusterRule

        // The inspector's switch, at the end of the bar directly over the column it shows
        // and hides — where Xcode and Keynote keep theirs. It is the one way back to the
        // tool tabs with the column put away, other than the View menu and a tool's
        // shortcut, so it is never hidden itself.
        GlyphButton(symbol: "sidebar.right",
                    help: showsInspector ? "Hide the inspector (⌥⌘I)" : "Show the inspector (⌥⌘I)",
                    accessibilityName: showsInspector ? "Hide inspector" : "Show inspector",
                    isOn: showsInspector) {
            showsInspector.toggle()
        }
    }

    /// The short rule between two clusters of controls.
    private var clusterRule: some View {
        StudioDivider(axis: .vertical, length: 16)
            .padding(.horizontal, Self.clusterGap - Self.gap)
    }

    // MARK: - The Save control's four faces

    private func saveTitle(for state: EditorAutosaver.State) -> String {
        switch state {
        case .saved: "Saved"
        case .edited: "Save"
        case .saving: "Saving…"
        case .failed: "Couldn't save"
        }
    }

    /// Red for a failure in either appearance: `Color.red` adapts, and it is the one
    /// state in this bar that must not be quiet. "Saved" and "Saving…" are secondary ink on
    /// a disabled button, which the button dims again — tertiary, in effect, without
    /// disappearing.
    private func saveStyle(for state: EditorAutosaver.State) -> AnyShapeStyle {
        switch state {
        case .saved, .saving: AnyShapeStyle(.secondary)
        case .edited: AnyShapeStyle(.primary)
        case .failed: AnyShapeStyle(Color.red)
        }
    }

    private func saveIsPressable(_ state: EditorAutosaver.State) -> Bool {
        switch state {
        case .edited, .failed: true
        case .saved, .saving: false
        }
    }

    private func saveHelp(for state: EditorAutosaver.State) -> String {
        switch state {
        case .saved:
            "Every edit is saved in the recording"
        case .edited:
            model.autosaver.isEnabled
                ? "These edits will be saved into the recording in a moment. ⌘S saves them now."
                : "Save these edits into the recording, so you can open it and carry on later (⌘S)"
        case .saving:
            "Writing the edits into the recording"
        case .failed(let reason):
            reason
        }
    }
}

/// One quiet control: a ghost `StudioIconButton` — nothing but its glyph until the pointer
/// is over it, dimmed when it cannot be used. The same 28-point squircle as the transport
/// bar's, so the rows of icons in this window read as one family.
private struct GlyphButton: View {
    let symbol: String
    let help: String
    var accessibilityName: String?
    var isEnabled = true
    /// For a switch: an accent wash and accent glyph while on, the way the system draws a
    /// toolbar toggle that is pressed in.
    var isOn = false
    let action: () -> Void

    var body: some View {
        StudioIconButton(systemImage: symbol,
                         help: help,
                         accessibilityName: accessibilityName,
                         isActive: isOn,
                         action: action)
            .disabled(!isEnabled)
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
