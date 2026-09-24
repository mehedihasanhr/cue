import CoreMedia
import Foundation
import Testing
@testable import TimelineKit

/// The sound lane, once it stops following the picture.
///
/// Two promises are worth more here than any individual edit. The first is that detaching
/// is *inaudible*: the lane it produces has to be the sound the clips were already laying
/// down, or nobody can afford to press the menu item in the middle of a cut. The second is
/// that an attached timeline is byte-for-byte what it was before this existed, on disk and
/// in the signature the preview watches — a project saved last week has to open and sound
/// identical. Most of what follows is one of those two.
struct DetachedSoundTests {
    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    private func timeline() -> Timeline { Timeline(sourceDuration: time(60)) }

    /// A cut-up, part-sped edit: the shape where a lazy detach would go wrong.
    private func edited() -> Timeline {
        var timeline = timeline()
        ClipSequence.split(&timeline, at: time(20))
        ClipSequence.split(&timeline, at: time(40))
        timeline.clips[1].speed = 2
        return timeline
    }

    // MARK: - Nothing changes until you ask it to

    @Test func aFreshTimelineHasNoSoundLaneOfItsOwn() {
        #expect(timeline().detachedSound == nil)
        #expect(!timeline().isSoundDetached)
    }

    @Test func detachingLaysTheSoundExactlyWhereTheClipsDid() {
        var timeline = edited()
        #expect(ClipSequence.detachSound(&timeline))
        let runs = try? #require(timeline.detachedSound)
        let runs2 = runs ?? []
        #expect(runs2.count == timeline.clips.count)

        var playhead = CMTime.zero
        for (run, clip) in zip(runs2, timeline.clips) {
            #expect(run.start == playhead)
            #expect(run.duration == clip.duration)
            #expect(run.sourceStart == clip.sourceStart)
            #expect(run.speed == clip.speed)
            // The source a run consumes is derived from its length and its speed, so it
            // has to come back out equal to the clip's — that is the arithmetic the
            // mixdown will use.
            #expect(abs((run.sourceDuration - clip.sourceDuration).seconds) < 1e-9)
            playhead = playhead + clip.duration
        }
        #expect(playhead == timeline.duration)
    }

    @Test func detachingTwiceDoesNothingTheSecondTime() {
        var timeline = edited()
        #expect(ClipSequence.detachSound(&timeline))
        let after = timeline
        #expect(!ClipSequence.detachSound(&timeline))
        #expect(timeline == after)
    }

    @Test func aFreshlyDetachedLaneIsInStepWithThePicture() {
        var timeline = edited()
        ClipSequence.detachSound(&timeline)
        #expect(timeline.detachedSoundIsInStepWithClips)
    }

    @Test func anAttachedLaneIsTriviallyInStep() {
        #expect(edited().detachedSoundIsInStepWithClips)
    }

    // MARK: - What the file says

    /// The promise that matters most: an attached project's JSON has to be what it always
    /// was, so a project written by this build opens in the one before it.
    @Test func anAttachedProjectWritesNoDetachmentKey() throws {
        let data = try JSONEncoder().encode(edited())
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["detachedSound"] == nil)
    }

    @Test func aProjectWithNoDetachmentKeyDecodesAsAttached() throws {
        var timeline = edited()
        ClipSequence.detachSound(&timeline)
        let data = try JSONEncoder().encode(timeline)
        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["detachedSound"] != nil, "the fixture, not the decoder")
        json.removeValue(forKey: "detachedSound")

        let older = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(Timeline.self, from: older)
        #expect(decoded.detachedSound == nil)
        #expect(!decoded.isSoundDetached)
    }

    @Test func aDetachedLaneSurvivesBeingWrittenAndReadBack() throws {
        var timeline = edited()
        ClipSequence.detachSound(&timeline)
        timeline.detachedSound?[0].start = time(3)
        let decoded = try JSONDecoder().decode(Timeline.self, from: JSONEncoder().encode(timeline))
        #expect(decoded == timeline)
    }

    /// A run written by a build that did not know about speed is a run at normal speed,
    /// for the reason every other decoder in the model is field by field.
    @Test func aRunWithNoSpeedDecodesAtNormalSpeed() throws {
        let run = SoundRun(start: time(1), duration: time(2), sourceStart: time(5), speed: 2)
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(run)) as? [String: Any])
        json.removeValue(forKey: "speed")
        let decoded = try JSONDecoder().decode(SoundRun.self,
                                               from: try JSONSerialization.data(withJSONObject: json))
        #expect(decoded.speed == 1)
        #expect(decoded.sourceStart == time(5))
    }

    // MARK: - The signature the preview watches

    /// Without this the preview goes on playing the edit from before the detach, which is
    /// the one failure a user would report as "the sound is wrong" and never find.
    @Test func detachingChangesTheSound() {
        var timeline = edited()
        let before = timeline.audioSignature
        ClipSequence.detachSound(&timeline)
        #expect(timeline.audioSignature != before)
    }

    @Test func movingARunChangesTheSound() {
        var timeline = edited()
        ClipSequence.detachSound(&timeline)
        let before = timeline.audioSignature
        timeline.detachedSound?[1].start = time(25)
        #expect(timeline.audioSignature != before)
    }

    @Test func reAttachingChangesTheSoundBack() {
        var timeline = edited()
        let attached = timeline.audioSignature
        ClipSequence.detachSound(&timeline)
        ClipSequence.attachSound(&timeline)
        #expect(timeline.audioSignature == attached)
    }

    /// The other half of the signature's job: a detached lane is not touched by the
    /// picture's look, exactly as an attached one is not.
    @Test func theLookOfTheFrameIsStillNotAudibleWhenDetached() {
        var timeline = edited()
        ClipSequence.detachSound(&timeline)
        let before = timeline.audioSignature
        timeline.style.padding = 120
        timeline.camera.follow = 0.3
        #expect(timeline.audioSignature == before)
    }

    // MARK: - Going back

    @Test func detachingAndReAttachingLeavesTheEditAsItWas() {
        let original = edited()
        var timeline = original
        #expect(ClipSequence.detachSound(&timeline))
        #expect(ClipSequence.attachSound(&timeline))
        #expect(timeline == original)
    }

    @Test func reAttachingAnAttachedLaneDoesNothing() {
        var timeline = edited()
        #expect(!ClipSequence.attachSound(&timeline))
    }

    @Test func anEditedLaneIsNoLongerInStepAndSaysSo() {
        var timeline = edited()
        ClipSequence.detachSound(&timeline)
        let was = timeline.detachedSound![1].start
        timeline.detachedSound?[1].start = was + time(0.5)
        #expect(!timeline.detachedSoundIsInStepWithClips)
    }

    @Test func aDeletedRunIsAnEditReAttachingWouldUndo() {
        var timeline = edited()
        ClipSequence.detachSound(&timeline)
        timeline.detachedSound?.removeLast()
        #expect(!timeline.detachedSoundIsInStepWithClips)
    }

    /// An empty lane is a real state — a detached lane whose runs have all gone is silence
    /// somebody chose — and must not read as "attached".
    @Test func aLaneWithNoRunsLeftIsStillDetached() {
        var timeline = edited()
        ClipSequence.detachSound(&timeline)
        timeline.detachedSound = []
        #expect(timeline.isSoundDetached)
        #expect(timeline.audioSignature.runs == [])
        #expect(timeline.audioSignature.cuts.isEmpty)
    }

    // MARK: - Editing the lane

    @Test func movingARunKeepsItsInPoint() {
        var timeline = edited()
        ClipSequence.detachSound(&timeline)
        let run = timeline.detachedSound![1]
        #expect(Commands.MoveSoundRun(id: run.id, start: time(25)).apply(to: &timeline))

        let moved = timeline.detachedSound![1]
        #expect(moved.start == time(25))
        #expect(moved.sourceStart == run.sourceStart, "sliding a run must not re-cut the take")
        #expect(moved.duration == run.duration)
    }

    /// The cough test. Trimming the front of a run has to leave the words that survive
    /// exactly where they were on the timeline, which means the in-point advances by as
    /// much *source* as the edge crossed — twice the timeline distance, at double speed.
    @Test func trimmingARunsHeadAdvancesItsInPointByTheSourceItCrossed() {
        var timeline = edited()
        ClipSequence.detachSound(&timeline)
        let run = timeline.detachedSound![1]
        #expect(run.speed == 2, "the fixture, not the command")

        let trimmed = run.start + time(1)
        #expect(Commands.MoveSoundRun(id: run.id,
                                      start: trimmed,
                                      duration: run.duration - time(1),
                                      trimsHead: true).apply(to: &timeline))

        let after = timeline.detachedSound![1]
        #expect(after.start == trimmed)
        #expect(abs((after.sourceStart - (run.sourceStart + time(2))).seconds) < 1e-6)
        // The far end has not moved: that is what "the words that survive stay where they
        // were" means, in both clocks at once.
        #expect(abs((after.end - run.end).seconds) < 1e-6)
        #expect(abs((after.sourceEnd - run.sourceEnd).seconds) < 1e-6)
    }

    @Test func trimmingARunsTailShortensTheSourceItConsumes() {
        var timeline = edited()
        ClipSequence.detachSound(&timeline)
        let run = timeline.detachedSound![0]
        #expect(Commands.MoveSoundRun(id: run.id,
                                      start: run.start,
                                      duration: run.duration - time(4)).apply(to: &timeline))

        let after = timeline.detachedSound![0]
        #expect(after.sourceStart == run.sourceStart)
        #expect(abs((after.sourceDuration - (run.sourceDuration - time(4))).seconds) < 1e-6)
    }

    /// Dragging a head trim back past the start of the recording cannot reveal sound that
    /// was never recorded, so the in-point stops at zero rather than going negative.
    @Test func aHeadTrimCannotReachBeforeTheRecordingBegan() {
        var timeline = timeline()
        ClipSequence.detachSound(&timeline)
        let run = timeline.detachedSound![0]
        #expect(run.sourceStart == .zero)
        _ = Commands.MoveSoundRun(id: run.id, start: .zero,
                                  duration: run.duration + time(5), trimsHead: true).apply(to: &timeline)
        #expect(timeline.detachedSound![0].sourceStart >= .zero)
    }

    @Test func aRunCanBeDeletedWithoutTouchingThePicture() {
        var timeline = edited()
        ClipSequence.detachSound(&timeline)
        let clips = timeline.clips
        let id = timeline.detachedSound![1].id
        #expect(Commands.DeleteRegion(id: id).apply(to: &timeline))
        #expect(timeline.detachedSound?.count == 2)
        #expect(timeline.clips == clips)
    }

    /// `MoveSoundRun` is the lane's own command, and `MoveRegion` must not reach it — the
    /// note on the command says why a head trim through `MoveRegion` would re-cut the take.
    @Test func theGenericMoveDoesNotReachIntoTheSoundLane() {
        var timeline = edited()
        ClipSequence.detachSound(&timeline)
        let runs = timeline.detachedSound!
        #expect(!Commands.MoveRegion(id: runs[0].id, start: time(5)).apply(to: &timeline))
        #expect(timeline.detachedSound == runs)
    }

    @Test func movingARunOnAnAttachedTimelineDoesNothing() {
        var timeline = edited()
        #expect(!Commands.MoveSoundRun(id: UUID(), start: time(1)).apply(to: &timeline))
    }

    // MARK: - Carried along by the edits above it

    /// A detached run is carried by the same region passes as an imported sound, and that
    /// is deliberate rather than accidental: ripple-deleting a stretch of picture with the
    /// audio left standing would desynchronise everything after it, which is not what
    /// anybody means by "detached".
    @Test func deletingAStretchOfPictureCarriesTheDetachedSoundWithIt() {
        var timeline = timeline()
        ClipSequence.detachSound(&timeline)
        // Two runs, so there is one to move and one to lose.
        ClipSequence.split(&timeline, at: time(30))
        timeline.detachedSound = [SoundRun(start: .zero, duration: time(10), sourceStart: .zero),
                                  SoundRun(start: time(20), duration: time(10), sourceStart: time(20)),
                                  SoundRun(start: time(40), duration: time(10), sourceStart: time(40))]

        #expect(ClipSequence.delete(&timeline, range: CMTimeRange(start: time(20), end: time(30))))
        let runs = timeline.detachedSound!
        #expect(runs.count == 2, "the run inside the deleted stretch went with it")
        #expect(runs[0].start == .zero)
        #expect(runs[1].start == time(30), "the run after it came back by the length removed")
    }

    @Test func aRunIsClampedToTheEditItBelongsTo() {
        var timeline = timeline()
        ClipSequence.detachSound(&timeline)
        timeline.detachedSound = [SoundRun(start: time(55), duration: time(20), sourceStart: .zero)]
        ClipSequence.clampRegions(&timeline)
        let run = timeline.detachedSound![0]
        #expect(run.end <= timeline.duration)
    }

    // MARK: - Snapping and selection

    @Test func aDetachedRunsEdgesAreSomethingToSnapTo() {
        var timeline = timeline()
        ClipSequence.detachSound(&timeline)
        timeline.detachedSound = [SoundRun(start: time(12), duration: time(4), sourceStart: .zero)]
        #expect(timeline.boundaries.contains(time(12)))
        #expect(timeline.boundaries.contains(time(16)))
    }

    /// An attached lane must not add its edges twice: the cuts are already in there from
    /// the clips, and a duplicate is work the snapping does for nothing.
    @Test func anAttachedLaneAddsNoBoundariesOfItsOwn() {
        var timeline = edited()
        let before = timeline.boundaries.sorted()
        ClipSequence.detachSound(&timeline)
        // Detaching adds one edge per run, all of which coincide with a cut or an end.
        #expect(Set(timeline.boundaries) == Set(before))
    }

    @Test func aSelectedRunStopsBeingValidWhenTheLaneIsReAttached() {
        var timeline = edited()
        ClipSequence.detachSound(&timeline)
        let selection = Selection.soundRun(timeline.detachedSound![0].id)
        #expect(selection.isValid(in: timeline))
        #expect(selection.range(in: timeline) != nil)
        ClipSequence.attachSound(&timeline)
        #expect(!selection.isValid(in: timeline))
    }

    /// A run of the recording is footage, not a region: copying one would mean a second
    /// copy of the take playing over itself, which is a feature rather than a paste.
    @Test func aRunIsNotSomethingToCopy() {
        var timeline = edited()
        ClipSequence.detachSound(&timeline)
        #expect(CopiedRegion(.soundRun(timeline.detachedSound![0].id), in: timeline) == nil)
    }
}
