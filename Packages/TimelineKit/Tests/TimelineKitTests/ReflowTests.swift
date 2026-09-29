import CoreMedia
import Foundation
import Testing
@testable import TimelineKit

/// What happens to the things sitting on top of the footage when the footage changes
/// length underneath them.
struct ReflowTests {
    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    private func timeline(zoomsAt seconds: [Double], length: Double = 2) -> Timeline {
        var timeline = Timeline(sourceDuration: time(30))
        timeline.zooms = seconds.map { ZoomRegion(start: time($0), duration: time(length)) }
        return timeline
    }

    /// The invariant that has to survive every one of these.
    private func expectContiguous(_ timeline: Timeline, _ comment: Comment) {
        let sum = timeline.clips.reduce(CMTime.zero) { $0 + $1.duration }
        #expect(abs((timeline.duration - sum).seconds) < 1e-9, comment)
    }

    // MARK: - Trimming

    @Test func trimmingTheHeadPullsLaterZoomsBackWithTheFootage() {
        var timeline = timeline(zoomsAt: [10])
        let id = timeline.clips[0].id

        // Take two seconds off the front: what was at ten is now at eight.
        ClipSequence.trim(&timeline, clipID: id, head: time(2), tail: nil)

        #expect(abs(timeline.zooms[0].start.seconds - 8) < 1e-6)
        expectContiguous(timeline, "trimming must not leave a gap")
    }

    @Test func trimmingTheTailLeavesEarlierZoomsAlone() {
        var timeline = timeline(zoomsAt: [4])
        let id = timeline.clips[0].id
        ClipSequence.trim(&timeline, clipID: id, head: nil, tail: time(20))

        #expect(timeline.zooms[0].start == time(4))
    }

    @Test func trimmingAMiddleClipMovesOnlyWhatComesAfterIt() {
        var timeline = timeline(zoomsAt: [2, 25])
        ClipSequence.split(&timeline, at: time(10))
        ClipSequence.split(&timeline, at: time(20))
        let middle = timeline.clips[1].id

        // The middle clip loses two seconds off its front.
        ClipSequence.trim(&timeline, clipID: middle,
                          head: timeline.clips[1].sourceStart + time(2), tail: nil)

        #expect(timeline.zooms[0].start == time(2), "a zoom before the change does not move")
        #expect(abs(timeline.zooms[1].start.seconds - 23) < 1e-6)
        expectContiguous(timeline, "trimming a middle clip must not leave a gap")
    }

    // MARK: - Speed

    @Test func speedingUpAStretchPullsLaterZoomsBackByExactlyTheDelta() {
        var timeline = timeline(zoomsAt: [25])
        // Ten seconds at 2× become five.
        ClipSequence.setSpeed(&timeline, range: CMTimeRange(start: .zero, end: time(10)), speed: 2)

        #expect(abs(timeline.duration.seconds - 25) < 1e-6)
        #expect(abs(timeline.zooms[0].start.seconds - 20) < 1e-6)
        expectContiguous(timeline, "a speed change must not leave a gap")
    }

    @Test func aZoomInsideASpedRangeIsSqueezedWithIt() {
        var timeline = timeline(zoomsAt: [4], length: 2)
        ClipSequence.setSpeed(&timeline, range: CMTimeRange(start: .zero, end: time(10)), speed: 2)

        // Half the length, half the offset: the zoom still covers the same footage.
        #expect(abs(timeline.zooms[0].start.seconds - 2) < 1e-6)
        #expect(abs(timeline.zooms[0].duration.seconds - 1) < 1e-6)
    }

    @Test func slowingDownPushesLaterZoomsLater() {
        var timeline = timeline(zoomsAt: [20])
        ClipSequence.setSpeed(&timeline, range: CMTimeRange(start: .zero, end: time(10)), speed: 0.5)

        #expect(abs(timeline.duration.seconds - 40) < 1e-6)
        #expect(abs(timeline.zooms[0].start.seconds - 30) < 1e-6)
    }

    @Test func aZoomStraddlingTheEndOfTheRangeIsClampedNotDropped() {
        var timeline = timeline(zoomsAt: [9], length: 4)   // 9 … 13, across the cut at 10
        ClipSequence.setSpeed(&timeline, range: CMTimeRange(start: .zero, end: time(10)), speed: 2)

        #expect(timeline.zooms.count == 1, "an effect the user placed is not thrown away")
        #expect(timeline.zooms[0].duration >= Clip.minimumDuration)
    }

    @Test func nothingEverEndsUpShorterThanAClipMayBe() {
        var timeline = timeline(zoomsAt: [0.5], length: 0.2)
        ClipSequence.setSpeed(&timeline, range: CMTimeRange(start: .zero, end: time(10)), speed: 8)

        for zoom in timeline.zooms {
            #expect(zoom.duration >= Clip.minimumDuration)
        }
    }

    @Test func theOldBehaviourIsStillAvailableWhenItIsWanted() throws {
        var timeline = timeline(zoomsAt: [20])
        ClipSequence.setSpeed(&timeline, range: CMTimeRange(start: .zero, end: time(10)),
                              speed: 2, movesRegions: false)

        let zoom = try #require(timeline.zooms.first)
        #expect(zoom.start == time(20), "left exactly where it was put")
    }

    /// Why the default changed: without it, a zoom near the end of a shortened timeline
    /// is not merely late, it is gone.
    @Test func leavingRegionsBehindCanClampThemOutOfExistence() {
        var timeline = timeline(zoomsAt: [25])
        ClipSequence.setSpeed(&timeline, range: CMTimeRange(start: .zero, end: time(10)),
                              speed: 2, movesRegions: false)
        #expect(timeline.zooms.isEmpty)

        var followed = self.timeline(zoomsAt: [25])
        ClipSequence.setSpeed(&followed, range: CMTimeRange(start: .zero, end: time(10)), speed: 2)
        #expect(followed.zooms.count == 1)
    }

    // MARK: - Positions are derived, so nothing needs reflowing

    @Test func clipPositionsFollowTheirNeighboursLengthsWithoutBeingTold() {
        var timeline = Timeline(sourceDuration: time(30))
        ClipSequence.split(&timeline, at: time(10))
        ClipSequence.split(&timeline, at: time(20))
        #expect(timeline.start(ofClipAt: 2) == time(20))

        ClipSequence.setSpeed(&timeline, range: CMTimeRange(start: .zero, end: time(10)), speed: 2)
        #expect(timeline.start(ofClipAt: 1) == time(5))
        #expect(timeline.start(ofClipAt: 2) == time(15))
        expectContiguous(timeline, "positions are derived, so they cannot disagree")
    }
}
