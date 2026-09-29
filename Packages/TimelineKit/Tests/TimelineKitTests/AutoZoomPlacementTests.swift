import CoreGraphics
import CoreMedia
import Testing
@testable import TimelineKit

/// Auto-zoom reads the recording; its zooms must land where their moments are in the edit.
struct AutoZoomPlacementTests {
    private func t(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600) }
    private func zoom(_ start: Double, _ length: Double) -> ZoomRegion {
        ZoomRegion(start: t(start), duration: t(length), scale: 2, center: CGPoint(x: 0.5, y: 0.5))
    }
    private func near(_ time: CMTime, _ seconds: Double) -> Bool { abs(time.seconds - seconds) < 0.01 }

    @Test func anUncutEditIsUnchanged() {
        let timeline = Timeline(sourceDuration: t(30))
        let placed = timeline.placedOnTimeline([zoom(10, 2)])
        #expect(placed.count == 1 && near(placed[0].start, 10) && near(placed[0].duration, 2))
    }

    @Test func aZoomAfterACutMovesWithItsMoment() {
        var timeline = Timeline(sourceDuration: t(30))
        Commands.DeleteRanges([CMTimeRange(start: t(2), end: t(6))], name: "Cut").apply(to: &timeline)
        let placed = timeline.placedOnTimeline([zoom(10, 2)])
        #expect(placed.count == 1 && near(placed[0].start, 6))
    }

    @Test func aSpedUpMomentShrinksWithIt() {
        var timeline = Timeline(sourceDuration: t(30))
        ClipSequence.setSpeed(&timeline, range: CMTimeRange(start: t(8), end: t(16)), speed: 2)
        let placed = timeline.placedOnTimeline([zoom(10, 2)])
        #expect(placed.count == 1 && near(placed[0].start, 9) && near(placed[0].duration, 1))
    }

    @Test func aMomentThatWasCutGoes() {
        var timeline = Timeline(sourceDuration: t(30))
        Commands.DeleteRanges([CMTimeRange(start: t(9), end: t(13))], name: "Cut").apply(to: &timeline)
        #expect(timeline.placedOnTimeline([zoom(10, 2)]).isEmpty)
    }
}
