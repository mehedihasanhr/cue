import CoreMedia
import Foundation
import Testing
@testable import TimelineKit

/// Editing one piece of a split take.
///
/// Splitting worked and then left you with pieces you could not act on individually. These
/// cover the arithmetic the per-clip panel drives: trimming one end of one piece without
/// disturbing its neighbours, and the guards that stop a piece being trimmed out of
/// existence.
struct ClipEditingTests {
    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    /// A 12-second take cut at 5s, like the one in the screenshot that prompted this.
    private func split() -> Timeline {
        var timeline = Timeline(sourceDuration: time(12))
        ClipSequence.split(&timeline, at: time(5))
        return timeline
    }

    @Test func aSplitLeavesTwoPiecesThatCanBeToldApart() {
        let timeline = split()
        #expect(timeline.clips.count == 2)
        #expect(timeline.clips[0].duration == time(5))
        #expect(timeline.clips[1].duration == time(7))
        #expect(timeline.start(ofClipAt: 1) == time(5))
    }

    /// The point of per-piece editing: the other piece does not move.
    @Test func trimmingOnePiecesInPointLeavesTheOtherAlone() {
        var timeline = split()
        let untouched = timeline.clips[0]

        _ = ClipSequence.trim(&timeline, clipID: timeline.clips[1].id, head: time(6), tail: nil)

        #expect(timeline.clips[0] == untouched)
        #expect(timeline.clips[1].sourceStart == time(6))
        #expect(timeline.clips[1].duration == time(6), "a second off the front is a second shorter")
    }

    @Test func trimmingTheOutPointShortensFromTheEnd() {
        var timeline = split()
        _ = ClipSequence.trim(&timeline, clipID: timeline.clips[1].id, head: nil, tail: time(10))
        #expect(timeline.clips[1].sourceStart == time(5))
        #expect(timeline.clips[1].duration == time(5))
    }

    /// The edit stays contiguous: trimming a piece shortens the whole take rather than
    /// opening a hole in it.
    @Test func trimmingAPieceShortensTheEditRatherThanLeavingAGap() {
        var timeline = split()
        let before = timeline.duration
        _ = ClipSequence.trim(&timeline, clipID: timeline.clips[0].id, head: time(2), tail: nil)

        #expect(timeline.duration == before - time(2))
        #expect(timeline.start(ofClipAt: 1) == timeline.clips[0].duration,
                "the second piece follows the first with nothing between them")
        // And time still maps everywhere in the edit.
        #expect(timeline.sourceTime(at: .zero) == time(2))
    }

    /// A speed change on one piece is a speed change on one piece.
    @Test func speedAppliesToThePieceItWasAskedOf() {
        var timeline = split()
        timeline.clips[1].speed = 2
        #expect(timeline.clips[0].duration == time(5))
        #expect(timeline.clips[1].duration == time(3.5), "seven seconds of source at 2×")
        #expect(timeline.duration == time(8.5))
    }

    /// Trimming cannot eat a piece: something has to be left to select.
    @Test func aPieceCannotBeTrimmedAwayToNothing() {
        var timeline = split()
        let clip = timeline.clips[1]
        // Ask for an in-point past its own out-point.
        _ = ClipSequence.trim(&timeline, clipID: clip.id, head: clip.sourceEnd + time(1), tail: nil)
        #expect(timeline.clips[1].duration >= Clip.minimumDuration)
    }

    /// Where a cut may go, which is what the Split button on a selected piece asks.
    @Test func aCutAtAPiecesOwnEdgeIsNotACut() {
        var timeline = split()
        #expect(!ClipSequence.split(&timeline, at: time(5)), "there is already a cut here")
        #expect(!ClipSequence.split(&timeline, at: .zero))
        #expect(timeline.clips.count == 2)
        #expect(ClipSequence.split(&timeline, at: time(8)), "but inside a piece it is")
        #expect(timeline.clips.count == 3)
    }
}
