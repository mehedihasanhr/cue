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

    // MARK: - The pointer over time

    @Test func aProjectWithNoCursorRegionsAsksNothingOfThePointer() {
        let timeline = timeline()
        #expect(timeline.cursorRegions.isEmpty)
        #expect(timeline.cursorOverride(at: time(10)) == .none)
        #expect(timeline.cursorOverride(at: time(10)).isNothing)
    }

    /// The backward-compatibility promise, at the level it actually lives at.
    ///
    /// A project written before cursor regions existed has no `cursorRegions` key at all,
    /// and one written before a *field* existed has the region but not the field. Both have
    /// to read as today's behaviour: no regions, and a region that hides the pointer and
    /// does nothing else — which is what the menu item makes.
    @Test func aCursorRegionDecodesAnAbsentFieldAsTodaysBehaviour() throws {
        let decoder = JSONDecoder()

        let withoutTheLane = """
        {"sourceDuration": {"value": 6000, "timescale": 600, "flags": 1, "epoch": 0}}
        """
        let bare = try decoder.decode(Timeline.self, from: Data(withoutTheLane.utf8))
        #expect(bare.cursorRegions.isEmpty)
        #expect(bare.cursorOverride(at: time(1)) == .none)

        let withoutTheFields = """
        {"id": "\(UUID().uuidString)",
         "start": {"value": 600, "timescale": 600, "flags": 1, "epoch": 0},
         "duration": {"value": 1200, "timescale": 600, "flags": 1, "epoch": 0}}
        """
        let region = try decoder.decode(CursorRegion.self, from: Data(withoutTheFields.utf8))
        #expect(region.isHidden)
        #expect(region.smoothing == 0)
        #expect(region.isHeld == false)
        #expect(region.start == time(1))
        #expect(region.duration == time(2))
        #expect(region == CursorRegion(id: region.id, start: time(1), duration: time(2)),
                "the absent fields are exactly the ones the initialiser defaults to")
    }

    @Test func aCursorRegionRoundTripsThroughAFile() throws {
        var written = timeline()
        written.cursorRegions = [CursorRegion(start: time(3), duration: time(5),
                                              isHidden: false, smoothing: 0.4, isHeld: true,
                                              transition: time(0.25))]
        let read = try JSONDecoder().decode(Timeline.self, from: JSONEncoder().encode(written))
        #expect(read.cursorRegions == written.cursorRegions)
    }

    /// A project is a file, and a file can say `smoothing: 40`.
    @Test func nonsensePointerSettingsAreClampedRatherThanObeyed() {
        let absurd = CursorRegion(start: time(1), duration: time(2),
                                  smoothing: 12, transition: time(30)).sanitised
        #expect(absurd.smoothing == 1)
        #expect(absurd.transition == time(1), "a ramp longer than half the region would never arrive")

        let negative = CursorRegion(start: time(1), duration: time(2),
                                    smoothing: -5, transition: time(-1)).sanitised
        #expect(negative.smoothing == 0)
        #expect(negative.transition == .zero)
    }

    /// The boundary: 0 outside, ramping in, 1 in the middle, and symmetrical.
    @Test func aCursorRegionArrivesOverItsRampRatherThanOnOneFrame() {
        let region = CursorRegion(start: time(2), duration: time(4), transition: time(1))
        #expect(region.presence(at: time(1.99)) == 0)
        #expect(region.presence(at: time(6)) == 0, "the end belongs to what comes after it")
        #expect(region.presence(at: time(4)) == 1)
        let quarter = region.presence(at: time(2.25))
        #expect(quarter > 0 && quarter < 1)
        #expect(abs(region.presence(at: time(5.75)) - quarter) < 1e-9, "it leaves the way it came")
        // A ramp longer than the region is halved rather than truncated, so the middle is
        // still fully there.
        #expect(CursorRegion(start: .zero, duration: time(1), transition: time(9))
            .sanitised.presence(at: time(0.5)) == 1)
    }

    /// Overlapping stretches resolve to the strongest of each effect, not to a winner.
    ///
    /// Picking one region would switch answers on a single frame exactly where both are
    /// weakest — the pointer would flash back into shot between two overlapping hides.
    @Test func overlappingPointerStretchesTakeTheStrongestOfEach() {
        var timeline = timeline()
        timeline.cursorRegions = [
            CursorRegion(start: time(0), duration: time(8), transition: time(2)),
            CursorRegion(start: time(4), duration: time(6), isHidden: false,
                         smoothing: 1, isHeld: true, transition: time(2)),
        ]
        // Deep inside the first and one second into the second: fully hidden by the first,
        // and already part-way into the second's calm and hold.
        let override = timeline.cursorOverride(at: time(5))
        #expect(override.hiding == 1)
        #expect(override.smoothingWindow > 0 && override.smoothingWindow < CursorRegion.maximumSmoothingWindow)
        #expect(override.holding > 0 && override.holding < 1)
        #expect(override.heldSince == time(4), "held from where the holding stretch began")

        // And where only the first covers, the second asks for nothing.
        let early = timeline.cursorOverride(at: time(3))
        #expect(early.hiding == 1)
        #expect(early.smoothingWindow == 0)
        #expect(early.holding == 0)
    }

    @Test func deletingAStretchTakesThePointerRegionsOverItAlong() {
        var timeline = timeline()
        timeline.cursorRegions = [CursorRegion(start: time(10), duration: time(4)),
                                  CursorRegion(start: time(30), duration: time(4))]
        ClipSequence.delete(&timeline, range: CMTimeRange(start: time(8), end: time(16)))

        #expect(timeline.cursorRegions.count == 1, "the one over the deleted stretch went with it")
        #expect(timeline.cursorRegions.first?.start == time(22), "and the later one moved back by 8")
    }

    @Test func aPointerRegionIsOnTheListOfEdgesADragSnapsTo() {
        var timeline = timeline()
        timeline.cursorRegions = [CursorRegion(start: time(12), duration: time(3))]
        #expect(timeline.boundaries.contains(time(12)))
        #expect(timeline.boundaries.contains(time(15)))
    }

    @Test func addingAndDeletingAPointerRegionAreBothOneEdit() {
        var timeline = timeline()
        let region = CursorRegion(start: time(5), duration: time(3))
        #expect(Commands.AddCursorRegion(region).apply(to: &timeline))
        #expect(timeline.cursorRegions.count == 1)
        #expect(Commands.AddCursorRegion(CursorRegion(start: time(90), duration: time(3)))
            .apply(to: &timeline) == false, "past the end of the edit is no place for one")

        #expect(Commands.RestyleCursorRegion(id: region.id, name: "Hold") { $0.isHeld = true }
            .apply(to: &timeline))
        #expect(timeline.cursorRegions.first?.isHeld == true)

        #expect(Commands.DeleteRegion(id: region.id).apply(to: &timeline))
        #expect(timeline.cursorRegions.isEmpty)
    }
    // MARK: - Zooms: the second pass over a take

    /// What every zoom over one moment adds up to, the way the renderer resolves it.
    ///
    /// `SceneBuilder.camera` takes the deepest zoom at each moment rather than multiplying
    /// them, so that is the only definition of "the combined effect" worth testing against —
    /// a split that preserved some other sum would still show a lurch on screen.
    private func combinedScale(_ zooms: [ZoomRegion], at time: CMTime) -> Double {
        zooms.map { $0.scale(at: time) }.max() ?? 1
    }

    @Test func aSplitZoomLooksExactlyLikeTheOneItCameFrom() throws {
        let original = ZoomRegion(start: time(2), duration: time(10), scale: 3,
                                  transition: time(0.5), followsCursor: false)
        let (first, second) = try #require(ZoomLane.split(original, at: time(7)))

        #expect(first.duration == time(5))
        #expect(second.start == time(7))
        #expect(second.end == original.end)

        // Sampled well outside the region as well as across it, because "no dip at the seam"
        // is only half the claim: the pair must also not zoom anywhere the original did not.
        for step in 0...1_200 {
            let at = time(1 + Double(step) / 100)
            let combined = combinedScale([first, second], at: at)
            #expect(abs(combined - original.scale(at: at)) < 1e-9,
                    "at \(at.seconds)s the pair is \(combined), the original was \(original.scale(at: at))")
        }
    }

    @Test func aSplitTooCloseToAnEndIsRefused() {
        let region = ZoomRegion(start: time(2), duration: time(4))
        #expect(ZoomLane.split(region, at: time(2)) == nil)
        #expect(ZoomLane.split(region, at: time(6)) == nil)
        #expect(ZoomLane.split(region, at: time(2.02)) == nil, "a sliver is a zoom the user has lost")
        #expect(ZoomLane.split(region, at: time(3)) != nil)
    }

    /// Merging is the inverse of splitting, down to the stored keys.
    @Test(arguments: [3.0, 4.0, 7.0, 11.0])
    func mergingTwoHalvesGivesBackTheZoomTheyWereCutFrom(_ at: Double) throws {
        let original = ZoomRegion(start: time(2), duration: time(10), scale: 2.4,
                                  center: CGPoint(x: 0.3, y: 0.7), easing: .easeInOut,
                                  transition: time(0.4), followsCursor: false, source: .manual)
        let (first, second) = try #require(ZoomLane.split(original, at: time(at)))
        #expect(ZoomLane.merge(first, second) == original)
        #expect(ZoomLane.merge(second, first) == original, "which one you name first is not an edit")
    }

    @Test func aMergeKeepsTheFramingAtEitherEnd() throws {
        let first = ZoomRegion(start: time(0), duration: time(4), scale: 2,
                               transition: time(1), followsCursor: false)
        let second = ZoomRegion(start: time(4), duration: time(6), scale: 3,
                                transition: time(0.5), followsCursor: false)
        let merged = try #require(ZoomLane.merge(first, second))

        #expect(merged.start == .zero)
        #expect(merged.end == time(10))
        #expect(merged.ramps.in == time(1), "it still takes a second to arrive")
        #expect(merged.ramps.out == time(0.5), "and half a second to leave")
        #expect(merged.scale == 3, "the longer of the two decides how far in")
        #expect(abs(merged.scale(at: .zero) - 1) < 1e-9, "no jump at the front")
        #expect(abs(merged.scale(at: time(1)) - 3) < 1e-9, "in by the time the first one was")
        #expect(abs(merged.scale(at: time(9.5)) - 3) < 1e-9, "and holding until the second one let go")
    }

    @Test func mergingAZoomWithItselfIsNotAnEdit() {
        let region = ZoomRegion(start: .zero, duration: time(4))
        #expect(ZoomLane.merge(region, region) == nil)
    }

    @Test func aResetZoomIsTheDefaultsAndStaysWhereItWas() throws {
        let region = ZoomRegion(start: time(3), duration: time(5), scale: 6,
                                center: CGPoint(x: 0.2, y: 0.8), easing: .linear,
                                transition: time(1.75), transitionIn: .zero,
                                followsCursor: false, source: .click, isLocked: true)
        let reset = ZoomLane.reset(region)

        #expect(reset.scale == ZoomRegion.defaultScale)
        #expect(reset.easing == ZoomRegion.defaultEasing)
        #expect(reset.transition == ZoomRegion.defaultTransition)
        #expect(reset.ramps.in == reset.ramps.out, "a seam ramp is not part of how a zoom looks")
        #expect(reset.start == region.start)
        #expect(reset.duration == region.duration)
        #expect(reset.center == region.center, "where it points is not a default to put back")
        #expect(reset.followsCursor == region.followsCursor)
        #expect(reset.isLocked, "a reset is not a way to quietly unlock something")
    }

    // MARK: - Locking

    @Test func aLockedZoomIsLeftWhereItIs() {
        var timeline = timeline()
        let locked = ZoomRegion(start: time(4), duration: time(4), isLocked: true)
        let loose = ZoomRegion(start: time(20), duration: time(4))
        timeline.zooms = [locked, loose]

        #expect(!Commands.MoveRegion(id: locked.id, start: time(30)).apply(to: &timeline))
        #expect(!Commands.MoveRegion(id: locked.id, start: time(4), duration: time(9)).apply(to: &timeline))
        #expect(timeline.zooms.first == locked, "neither the drag nor the resize touched it")

        #expect(Commands.MoveRegion(id: loose.id, start: time(30)).apply(to: &timeline),
                "and the lock is about one zoom, not about the lane")
    }

    @Test func aLockedZoomCanStillBeRestyledAndDeleted() {
        var timeline = timeline()
        let locked = ZoomRegion(start: time(4), duration: time(4), isLocked: true)
        timeline.zooms = [locked]

        #expect(Commands.RestyleZoom(id: locked.id, name: "Zoom Scale") { $0.scale = 4 }
            .apply(to: &timeline), "the inspector is somewhere the user aimed")
        #expect(timeline.zooms.first?.scale == 4)
        #expect(Commands.DeleteRegion(id: locked.id).apply(to: &timeline),
                "a lock the Delete key cannot beat is a region nobody can get rid of")
    }

    // MARK: - Running auto-zoom again

    @Test func reRunningAutoZoomReplacesItsOwnWorkAndKeepsEverythingElse() {
        var timeline = timeline()
        let byHand = ZoomRegion(start: time(10), duration: time(4), source: .manual)
        let ancient = ZoomRegion(start: time(40), duration: time(3), source: nil)
        let lockedSuggestion = ZoomRegion(start: time(20), duration: time(3), source: .click, isLocked: true)
        let lastRun = ZoomRegion(start: time(30), duration: time(3), source: .click)
        timeline.zooms = [byHand, lockedSuggestion, lastRun, ancient]

        // What a second run proposes: something over the hand-made zoom, something over the
        // locked one, and one in the clear.
        let proposed = [ZoomRegion(start: time(11), duration: time(3), source: .click),
                        ZoomRegion(start: time(21), duration: time(3), source: .field),
                        ZoomRegion(start: time(50), duration: time(3), source: .click)]
        #expect(Commands.SuggestZooms(proposed).apply(to: &timeline))

        #expect(timeline.zooms.contains(byHand))
        #expect(timeline.zooms.contains(ancient), "a zoom from a build with no opinion is the user's")
        #expect(timeline.zooms.contains(lockedSuggestion))
        #expect(!timeline.zooms.contains(lastRun), "the previous run's work is replaced, not doubled")
        #expect(timeline.zooms.count == 4, "only the suggestion that overlapped nothing survived")
        #expect(timeline.zooms.map(\.start) == timeline.zooms.map(\.start).sorted())
    }

    @Test func runningAutoZoomTwiceOverTheSameTakeSettles() {
        var timeline = timeline()
        let proposed = [ZoomRegion(start: time(4), duration: time(3), source: .click),
                        ZoomRegion(start: time(12), duration: time(3), source: .field)]
        #expect(Commands.SuggestZooms(proposed).apply(to: &timeline))
        #expect(timeline.zooms.count == 2)
        #expect(!Commands.SuggestZooms(proposed).apply(to: &timeline),
                "the same answer twice is not an edit, and must not reach the undo stack")
        #expect(timeline.zooms.count == 2)
    }

    // MARK: - What older projects see

    /// The ramps are the same numbers they always were where both ends want the same thing.
    @Test(arguments: [0.0, 0.2, 0.5, 2.0, 9.0])
    func aZoomThatWasNeverSplitRampsExactlyAsItAlwaysDid(_ transition: Double) {
        let region = ZoomRegion(start: time(2), duration: time(4), scale: 3,
                                easing: .spring, transition: time(transition), followsCursor: false)
        // The arithmetic this used to do, spelled out, so a change to `scale(at:)` that moves
        // an existing project's camera fails here rather than in somebody's export.
        func asItWas(at at: CMTime) -> Double {
            guard region.contains(at) else { return 1 }
            let ramp = min(region.transition, CMTimeMultiplyByFloat64(region.duration, multiplier: 0.5))
            guard ramp.seconds > 0 else { return region.scale }
            let progress = min((at - region.start).seconds, (region.end - at).seconds) / ramp.seconds
            return 1 + (region.scale - 1) * region.easing.apply(min(1, max(0, progress)))
        }
        for step in 0...800 {
            let at = time(1 + Double(step) / 100)
            #expect(abs(region.scale(at: at) - asItWas(at: at)) < 1e-9, "at \(at.seconds)s")
        }
    }

    @Test func aProjectWrittenBeforeLocksAndSeamRampsOpensUnchanged() throws {
        // Exactly the keys an older build wrote, and not one more.
        let json = """
        {"formatVersion":1,"sourceDuration":{"value":600,"timescale":600},
         "clips":[{"id":"\(UUID().uuidString)","sourceStart":{"value":0,"timescale":600},
                   "sourceDuration":{"value":600,"timescale":600},"speed":1}],
         "zooms":[{"id":"\(UUID().uuidString)","start":{"value":600,"timescale":600},
                   "duration":{"value":1200,"timescale":600},"scale":2.5,
                   "center":[0.25,0.75],"easing":"spring",
                   "transition":{"value":300,"timescale":600},"followsCursor":true}]}
        """
        let timeline = try JSONDecoder().decode(Timeline.self, from: Data(json.utf8))
        let zoom = try #require(timeline.zooms.first, "a new field must not cost the user the lane")

        #expect(zoom.scale == 2.5)
        #expect(zoom.center == CGPoint(x: 0.25, y: 0.75))
        #expect(!zoom.isLocked, "nothing arrives locked")
        #expect(zoom.transitionIn == nil)
        #expect(zoom.transitionOut == nil)
        #expect(zoom.ramps.in == time(0.5))
        #expect(zoom.ramps.out == time(0.5))
    }

    @Test func aSplitSurvivesBeingWrittenOutAndReadBack() throws {
        var timeline = timeline()
        let region = ZoomRegion(start: time(2), duration: time(10), transition: time(0.5))
        timeline.zooms = [region]
        #expect(Commands.SplitZoom(id: region.id, at: time(7)).apply(to: &timeline))

        let data = try JSONEncoder().encode(timeline)
        let read = try JSONDecoder().decode(Timeline.self, from: data)
        #expect(read.zooms == timeline.zooms, "including the ramps that are zero at the seam")
        #expect(read.zooms.last?.ramps.in == .zero)
    }

}
