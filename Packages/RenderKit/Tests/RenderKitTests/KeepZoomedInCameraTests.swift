import CoreGraphics
import CoreMedia
import Foundation
import Testing
import TimelineKit
@testable import RenderKit

/// The camera staying zoomed in across a gap it would otherwise pull back through.
struct KeepZoomedInCameraTests {
    private func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600) }

    private func timeline(keep: Double) -> Timeline {
        var timeline = Timeline(sourceDuration: time(30))
        timeline.style.padding = 0
        timeline.cursor.isVisible = false
        timeline.camera.glidesBetweenZooms = true
        timeline.camera.keepsZoomedInFor = keep
        // Three seconds apart: far more than the two half-second ramps.
        timeline.zooms = [ZoomRegion(start: time(2), duration: time(4), scale: 3,
                                     center: CGPoint(x: 0.25, y: 0.3), easing: .easeInOut,
                                     transition: time(0.5), followsCursor: false),
                          ZoomRegion(start: time(9), duration: time(4), scale: 2,
                                     center: CGPoint(x: 0.75, y: 0.7), easing: .easeInOut,
                                     transition: time(0.5), followsCursor: false)]
        return timeline
    }

    private func zoom(_ timeline: Timeline, at frame: Int) -> Double {
        SceneBuilder(videoSize: CGSize(width: 1_600, height: 1_000), displayScale: 2)
            .descriptor(for: timeline, at: CMTime(value: CMTimeValue(frame), timescale: 60)).zoom
    }

    @Test func withoutItTheCameraPullsBackInTheGap() {
        #expect(abs(zoom(timeline(keep: 0), at: 7 * 60) - 1) < 0.001)
    }

    @Test func withItTheCameraNeverPullsBack() {
        let kept = timeline(keep: 4)
        // Every frame from inside the first zoom to inside the second stays at or above the
        // wider of the two shots.
        for frame in (3 * 60)...(12 * 60) {
            #expect(zoom(kept, at: frame) >= 2 - 0.001, "frame \(frame)")
        }
        // Held on the first shot through most of the gap, then arriving at the second.
        #expect(abs(zoom(kept, at: 7 * 60) - 3) < 0.001)
        #expect(abs(zoom(kept, at: 10 * 60) - 2) < 0.001)
    }
}
