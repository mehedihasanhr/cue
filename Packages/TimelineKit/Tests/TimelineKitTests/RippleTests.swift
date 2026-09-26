import CoreGraphics
import CoreMedia
import Foundation
import Testing
@testable import TimelineKit

/// Copying footage, pasting it, and the ripple arithmetic underneath both.
///
/// The feature is almost entirely arithmetic, so these are the deliverable as much as the
/// code is. Two of them are the judgement calls written up in `CopiedFootage` and in
/// `ClipSequence.rippled(_:at:by:)` — what travels with the footage, and what an insertion
/// does to a detached sound lane — pinned here so a later change to either has to argue
/// with a test rather than merely compile.
struct RippleTests {
    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    private func timeline(seconds: Double = 60) -> Timeline {
        Timeline(sourceDuration: time(seconds))
    }

    private let rect = CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.3)

    /// A 10-second stretch lifted off the front of a fresh 60-second take.
    private func tenSeconds(from source: Timeline? = nil) throws -> CopiedFootage {
        let source = source ?? timeline()
        return try #require(CopiedFootage(CMTimeRange(start: .zero, duration: time(10)), in: source))
    }

    // MARK: - Lifting footage off the timeline

    @Test func aSelectedClipIsCopyableNow() throws {
        var timeline = timeline()
        ClipSequence.split(&timeline, at: time(20))
        ClipSequence.split(&timeline, at: time(40))
        let footage = try #require(CopiedFootage(.clip(timeline.clips[1].id), in: timeline))
        #expect(footage.clips.count == 1)
        #expect(footage.duration == time(20))
        #expect(footage.clips[0].sourceStart == time(20))
    }

    @Test func aSelectedRangeIsCopyableNow() throws {
        let timeline = timeline()
        let footage = try #require(CopiedFootage(.range(CMTimeRange(start: time(10), duration: time(15))),
                                                in: timeline))
        #expect(footage.duration == time(15))
        #expect(footage.clips[0].sourceStart == time(10))
    }

    /// Copying must not be an edit. The cuts a copy makes are made on a throwaway value.
    @Test func copyingDoesNotChangeTheTimelineItCopiesFrom() throws {
        let timeline = timeline()
        let before = timeline
        _ = try #require(CopiedFootage(CMTimeRange(start: time(10), duration: time(15)), in: timeline))
        #expect(timeline == before)
    }

    /// Several clips at once, and their own cuts come along — a copied stretch that had a
    /// cut in it is not the same footage as one that did not.
    @Test func copyingARangeWithCutsInItKeepsThem() throws {
        var timeline = timeline()
        ClipSequence.split(&timeline, at: time(15))
        let footage = try #require(CopiedFootage(CMTimeRange(start: time(10), duration: time(10)),
                                                in: timeline))
        #expect(footage.clips.count == 2)
        #expect(footage.duration == time(10))
    }

    @Test func everythingCopyableByTheOtherHalfOfTheClipboardIsRefusedHere() {
        var timeline = timeline()
        let zoom = ZoomRegion(start: time(4), duration: time(3))
        timeline.zooms = [zoom]
        #expect(CopiedFootage(.zoom(zoom.id), in: timeline) == nil)
        #expect(CopiedFootage(.none, in: timeline) == nil)
        #expect(CopiedFootage(.headTrim, in: timeline) == nil)
        #expect(CopiedFootage(.sound, in: timeline) == nil)
    }

    @Test func aStretchTooShortToBeAClipIsNotFootage() {
        let timeline = timeline()
        #expect(CopiedFootage(CMTimeRange(start: time(10), duration: time(0.05)), in: timeline) == nil)
        #expect(CopiedFootage(CMTimeRange(start: time(10), duration: .zero), in: timeline) == nil)
    }

    // MARK: - What travels with the footage

    /// The judgement call, in the affirmative: a zoom placed over the copied frames is part
    /// of what was copied, because it is a statement about those frames.
    @Test func aZoomWhollyOverTheCopiedStretchTravels() throws {
        var timeline = timeline()
        timeline.zooms = [ZoomRegion(start: time(12), duration: time(4), scale: 2.75)]
        let footage = try #require(CopiedFootage(CMTimeRange(start: time(10), duration: time(10)),
                                                in: timeline))
        #expect(footage.zooms.count == 1)
        // Rebased to the start of the copy, which is the whole reason the payload's times
        // are relative: the copy is going to land somewhere else.
        #expect(footage.zooms[0].start == time(2))
        #expect(footage.zooms[0].duration == time(4))
        #expect(footage.zooms[0].scale == 2.75)
    }

    /// The same call in the negative, and the more interesting half. Neither clipping the
    /// zoom nor taking it whole is honest, so it stays where the user put it.
    @Test(arguments: [8.0, 18.0])
    func aZoomStraddlingAnEdgeOfTheCopiedStretchStaysBehind(_ start: Double) throws {
        var timeline = timeline()
        timeline.zooms = [ZoomRegion(start: time(start), duration: time(4))]
        let footage = try #require(CopiedFootage(CMTimeRange(start: time(10), duration: time(10)),
                                                in: timeline))
        #expect(footage.zooms.isEmpty)
        #expect(timeline.zooms.count == 1, "and it is still on the timeline it was copied from")
    }

    /// A caption travels on exactly the same rule as a zoom, which is the answer to the
    /// question the feature's brief asks: one rule across six lanes rather than a lane the
    /// user has to learn a special case for.
    @Test func aCaptionTravelsOnTheSameRuleAsAZoom() throws {
        var timeline = timeline()
        timeline.captions = [CaptionCue(start: time(11), duration: time(3), text: "inside"),
                             CaptionCue(start: time(19), duration: time(3), text: "straddling"),
                             CaptionCue(start: time(40), duration: time(3), text: "elsewhere")]
        let footage = try #require(CopiedFootage(CMTimeRange(start: time(10), duration: time(10)),
                                                in: timeline))
        #expect(footage.captions.map(\.text) == ["inside"])
    }

    @Test func everyLaneTravelsOnTheSameRule() throws {
        var timeline = timeline()
        let inside = CMTimeRange(start: time(12), duration: time(2))
        timeline.zooms = [ZoomRegion(start: inside.start, duration: inside.duration)]
        timeline.blurs = [BlurRegion(start: inside.start, duration: inside.duration,
                                     rect: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3))]
        timeline.annotations = [AnnotationItem(start: inside.start, duration: inside.duration,
                                              kind: .text("hello"), rect: rect)]
        timeline.captions = [CaptionCue(start: inside.start, duration: inside.duration, text: "hi")]
        timeline.audio = [AudioRegion(start: inside.start, duration: inside.duration, path: "a.m4a")]
        timeline.cursorRegions = [CursorRegion(start: inside.start, duration: inside.duration,
                                              isHidden: true)]
        let footage = try #require(CopiedFootage(CMTimeRange(start: time(10), duration: time(10)),
                                                in: timeline))
        #expect(footage.carried == 6)
        #expect(footage.zooms.count == 1)
        #expect(footage.blurs.count == 1)
        #expect(footage.annotations.count == 1)
        #expect(footage.captions.count == 1)
        #expect(footage.audio.count == 1)
        #expect(footage.cursorRegions.count == 1)
    }

    /// A sound whose file this project has not got costs that sound and not the paste.
    @Test func aSoundThisProjectCannotFindIsDroppedRatherThanRefused() throws {
        var timeline = timeline()
        timeline.audio = [AudioRegion(start: time(12), duration: time(2), path: "elsewhere.m4a"),
                          AudioRegion(start: time(15), duration: time(2), path: "here.m4a")]
        let footage = try #require(CopiedFootage(CMTimeRange(start: time(10), duration: time(10)),
                                                in: timeline))
        let settled = footage.withoutSounds { $0 == "elsewhere.m4a" }
        #expect(settled.audio.map(\.path) == ["here.m4a"])
        #expect(settled.clips == footage.clips, "the picture is what the user asked for")
    }

    // MARK: - Inserting time

    @Test func pastingMakesTheTimelineLongerByExactlyTheFootagesLength() throws {
        var timeline = timeline()
        let footage = try tenSeconds()
        #expect(ClipSequence.insert(&timeline, footage.freshened(), at: time(20)))
        #expect(timeline.duration == time(70))
    }

    @Test func everyRegionAfterTheInsertionPointMovesByTheInsertedLength() throws {
        var timeline = timeline()
        timeline.zooms = [ZoomRegion(start: time(30), duration: time(5))]
        timeline.blurs = [BlurRegion(start: time(45), duration: time(5),
                                     rect: CGRect(x: 0, y: 0, width: 0.5, height: 0.5))]
        timeline.captions = [CaptionCue(start: time(20), duration: time(2), text: "on the seam")]
        timeline.cursorRegions = [CursorRegion(start: time(50), duration: time(4), isHidden: true)]
        let footage = try tenSeconds()

        #expect(ClipSequence.insert(&timeline, footage.freshened(), at: time(20)))
        #expect(timeline.zooms[0].start == time(40))
        #expect(timeline.blurs[0].start == time(55))
        #expect(timeline.cursorRegions[0].start == time(60))
        // Starting exactly *at* the insertion point counts as after it: the footage that
        // region was placed against now begins ten seconds later, and so must it.
        #expect(timeline.captions.first { $0.text == "on the seam" }?.start == time(30))
    }

    @Test func aRegionBeforeTheInsertionPointDoesNotMove() throws {
        var timeline = timeline()
        let zoom = ZoomRegion(start: time(5), duration: time(4))
        timeline.zooms = [zoom]
        let footage = try tenSeconds()
        #expect(ClipSequence.insert(&timeline, footage.freshened(), at: time(20)))
        #expect(timeline.zooms.first { $0.id == zoom.id }?.start == time(5))
        #expect(timeline.zooms.first { $0.id == zoom.id }?.duration == time(4))
    }

    /// The documented answer for a region spanning the insertion point: its start is a
    /// moment the user chose, so the inserted length goes into its *length*.
    @Test func aRegionSpanningTheInsertionPointIsStretchedOverIt() throws {
        var timeline = timeline()
        let blur = BlurRegion(start: time(18), duration: time(6),
                              rect: CGRect(x: 0.2, y: 0.2, width: 0.2, height: 0.2))
        timeline.blurs = [blur]
        let footage = try tenSeconds()
        #expect(ClipSequence.insert(&timeline, footage.freshened(), at: time(20)))
        let after = try #require(timeline.blurs.first { $0.id == blur.id })
        #expect(after.start == time(18), "it must not slide off the thing it covers")
        #expect(after.duration == time(16), "and it must not stop applying early")
    }

    @Test func theRegionsThatTravelledLandRelativeToTheInsertionPoint() throws {
        var source = timeline()
        source.zooms = [ZoomRegion(start: time(2), duration: time(3), scale: 3)]
        source.captions = [CaptionCue(start: time(1), duration: time(2), text: "travelled")]
        let footage = try tenSeconds(from: source)

        var timeline = timeline()
        #expect(ClipSequence.insert(&timeline, footage.freshened(), at: time(20)))
        #expect(timeline.zooms.map(\.start) == [time(22)])
        #expect(timeline.captions.first { $0.text == "travelled" }?.start == time(21))
    }

    // MARK: - The ends of the edit

    @Test func pastingAtTheVeryStartPutsTheFootageFirst() throws {
        var timeline = timeline()
        timeline.zooms = [ZoomRegion(start: time(5), duration: time(3))]
        let original = timeline.clips[0].id
        let footage = try tenSeconds()
        #expect(ClipSequence.insert(&timeline, footage.freshened(), at: .zero))
        #expect(timeline.duration == time(70))
        #expect(timeline.clips.count == 2)
        #expect(timeline.clips[1].id == original, "the take it was pasted in front of")
        #expect(timeline.zooms[0].start == time(15), "and everything moved, because everything is after")
    }

    @Test func pastingAtTheVeryEndPutsTheFootageLast() throws {
        var timeline = timeline()
        let original = timeline.clips[0].id
        let footage = try tenSeconds()
        #expect(ClipSequence.insert(&timeline, footage.freshened(), at: timeline.duration))
        #expect(timeline.duration == time(70))
        #expect(timeline.clips.count == 2)
        #expect(timeline.clips[0].id == original)
        #expect(timeline.sourceTime(at: time(65)) == time(5), "the last five seconds are the copy's")
    }

    @Test func pastingPastTheEndIsPastingAtTheEnd() throws {
        var timeline = timeline()
        let footage = try tenSeconds()
        #expect(ClipSequence.insert(&timeline, footage.freshened(), at: time(900)))
        #expect(timeline.duration == time(70))
        #expect(timeline.clips.count == 2)
    }

    // MARK: - The invariants that must survive it

    @Test func theSequenceStaysContiguousAndTheDurationStaysDerived() throws {
        var timeline = timeline()
        ClipSequence.split(&timeline, at: time(25))
        let footage = try #require(CopiedFootage(CMTimeRange(start: time(20), duration: time(10)),
                                                in: timeline))
        #expect(ClipSequence.insert(&timeline, footage.freshened(), at: time(25)))

        #expect(timeline.duration == timeline.clips.reduce(CMTime.zero) { $0 + $1.duration })
        #expect(timeline.clips.allSatisfy { $0.duration >= Clip.minimumDuration })
        // Contiguity, read the way the model defines it: a clip's position is the lengths
        // before it, so the starts must march forward and the last one must close the edit.
        var previous = CMTime.zero
        for index in timeline.clips.indices {
            let start = timeline.start(ofClipAt: index)
            #expect(start >= previous)
            previous = start
        }
        #expect(previous + (timeline.clips.last?.duration ?? .zero) == timeline.duration)
        // And every moment of it maps into the recording — a gap would have no frame.
        for second in stride(from: 0.0, to: timeline.duration.seconds, by: 2.5) {
            #expect(timeline.sourceTime(at: time(second)) != nil)
        }
    }

    @Test func pastedFootagePlaysTheFramesItWasCopiedFrom() throws {
        var timeline = timeline()
        let footage = try #require(CopiedFootage(CMTimeRange(start: time(40), duration: time(10)),
                                                in: timeline))
        #expect(ClipSequence.insert(&timeline, footage.freshened(), at: time(20)))
        #expect(timeline.sourceTime(at: time(20)) == time(40))
        #expect(timeline.sourceTime(at: time(25)) == time(45))
        #expect(timeline.sourceTime(at: time(31)) == time(21), "and the take resumes where it left off")
    }

    @Test func pastedFootageGetsNewIdentitiesEveryTime() throws {
        var timeline = timeline()
        timeline.zooms = [ZoomRegion(start: time(2), duration: time(3))]
        let footage = try tenSeconds(from: timeline)

        var once = timeline
        #expect(ClipSequence.insert(&once, footage.freshened(), at: time(30)))
        var twice = once
        #expect(ClipSequence.insert(&twice, footage.freshened(), at: time(50)))

        #expect(Set(twice.clips.map(\.id)).count == twice.clips.count)
        #expect(Set(twice.zooms.map(\.id)).count == twice.zooms.count)
        #expect(twice.zooms.count == 3, "the original and one per paste")
    }

    /// A copy arrives unlocked and without a seam ramp, exactly as a region paste does.
    @Test func aTravellingZoomArrivesUnlockedAndWithoutASeamRamp() throws {
        var source = timeline()
        var zoom = ZoomRegion(start: time(2), duration: time(3))
        zoom.isLocked = true
        zoom.transitionIn = time(0.01)
        source.zooms = [zoom]
        let footage = try tenSeconds(from: source).freshened()
        #expect(footage.zooms[0].isLocked == false)
        #expect(footage.zooms[0].transitionIn == nil)
    }

    @Test func footageNamingSourceThisRecordingHasNotGotIsRefused() throws {
        let long = timeline(seconds: 120)
        let footage = try #require(CopiedFootage(CMTimeRange(start: time(100), duration: time(10)),
                                                in: long))
        var short = timeline(seconds: 60)
        let before = short
        #expect(!ClipSequence.insert(&short, footage.freshened(), at: time(20)))
        #expect(short == before, "a refused paste is not an edit")
    }

    @Test func emptyFootageIsRefused() {
        var timeline = timeline()
        let footage = CopiedFootage(clips: [], sourceDuration: time(60))
        #expect(!ClipSequence.insert(&timeline, footage, at: time(20)))
    }

    // MARK: - Delete as the inverse

    /// The property the whole feature rests on, at the case where it can be exact: a paste
    /// onto an existing cut, and a ripple delete of the stretch it created.
    @Test func insertingThenDeletingTheSameStretchReturnsTheTimeline() throws {
        var timeline = timeline()
        ClipSequence.split(&timeline, at: time(20))
        // In start order, because a sorted zoom lane is an invariant rather than a
        // convention — seeding an unsorted one would make this test fail for a reason that
        // has nothing to do with the ripple.
        timeline.zooms = [ZoomRegion(start: time(18), duration: time(6)),
                          ZoomRegion(start: time(30), duration: time(4))]
        timeline.captions = [CaptionCue(start: time(5), duration: time(2), text: "before")]
        let before = timeline

        let footage = try #require(CopiedFootage(CMTimeRange(start: .zero, duration: time(10)),
                                                in: timeline))
        #expect(ClipSequence.insert(&timeline, footage.freshened(), at: time(20)))
        #expect(timeline != before)
        #expect(ClipSequence.delete(&timeline, range: CMTimeRange(start: time(20), duration: time(10))))
        #expect(timeline == before)
    }

    /// The same at the front and the back of the edit, where there is no cut to make at all.
    @Test(arguments: [0.0, 60.0])
    func insertingAtAnEndAndDeletingItAgainReturnsTheTimeline(_ at: Double) throws {
        var timeline = timeline()
        timeline.zooms = [ZoomRegion(start: time(30), duration: time(4))]
        let before = timeline
        let footage = try tenSeconds()
        #expect(ClipSequence.insert(&timeline, footage.freshened(), at: time(at)))
        #expect(ClipSequence.delete(&timeline, range: CMTimeRange(start: time(at), duration: time(10))))
        #expect(timeline == before)
    }

    /// Where the paste had to open a new cut, everything comes back except the cut — which
    /// is what `ClipSequence.delete`'s note says, and worth a test so the exception stays a
    /// known one rather than a surprise.
    @Test func insertingMidClipLeavesOnlyTheCutBehindAfterDeleting() throws {
        var timeline = timeline()
        timeline.zooms = [ZoomRegion(start: time(30), duration: time(4))]
        let before = timeline
        let footage = try tenSeconds()

        #expect(ClipSequence.insert(&timeline, footage.freshened(), at: time(20)))
        #expect(ClipSequence.delete(&timeline, range: CMTimeRange(start: time(20), duration: time(10))))

        #expect(timeline.duration == before.duration)
        #expect(timeline.zooms == before.zooms)
        #expect(timeline.clips.count == 2, "the clip the paste split stays split")
        #expect(timeline.sourceTime(at: time(30)) == before.sourceTime(at: time(30)))
    }

    // MARK: - An attached sound lane

    /// Nothing to do, and that is the finding rather than an omission: where the sound
    /// follows the picture, inserting clips inserts their sound.
    @Test func pastingIntoAnAttachedTimelineDoesNotCreateASoundLane() throws {
        var timeline = timeline()
        let footage = try tenSeconds()
        #expect(ClipSequence.insert(&timeline, footage.freshened(), at: time(20)))
        #expect(timeline.detachedSound == nil)
        #expect(timeline.isSoundDetached == false)
    }

    /// The preview rebuilds its composition from this and nothing else, so a change to the
    /// footage that it cannot see is a preview that goes on playing the old edit.
    @Test func audioSignatureChangesWhenFootageIsPasted() throws {
        var timeline = timeline()
        let before = timeline.audioSignature
        let footage = try tenSeconds()
        #expect(ClipSequence.insert(&timeline, footage.freshened(), at: time(20)))
        #expect(timeline.audioSignature != before)
    }

    // MARK: - A detached sound lane

    /// The second judgement call: a detached lane is an independent edit, and it still
    /// ripples, because time inserted into the picture is time the sound has to make room
    /// for. The disagreements the user authored survive — each run keeps its offset.
    @Test func aDetachedSoundLaneRipplesWithThePicture() throws {
        var timeline = timeline()
        ClipSequence.split(&timeline, at: time(20))
        #expect(ClipSequence.detachSound(&timeline))
        let footage = try tenSeconds(from: timeline)

        #expect(ClipSequence.insert(&timeline, footage.freshened(), at: time(20)))
        let runs = try #require(timeline.detachedSound)
        #expect(runs.map(\.start) == [.zero, time(20), time(30)])
        // The run that was after the seam kept its own in-point, so the words it carries
        // still land on the picture they were detached from.
        #expect(runs[2].sourceStart == time(20))
        #expect(runs[2].duration == time(40))
    }

    /// The inserted footage is audible rather than silent, which is the whole reason a copy
    /// carries `soundRuns` even when the lane it came from was attached.
    @Test func theInsertedFootageBringsItsOwnSoundToADetachedLane() throws {
        var timeline = timeline()
        ClipSequence.split(&timeline, at: time(20))
        #expect(ClipSequence.detachSound(&timeline))
        // Copied from a take whose sound followed its picture, so these runs were derived
        // rather than authored — and they are still the right sound for these frames.
        let footage = try #require(CopiedFootage(CMTimeRange(start: time(40), duration: time(10)),
                                                in: self.timeline()))
        #expect(footage.soundRuns.count == 1)
        #expect(footage.soundRuns[0].sourceStart == time(40))

        #expect(ClipSequence.insert(&timeline, footage.freshened(), at: time(20)))
        let runs = try #require(timeline.detachedSound)
        let arrived = try #require(runs.first { $0.start == time(20) })
        #expect(arrived.sourceStart == time(40))
        #expect(arrived.duration == time(10))
        // And the lane still covers the whole edit, with nothing overlapping.
        #expect(runs.map(\.duration).reduce(CMTime.zero, +) == timeline.duration)
    }

    /// The one place the sound lane parts company with the other six: stretching a run would
    /// make it play words that were never there.
    @Test func aSoundRunSpanningTheInsertionPointIsCutInTwo() throws {
        var timeline = timeline()
        #expect(ClipSequence.detachSound(&timeline))
        #expect(timeline.detachedSound?.count == 1)
        let footage = try tenSeconds(from: self.timeline())

        #expect(ClipSequence.insert(&timeline, footage.freshened(), at: time(20)))
        let runs = try #require(timeline.detachedSound)
        #expect(runs.count == 3, "the two halves of the split run, and the footage's own")
        #expect(runs[0].start == .zero)
        #expect(runs[0].duration == time(20))
        #expect(runs[0].sourceStart == .zero)
        #expect(runs[2].start == time(30))
        #expect(runs[2].duration == time(40))
        // The heart of it: the back half's in-point advanced by exactly the source the front
        // half consumes, so the word that played at 20s still plays over the same frame.
        #expect(runs[2].sourceStart == time(20))
    }

    /// The same cut, at a speed, where a stretched run would have been audibly wrong.
    @Test func cuttingASpannedRunRespectsItsSpeed() {
        let run = SoundRun(start: .zero, duration: time(20), sourceStart: time(5), speed: 2)
        let rippled = ClipSequence.rippled([run], at: time(8), by: time(10))
        #expect(rippled.count == 2)
        #expect(rippled[0].duration == time(8))
        // Eight timeline seconds at 2× consume sixteen source seconds.
        #expect(rippled[1].sourceStart == time(21))
        #expect(rippled[1].start == time(18))
        #expect(rippled[1].duration == time(12))
    }

    /// A half too short to grab is a half the user has lost, so the run is left whole and
    /// treated as beginning or ending at the seam.
    @Test func aRunTooShortToHalveIsMovedOrLeftRatherThanSlivered() {
        let run = SoundRun(start: time(10), duration: time(20), sourceStart: .zero)
        // The seam lands a hundredth of a second into it: it may as well begin there.
        let early = ClipSequence.rippled([run], at: time(10.01), by: time(5))
        #expect(early.count == 1)
        #expect(early[0].start == time(15))
        // And a hundredth before its end: it may as well end there.
        let late = ClipSequence.rippled([run], at: time(29.99), by: time(5))
        #expect(late.count == 1)
        #expect(late[0].start == time(10))
        #expect(late[0].duration == time(20))
    }

    @Test func copyingFromADetachedLaneClipsTheRunsToTheStretch() throws {
        var timeline = timeline()
        #expect(ClipSequence.detachSound(&timeline))
        let footage = try #require(CopiedFootage(CMTimeRange(start: time(15), duration: time(10)),
                                                in: timeline))
        #expect(footage.soundRuns.count == 1)
        #expect(footage.soundRuns[0].start == .zero)
        #expect(footage.soundRuns[0].duration == time(10))
        #expect(footage.soundRuns[0].sourceStart == time(15),
                "clipping a run plays exactly the sound that was over the copied frames")
    }

    @Test func audioSignatureChangesWhenFootageIsPastedIntoADetachedLane() throws {
        var timeline = timeline()
        #expect(ClipSequence.detachSound(&timeline))
        let before = timeline.audioSignature
        let footage = try tenSeconds(from: self.timeline())
        #expect(ClipSequence.insert(&timeline, footage.freshened(), at: time(20)))
        #expect(timeline.audioSignature != before)
        #expect(timeline.audioSignature.runs != nil, "and it is still a detached lane")
    }

    @Test func aDetachedLaneStaysDetachedAndAnAttachedOneStaysAttached() throws {
        let footage = try tenSeconds()
        var attached = timeline()
        #expect(ClipSequence.insert(&attached, footage.freshened(), at: time(20)))
        #expect(attached.detachedSound == nil)

        var detached = timeline()
        #expect(ClipSequence.detachSound(&detached))
        #expect(ClipSequence.insert(&detached, footage.freshened(), at: time(20)))
        #expect(detached.detachedSound != nil)
    }

    // MARK: - One undo step

    /// However many clips and regions came along, a paste is one thing the user did.
    @Test func aPasteIsOneUndoStep() throws {
        var source = timeline()
        source.zooms = [ZoomRegion(start: time(1), duration: time(2)),
                        ZoomRegion(start: time(4), duration: time(2))]
        source.captions = [CaptionCue(start: time(3), duration: time(1), text: "a")]
        let footage = try tenSeconds(from: source).freshened()

        var timeline = timeline()
        let before = timeline
        var undo = UndoStack()
        let command = Commands.InsertFootage(footage, at: time(20), name: "Paste Footage")
        undo.record(timeline, name: command.name)
        #expect(command.apply(to: &timeline))
        #expect(timeline.clips.count == 3, "the split halves, and the footage between them")
        #expect(timeline.zooms.count == 2)
        #expect(timeline.captions.count == 1)

        // Taken out before `#require` sees it: the macro wraps the expression in a closure
        // that cannot call a mutating method on `undo`.
        let undone = undo.undo(current: timeline)
        let entry = try #require(undone)
        #expect(entry.name == "Paste Footage")
        #expect(entry.timeline == before)
        #expect(!undo.canUndo, "one step, not one per clip and region")
    }

    @Test func aRefusedPasteIsNotAnUndoStep() throws {
        let footage = try #require(CopiedFootage(CMTimeRange(start: time(100), duration: time(10)),
                                                in: timeline(seconds: 120)))
        var timeline = timeline(seconds: 60)
        #expect(!Commands.InsertFootage(footage, at: time(20), name: "Paste Footage").apply(to: &timeline))
    }

    // MARK: - Crossing the pasteboard

    @Test func footageSurvivesTheTripThroughTheClipboard() throws {
        var source = timeline()
        source.zooms = [ZoomRegion(start: time(2), duration: time(3), scale: 2.5)]
        source.captions = [CaptionCue(start: time(1), duration: time(2), text: "words")]
        source.cursorRegions = [CursorRegion(start: time(4), duration: time(2), isHidden: true)]
        let footage = try tenSeconds(from: source)

        let data = try #require(footage.encoded())
        let read = try #require(CopiedFootage.decoded(from: data))
        #expect(read == footage)
    }

    /// The two payloads share a pasteboard, so each has to refuse the other's bytes rather
    /// than decode them into something empty.
    @Test func theTwoHalvesOfTheClipboardRefuseEachOthersBytes() throws {
        let footage = try tenSeconds()
        let region = CopiedRegion.zoom(ZoomRegion(start: time(2), duration: time(3)))
        let footageBytes = try #require(footage.encoded())
        let regionBytes = try #require(region.encoded())
        #expect(CopiedRegion.decoded(from: footageBytes) == nil)
        #expect(CopiedFootage.decoded(from: regionBytes) == nil)
    }

    @Test func rubbishOnTheClipboardIsNotFootage() {
        #expect(CopiedFootage.decoded(from: Data()) == nil)
        #expect(CopiedFootage.decoded(from: Data("not json at all".utf8)) == nil)
        #expect(CopiedFootage.decoded(from: Data(#"{"kind":"footage"}"#.utf8)) == nil)
        #expect(CopiedFootage.decoded(from: Data(#"{"kind":"footage","clips":[]}"#.utf8)) == nil)
    }

    /// A lane a newer build wrote should cost the user that lane, not the paste.
    @Test func footageWithOneUnreadableLaneStillPastes() throws {
        let footage = try tenSeconds()
        let encoded = try #require(footage.encoded())
        var object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["zooms"] = "not an array of zooms"
        let data = try JSONSerialization.data(withJSONObject: object)
        let read = try #require(CopiedFootage.decoded(from: data))
        #expect(read.clips == footage.clips)
        #expect(read.zooms.isEmpty)
    }
}
