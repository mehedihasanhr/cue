import CoreGraphics
import CoreMedia
import Foundation
import Testing
@testable import TimelineKit

/// Freeze frames: a clip that holds one frame of the recording for a length of its own.
///
/// The hold is a clip like any other in the sequence, so most of these are about every
/// existing edit meeting one — split, delete, speed, trim, copy, paste, the excerpt — and
/// doing something a person would call sensible rather than something the arithmetic
/// happened to produce.
struct FreezeFrameTests {
    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    private func close(_ a: CMTime, _ b: CMTime, within tolerance: Double = 0.002) -> Bool {
        abs((a - b).seconds) < tolerance
    }

    private func timeline(seconds: Double = 30) -> Timeline {
        Timeline(sourceDuration: time(seconds))
    }

    // MARK: - Putting one in

    @Test func freezingInTheMiddleOfAClipHoldsThatFrameThereAndPushesTheRestAlong() throws {
        var timeline = timeline()
        #expect(ClipSequence.freeze(&timeline, at: time(10), for: time(2)))

        #expect(timeline.clips.count == 3)
        let still = timeline.clips[1]
        #expect(still.isStill)
        #expect(still.sourceStart == time(10), "the frame under the playhead")
        #expect(still.duration == time(2))
        #expect(timeline.duration == time(32), "two seconds longer, and nothing else lost")
        #expect(timeline.sourceTime(at: time(10.5)) == time(10), "it holds")
        #expect(timeline.sourceTime(at: time(11.99)) == time(10))
        #expect(timeline.sourceTime(at: time(12)) == time(10), "and then plays on from where it stopped")
        #expect(timeline.sourceTime(at: time(13)) == time(11))
    }

    /// The default the menu uses when nobody has said how long.
    @Test func aFreezeFrameIsTwoSecondsUnlessToldOtherwise() {
        var timeline = timeline()
        #expect(Commands.FreezeFrame(at: time(5)).apply(to: &timeline))
        #expect(timeline.clips[1].duration == time(2))
    }

    /// The id is the caller's, so the editor can select the still it just made.
    @Test func theCommandsIdIsTheStillsId() {
        var timeline = timeline()
        let id = UUID()
        #expect(Commands.FreezeFrame(at: time(5), id: id).apply(to: &timeline))
        #expect(timeline.clips.contains { $0.id == id && $0.isStill })
    }

    /// A sped-up clip is held at the frame the playhead is showing, not the one its
    /// timeline position would name at normal speed.
    @Test func freezingInsideASpedUpClipHoldsTheFrameOnScreen() {
        var timeline = timeline()
        ClipSequence.setSpeed(&timeline, range: CMTimeRange(start: .zero, end: time(30)), speed: 2)
        #expect(ClipSequence.freeze(&timeline, at: time(4)))
        #expect(timeline.clips[1].sourceStart == time(8))
    }

    /// At the very end, the source time is the clip's out-point — the first frame it does
    /// not show. The hold takes the last frame it does.
    @Test func freezingAtTheEndHoldsTheLastFrameTheEditShows() throws {
        var timeline = timeline()
        _ = ClipSequence.trim(&timeline, clipID: timeline.clips[0].id, head: nil, tail: time(20))
        #expect(ClipSequence.freeze(&timeline, at: timeline.duration))
        let still = try #require(timeline.clips.last)
        #expect(still.isStill)
        #expect(still.sourceStart < time(20))
        #expect(close(still.sourceStart, time(20), within: 0.01))
    }

    /// A regions laid over the recording keep their footage: the ones after the playhead
    /// move on by the hold, and one spanning it holds with the frame.
    @Test func regionsAfterTheFreezeMoveWithTheirFootage() {
        var timeline = timeline()
        timeline.zooms = [ZoomRegion(start: time(15), duration: time(3))]
        timeline.captions = [CaptionCue(start: time(9), duration: time(2), text: "held")]
        timeline.blurs = [BlurRegion(start: time(2), duration: time(3), rect: CGRect(x: 0, y: 0, width: 0.2, height: 0.2))]

        #expect(ClipSequence.freeze(&timeline, at: time(10), for: time(2)))

        #expect(timeline.zooms[0].start == time(17))
        #expect(timeline.captions[0].start == time(9))
        #expect(timeline.captions[0].duration == time(4), "a caption over the frozen moment stays up through it")
        #expect(timeline.blurs[0].start == time(2), "before the freeze, nothing moves")
    }

    // MARK: - Nothing to freeze

    @Test func aTitleHasNoFrameToFreeze() {
        var timeline = timeline()
        ClipSequence.insert(&timeline, clip: .title(TitleCard()), at: .zero)
        let before = timeline
        #expect(!ClipSequence.freeze(&timeline, at: time(1)))
        #expect(timeline == before)
    }

    @Test func freezingAFreezeFrameIsRefused() {
        var timeline = timeline()
        ClipSequence.freeze(&timeline, at: time(10))
        let before = timeline
        #expect(!ClipSequence.freeze(&timeline, at: time(11)))
        #expect(timeline == before)
    }

    // MARK: - It is silent

    /// Picture held, sound not: a detach lays no run down over it, and a copy of it
    /// carries none.
    @Test func aStillLaysNoSoundDown() throws {
        var timeline = timeline()
        ClipSequence.freeze(&timeline, at: time(10), for: time(2))
        let runs = timeline.soundRunsFollowingClips
        #expect(runs.count == 2)
        #expect(runs[0].end == time(10))
        #expect(runs[1].start == time(12), "a gap of silence over the still")
        #expect(runs[1].sourceStart == time(10), "and the words carry on where they stopped")

        let footage = try #require(CopiedFootage(CMTimeRange(start: time(9), duration: time(4)), in: timeline))
        #expect(footage.soundRuns.allSatisfy { run in
            !(run.start < time(3) && run.end > time(1))
        }, "nothing sounds over the part of the copy that is the still")
    }

    /// A detached lane keeps its words on their pictures: the still opens a gap in it.
    @Test func freezingOnADetachedLaneCutsTheRunAndLeavesSilence() {
        var timeline = timeline()
        ClipSequence.detachSound(&timeline)
        ClipSequence.freeze(&timeline, at: time(10), for: time(2))
        let runs = timeline.detachedSound ?? []
        #expect(runs.count == 2)
        #expect(runs[0].end == time(10))
        #expect(runs[1].start == time(12))
        #expect(runs[1].sourceStart == time(10))
    }

    /// Clicks are heard where they are seen, and a click in the frozen moment is not seen
    /// happening — it is seen once, in the footage after the hold.
    @Test func aClickUnderTheHeldFrameIsHeardOnceAfterIt() {
        var timeline = timeline()
        timeline.cursor.clickSound = true
        ClipSequence.freeze(&timeline, at: time(10), for: time(2))
        let click = CursorTrack.Click(t: 10.5, point: CGPoint(x: 10, y: 10), isSecondary: false)
        let moments = timeline.clickSoundMoments(for: [click])
        #expect(moments.count == 1)
        #expect(close(moments[0].time, time(12.5)))
    }

    /// The sound's shape changed, so the preview has to rebuild it — even though a hold
    /// consumes nothing from the recording and the numbers a cut used to carry are equal.
    @Test func lengtheningAStillChangesTheSoundsSignature() throws {
        var timeline = timeline()
        ClipSequence.freeze(&timeline, at: time(10), for: time(2))
        let before = timeline.audioSignature
        let id = timeline.clips[1].id
        #expect(ClipSequence.setHold(&timeline, clipID: id, to: time(5)))
        #expect(timeline.audioSignature != before)
    }

    // MARK: - Its length

    @Test func lengtheningAStillMovesWhatComesAfterIt() {
        var timeline = timeline()
        ClipSequence.freeze(&timeline, at: time(10), for: time(2))
        timeline.zooms = [ZoomRegion(start: time(15), duration: time(2)),
                          ZoomRegion(start: time(10.5), duration: time(1))]
        let id = timeline.clips[1].id

        #expect(ClipSequence.setHold(&timeline, clipID: id, to: time(4)))
        #expect(timeline.clips[1].duration == time(4))
        #expect(timeline.duration == time(34))
        #expect(timeline.zooms.contains { $0.start == time(17) }, "the later zoom moved by two seconds")
        #expect(timeline.zooms.contains { $0.start == time(10.5) && $0.duration == time(1) },
                "one placed on the still stays where it was put")
    }

    @Test func shorteningAStillTakesTheTimeOffItsEnd() {
        var timeline = timeline()
        ClipSequence.freeze(&timeline, at: time(10), for: time(4))
        timeline.zooms = [ZoomRegion(start: time(12.5), duration: time(1)),
                          ZoomRegion(start: time(20), duration: time(2))]
        let id = timeline.clips[1].id

        #expect(ClipSequence.setHold(&timeline, clipID: id, to: time(2)))
        #expect(timeline.duration == time(32))
        #expect(timeline.zooms.count == 1, "a zoom on the part that went goes with it")
        #expect(timeline.zooms[0].start == time(18))
    }

    @Test func aHoldCannotBeMadeShorterThanAClip() {
        var timeline = timeline()
        ClipSequence.freeze(&timeline, at: time(10))
        let id = timeline.clips[1].id
        ClipSequence.setHold(&timeline, clipID: id, to: .zero)
        #expect(timeline.clips[1].duration == Clip.minimumDuration)
    }

    @Test func footageHasNoHoldToChange() {
        var timeline = timeline()
        let before = timeline
        #expect(!ClipSequence.setHold(&timeline, clipID: timeline.clips[0].id, to: time(3)))
        #expect(timeline == before)
    }

    // MARK: - Every other edit, meeting one

    @Test func splittingAStillGivesTwoStillsOfTheSameFrame() {
        var timeline = timeline()
        ClipSequence.freeze(&timeline, at: time(10), for: time(2))
        #expect(ClipSequence.split(&timeline, at: time(11)))
        #expect(timeline.clips.count == 4)
        #expect(timeline.clips[1].isStill && timeline.clips[2].isStill)
        #expect(timeline.clips[1].duration == time(1))
        #expect(timeline.clips[2].duration == time(1))
        #expect(timeline.clips[2].sourceStart == time(10))
        #expect(timeline.duration == time(32), "a split is not an edit to the length")
    }

    @Test func deletingAStillTakesExactlyItsLengthOut() {
        var timeline = timeline()
        ClipSequence.freeze(&timeline, at: time(10), for: time(2))
        timeline.zooms = [ZoomRegion(start: time(20), duration: time(2))]
        #expect(ClipSequence.delete(&timeline, range: CMTimeRange(start: time(10), duration: time(2))))
        #expect(timeline.duration == time(30))
        #expect(timeline.clips.allSatisfy { $0.isFootage })
        #expect(timeline.zooms[0].start == time(18))
    }

    /// A still in a stretch being sped up is still that long: there is no footage in it to
    /// go faster, and the regions over the footage either side still land on their frames.
    @Test func speedingUpAStretchWithAStillInItLeavesTheStillsLength() {
        var timeline = timeline()
        ClipSequence.freeze(&timeline, at: time(10), for: time(2))
        timeline.zooms = [ZoomRegion(start: time(20), duration: time(2))]   // 18 s of source
        #expect(ClipSequence.setSpeed(&timeline, range: CMTimeRange(start: .zero, end: time(32)), speed: 2))
        #expect(timeline.clips.first { $0.isStill }?.duration == time(2))
        #expect(timeline.duration == time(17), "five, then the two-second still, then ten")
        // 18 s of source is 8 s past the still at 2×: 5 + 2 + 4.
        #expect(close(timeline.zooms[0].start, time(11)))
    }

    @Test func aStillCannotBeTrimmed() {
        var timeline = timeline()
        ClipSequence.freeze(&timeline, at: time(10))
        let before = timeline
        #expect(!ClipSequence.trim(&timeline, clipID: timeline.clips[1].id, head: time(4), tail: nil))
        #expect(timeline == before)
    }

    /// Copy, paste and duplicate carry the hold. Rebuilt field by field, the copy used to
    /// arrive as a clip of no length.
    @Test func copyingAndPastingAStillKeepsItAStill() throws {
        var timeline = timeline()
        ClipSequence.freeze(&timeline, at: time(10), for: time(2))
        let footage = try #require(CopiedFootage(.clip(timeline.clips[1].id), in: timeline)).freshened()
        #expect(footage.clips.count == 1)
        #expect(footage.clips[0].isStill)
        #expect(footage.clips[0].duration == time(2))

        #expect(ClipSequence.insert(&timeline, footage, at: time(20)))
        #expect(timeline.duration == time(34))
        #expect(timeline.clips.filter { $0.isStill }.count == 2)
        #expect(Set(timeline.clips.map(\.id)).count == timeline.clips.count, "the paste has its own id")
    }

    @Test func aStillSurvivesThePasteboard() throws {
        var timeline = timeline()
        ClipSequence.freeze(&timeline, at: time(10), for: time(3))
        let footage = try #require(CopiedFootage(.clip(timeline.clips[1].id), in: timeline))
        let data = try #require(footage.encoded())
        let back = try #require(CopiedFootage.decoded(from: data))
        #expect(back == footage)
    }

    /// Export Selection cuts into a still and keeps holding.
    @Test func anExcerptThatCutsIntoAStillHoldsForThePartItKept() {
        var timeline = timeline()
        ClipSequence.freeze(&timeline, at: time(10), for: time(2))
        let cut = timeline.cut(to: CMTimeRange(start: time(11), duration: time(3)))
        #expect(cut.duration == time(3))
        #expect(cut.clips[0].isStill)
        #expect(cut.clips[0].duration == time(1))
        #expect(cut.sourceTime(at: time(0.5)) == time(10))
        #expect(cut.sourceTime(at: time(1.5)) == time(10.5))
    }

    // MARK: - Reading it back

    @Test func aStillRoundTripsThroughAProject() throws {
        var timeline = timeline()
        ClipSequence.freeze(&timeline, at: time(10), for: time(2.5))
        let data = try JSONEncoder().encode(timeline)
        let back = try JSONDecoder().decode(Timeline.self, from: data)
        #expect(back == timeline)
    }

    /// A clip written before clips could hold has none of the new keys, and is footage.
    @Test func aClipFromBeforeHoldsIsFootage() throws {
        let json = """
        {"id":"\(UUID().uuidString)","sourceStart":{"value":0,"timescale":600},
         "sourceDuration":{"value":6000,"timescale":600},"speed":1}
        """
        let clip = try JSONDecoder().decode(Clip.self, from: Data(json.utf8))
        #expect(clip.isFootage)
        #expect(clip.hold == nil && clip.title == nil && clip.transition == nil)
        #expect(clip.duration == time(10))
    }

    /// Footage is written exactly as it was before, so an older build reads a project with
    /// no stills in it as it always did.
    @Test func footageIsWrittenWithoutTheNewKeys() throws {
        let clip = Clip(sourceStart: .zero, sourceDuration: time(5))
        let json = try #require(String(data: try JSONEncoder().encode(clip), encoding: .utf8))
        #expect(!json.contains("hold"))
        #expect(!json.contains("title"))
        #expect(!json.contains("transition"))
    }

    /// A hold a file got wrong costs the hold, not the clip — and not the edit, which is
    /// what a clip failing to decode costs.
    @Test func aBrokenHoldCostsOnlyTheHold() throws {
        let json = """
        {"id":"\(UUID().uuidString)","sourceStart":{"value":0,"timescale":600},
         "sourceDuration":{"value":6000,"timescale":600},"speed":1,"hold":"forever"}
        """
        let clip = try JSONDecoder().decode(Clip.self, from: Data(json.utf8))
        #expect(clip.isFootage)
        #expect(clip.duration == time(10))
    }

    @Test func anAbsurdHoldIsHeldToSomethingDrawable() throws {
        let json = """
        {"id":"\(UUID().uuidString)","sourceStart":{"value":0,"timescale":600},
         "sourceDuration":{"value":0,"timescale":600},"speed":1,
         "hold":{"value":600000000,"timescale":600}}
        """
        let clip = try JSONDecoder().decode(Clip.self, from: Data(json.utf8))
        #expect(clip.duration == Clip.maximumHold)
    }
}
