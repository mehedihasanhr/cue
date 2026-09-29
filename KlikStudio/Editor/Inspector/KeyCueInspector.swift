import CoreMedia
import SwiftUI
import TimelineKit

/// One shortcut: which keys, when, and whether it is drawn.
///
/// The Keyboard panel is the lane as a whole. This is a single press on it, reached by
/// clicking its chip, and it holds the things done to one press rather than to the
/// keys: correct what it says, move where it begins and ends, or keep it off the picture
/// without losing its place. Delete is the panel's own button under this.
struct KeyCueInspector: View {
    let model: EditorModel
    let id: UUID

    /// What is being typed, kept apart from the document until it is committed. Parsing
    /// on every keystroke would turn "⌘" into a cue with no key before the K arrives.
    @State private var draft = ""
    @FocusState private var isEditing: Bool

    private var cue: KeyCue? { model.timeline.keyCues.first { $0.id == id } }

    var body: some View {
        if let cue {
            VStack(alignment: .leading, spacing: SidebarSpacing.betweenSections) {
                keys(cue)
                timing(cue)
                visibility(cue)
            }
            .onAppear { draft = cue.title }
            .onChange(of: cue.title) { _, title in
                if !isEditing { draft = title }
            }
        }
    }

    // MARK: - Which keys

    private func keys(_ cue: KeyCue) -> some View {
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
            TextField("⌘⇧K, or cmd shift k", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.primary.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .focused($isEditing)
                .onSubmit { commit() }
                .onChange(of: isEditing) { _, editing in
                    if !editing { commit() }
                }
                .accessibilityLabel("Shortcut keys")

            Text("Symbols or words, in any order: ⌘⇧K, cmd shift k, ctrl-alt-delete. Add ×3 for a repeat.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .inspectorSection("Keys", systemImage: "keyboard")
    }

    private func commit() {
        guard let cue, draft != cue.title else { return }
        model.setKeyCueText(id, draft)
        // Whatever was typed, the field now shows what the document made of it.
        if let updated = self.cue { draft = updated.title }
    }

    // MARK: - When

    private func timing(_ cue: KeyCue) -> some View {
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
            edge(cue, title: "Starts", value: cue.start, isHead: true)
            edge(cue, title: "Ends", value: cue.end, isHead: false)
            InspectorRow(title: "Lasts", value: Timecode.length(cue.duration))
        }
        .inspectorSection("Timing", systemImage: "clock") {
            SectionButton(title: "Go to Start") { model.scrub(to: cue.start) }
        }
    }

    /// One edge, with a frame's nudge either way — the same control a caption has, for
    /// the same reason: a key that appears a frame before the thing it did is what "in
    /// sync" looks like.
    private func edge(_ cue: KeyCue, title: String, value: CMTime, isHead: Bool) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 66, alignment: .leading)
            Spacer(minLength: 0)
            nudge("chevron.left", isHead: isHead, forward: false)
            Text(Timecode.short(value))
                .font(.system(size: 12).monospacedDigit())
                .frame(minWidth: 58)
            nudge("chevron.right", isHead: isHead, forward: true)
        }
    }

    private func nudge(_ symbol: String, isHead: Bool, forward: Bool) -> some View {
        Button {
            let frame = CMTime(seconds: model.frameDuration, preferredTimescale: 60_000)
            model.moveKeyCueEdge(id, isHead: isHead, by: forward ? frame : .zero - frame)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .help("\(isHead ? "Start" : "End") one frame \(forward ? "later" : "earlier")")
        .accessibilityLabel("\(isHead ? "Start" : "End") one frame \(forward ? "later" : "earlier")")
    }

    // MARK: - Shown or not

    private func visibility(_ cue: KeyCue) -> some View {
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
            Button {
                model.toggleKeyCueHidden(id)
            } label: {
                Label(cue.isHidden ? "Show" : "Hide", systemImage: cue.isHidden ? "eye" : "eye.slash")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.small)
            .help(cue.isHidden ? "Draw this shortcut in the video again" : "Keep this on the lane but leave it out of the video")

            Text(note(cue))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .inspectorSection("In the video", systemImage: "eye")
    }

    /// Why this press is not on the picture, when it is not. A faded chip with no reason
    /// beside it is a chip that looks broken.
    private func note(_ cue: KeyCue) -> String {
        if cue.isHidden {
            return "Hidden: it stays on the lane and is left out of the video and the export."
        }
        if cue.isEmpty {
            return "Type the keys above and it will appear in the video."
        }
        if !model.timeline.keyStyle.isVisible {
            return "Keys are switched off for the whole video. Turn them on in the Keyboard panel or the Keyboard menu."
        }
        if cue.isNamedKeyAlone, !model.timeline.keyStyle.showsNamedKeysAlone {
            return "\(cue.title) pressed on its own is left out unless the Keyboard panel says to show those."
        }
        return "Shown in the video while the playhead is inside it."
    }
}
