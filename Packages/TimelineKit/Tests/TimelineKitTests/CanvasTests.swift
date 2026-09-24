import CoreGraphics
import CoreMedia
import Foundation
import RecordKit
import Testing
@testable import TimelineKit

/// The things drawn on the picture: blurs and annotations, moved and restyled.
struct CanvasTests {
    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    private func timelineWithABlur() -> (Timeline, UUID) {
        var timeline = Timeline(sourceDuration: time(60))
        let blur = BlurRegion(start: time(2), duration: time(3),
                              rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))
        timeline.blurs = [blur]
        return (timeline, blur.id)
    }

    private func timelineWithAnAnnotation() -> (Timeline, UUID) {
        var timeline = Timeline(sourceDuration: time(60))
        let item = AnnotationItem(start: time(2), duration: time(3), kind: .text("Hello"),
                                  rect: CGRect(x: 0.3, y: 0.3, width: 0.2, height: 0.1))
        timeline.annotations = [item]
        return (timeline, item.id)
    }

    // MARK: - Moving and resizing

    @Test func movingABlurStoresItsNewRectangle() {
        var (timeline, id) = timelineWithABlur()
        let moved = CGRect(x: 0.5, y: 0.4, width: 0.2, height: 0.2)
        #expect(Commands.SetRegionRect(id: id, rect: moved).apply(to: &timeline))
        #expect(timeline.blurs[0].rect == moved)
    }

    /// One command for both kinds, so the canvas does not need to know which it is
    /// dragging before it can ask for the move.
    @Test func theSameCommandMovesAnAnnotation() {
        var (timeline, id) = timelineWithAnAnnotation()
        let moved = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.1)
        #expect(Commands.SetRegionRect(id: id, rect: moved).apply(to: &timeline))
        #expect(timeline.annotations[0].rect == moved)
    }

    @Test func movingSomethingThatIsNotThereChangesNothing() {
        var (timeline, _) = timelineWithABlur()
        #expect(!Commands.SetRegionRect(id: UUID(), rect: .zero).apply(to: &timeline))
    }

    /// An edit that changes nothing must not land on the undo stack.
    @Test func movingSomethingNowhereIsNotAnEdit() {
        var (timeline, id) = timelineWithABlur()
        let same = timeline.blurs[0].rect
        #expect(!Commands.SetRegionRect(id: id, rect: same).apply(to: &timeline))
    }

    /// A rectangle dragged to nothing is not a small rectangle — it is one the user has
    /// lost, because there is no handle left to pull it back out by.
    @Test func aRegionIsNeverDraggedDownToNothing() {
        var (timeline, id) = timelineWithABlur()
        _ = Commands.SetRegionRect(id: id, rect: CGRect(x: 0.5, y: 0.5, width: 0, height: 0)).apply(to: &timeline)
        #expect(timeline.blurs[0].rect.width >= Commands.SetRegionRect.minimumSide)
        #expect(timeline.blurs[0].rect.height >= Commands.SetRegionRect.minimumSide)
    }

    @Test func aRegionIsKeptInsideTheFrame() {
        var (timeline, id) = timelineWithABlur()
        _ = Commands.SetRegionRect(id: id, rect: CGRect(x: 0.9, y: 0.9, width: 0.4, height: 0.4)).apply(to: &timeline)
        let rect = timeline.blurs[0].rect
        #expect(rect.maxX <= 1.0001)
        #expect(rect.maxY <= 1.0001)
        #expect(rect.minX >= 0)
    }

    @Test func aBackwardsDragIsStillARectangle() {
        var (timeline, id) = timelineWithABlur()
        _ = Commands.SetRegionRect(id: id, rect: CGRect(x: 0.6, y: 0.6, width: -0.3, height: -0.2)).apply(to: &timeline)
        let rect = timeline.blurs[0].rect
        #expect(rect.width > 0 && rect.height > 0)
        #expect(abs(rect.minX - 0.3) < 0.001, "the drag started at 0.6 and went back to 0.3")
    }

    // MARK: - Restyling

    @Test func changingWhatAnAnnotationSaysIsAnEdit() {
        var (timeline, id) = timelineWithAnAnnotation()
        let command = Commands.RestyleAnnotation(id: id, name: "Annotation Text") { $0.kind = .text("Goodbye") }
        #expect(command.apply(to: &timeline))
        #expect(timeline.annotations[0].kind == .text("Goodbye"))
    }

    @Test func settingTheSameTextAgainIsNotAnEdit() {
        var (timeline, id) = timelineWithAnAnnotation()
        let command = Commands.RestyleAnnotation(id: id, name: "Annotation Text") { $0.kind = .text("Hello") }
        #expect(!command.apply(to: &timeline), "an edit that changes nothing must not reach the undo stack")
    }

    @Test func restylingSomethingThatIsNotThereChangesNothing() {
        var (timeline, _) = timelineWithAnAnnotation()
        let command = Commands.RestyleAnnotation(id: UUID(), name: "Annotation Text") { $0.fontSize = 0.2 }
        #expect(!command.apply(to: &timeline))
    }

    // MARK: - What is on screen

    @Test func aRegionIsOnScreenOnlyWhileItLasts() {
        let (timeline, _) = timelineWithABlur()
        let blur = timeline.blurs[0]
        #expect(!blur.contains(time(1.9)))
        #expect(blur.contains(time(2)))
        #expect(blur.contains(time(4.9)))
        #expect(!blur.contains(time(5)), "a region ends before its end, or two neighbours would both be on")
    }
}

/// Captions: where a recognised word lands once the edit has moved it.
struct CaptionTests {
    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    // MARK: - Source times onto the edit

    @Test func anUntouchedEditMapsSourceTimesStraightThrough() {
        let timeline = Timeline(sourceDuration: time(60))
        #expect(timeline.timelineTime(atSource: time(12)) == time(12))
    }

    /// The case captions exist for: recognition runs on the whole recording, and the
    /// words spoken after a cut have to move back with the footage.
    @Test func trimmingTheHeadPullsLaterWordsBack() {
        var timeline = Timeline(sourceDuration: time(60))
        timeline.clips = [Clip(sourceStart: time(10), sourceDuration: time(50))]

        let mapped = try! #require(timeline.timelineTime(atSource: time(20)))
        #expect(abs(mapped.seconds - 10) < 0.001, "ten seconds in, once the first ten are gone")
    }

    @Test func wordsInFootageNobodyKeptHaveNowhereToGo() {
        var timeline = Timeline(sourceDuration: time(60))
        timeline.clips = [Clip(sourceStart: time(10), sourceDuration: time(50))]
        #expect(timeline.timelineTime(atSource: time(4)) == nil,
                "a caption for words nobody will hear is worse than no caption")
    }

    @Test func speedingUpBringsWordsForward() {
        var timeline = Timeline(sourceDuration: time(60))
        timeline.clips = [Clip(sourceStart: .zero, sourceDuration: time(60), speed: 2)]

        let mapped = try! #require(timeline.timelineTime(atSource: time(20)))
        #expect(abs(mapped.seconds - 10) < 0.001, "twice as fast, half as far in")
    }

    @Test func aWordInALaterClipLandsAfterTheOnesBeforeIt() {
        var timeline = Timeline(sourceDuration: time(60))
        timeline.clips = [
            Clip(sourceStart: .zero, sourceDuration: time(10)),
            Clip(sourceStart: time(30), sourceDuration: time(10)),
        ]
        let mapped = try! #require(timeline.timelineTime(atSource: time(35)))
        #expect(abs(mapped.seconds - 15) < 0.001, "ten seconds of first clip, then five into the second")
    }

    /// The two mappings have to agree, or a caption drifts from the picture it belongs to.
    @Test func mappingThereAndBackAgainLandsWhereItStarted() {
        var timeline = Timeline(sourceDuration: time(60))
        timeline.clips = [
            Clip(sourceStart: time(5), sourceDuration: time(20), speed: 1.5),
            Clip(sourceStart: time(40), sourceDuration: time(10)),
        ]
        for seconds in [0.5, 3.0, 9.0, 14.0, 20.0] {
            guard let source = timeline.sourceTime(at: time(seconds)),
                  let back = timeline.timelineTime(atSource: source) else { continue }
            #expect(abs(back.seconds - seconds) < 0.01, "round trip at \(seconds)s")
        }
    }

    // MARK: - The commands

    /// Held rather than rebuilt per call: a cue carries an id, so two transcripts with
    /// the same words are still two different transcripts — which is the behaviour that
    /// makes regenerating captions land on the undo stack, as it should.
    private let cues = [
        CaptionCue(start: CMTime(seconds: 2, preferredTimescale: 600),
                   duration: CMTime(seconds: 1, preferredTimescale: 600), text: "hello"),
        CaptionCue(start: .zero,
                   duration: CMTime(seconds: 1, preferredTimescale: 600), text: "first"),
    ]

    @Test func settingCaptionsSortsThem() {
        var timeline = Timeline(sourceDuration: time(60))
        #expect(Commands.SetCaptions(cues).apply(to: &timeline))
        #expect(timeline.captions.map(\.text) == ["first", "hello"])
    }

    @Test func settingTheSameCaptionsAgainIsNotAnEdit() {
        var timeline = Timeline(sourceDuration: time(60))
        _ = Commands.SetCaptions(cues).apply(to: &timeline)
        #expect(!Commands.SetCaptions(cues).apply(to: &timeline))
    }

    @Test func clearingCaptionsIsOneUndoableStep() {
        var timeline = Timeline(sourceDuration: time(60))
        _ = Commands.SetCaptions(cues).apply(to: &timeline)
        #expect(Commands.SetCaptions([]).apply(to: &timeline))
        #expect(timeline.captions.isEmpty)
    }

    @Test func editingOneLineLeavesTheRestAlone() {
        var timeline = Timeline(sourceDuration: time(60))
        _ = Commands.SetCaptions(cues).apply(to: &timeline)
        let id = timeline.captions[1].id

        #expect(Commands.SetCaptionText(id: id, text: "goodbye").apply(to: &timeline))
        #expect(timeline.captions[1].text == "goodbye")
        #expect(timeline.captions[0].text == "first")
    }

    /// A caption style written by a newer build must not cost someone their edit.
    @Test func aProjectWithoutACaptionStyleStillDecodes() throws {
        let json = #"{"sourceDuration":{"value":600,"timescale":600},"clips":[]}"#
        let timeline = try JSONDecoder().decode(Timeline.self, from: Data(json.utf8))
        #expect(timeline.captionStyle == CaptionStyle())
    }
}

/// Where the camera looks when it follows the pointer.
struct CameraTrackTests {
    /// A hand jittering in place must not move the camera.
    ///
    /// Averaged over the recorded samples rather than probed at a fixed rate: probing
    /// aliases against the jitter and produces an "average" that swings as widely as the
    /// pointer does, which is the bug this replaced.
    @Test func averagingIgnoresJitterWhateverItsRate() {
        for period in [2.0, 3.0, 5.0, 7.0] {
            let samples = (0...400).map { step in
                CursorSample(t: Double(step) / 100,
                             x: 500 + 60 * sin(2 * .pi * Double(step) / period),
                             y: 300,
                             shape: .arrow)
            }
            let track = CursorTrack(samples: samples)

            // How far each travels over the same stretch. Comparing travel rather than
            // distance from a nominal centre, because "the average" of an uneven wobble
            // is not the middle of its range — the property that matters is that the
            // camera moves much less than the hand does.
            var cameraTravel = 0.0
            var pointerTravel = 0.0
            var lastCamera: Double?
            var lastPointer: Double?
            for step in 0...60 {
                let at = 2 + Double(step) / 60
                let camera = try! #require(track.averagePosition(at: at, window: 0.7)).x
                let pointer = try! #require(track.position(at: at)).x
                if let lastCamera { cameraTravel += abs(camera - lastCamera) }
                if let lastPointer { pointerTravel += abs(pointer - lastPointer) }
                lastCamera = camera
                lastPointer = pointer
            }

            #expect(cameraTravel < pointerTravel / 4,
                    "jitter every \(period) samples leaked into the camera: \(cameraTravel) vs \(pointerTravel)")
        }
    }

    /// Steady travel still has to be followed, or the camera never arrives.
    @Test func averagingStillFollowsRealMovement() {
        let samples = (0...400).map {
            CursorSample(t: Double($0) / 100, x: Double($0) * 2, y: 0, shape: .arrow)
        }
        let track = CursorTrack(samples: samples)
        let early = try! #require(track.averagePosition(at: 1, window: 0.7))
        let later = try! #require(track.averagePosition(at: 3, window: 0.7))

        #expect(later.x > early.x + 300, "the camera has to keep up with the work")
        // Behind the pointer, because it is averaging what just happened — that lag is
        // the whole point.
        let now = try! #require(track.position(at: 3))
        #expect(later.x < now.x)
    }

    @Test func aSparseTrackFallsBackToInterpolating() {
        let track = CursorTrack(samples: [CursorSample(t: 0, x: 0, y: 0, shape: .arrow),
                                          CursorSample(t: 10, x: 1_000, y: 0, shape: .arrow)])
        let averaged = try! #require(track.averagePosition(at: 5, window: 0.7))
        #expect(abs(averaged.x - 500) < 1, "two samples ten seconds apart is not a still hand")
    }

    @Test func anEmptyTrackAveragesToNothing() {
        #expect(CursorTrack(samples: []).averagePosition(at: 1, window: 0.7) == nil)
    }
}
