import CoreGraphics
import CoreMedia
import Testing
import TimelineKit
@testable import RenderKit

/// The camera the renderer actually builds, through a zoom aimed near an edge — the case
/// that used to wobble: the aimed point slid sideways as the zoom grew, and the scale went
/// past its depth and back.
struct ZoomPathRenderTests {
    private func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600) }

    @Test func aZoomNearTheTopGoesStraightInAndStraightOut() {
        var timeline = Timeline(sourceDuration: time(6))
        timeline.style.padding = 0
        let aim = CGPoint(x: 0.54, y: 0.1)
        timeline.zooms = [ZoomRegion(start: time(1), duration: time(3), scale: 1.8, center: aim,
                                     transition: time(0.9), followsCursor: false)]
        let builder = SceneBuilder(videoSize: CGSize(width: 1_600, height: 1_000), displayScale: 1)
        // Where the zoom ends up looking, once in: the aim, kept on the picture.
        let held = builder.descriptor(for: timeline, at: time(2.5))
        #expect(abs(held.zoom - 1.8) < 1e-9)

        var previous: CGPoint?
        var deepest = 0.0
        for frame in 0...(5 * 60) {
            let scene = builder.descriptor(for: timeline, at: time(Double(frame) / 60))
            deepest = max(deepest, scene.zoom)
            // Where the held shot's middle is on the screen at this frame.
            let onScreen = CGPoint(x: (held.zoomCenter.x - scene.zoomCenter.x) * scene.zoom + 0.5,
                                   y: (held.zoomCenter.y - scene.zoomCenter.y) * scene.zoom + 0.5)
            if let previous, frame <= 115 {
                // On the way in it only ever moves towards the middle…
                #expect(abs(onScreen.x - 0.5) <= abs(previous.x - 0.5) + 1e-9, "frame \(frame)")
                #expect(abs(onScreen.y - 0.5) <= abs(previous.y - 0.5) + 1e-9, "frame \(frame)")
            }
            previous = onScreen
        }
        #expect(deepest <= 1.8 + 1e-9, "never deeper than the zoom's own depth")
    }
}
