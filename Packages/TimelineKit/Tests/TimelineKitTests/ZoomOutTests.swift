import CoreGraphics
import CoreMedia
import Foundation
import Testing
@testable import TimelineKit

/// Zooming out: a zoom below 1× that shrinks the recording inside the frame.
///
/// The model half. What matters here is that the new range does not disturb anything that
/// was already true — old projects decode to exactly what they were, a zoom in eases as it
/// always did — and that the same curves and the same glide carry a pull back without a
/// step anywhere, including through 1× on the way from one kind to the other.
struct ZoomOutTests {
    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    private func zoom(start: Double = 2, duration: Double = 4, scale: Double,
                      center: CGPoint = CGPoint(x: 0.5, y: 0.5), ramp: Double = 0.5) -> ZoomRegion {
        ZoomRegion(start: time(start), duration: time(duration), scale: scale, center: center,
                   easing: .easeInOut, transition: time(ramp), followsCursor: false)
    }

    // MARK: - The range

    @Test func aZoomCanGoDownToHalfAndNoFurther() {
        #expect(zoom(scale: 0.5).scale == 0.5)
        #expect(zoom(scale: 0.75).scale == 0.75)
        #expect(zoom(scale: 0.1).scale == ZoomRegion.minimumScale)
        #expect(zoom(scale: 20).scale == ZoomRegion.maximumScale)
        #expect(zoom(scale: 0.5).zoomsOut)
        #expect(!zoom(scale: 1).zoomsOut)
        #expect(!zoom(scale: 2).zoomsOut)
    }

    /// A project written before zooming out existed stores only 1× and above, and decodes
    /// to exactly the zoom it was — the decoder clamps nothing, in either direction.
    @Test func anOldProjectsZoomDecodesUnchanged() throws {
        let old = zoom(scale: 2.5, center: CGPoint(x: 0.3, y: 0.6))
        var stored = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        // What a zoom looked like before the later fields: only the first seven keys.
        for key in ["transitionIn", "transitionOut", "source", "isLocked", "isEnabled", "isEdited", "isInstant"] {
            stored[key] = nil
        }
        let decoded = try JSONDecoder().decode(ZoomRegion.self, from: JSONSerialization.data(withJSONObject: stored))
        #expect(decoded == old)
        for probe in stride(from: 0.0, through: 8.0, by: 0.25) {
            #expect(decoded.scale(at: time(probe)) == old.scale(at: time(probe)))
        }
    }

    @Test func aZoomOutSurvivesARoundTrip() throws {
        let out = zoom(scale: 0.5)
        let decoded = try JSONDecoder().decode(ZoomRegion.self, from: JSONEncoder().encode(out))
        #expect(decoded.scale == 0.5)
        #expect(decoded == out)
    }

    // MARK: - The ramp

    /// Eased from 1× down to the zoom's scale and back up again: exactly 1 at both edges,
    /// the scale while it holds, never below it, and without a step between any two frames.
    @Test func aZoomOutEasesDownAndBackUp() {
        let out = zoom(scale: 0.5)
        #expect(out.scale(at: time(1.9)) == 1)
        #expect(out.scale(at: time(2)) == 1)
        #expect(abs(out.scale(at: time(4)) - 0.5) < 1e-9)
        #expect(out.scale(at: time(6)) == 1)

        var previous = out.scale(at: time(1.5))
        for frame in Int(1.5 * 60)...Int(6.5 * 60) {
            let value = out.scale(at: CMTime(value: CMTimeValue(frame), timescale: 60))
            #expect(value >= 0.5 - 1e-9 && value <= 1 + 1e-9)
            #expect(abs(value - previous) < 0.05, "stepped from \(previous) to \(value) at frame \(frame)")
            previous = value
        }
    }

    // MARK: - Strength

    /// Half and double are one doubling from 1× each, so neither beats the other by being
    /// "a bigger number".
    @Test func aPullBackIsAsStrongAsThePushInItMirrors() {
        #expect(abs(ZoomRegion.strength(ofScale: 0.5) - ZoomRegion.strength(ofScale: 2)) < 1e-12)
        #expect(ZoomRegion.strength(ofScale: 0.5) > ZoomRegion.strength(ofScale: 1.5))
        #expect(ZoomRegion.strength(ofScale: 1) == 0)
    }

    // MARK: - Where the camera may look

    @Test func atHalfTheCameraMayLookAnywhere() {
        for point in [CGPoint(x: 0, y: 0), CGPoint(x: 0.25, y: 0.8), CGPoint(x: 1, y: 1)] {
            #expect(ZoomFraming.cameraCenter(point, scale: 0.5) == point)
        }
    }

    /// Between 0.5× and 1× the shrunken picture may only move as far as keeps it inside the
    /// hole: at 0.8× that is a centre between 0.375 and 0.625.
    @Test func aShallowPullBackKeepsThePictureInsideTheHole() {
        let held = ZoomFraming.cameraCenter(CGPoint(x: 0, y: 1), scale: 0.8)
        #expect(abs(held.x - 0.375) < 1e-9)
        #expect(abs(held.y - 0.625) < 1e-9)
    }

    /// Crossing 1× — the moment a pull back becomes a push in — moves nothing.
    @Test func theCameraCentreIsContinuousThroughOne() {
        for point in [CGPoint(x: 0.1, y: 0.9), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.8, y: 0.2)] {
            let below = ZoomFraming.cameraCenter(point, scale: 0.9999)
            let at = ZoomFraming.cameraCenter(point, scale: 1)
            let above = ZoomFraming.cameraCenter(point, scale: 1.0001)
            #expect(hypot(below.x - at.x, below.y - at.y) < 1e-3)
            #expect(hypot(above.x - at.x, above.y - at.y) < 1e-3)
        }
    }

    /// A pull back has no framing box smaller than the recording: its framing is all of it.
    @Test func aPullBacksFramingIsTheWholeRecording() {
        let area = ZoomFraming.area(of: zoom(scale: 0.5, center: CGPoint(x: 0.2, y: 0.3)))
        #expect(abs(area.minX) < 1e-9 && abs(area.minY) < 1e-9)
        #expect(abs(area.width - 1) < 1e-9 && abs(area.height - 1) < 1e-9)
    }

    // MARK: - Gliding

    /// From a push in straight to a pull back: the scale travels between the two, through
    /// 1×, without a step and without ever leaving the range the two zooms span.
    @Test func aGlideFromInToOutIsContinuous() throws {
        let first = zoom(start: 2, duration: 4, scale: 2)
        let second = zoom(start: 6.2, duration: 4, scale: 0.5)
        let glide = try #require(ZoomLane.glides(in: [first, second]).first)
        #expect(glide.scale(at: glide.start) == 2)
        #expect(abs(glide.scale(at: glide.end) - 0.5) < 1e-9)

        var previous = glide.scale(at: glide.start)
        var frame = glide.start
        let step = CMTime(value: 1, timescale: 60)
        while frame <= glide.end {
            let value = glide.scale(at: frame)
            #expect(value >= 0.5 - 1e-9 && value <= 2 + 1e-9)
            #expect(abs(value - previous) < 0.1, "stepped from \(previous) to \(value)")
            previous = value
            frame = frame + step
        }
    }
}
