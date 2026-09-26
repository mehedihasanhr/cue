import CoreMedia
import Foundation
import Testing
@testable import TimelineKit

/// What a drag is asking for.
///
/// Deliberately not about clamping: the command decides what is allowed, so that a preview
/// and the edit it turns into cannot disagree. These cover the part that is genuinely the
/// gesture's — which end moves, which end stays, and that a slow drag lands where a fast
/// one does.
struct DragGeometryTests {
    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    private func proposal(_ grip: DragGeometry.Grip,
                          by offset: Double,
                          start: Double = 10,
                          duration: Double = 5) -> (start: CMTime, duration: CMTime) {
        DragGeometry.proposal(start: time(start), duration: time(duration),
                              grip: grip, offset: time(offset))
    }

    // MARK: - Moving

    @Test func movingSlidesWithoutChangingLength() {
        let moved = proposal(.body, by: 4)
        #expect(moved.start == time(14))
        #expect(moved.duration == time(5))
    }

    @Test func movingBackwardsAsksToGoBackwards() {
        // Asking to go before zero is allowed here; the command is what refuses, so that
        // one piece of code decides it. See `MoveManyTests`.
        #expect(proposal(.body, by: -40).start == time(-30))
    }

    // MARK: - Resizing

    @Test func draggingTheHeadLeavesTheTailWhereItIs() {
        let sized = proposal(.head, by: 2)
        #expect(sized.start == time(12))
        #expect(sized.start + sized.duration == time(15))
    }

    @Test func draggingTheTailLeavesTheHeadWhereItIs() {
        let sized = proposal(.tail, by: 3)
        #expect(sized.start == time(10))
        #expect(sized.duration == time(8))
    }

    /// The one limit that is the gesture's own, because the command cannot see it: it is
    /// handed absolute positions, so it has no way to know which end the pointer held.
    @Test func anEndCannotBeDraggedPastTheOther() {
        let head = proposal(.head, by: 20)
        #expect(head.duration == Clip.minimumDuration)
        #expect(head.start + head.duration == time(15), "the tail did not move")

        let tail = proposal(.tail, by: -20)
        #expect(tail.duration == Clip.minimumDuration)
        #expect(tail.start == time(10), "the head did not move")
    }

    // MARK: - No drift

    /// Every frame is measured from where the gesture began, so a drag applied in one step
    /// and the same drag applied in a hundred land in the same place.
    @Test func aSlowDragEndsWhereAFastOneDoes() {
        let once = proposal(.body, by: 7)
        var offset = 0.0
        for _ in 0..<100 { offset += 0.07 }
        let gradually = proposal(.body, by: offset)
        #expect(abs((once.start - gradually.start).seconds) < 0.001)
    }

    @Test func noOffsetChangesNothing() {
        for grip in [DragGeometry.Grip.body, .head, .tail] {
            let still = proposal(grip, by: 0)
            #expect(still.start == time(10))
            #expect(still.duration == time(5))
        }
    }

    // MARK: - Finding a region again

    /// What the preview reads to find out where the thing it just moved ended up.
    @Test func aRegionCanBeFoundOnWhicheverLaneItIsOn() {
        let zoom = ZoomRegion(start: time(2), duration: time(3))
        let blur = BlurRegion(start: time(8), duration: time(4),
                              rect: CGRect(x: 0, y: 0, width: 0.5, height: 0.5))
        let timeline = Timeline(sourceDuration: time(60), zooms: [zoom], blurs: [blur])

        #expect(timeline.range(ofRegion: zoom.id)?.start == time(2))
        #expect(timeline.range(ofRegion: blur.id)?.duration == time(4))
        #expect(timeline.range(ofRegion: UUID()) == nil)
    }

    @Test func aDetachedSoundRunCanBeFoundToo() {
        let run = SoundRun(start: time(5), duration: time(2), sourceStart: .zero)
        let timeline = Timeline(sourceDuration: time(60), detachedSound: [run])
        #expect(timeline.range(ofRegion: run.id)?.start == time(5))
    }
}
