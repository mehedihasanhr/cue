import CoreGraphics
import CoreMedia
import Foundation
import RecordKit
import Testing
import TimelineKit
@testable import RenderKit

/// What the camera does between two zooms that are close together, and at a cut.
///
/// `ZoomGlideTests` in TimelineKit pins the rule — which pairs glide and when the move
/// begins and ends. These pin what the camera actually does with it: the scale through
/// the move, the path of the centre, and that a long gap still pulls back.
struct ZoomGlideCameraTests {
    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    private let videoSize = CGSize(width: 1_600, height: 1_000)

    private func builder() -> SceneBuilder {
        SceneBuilder(videoSize: videoSize, displayScale: 2)
    }

    /// Two zooms aimed at different corners, with the pointer left out of it.
    private func timeline(gap: Double, scales: (Double, Double) = (3, 2), ramp: Double = 0.5,
                          easing: Easing = .easeInOut, glides: Bool = true) -> Timeline {
        var timeline = Timeline(sourceDuration: time(30))
        timeline.style.padding = 0
        timeline.cursor.isVisible = false
        timeline.camera.glidesBetweenZooms = glides
        timeline.zooms = [ZoomRegion(start: time(2), duration: time(4), scale: scales.0,
                                     center: CGPoint(x: 0.25, y: 0.3), easing: easing,
                                     transition: time(ramp), followsCursor: false),
                          ZoomRegion(start: time(6 + gap), duration: time(4), scale: scales.1,
                                     center: CGPoint(x: 0.75, y: 0.7), easing: easing,
                                     transition: time(ramp), followsCursor: false)]
        return timeline
    }

    private func camera(_ timeline: Timeline, at seconds: Double) -> (zoom: Double, center: CGPoint) {
        camera(timeline, at: time(seconds))
    }

    /// Frame `index` of a 60 fps export, as the exact rational the exporter walks — a
    /// `Double` of seconds truncates on its way into a `CMTime` and lands a frame short.
    private func camera(_ timeline: Timeline, atFrame index: Int) -> (zoom: Double, center: CGPoint) {
        camera(timeline, at: CMTime(value: CMTimeValue(index), timescale: 60))
    }

    private func camera(_ timeline: Timeline, at time: CMTime) -> (zoom: Double, center: CGPoint) {
        let scene = builder().descriptor(for: timeline, at: time)
        return (scene.zoom, scene.zoomCenter)
    }

    // MARK: - Through the gap

    /// The headline: the camera never pulls back to the whole picture between two close
    /// zooms. Sampled on a 60 fps grid from before the first zoom's ramp out to after the
    /// second's ramp in.
    @Test(arguments: [0.0, 0.2, 0.5])
    func theScaleNeverFallsBelowTheSmallerOfTheTwoZooms(gap: Double) {
        let edit = timeline(gap: gap)
        for frame in Int(5.4 * 60)...Int((7.4 + gap) * 60) {
            let zoom = camera(edit, atFrame: frame).zoom
            #expect(zoom >= 2 - 1e-9, "pulled back to \(zoom) at frame \(frame)")
            #expect(zoom <= 3 + 1e-9)
        }
    }

    /// The other headline: the centre travels, it does not jump. No frame-to-frame step
    /// is larger than what the eased move covers in one frame at its fastest — and that
    /// includes the frames where the move begins and ends.
    @Test func theCentreIsContinuousThroughTheMove() {
        let edit = timeline(gap: 0.2, easing: .easeInOut)
        // From (0.25, 0.3) honoured at 3× to (0.75, 0.7) honoured at 2×: the honoured
        // centres are what the camera actually travels between.
        let from = ZoomFraming.honoured(center: CGPoint(x: 0.25, y: 0.3), scale: 3)
        let to = ZoomFraming.honoured(center: CGPoint(x: 0.75, y: 0.7), scale: 2)
        let travel = hypot(to.x - from.x, to.y - from.y)
        // The move lasts 1.2 s; an ease-in-out peaks at twice the average speed.
        let oneFrame = travel / (1.2 * 60) * 2 * 1.05

        var previous = camera(edit, atFrame: 300).center
        for frame in 301...480 {
            let now = camera(edit, atFrame: frame).center
            let step = hypot(now.x - previous.x, now.y - previous.y)
            #expect(step <= oneFrame, "a jump of \(step) at frame \(frame)")
            previous = now
        }
        #expect(abs(camera(edit, at: 5.4).center.x - from.x) < 1e-9, "still holding the first shot")
        #expect(abs(camera(edit, at: 7.4).center.x - to.x) < 1e-9, "and has arrived at the second")
    }

    /// The move starts and ends at the moments the ramps always did: only the path between
    /// is new.
    @Test func theMoveKeepsTheRampsTiming() {
        let edit = timeline(gap: 0.2)
        #expect(abs(camera(edit, at: 5.49).zoom - 3) < 1e-9, "not yet leaving")
        #expect(camera(edit, at: 5.6).zoom < 3, "leaving")
        #expect(camera(edit, at: 6.6).zoom > 2, "not yet arrived")
        #expect(abs(camera(edit, at: 6.7).zoom - 2) < 1e-9, "arrived where the ramp in would have ended")
    }

    /// A gap the ramps could fill is a pause, and the camera pulls back through it as it
    /// always did — all the way to the whole picture.
    @Test func aLongGapStillPullsBackToTheWholePicture() {
        let edit = timeline(gap: 1.5)
        #expect(camera(edit, at: 6.5).zoom == 1)
        #expect(camera(edit, at: 7.0).zoom == 1)
        #expect(camera(edit, at: 6.5).center == CGPoint(x: 0.5, y: 0.5))
    }

    /// With the project's switch off, the same two zooms pull back as they always did.
    @Test func theProjectSwitchTurnsItOff() {
        let edit = timeline(gap: 0.2, glides: false)
        #expect(camera(edit, at: 6.1).zoom == 1, "the gap shows the whole picture")
        #expect(camera(edit, at: 6.0).zoom == 1)
    }

    /// A spring settles past its mark; the scale is not allowed to follow it there.
    @Test func aSpringsOvershootStaysOutOfTheScale() {
        let edit = timeline(gap: 0, easing: .spring)
        for frame in 330...390 {
            let zoom = camera(edit, atFrame: frame).zoom
            #expect(zoom >= 2 - 1e-9 && zoom <= 3 + 1e-9, "\(zoom) at frame \(frame)")
        }
    }

    // MARK: - Following the pointer through a glide

    /// A zoom that follows the pointer glides from the shot it is actually holding — the
    /// one the pointer dragged it to — not from where it was aimed.
    @Test func aFollowingZoomGlidesFromTheShotItIsHolding() {
        var edit = timeline(gap: 0)
        edit.cursor.isVisible = true
        edit.cursor.smoothing = 0
        edit.zooms[0].followsCursor = true
        edit.zooms[0].center = CGPoint(x: 0.5, y: 0.5)
        // The pointer sits at the right-hand edge throughout, so the first zoom's shot is
        // dragged across to keep it in frame.
        let track = CursorTrack(samples: [CursorSample(t: 0, x: 790, y: 250, shape: .arrow),
                                          CursorSample(t: 30, x: 790, y: 250, shape: .arrow)])
        let held = builder().descriptor(for: edit, at: time(5.4), cursor: track).zoomCenter
        #expect(held.x > 0.6, "dragged across by the pointer")
        let leaving = builder().descriptor(for: edit, at: time(5.5), cursor: track).zoomCenter
        // Within a point: the path is rounded off over a few frames either side (see
        // `SceneBuilder.smoothedShot`), so the move is already just under way as it begins
        // rather than starting from that shot on one frame.
        #expect(abs(leaving.x - held.x) < 1e-3, "the move begins from that very shot")

        // And the pointer never leaves the picture the camera is showing, all the way.
        for frame in 324...396 {
            let scene = builder().descriptor(for: edit, at: CMTime(value: CMTimeValue(frame), timescale: 60), cursor: track)
            guard let cursor = scene.cursor else { continue }
            let half = 0.5 / scene.zoom
            #expect(abs(cursor.position.x - scene.zoomCenter.x) <= half + 1e-9, "lost at frame \(frame)")
        }
    }

    // MARK: - An instant zoom

    /// A cut, on the exact frames: all the way in on the first frame the region covers,
    /// all the way out on the frame after its last — and the camera's centre with it.
    @Test func anInstantZoomIsInOnItsFirstFrameAndOutOnTheFrameAfterItsLast() {
        var edit = timeline(gap: 5)
        edit.zooms[0].isInstant = true
        #expect(camera(edit, atFrame: 119).zoom == 1)
        #expect(camera(edit, atFrame: 119).center == CGPoint(x: 0.5, y: 0.5))
        #expect(camera(edit, atFrame: 120).zoom == 3, "the first frame of the region")
        #expect(camera(edit, atFrame: 120).center == ZoomFraming.honoured(center: CGPoint(x: 0.25, y: 0.3), scale: 3))
        #expect(camera(edit, atFrame: 359).zoom == 3, "the last")
        #expect(camera(edit, atFrame: 360).zoom == 1, "the frame after it")
        #expect(camera(edit, atFrame: 360).center == CGPoint(x: 0.5, y: 0.5))
    }

    /// An instant zoom beside a smooth one is a cut at the join, with the smooth one
    /// ramping on its own as it always did.
    @Test func anInstantZoomDoesNotGlideWithItsNeighbour() {
        var edit = timeline(gap: 0)
        edit.zooms[1].isInstant = true
        #expect(camera(edit, at: 5.99).zoom < 1.2, "the first zoom pulled back on its own")
        #expect(camera(edit, at: 6.0).zoom == 2, "and the second cut in")
    }
}
