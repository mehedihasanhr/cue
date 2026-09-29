import CoreMedia
import Foundation
import Testing
@testable import TimelineKit

/// Two ways regions used to slide off their footage during ordinary cuts and speed
/// changes, found while teaching those edits about freeze frames.
struct ClipDriftTests {
    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    private func close(_ a: CMTime, _ b: CMTime, within tolerance: Double = 0.002) -> Bool {
        abs((a - b).seconds) < tolerance
    }

    /// A delete whose start is a sliver before a cut cannot cut there, so the clip in front
    /// stays whole. The regions used to move back by the whole length asked for anyway, and
    /// everything after sat early by the sliver.
    @Test func aDeleteThatCannotCutAtItsStartMovesRegionsByWhatWent() {
        var timeline = Timeline(sourceDuration: time(30))
        ClipSequence.split(&timeline, at: time(3))
        ClipSequence.split(&timeline, at: time(10))
        timeline.zooms = [ZoomRegion(start: time(20), duration: time(2))]   // on source 20 s

        // 2.95 is a twentieth before the cut: too close to cut, so only 3…10 can go.
        #expect(ClipSequence.delete(&timeline, range: CMTimeRange(start: time(2.95), end: time(10))))
        #expect(timeline.duration == time(23))
        #expect(timeline.zooms[0].start == time(13))
        #expect(timeline.sourceTime(at: timeline.zooms[0].start) == time(20), "on the frame it was placed on")
    }

    /// Setting one speed across clips that were at different speeds changes each by a
    /// different factor. Retimed as one stretch, everything inside drifted.
    @Test func oneSpeedAcrossClipsAtDifferentSpeedsKeepsRegionsOnTheirFrames() {
        var timeline = Timeline(sourceDuration: time(40))
        ClipSequence.split(&timeline, at: time(20))
        ClipSequence.setSpeed(&timeline, range: CMTimeRange(start: time(20), end: time(40)), speed: 2)
        // Now 0…20 at 1× and 20…30 at 2× (source 20…40).
        timeline.zooms = [ZoomRegion(start: time(10), duration: time(1)),      // source 10
                          ZoomRegion(start: time(25), duration: time(1))]      // source 30
        let sources = timeline.zooms.map { timeline.sourceTime(at: $0.start) }

        #expect(ClipSequence.setSpeed(&timeline, range: CMTimeRange(start: .zero, end: time(30)), speed: 4))
        #expect(timeline.duration == time(10))
        for (zoom, source) in zip(timeline.zooms, sources) {
            let now = timeline.sourceTime(at: zoom.start) ?? .zero
            #expect(close(now, source ?? .zero, within: 0.01), "zoom at \(zoom.start.seconds) left its frame")
        }
    }

    /// Asking for a speed past the limit on a clip already at the limit changes nothing,
    /// and so must not be an edit that lands on the undo stack.
    @Test func aSpeedPastTheLimitOnAClipAtTheLimitIsNotAnEdit() {
        var timeline = Timeline(sourceDuration: time(40))
        ClipSequence.setSpeed(&timeline, range: CMTimeRange(start: .zero, end: time(40)), speed: 8)
        let before = timeline
        #expect(!ClipSequence.setSpeed(&timeline, range: CMTimeRange(start: .zero, end: timeline.duration), speed: 20))
        #expect(timeline == before)
    }
}
