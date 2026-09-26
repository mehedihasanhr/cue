import CoreGraphics
import CoreMedia
import Foundation
import RecordKit
import Testing
import TimelineKit
@testable import RenderKit

/// What the camera does while the pointer moves inside a zoom.
///
/// The rule these pin down: **work inside the shot costs no camera movement.** Clicking
/// three things inside one zoomed area used to slide the picture three times, to frame
/// things that were already framed. The camera holds what it was aimed at and moves only
/// when the pointer would otherwise leave.
struct CameraFollowTests {
    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    private let videoSize = CGSize(width: 1_600, height: 1_000)
    /// 1600×1000 pixels at 2× is 800×500 points, so the frame's middle is (400, 250).
    private let middle = CGPoint(x: 400, y: 250)

    private func builder() -> SceneBuilder {
        SceneBuilder(videoSize: videoSize, displayScale: 2)
    }

    /// A zoom on the middle of the frame, running 1s…9s, fully in by 2s.
    private func timeline(scale: Double = 3, follows: Bool = true) -> Timeline {
        var timeline = Timeline(sourceDuration: time(20))
        timeline.style.padding = 0
        timeline.style.cornerRadius = 0
        timeline.style.shadowOpacity = 0
        timeline.cursor.isVisible = true
        timeline.cursor.smoothing = 0
        timeline.zooms = [ZoomRegion(start: time(1), duration: time(8), scale: scale,
                                     center: CGPoint(x: 0.5, y: 0.5),
                                     easing: .linear, transition: time(1),
                                     followsCursor: follows)]
        return timeline
    }

    /// A pointer that walks a path, sampled at 120 Hz.
    private func track(_ path: [(t: Double, at: CGPoint)]) -> CursorTrack {
        var samples: [CursorSample] = []
        for step in 0...(20 * 120) {
            let t = Double(step) / 120
            let at = position(on: path, at: t)
            samples.append(CursorSample(t: t, x: at.x, y: at.y, shape: .arrow))
        }
        return CursorTrack(samples: samples)
    }

    private func position(on path: [(t: Double, at: CGPoint)], at t: Double) -> CGPoint {
        guard let first = path.first else { return middle }
        if t <= first.t { return first.at }
        for index in 1..<path.count where t <= path[index].t {
            let a = path[index - 1], b = path[index]
            let span = max(1e-9, b.t - a.t)
            let progress = (t - a.t) / span
            return CGPoint(x: a.at.x + (b.at.x - a.at.x) * progress,
                           y: a.at.y + (b.at.y - a.at.y) * progress)
        }
        return path[path.count - 1].at
    }

    private func centre(_ timeline: Timeline, _ track: CursorTrack, at seconds: Double) -> CGPoint {
        builder().descriptor(for: timeline, at: time(seconds), cursor: track).zoomCenter
    }

    // MARK: - Holding

    /// The headline: a pointer moving about *inside* the shot does not move the camera.
    ///
    /// At 3× the shot is a third of the frame — roughly 266 × 166 points here — so a
    /// pointer wandering 60 points around the middle is well inside it, and three clicks
    /// in three different places in there is an ordinary thing to do.
    @Test func workingInsideTheShotDoesNotMoveTheCamera() {
        let edit = timeline()
        let walk = track([
            (0, middle),
            (3, CGPoint(x: middle.x - 60, y: middle.y - 30)),
            (5, CGPoint(x: middle.x + 55, y: middle.y + 35)),
            (7, CGPoint(x: middle.x - 40, y: middle.y + 20)),
            (9, middle),
        ])

        let aimed = CGPoint(x: 0.5, y: 0.5)
        for at in stride(from: 2.5, through: 8.5, by: 0.1) {
            let centre = centre(edit, walk, at: at)
            #expect(abs(centre.x - aimed.x) < 0.001, "the camera moved at \(at)")
            #expect(abs(centre.y - aimed.y) < 0.001, "the camera moved at \(at)")
        }
    }

    /// And the counterpart: leaving the shot does bring the camera along.
    @Test func leavingTheShotMovesTheCamera() {
        let edit = timeline()
        let away = track([(0, middle), (3, middle), (6, CGPoint(x: 740, y: 250))])
        #expect(abs(centre(edit, away, at: 3) - 0.5) < 0.001, "still held")
        #expect(centre(edit, away, at: 6).x > 0.6, "and dragged across by the time it is out there")
    }

    /// How far out of the *shot* the pointer got, as a fraction of centre-to-edge. 1 is
    /// the very edge of what the camera is showing; past that it is clipped away and
    /// simply vanishes from the video.
    private func worstReach(_ timeline: Timeline, _ track: CursorTrack,
                            from: Double, to: Double) -> Double {
        var worst = 0.0
        for at in stride(from: from, through: to, by: 0.05) {
            let scene = builder().descriptor(for: timeline, at: time(at), cursor: track)
            guard let cursor = scene.cursor else { continue }
            let half = 0.5 / scene.zoom
            worst = max(worst, max(abs(cursor.position.x - scene.zoomCenter.x),
                                   abs(cursor.position.y - scene.zoomCenter.y)) / half)
        }
        return worst
    }

    /// The guarantee that makes the dead zone safe: whatever it allows, the pointer stays
    /// inside the shot — not merely inside the recording. A cursor outside the shot is
    /// clipped away, so from the viewer's side it has disappeared.
    @Test func thePointerNeverLeavesTheShot() {
        let edit = timeline()
        let roaming = track([
            (0, middle), (2, CGPoint(x: 40, y: 40)), (4, CGPoint(x: 760, y: 460)),
            (6, CGPoint(x: 40, y: 460)), (8, CGPoint(x: 760, y: 40)),
        ])
        #expect(worstReach(edit, roaming, from: 2.0, to: 8.5) <= 1.0001)
    }

    /// A pointer that wanders out and comes back leaves the camera where the zoom was
    /// aimed, not wherever the wandering ended. No accumulated state, no drift.
    @Test func theCameraComesBackToWhereTheZoomWasAimed() {
        let edit = timeline()
        let there = track([(0, middle), (3, CGPoint(x: 760, y: 250)), (6, middle), (9, middle)])
        #expect(abs(centre(edit, there, at: 8.5) - 0.5) < 0.002)
    }

    // MARK: - The dials

    @Test func followingCanBeTurnedOff() {
        var edit = timeline()
        edit.camera.follow = 0
        let away = track([(0, middle), (6, CGPoint(x: 760, y: 460))])
        for at in stride(from: 2.0, through: 8.5, by: 0.25) {
            #expect(abs(centre(edit, away, at: at) - 0.5) < 0.001, "moved at \(at)")
        }
    }

    /// A zoom that does not follow holds its aim — while the pointer is in the shot.
    ///
    /// Aiming a zoom by hand turns following off, and focus and typing zooms never follow,
    /// because a camera drifting after the mouse while somebody types is seasickness. All
    /// of that is right, and all of it used to leave the pointer free to walk out of the
    /// shot and vanish. So the aim is held until the pointer would be lost, and then the
    /// camera gives way by the least it can.
    @Test func aZoomThatDoesNotFollowHoldsItsAimUntilThePointerWouldBeLost() {
        let edit = timeline(follows: false)
        let inside = track([(0, middle), (6, CGPoint(x: middle.x + 60, y: middle.y + 30))])
        #expect(abs(centre(edit, inside, at: 6) - 0.5) < 0.001, "held, while the pointer is in shot")

        let away = track([(0, middle), (6, CGPoint(x: 760, y: 460))])
        #expect(worstReach(edit, away, from: 2.0, to: 8.5) <= 1.0001, "and the pointer is never lost")
        #expect(centre(edit, away, at: 6).x > 0.55, "which it could only manage by giving way")
    }

    /// And it gives way by the *least* it can: a following zoom keeps the pointer well
    /// inside the shot, a holding one lets it right out to the edge before moving at all.
    @Test func aHoldingZoomGivesWayLaterThanAFollowingOne() {
        let roam = track([(0, middle), (3, CGPoint(x: 700, y: 400)), (6, CGPoint(x: 120, y: 90))])
        let following = worstReach(timeline(follows: true), roam, from: 2.0, to: 8.5)
        let holding = worstReach(timeline(follows: false), roam, from: 2.0, to: 8.5)
        #expect(holding > following, "holding: \(holding), following: \(following)")
        #expect(following <= 0.87, "a following camera keeps it comfortably inside")
    }

    /// A tighter dead zone lets the pointer drag the camera sooner.
    @Test func theDeadZoneIsTheSettingThatDecidesWhen() {
        let walk = track([(0, middle), (4, CGPoint(x: middle.x + 70, y: 250))])
        var wide = timeline()
        wide.camera.safeArea = 0.95
        var tight = timeline()
        tight.camera.safeArea = 0.2

        #expect(abs(centre(wide, walk, at: 4) - 0.5) < 0.001, "inside a wide dead zone")
        #expect(centre(tight, walk, at: 4).x > 0.51, "outside a tight one")
    }

    // MARK: - Determinism

    /// The framing at a moment does not depend on how you got there.
    @Test func theFramingIsTheSameHoweverYouArriveAtTheMoment() {
        let edit = timeline()
        let walk = track([(0, middle), (3, CGPoint(x: 700, y: 400)), (6, CGPoint(x: 120, y: 90))])
        let probes = stride(from: 1.0, through: 9.0, by: 0.05).map { $0 }

        let forwards = probes.map { centre(edit, walk, at: $0) }
        let backwards = probes.reversed().map { centre(edit, walk, at: $0) }.reversed()
        #expect(Array(backwards) == forwards)

        for (index, at) in probes.enumerated().shuffled() {
            #expect(centre(edit, walk, at: at) == forwards[index], "jumping to \(at)")
        }
    }

    /// No steps in the movement, even while the pointer is dragging the camera about.
    @Test func theCameraNeverJumps() {
        let edit = timeline()
        let roaming = track([(0, middle), (3, CGPoint(x: 760, y: 460)), (6, CGPoint(x: 40, y: 40)), (9, middle)])
        var previous = centre(edit, roaming, at: 1)
        for step in 1...(8 * 60) {
            let at = 1 + Double(step) / 60
            let now = centre(edit, roaming, at: at)
            #expect(abs(now.x - previous.x) < 0.05, "a step at \(at)")
            #expect(abs(now.y - previous.y) < 0.05, "a step at \(at)")
            previous = now
        }
    }
}

private func - (lhs: CGPoint, rhs: Double) -> Double {
    // Only ever used to compare a centre against the middle of the frame, on both axes at
    // once — the tests above read better for it than two subtractions would.
    max(abs(lhs.x - rhs), abs(lhs.y - rhs))
}
