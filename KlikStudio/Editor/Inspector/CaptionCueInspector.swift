import CoreMedia
import SwiftUI
import TimelineKit

/// One caption: what it says, when, and where it is cut.
///
/// The Captions panel is the transcript as a whole. This is a single line of it, reached
/// by clicking that line on the timeline, and it holds the things you do to a line rather
/// than to the captions: correct it, move where it begins and ends, cut it where the
/// speaker paused, or join it to the next.
struct CaptionCueInspector: View {
    let model: EditorModel
    let id: UUID

    private var cue: CaptionCue? { model.timeline.captions.first { $0.id == id } }

    var body: some View {
        if let cue {
            VStack(alignment: .leading, spacing: SidebarSpacing.betweenSections) {
                words(cue)
                timing(cue)
                shape(cue)
            }
        }
    }

    // MARK: - What it says

    private func words(_ cue: CaptionCue) -> some View {
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
            TextField("What is said here", text: text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(2...6)
                .font(.system(size: 12))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.primary.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .accessibilityLabel("Caption text")
        }
        .inspectorSection("Text", systemImage: "captions.bubble")
    }

    private var text: Binding<String> {
        Binding {
            cue?.text ?? ""
        } set: { text in
            model.setCaptionText(id, text)
        }
    }

    // MARK: - When

    private func timing(_ cue: CaptionCue) -> some View {
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
            edge(cue, title: "Starts", value: cue.start, isHead: true)
            edge(cue, title: "Ends", value: cue.end, isHead: false)
            InspectorRow(title: "Lasts", value: Timecode.length(cue.duration))
        }
        .inspectorSection("Timing", systemImage: "clock") {
            SectionButton(title: "Go to Start") { model.scrub(to: cue.start) }
        }
    }

    /// One edge of the line, with a frame's nudge either way.
    ///
    /// A frame rather than a tenth of a second: a caption that arrives a frame before the
    /// word is what "in sync" looks like, and that is a judgement made one frame at a
    /// time.
    private func edge(_ cue: CaptionCue, title: String, value: CMTime, isHead: Bool) -> some View {
        let frame = CMTime(seconds: model.frameDuration, preferredTimescale: 60_000)
        let name = isHead ? "Start" : "End"
        return InspectorNudgeRow(title: title, value: Timecode.short(value),
                                 earlierHelp: "\(name) one frame earlier",
                                 laterHelp: "\(name) one frame later",
                                 earlier: { move(cue, isHead: isHead, by: .zero - frame) },
                                 later: { move(cue, isHead: isHead, by: frame) })
    }

    private func move(_ cue: CaptionCue, isHead: Bool, by step: CMTime) {
        if isHead {
            // The far edge stays where it is: moving where a line begins must not move
            // where it ends.
            let start = max(.zero, min(cue.start + step, cue.end - Clip.minimumDuration))
            model.apply(Commands.MoveRegion(id: cue.id, start: start, duration: cue.end - start, trimsHead: true))
        } else {
            let end = max(cue.start + Clip.minimumDuration, min(cue.end + step, model.duration))
            model.apply(Commands.MoveRegion(id: cue.id, start: cue.start, duration: end - cue.start))
        }
    }

    // MARK: - Cutting and joining

    private func shape(_ cue: CaptionCue) -> some View {
        VStack(alignment: .leading, spacing: SidebarSpacing.betweenControls) {
            HStack(spacing: 8) {
                Button {
                    model.splitCaptionAtPlayhead(cue.id)
                } label: {
                    Label("Split at Playhead", systemImage: "scissors")
                        .frame(maxWidth: .infinity)
                }
                .disabled(!model.canSplitCaption(cue))

                Button {
                    model.mergeCaptionWithNext(cue.id)
                } label: {
                    Label("Join Next", systemImage: "arrow.right.to.line")
                        .frame(maxWidth: .infinity)
                }
                .disabled(model.captionAfter(cue.id) == nil)
            }
            .controlSize(.small)
            .help(note(cue))
        }
        .inspectorSection("Line", systemImage: "text.alignleft")
    }

    /// Why the split is not on offer, when it is not — a disabled button with no reason
    /// beside it is a button that looks broken.
    private func note(_ cue: CaptionCue) -> String {
        if cue.timedWords.isEmpty {
            return "Type what is said here. A line can then be split where the speaker pauses."
        }
        if cue.timedWords.count < 2 {
            return "A line of one word cannot be split."
        }
        if !model.canSplitCaption(cue) {
            return "Move the playhead inside this line to split it there."
        }
        return "Splitting puts each word on the side it was said on."
    }
}
