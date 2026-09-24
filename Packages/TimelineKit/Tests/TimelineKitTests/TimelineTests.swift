import CoreMedia
import Foundation
import RecordKit
import Testing
@testable import TimelineKit

/// The clip arithmetic. Every case here is one a timeline gets wrong at least once.
struct TimelineTests {
    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    private func timeline(seconds: Double = 60) -> Timeline {
        Timeline(sourceDuration: time(seconds))
    }

    // MARK: - Shape

    @Test func afreshTimelineIsTheWholeRecording() {
        let timeline = timeline()
        #expect(timeline.clips.count == 1)
        #expect(timeline.duration == time(60))
        #expect(timeline.sourceTime(at: time(12)) == time(12))
    }

    @Test func aClipsPositionIsWhatCameBeforeIt() {
        var timeline = timeline()
        ClipSequence.split(&timeline, at: time(20))
        #expect(timeline.start(ofClipAt: 0) == .zero)
        #expect(timeline.start(ofClipAt: 1) == time(20))
    }

    // MARK: - Splitting

    @Test func aCutHasNoDuration() {
        var timeline = timeline()
        #expect(ClipSequence.split(&timeline, at: time(25)))
        #expect(timeline.clips.count == 2)
        #expect(timeline.duration == time(60), "a cut must not change how long the edit is")
        #expect(timeline.sourceTime(at: time(25)) == time(25))
    }

    @Test func splittingWhereTheresAlreadyACutDoesNothing() {
        var timeline = timeline()
        ClipSequence.split(&timeline, at: time(25))
        #expect(!ClipSequence.split(&timeline, at: time(25)))
        #expect(timeline.clips.count == 2)
    }

    @Test(arguments: [0.0, 60.0])
    func splittingAtTheEndsDoesNothing(_ seconds: Double) {
        var timeline = timeline()
        #expect(!ClipSequence.split(&timeline, at: time(seconds)))
    }

    // MARK: - Deleting

    @Test func deletingClosesTheGap() {
        var timeline = timeline()
        #expect(ClipSequence.delete(&timeline, range: CMTimeRange(start: time(10), end: time(20))))
        #expect(timeline.duration == time(50))
        // What was at 30 in the recording is now at 20 in the edit.
        #expect(timeline.sourceTime(at: time(20)) == time(30))
    }

    /// The in-point is the one thing that must never be re-derived from a new position.
    @Test func deletingDoesNotReDeriveWhereFootageStarts() {
        var timeline = timeline()
        ClipSequence.delete(&timeline, range: CMTimeRange(start: time(10), end: time(20)))
        #expect(timeline.clips.last?.sourceStart == time(20))
        #expect(timeline.sourceTime(at: .zero) == .zero)
    }

    @Test func deletingEverythingIsRefused() {
        var timeline = timeline()
        #expect(!ClipSequence.delete(&timeline, range: CMTimeRange(start: .zero, end: time(60))))
        #expect(timeline.duration == time(60))
    }

    @Test func aZoomInsideADeletedStretchGoesWithIt() {
        var timeline = timeline()
        timeline.zooms = [ZoomRegion(start: time(12), duration: time(4)),
                          ZoomRegion(start: time(30), duration: time(5))]
        ClipSequence.delete(&timeline, range: CMTimeRange(start: time(10), end: time(20)))

        #expect(timeline.zooms.count == 1)
        #expect(timeline.zooms[0].start == time(20), "the survivor moves back by what was removed")
    }

    // MARK: - Speed

    @Test func speedChangesHowLongTheEditRuns() {
        var timeline = timeline()
        #expect(ClipSequence.setSpeed(&timeline, range: CMTimeRange(start: time(10), end: time(20)), speed: 2))
        // Ten seconds of footage at 2× is five seconds of edit.
        #expect(abs(timeline.duration.seconds - 55) < 0.001)
    }

    @Test func speedIsClampedToWhatLooksLikeVideo() {
        let fast = Clip(sourceStart: .zero, sourceDuration: CMTime(seconds: 1, preferredTimescale: 600), speed: 100)
        let slow = Clip(sourceStart: .zero, sourceDuration: CMTime(seconds: 1, preferredTimescale: 600), speed: 0.001)
        #expect(fast.speed == Clip.maximumSpeed)
        #expect(slow.speed == Clip.minimumSpeed)
    }

    @Test func aSpedUpClipStillMapsBackToTheRightFootage() {
        var timeline = timeline()
        ClipSequence.setSpeed(&timeline, range: CMTimeRange(start: .zero, end: time(10)), speed: 2)
        // Two and a half seconds into a 2× clip is five seconds into the recording.
        #expect(timeline.sourceTime(at: time(2.5)) == time(5))
    }

    // MARK: - Reordering and trimming

    @Test func reorderingKeepsEveryFrameAndEveryInPoint() {
        var timeline = timeline()
        ClipSequence.split(&timeline, at: time(20))
        ClipSequence.split(&timeline, at: time(40))
        let sourceStarts = Set(timeline.clips.map(\.sourceStart))

        #expect(ClipSequence.move(&timeline, from: 2, to: 0))
        #expect(timeline.duration == time(60))
        #expect(Set(timeline.clips.map(\.sourceStart)) == sourceStarts)
        #expect(timeline.sourceTime(at: .zero) == time(40), "the clip that was last now plays first")
    }

    @Test func trimmingIsBoundedBySourceNotByNeighbours() {
        var timeline = timeline()
        ClipSequence.split(&timeline, at: time(30))
        let second = timeline.clips[1]
        #expect(ClipSequence.trim(&timeline, clipID: second.id, head: time(20), tail: nil))
        #expect(timeline.clips[1].sourceStart == time(20))
        #expect(timeline.duration == time(70), "revealing footage makes the edit longer")
    }

    @Test func aClipCannotBeTrimmedAway() {
        var timeline = timeline()
        let clip = timeline.clips[0]
        _ = ClipSequence.trim(&timeline, clipID: clip.id, head: time(59.99), tail: nil)
        #expect(timeline.clips[0].duration >= Clip.minimumDuration)
    }

    // MARK: - Regions

    @Test func regionsNeverOutliveTheTimeline() {
        var timeline = timeline()
        timeline.zooms = [ZoomRegion(start: time(50), duration: time(20))]
        ClipSequence.clampRegions(&timeline)
        #expect(timeline.zooms[0].end == time(60))
    }

    @Test func aZoomEasesInAndOutAndIsOneOutside() {
        let zoom = ZoomRegion(start: time(10), duration: time(6), scale: 2,
                              easing: .easeInOut, transition: time(1))
        #expect(zoom.scale(at: time(9)) == 1)
        #expect(zoom.scale(at: time(17)) == 1)
        #expect(zoom.scale(at: time(13)) == 2, "held at full scale in the middle")
        let rampingIn = zoom.scale(at: time(10.5))
        #expect(rampingIn > 1 && rampingIn < 2)
    }

    /// A one-second zoom must not spend two seconds arriving.
    @Test func aShortZoomShortensItsOwnTransition() {
        let zoom = ZoomRegion(start: .zero, duration: time(1), scale: 3, transition: time(5))
        #expect(zoom.scale(at: time(0.5)) == 3)
    }

    // MARK: - Snapping

    @Test func aDragSnapsInPointsNotSeconds() {
        let boundaries = [time(10)]
        // 100 points per second: a tenth of a second away is 10 points — outside an
        // 8-point tolerance.
        let tight = Snapping(pointsPerSecond: 100)
        #expect(tight.snap(time(10.1), to: boundaries) == time(10.1))

        // 10 points per second: the same tenth of a second is 1 point away.
        let wide = Snapping(pointsPerSecond: 10)
        #expect(wide.snap(time(10.1), to: boundaries) == time(10))
    }

    @Test func aRegionSnapsByWhicheverEdgeIsCloser() {
        let snapping = Snapping(pointsPerSecond: 50)
        let boundaries = [time(20)]
        // A five-second region dragged so its *end* is just past a cut.
        let start = snapping.snapRegion(start: time(15.05), duration: time(5), to: boundaries)
        #expect(start == time(15), "snapped by the end, keeping the length")
    }

    // MARK: - Undo

    @Test func undoAndRedoWalkTheEdits() {
        var stack = UndoStack()
        let first = timeline()
        var second = first
        ClipSequence.split(&second, at: time(10))

        stack.record(first, name: "Split")
        #expect(stack.canUndo)
        #expect(stack.undoName == "Split")

        let undone = stack.undo(current: second)
        #expect(undone?.timeline == first)
        #expect(stack.canRedo)

        let redone = stack.redo(current: first)
        #expect(redone?.timeline == second)
    }

    /// Editing after undoing abandons the branch that was undone.
    @Test func aNewEditDropsWhatWasUndone() {
        var stack = UndoStack()
        let original = timeline()
        stack.record(original, name: "First")
        _ = stack.undo(current: original)
        #expect(stack.canRedo)

        stack.record(original, name: "Second")
        #expect(!stack.canRedo)
    }

    @Test func theStackIsBounded() {
        var stack = UndoStack(limit: 3)
        for index in 0..<10 {
            stack.record(timeline(seconds: Double(index + 1)), name: "Edit \(index)")
        }
        var current = timeline()
        var count = 0
        while let entry = stack.undo(current: current) {
            current = entry.timeline
            count += 1
        }
        #expect(count == 3)
    }

    // MARK: - Commands

    @Test func aCommandThatChangesNothingIsNotAnEdit() {
        var timeline = timeline()
        #expect(!Commands.Split(at: .zero).apply(to: &timeline))
        #expect(Commands.Split(at: time(5)).apply(to: &timeline))
    }

    @Test func restylingIsOneUndoableStepWithAName() {
        var timeline = timeline()
        let command = Commands.Restyle("Padding") { $0.style.padding = 0.2 }
        #expect(command.apply(to: &timeline))
        #expect(timeline.style.padding == 0.2)
        #expect(!command.apply(to: &timeline), "setting it to what it already is is not an edit")
    }

    @Test func deletingARegionWorksWhateverKindItIs() {
        var timeline = timeline()
        let zoom = ZoomRegion(start: .zero, duration: time(2))
        let blur = BlurRegion(start: .zero, duration: time(2), rect: .zero)
        timeline.zooms = [zoom]
        timeline.blurs = [blur]

        #expect(Commands.DeleteRegion(id: blur.id).apply(to: &timeline))
        #expect(timeline.blurs.isEmpty)
        #expect(timeline.zooms.count == 1)
        #expect(!Commands.DeleteRegion(id: UUID()).apply(to: &timeline))
    }

    // MARK: - Camera

    /// A project from before the camera was adjustable frames exactly as it did.
    ///
    /// The defaults are the constants they replaced, so this is not just "it decodes" —
    /// it is "nothing anyone has already edited moves by a pixel".
    @Test func aProjectWithNoCameraSettingsGetsTheOldBehaviour() throws {
        var written = Timeline(sourceDuration: CMTime(seconds: 10, preferredTimescale: 600))
        written.camera = CameraStyle()
        let data = try JSONEncoder().encode(written)

        // Strip the key back out, the way a file written by the previous build has it.
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "camera")
        let older = try JSONSerialization.data(withJSONObject: object)

        let read = try JSONDecoder().decode(Timeline.self, from: older)
        #expect(read.camera == CameraStyle())
        #expect(read.camera.steadiness == 0.7)
        #expect(read.camera.follow == 1)
        #expect(read.camera.safeArea == 0.85)
    }

    @Test func cameraSettingsSurviveARoundTrip() throws {
        var written = Timeline(sourceDuration: CMTime(seconds: 10, preferredTimescale: 600))
        written.camera = CameraStyle(steadiness: 1.4, follow: 0.5, safeArea: 0.6)
        let read = try JSONDecoder().decode(Timeline.self, from: JSONEncoder().encode(written))
        #expect(read.camera == written.camera)
    }

    /// A project is a file, and a file can say anything.
    @Test func nonsenseCameraSettingsAreClampedRatherThanObeyed() {
        let absurd = CameraStyle(steadiness: -3, follow: 12, safeArea: 40).sanitised
        #expect(absurd.steadiness == 0)
        #expect(absurd.follow == 1)
        #expect(absurd.safeArea == 1)

        let tiny = CameraStyle(steadiness: 99, follow: -1, safeArea: 0).sanitised
        #expect(tiny.steadiness == 5)
        #expect(tiny.follow == 0)
        #expect(tiny.safeArea == 0.05, "a zero safe area would pin the camera to the pointer")
    }

}
