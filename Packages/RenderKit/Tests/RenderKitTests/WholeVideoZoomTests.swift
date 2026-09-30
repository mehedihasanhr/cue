import CoreGraphics
import CoreMedia
import Foundation
import RecordKit
import Testing
import TimelineKit
@testable import RenderKit

/// The whole video held zoomed in, the camera panning after the pointer throughout, and
/// zooms going further in from there.
struct WholeVideoZoomTests {
    private func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600) }

    /// 800 × 500 points, two pixels to a point.
    private let builder = SceneBuilder(videoSize: CGSize(width: 1_600, height: 1_000), displayScale: 2)

    private func timeline(held: Double, _ change: (inout Timeline) -> Void = { _ in }) -> Timeline {
        var timeline = Timeline(sourceDuration: time(12))
        timeline.style.padding = 0
        timeline.cursor.smoothing = 0
        timeline.camera.motionBlur = false
        timeline.camera.wholeVideoZoom = held
        change(&timeline)
        return timeline
    }

    /// Parked on the left for three seconds, across to the right over four, parked there.
    private var sweep: CursorTrack {
        CursorTrack(samples: (0...1_200).map { step in
            let t = Double(step) / 100
            let x = 80 + min(max(t - 3, 0), 4) / 4 * 640
            return CursorSample(t: t, x: x, y: 250, shape: .arrow)
        })
    }

    private func shot(_ timeline: Timeline, at seconds: Double) -> SceneDescriptor {
        builder.descriptor(for: timeline, at: time(seconds), cursor: sweep)
    }

    @Test func offLeavesTheWholePictureAlone() {
        let scene = shot(timeline(held: 1), at: 5)
        #expect(scene.zoom == 1)
        #expect(scene.zoomCenter == CGPoint(x: 0.5, y: 0.5))
    }

    @Test func theWholeVideoIsHeldAtTheLevel() {
        let held = timeline(held: 2)
        for seconds in stride(from: 0.0, to: 12, by: 0.5) {
            #expect(abs(shot(held, at: seconds).zoom - 2) < 1e-9, "at \(seconds)")
        }
    }

    @Test func theCameraPansAfterThePointer() {
        let held = timeline(held: 2)
        #expect(shot(held, at: 2).zoomCenter.x < 0.4, "looking left while the pointer is on the left")
        #expect(shot(held, at: 11).zoomCenter.x > 0.6, "and right once it has gone right")
    }

    @Test func thePointerIsNeverLeftOutOfShot() throws {
        let held = timeline(held: 2.5)
        for frame in 0..<(12 * 30) {
            let scene = shot(held, at: Double(frame) / 30)
            let pointer = try #require(scene.cursor).position
            let half = 0.5 / scene.zoom
            #expect(abs(pointer.x - scene.zoomCenter.x) <= half + 1e-6, "frame \(frame)")
            #expect(abs(pointer.y - scene.zoomCenter.y) <= half + 1e-6, "frame \(frame)")
        }
    }

    @Test func thePanIsSmooth() {
        let held = timeline(held: 2)
        var previous = shot(held, at: 0).zoomCenter
        var largest = 0.0
        for frame in 1..<(12 * 60) {
            let center = shot(held, at: Double(frame) / 60).zoomCenter
            largest = max(largest, hypot(center.x - previous.x, center.y - previous.y))
            previous = center
        }
        // Across most of the picture in four seconds: well under a hundredth a frame.
        #expect(largest < 0.01, "\(largest)")
    }

    @Test func aZoomInsideGoesFurtherIn() {
        let zoomed = timeline(held: 1.5) {
            $0.zooms = [ZoomRegion(start: time(4), duration: time(4), scale: 2,
                                   center: CGPoint(x: 0.5, y: 0.5), easing: .easeInOut,
                                   transition: time(0.5), followsCursor: true)]
        }
        #expect(abs(shot(zoomed, at: 6).zoom - 3) < 1e-9)
        #expect(abs(shot(zoomed, at: 2).zoom - 1.5) < 1e-9)
        #expect(abs(shot(zoomed, at: 10).zoom - 1.5) < 1e-9, "and back to the held level after")
    }

    @Test func aZoomArrivesFromTheHeldShotWithoutAJump() {
        // A zoom aimed somewhere the held camera is not looking, and holding its aim.
        let zoomed = timeline(held: 2) {
            $0.zooms = [ZoomRegion(start: time(1), duration: time(1.5), scale: 2,
                                   center: CGPoint(x: 0.8, y: 0.8), easing: .easeInOut,
                                   transition: time(0.5), followsCursor: false)]
        }
        var previous = shot(zoomed, at: 0.5)
        var largest = 0.0
        for frame in 31..<(3 * 60) {
            let scene = shot(zoomed, at: Double(frame) / 60)
            largest = max(largest, hypot(scene.zoomCenter.x - previous.zoomCenter.x,
                                         scene.zoomCenter.y - previous.zoomCenter.y))
            previous = scene
        }
        // The push-in moves the camera — a few hundredths of the picture a frame at its
        // fastest — but never by the tenth or more it would jump on the ramp's first frame
        // if the zoom's own aim took over at once.
        #expect(largest < 0.05, "\(largest)")
    }

    @Test func aHiddenPointerLeavesTheCameraInTheMiddle() {
        let hidden = timeline(held: 2) { $0.cursor.isVisible = false }
        #expect(shot(hidden, at: 11).zoomCenter == CGPoint(x: 0.5, y: 0.5))
    }

    @Test func thePanIsSmearedWhenTheCameraMotionIsBlurred() {
        let blurred = timeline(held: 3) { $0.camera.motionBlur = true }
        #expect(shot(blurred, at: 5).cameraMotion != nil, "panning with the sweep")
        #expect(shot(blurred, at: 11.5).cameraMotion == nil, "settled")
    }
}
