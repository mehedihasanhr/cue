import CoreMedia
import Foundation

extension ClipSequence {
    /// Puts one clip into the sequence at a moment, pushing everything after it along.
    ///
    /// A title slide or a freeze frame going in is a paste of one clip, so it is one:
    /// `insert` already knows where a clip may land (at a cut, opening one if it can), what
    /// happens to the regions after it (they move with their footage) and to one spanning
    /// the seam (it is stretched over the new clip). Neither needed a rule of its own.
    @discardableResult
    public static func insert(_ timeline: inout Timeline, clip: Clip, at time: CMTime) -> Bool {
        insert(&timeline, CopiedFootage(clips: [clip], sourceDuration: timeline.sourceDuration,
                                        media: timeline.media.filter { $0.path == clip.source }), at: time)
    }

    /// The frame under a moment, held for `length`, put in at that moment.
    ///
    /// "The frame under the playhead" is the frame the preview is showing there, which is
    /// the one the playhead's source time falls in — with one exception. At the very end
    /// of a clip the source time is the clip's out-point, which is the first frame the
    /// clip does *not* show; so the moment is taken a millisecond back, inside the clip,
    /// where the frame is one the edit actually plays.
    ///
    /// Refused on a title, which has no frame to hold, and on a freeze frame, which is
    /// already one — lengthening it is what was meant.
    ///
    /// - Parameter id: the new clip's identity, chosen by the caller so it can select what
    ///   it just made.
    @discardableResult
    public static func freeze(_ timeline: inout Timeline,
                              at time: CMTime,
                              for length: CMTime = Clip.defaultStillLength,
                              id: UUID = UUID()) -> Bool {
        guard let (_, clip, offset) = timeline.clip(at: max(.zero, min(time, timeline.duration))),
              clip.isFootage else { return false }
        let inside = offset >= clip.duration
            ? max(.zero, clip.duration - CMTime(value: 1, timescale: 1_000))
            : offset
        // Of the clip's own file: a freeze of an imported clip holds that clip's frame.
        let still = Clip(id: id, sourceStart: clip.sourceTime(atOffset: inside), sourceDuration: .zero,
                         hold: length, source: clip.source)
        return insert(&timeline, clip: still, at: time)
    }

    /// Changes how a clip arrives from the one before it. `nil` makes the cut a plain cut.
    ///
    /// Refused on the first clip, which has nothing before it to arrive from — the menu
    /// offering it there would be offering an edit nobody could see.
    @discardableResult
    public static func setTransition(_ timeline: inout Timeline,
                                     clipID: UUID,
                                     to transition: ClipTransition?) -> Bool {
        guard let index = timeline.clips.firstIndex(where: { $0.id == clipID }), index > 0,
              timeline.clips[index].transition != transition else { return false }
        timeline.clips[index].transition = transition
        return true
    }
}
