import CoreMedia
import Foundation
import TimelineKit

/// The clip lane's second set of verbs: freeze frames, title slides, moving a clip, and
/// how one clip gives way to the next.
///
/// All of them are one command each, so each is one step on the undo stack, and all of
/// them leave the thing they made or moved selected — the inspector then shows what can
/// be done to it next.
extension EditorModel {
    /// The selected clip and where it is, when a clip is what is selected.
    var selectedClip: (index: Int, clip: Clip)? {
        guard case .clip(let id) = selection,
              let index = timeline.clips.firstIndex(where: { $0.id == id }) else { return nil }
        return (index, timeline.clips[index])
    }

    // MARK: - Freeze frames

    /// Whether the playhead is over footage — the only thing with a frame to hold.
    var canFreezeFrame: Bool {
        timeline.clip(at: playhead)?.clip.isFootage == true
    }

    /// Why Freeze Frame is off, for the tooltip beside it.
    var freezeFrameReason: String? {
        guard !canFreezeFrame, let clip = timeline.clip(at: playhead)?.clip else { return nil }
        return clip.isTitle
            ? "A title has no frame to freeze — move the playhead onto the recording."
            : "The playhead is already on a freeze frame. Make it longer in the inspector."
    }

    /// A still of the frame under the playhead, two seconds long, put in at the playhead.
    func freezeFrameAtPlayhead() {
        let command = Commands.FreezeFrame(at: playhead)
        let before = timeline
        apply(command)
        guard timeline != before else { return }
        select(.clip(command.id))
    }

    /// How long a freeze frame or a title lasts, in seconds.
    func setHold(_ clipID: UUID, seconds: Double) {
        guard seconds.isFinite else { return }
        apply(Commands.SetHold(clipID: clipID, to: CMTime(seconds: seconds, preferredTimescale: 600)))
    }

    // MARK: - Title slides

    enum TitlePlace: CaseIterable, Identifiable {
        case start, playhead, end

        var id: Self { self }

        var menuTitle: String {
            switch self {
            case .start: "At Start"
            case .playhead: "At Playhead"
            case .end: "At End"
            }
        }
    }

    /// A title slide, three seconds long, at the start, the end or the playhead.
    func addTitle(at place: TitlePlace) {
        let time: CMTime = switch place {
        case .start: .zero
        case .playhead: playhead
        case .end: duration
        }
        let command = Commands.AddTitle(at: time)
        let before = timeline
        apply(command)
        guard timeline != before else { return }
        select(.clip(command.clip.id))
        // The playhead on the slide, so the preview shows what is being written.
        if let index = timeline.clips.firstIndex(where: { $0.id == command.clip.id }) {
            scrub(to: timeline.start(ofClipAt: index) + CMTime(value: 1, timescale: 1))
        }
    }

    func restyleTitle(_ clipID: UUID, _ name: String, _ change: @escaping @Sendable (inout TitleCard) -> Void) {
        apply(Commands.RestyleTitle(clipID: clipID, name, change))
    }

    // MARK: - Moving a clip

    /// Whether the selected clip can go `offset` places along — there is a place there.
    func canMoveSelectedClip(by offset: Int) -> Bool {
        guard let (index, _) = selectedClip else { return false }
        return timeline.clips.indices.contains(index + offset)
    }

    /// Swaps the selected clip with its neighbour, what was placed on it going with it.
    func moveSelectedClip(by offset: Int) {
        guard let (index, _) = selectedClip, timeline.clips.indices.contains(index + offset) else { return }
        moveClip(from: index, to: index + offset)
    }

    /// Moves a clip to a place in the order. See `ClipSequence.move` for what goes with it.
    func moveClip(from index: Int, to destination: Int) {
        guard timeline.clips.indices.contains(index) else { return }
        let id = timeline.clips[index].id
        apply(Commands.MoveClip(from: index, to: destination))
        select(.clip(id))
    }

    // MARK: - Transitions

    /// How the clip arrives from the one before it. `nil` is a plain cut.
    func setTransition(_ clipID: UUID, _ transition: ClipTransition?) {
        apply(Commands.SetTransition(clipID: clipID, transition))
    }

    /// The same transition with a different style, keeping its length — or a new one at
    /// the default length. `nil` takes it away.
    func setTransitionStyle(_ clipID: UUID, _ style: ClipTransition.Style?) {
        guard let clip = timeline.clips.first(where: { $0.id == clipID }) else { return }
        guard let style else {
            setTransition(clipID, nil)
            return
        }
        setTransition(clipID, ClipTransition(style, duration: clip.transition?.duration ?? ClipTransition.defaultDuration))
    }

    /// Whether the selected clip has a cut before it to arrive through.
    var selectedClipCanHaveTransition: Bool {
        (selectedClip?.index ?? 0) > 0
    }
}
