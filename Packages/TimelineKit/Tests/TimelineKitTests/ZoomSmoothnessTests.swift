import CoreGraphics
import CoreMedia
import Foundation
import RecordKit
import Testing
@testable import TimelineKit

/// Zooms that move like a camera: start from rest, never pass where they are going, and
/// travel straight there. Each test is one of the faults a real take showed — a zoom that
/// snapped in, went past its depth and came back, and wobbled sideways before settling.
struct ZoomSmoothnessTests {
    private func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600) }

    // MARK: - The curve

    /// Starts from rest, never goes back, never passes 1, and arrives exactly.
    @Test func theSpringStartsFromRestAndNeverOvershoots() {
        let curve = Easing.spring
        #expect(curve.apply(0) == 0)
        #expect(abs(curve.apply(1) - 1) < 1e-12)
        var last = 0.0
        for step in 1...1_000 {
            let value = curve.apply(Double(step) / 1_000)
            #expect(value >= last - 1e-12, "went back at \(step)")
            #expect(value <= 1 + 1e-12, "passed its target at \(step)")
            last = value
        }
        // Over a 0.5 s ramp at 60 fps the first frame moves less than an average frame —
        // the old curve moved about four times as far.
        let frames = 30.0
        #expect(curve.apply(1 / frames) < 1 / frames)
    }

    /// The way out leaves as the way in arrived — from rest — and settles softly rather
    /// than landing at full speed.
    @Test func leavingIsTheMirrorOfArriving() {
        let curve = Easing.spring
        for step in 0...100 {
            let t = Double(step) / 100
            #expect(abs(curve.applyLeaving(t) - (1 - curve.apply(1 - t))) < 1e-12)
        }
        let frames = 30.0
        // Leaving: progress runs from 1 (held) to 0 (out). Its first frame barely moves…
        #expect(1 - curve.applyLeaving(1 - 1 / frames) < 1 / frames)
        // …and neither does its last.
        #expect(curve.applyLeaving(1 / frames) < 1 / frames)
    }

    /// A pop keeps its bounce: that one is meant to go past and come back.
    @Test func aPopStillBounces() {
        let peak = stride(from: 0.0, through: 1.0, by: 0.01).map(Easing.overshoot).max() ?? 0
        #expect(peak > 1.01)
    }

    // MARK: - A zoom's ramps

    /// In and out, the scale never goes past the zoom's own depth, and moves least at the
    /// two ends of the whole move.
    @Test func aZoomNeverGoesDeeperThanItsDepth() {
        let zoom = ZoomRegion(start: time(1), duration: time(3), scale: 1.8, transition: time(0.9))
        var scales: [Double] = []
        for frame in 0...240 { scales.append(zoom.scale(at: time(1 + Double(frame) / 60))) }
        #expect((scales.max() ?? 0) <= 1.8 + 1e-9)
        #expect(scales[1] - scales[0] < 0.8 / 54, "starts gently")
        let last = scales.lastIndex { $0 > 1 } ?? 0
        #expect(scales[last] - 1 < 0.8 / 54, "and lands gently")
    }

    // MARK: - The path

    /// One point holds still on the screen while the picture grows round it, the view stays
    /// on the picture throughout, and the aimed point travels straight to the middle.
    @Test func aZoomTravelsStraightToItsAim() {
        let aim = CGPoint(x: 0.54, y: 0.28) // near the top edge, as far up as 1.8× can look
        let target = 1.8
        let fixed = CGPoint(x: (aim.x * target - 0.5) / (target - 1), y: (aim.y * target - 0.5) / (target - 1))
        var previous: CGPoint?
        for step in 0...100 {
            let progress = Double(step) / 100
            let scale = 1 + (target - 1) * progress
            let center = ZoomFraming.dolly(from: (1, CGPoint(x: 0.5, y: 0.5)), to: (target, aim),
                                           atScale: scale, progress: progress)
            // The fixed point is where it always was on the screen.
            let onScreen = CGPoint(x: (fixed.x - center.x) * scale + 0.5, y: (fixed.y - center.y) * scale + 0.5)
            #expect(abs(onScreen.x - fixed.x) < 1e-9 && abs(onScreen.y - fixed.y) < 1e-9)
            // The view is on the picture.
            let half = 0.5 / scale
            #expect(center.x - half >= -1e-9 && center.x + half <= 1 + 1e-9)
            #expect(center.y - half >= -1e-9 && center.y + half <= 1 + 1e-9)
            // The aimed point only ever moves towards the middle of the screen.
            let aimed = CGPoint(x: (aim.x - center.x) * scale + 0.5, y: (aim.y - center.y) * scale + 0.5)
            if let previous {
                #expect(abs(aimed.x - 0.5) <= abs(previous.x - 0.5) + 1e-9)
                #expect(abs(aimed.y - 0.5) <= abs(previous.y - 0.5) + 1e-9)
            }
            previous = aimed
        }
    }

    /// Two shots at the same depth: a straight pan, blended by progress.
    @Test func sameDepthIsAPan() {
        let a = CGPoint(x: 0.3, y: 0.4), b = CGPoint(x: 0.7, y: 0.6)
        let middle = ZoomFraming.dolly(from: (1.8, a), to: (1.8, b), atScale: 1.8, progress: 0.5)
        #expect(abs(middle.x - 0.5) < 1e-9 && abs(middle.y - 0.5) < 1e-9)
    }

    // MARK: - Zoom speed

    /// The speed control retimes every zoom not timed by hand, and only those.
    @Test func zoomSpeedRetimesTheZoomsNotSetByHand() {
        var timeline = Timeline(sourceDuration: time(30))
        timeline.zooms = [ZoomRegion(start: time(1), duration: time(4), transition: time(0.5)),
                          ZoomRegion(start: time(8), duration: time(4), transition: time(0.5), isEdited: true),
                          ZoomRegion(start: time(14), duration: time(1), transition: time(0.5))]
        #expect(Commands.setZoomSpeed(.slow).apply(to: &timeline))
        #expect(timeline.camera.zoomSpeed == .slow)
        #expect(abs(timeline.zooms[0].transition.seconds - 1.2) < 0.01)
        #expect(abs(timeline.zooms[1].transition.seconds - 0.5) < 0.01, "timed by hand, kept")
        #expect(abs(timeline.zooms[2].transition.seconds - 0.5) < 0.01, "no more than half a short zoom")
    }

    /// A project saved before the speed existed opens at Medium, and a look carries it.
    @Test func oldProjectsOpenAtMediumAndLooksCarryTheSpeed() throws {
        let old = try JSONDecoder().decode(CameraStyle.self, from: Data(#"{"follow":0.5}"#.utf8))
        #expect(old.zoomSpeed == .medium)
        var style = CameraStyle()
        style.zoomSpeed = .fast
        var restored = CameraStyle()
        Look.Camera(style).apply(to: &restored)
        #expect(restored.zoomSpeed == .fast)
    }

    // MARK: - The picture track's noise

    /// A window that never changed, flickering between 1511.4 and 1512 points wide as a
    /// real take's did: read back, it is one picture that fills the frame, never a crop.
    @Test func roundingNoiseInThePictureTrackIsNotACrop() {
        let frame = CGSize(width: 1_512, height: 949)
        let samples = (0..<20).map { index in
            PictureSample(t: Double(index), rect: CGRect(x: 0, y: 0, width: index % 2 == 0 ? 1_511.407 : 1_512, height: 949))
        }
        let track = PictureTrack(samples: samples)
        #expect(track.samples.count == 1)
        for index in 0..<20 {
            #expect(track.shown(at: Double(index) + 0.5, in: frame) == CGRect(origin: .zero, size: frame))
        }
        #expect(PictureTrack.fillsFrame(CGRect(x: 0, y: 0, width: 1_300, height: 949), frame: frame) == false,
                "a real resize is still one")
    }
}
