import CoreGraphics
import CoreMedia
import Foundation
import Testing
import TimelineKit
@testable import RenderKit

/// What the camera costs as a project fills up with zooms.
///
/// The baseline the later optimisation work is judged against, and the reason to measure
/// before optimising: `SceneBuilder.camera` walks every zoom on the timeline for every
/// frame it describes, which is the shape of cost that looks alarming on paper and may be
/// nothing at all in practice. 10,000 regions × 60 frames a second is a number worth
/// knowing rather than guessing, and an index is worth building only if this says so.
///
/// Off by default, like the other benchmarks:
///
///     KLIK_BENCH=1 swift test --filter ZoomScaleBenchmarks
@Suite(.enabled(if: ProcessInfo.processInfo.environment["KLIK_BENCH"] != nil,
                "set KLIK_BENCH=1 to measure"),
       .serialized,
       .timeLimit(.minutes(5)))
struct ZoomScaleBenchmarks {
    /// A project with `count` zooms spread across an hour, each two seconds long with a
    /// gap — the shape a long recording with a lot of clicking in it actually produces.
    private func timeline(zooms count: Int) -> Timeline {
        let span = 3_600.0
        let step = span / Double(max(1, count))
        var timeline = Timeline(sourceDuration: RenderWorkload.time(span))
        timeline.cursor.isVisible = false
        timeline.zooms = (0..<count).map { index in
            ZoomRegion(start: RenderWorkload.time(Double(index) * step),
                       duration: RenderWorkload.time(min(2, step * 0.8)),
                       scale: 2 + Double(index % 3) * 0.5,
                       center: CGPoint(x: 0.3 + Double(index % 5) / 10,
                                       y: 0.3 + Double(index % 7) / 10),
                       source: .click)
        }
        return timeline
    }

    /// Frames scattered across the whole hour rather than taken from one stretch: a scrub
    /// lands anywhere, and a walk through the first two seconds would measure a warm cache
    /// that scrubbing never has.
    private func probes(_ count: Int, span: Double = 3_600) -> [CMTime] {
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { _ in RenderWorkload.time(Double.random(in: 0..<span, using: &generator)) }
    }

    @Test func describingAFrameAsTheLaneFillsUp() {
        let builder = RenderWorkload.builder()
        let times = probes(2_000)

        for count in [0, 100, 1_000, 10_000] {
            let timeline = timeline(zooms: count)
            // Warmed, so the first call's lazy work is not charged to the measurement.
            _ = builder.descriptor(for: timeline, at: times[0])

            let started = Date()
            for at in times { _ = builder.descriptor(for: timeline, at: at) }
            let each = Date().timeIntervalSince(started) / Double(times.count) * 1_000_000
            RenderWorkload.report("descriptor · \(count) zooms", microseconds: each,
                                  extra: String(format: "%.1f× the empty lane",
                                                count == 0 ? 1 : each))
        }
    }

    /// The evaluator alone, with the layout arithmetic taken out — this is the part that
    /// grows with the lane, and separating it says whether an index would help the frame
    /// or only help this loop.
    @Test func evaluatingTheCameraAlone() {
        let times = probes(5_000)
        for count in [100, 1_000, 10_000] {
            let timeline = timeline(zooms: count)
            let started = Date()
            var deepest = 0.0
            for at in times {
                for zoom in timeline.zooms {
                    deepest = max(deepest, zoom.scale(at: at))
                }
            }
            let each = Date().timeIntervalSince(started) / Double(times.count) * 1_000_000
            RenderWorkload.report("camera scan · \(count) zooms", microseconds: each,
                                  extra: String(format: "deepest %.1f×", deepest))
        }
    }

    /// Scrubbing, which is the interaction this has to keep up with: sixty descriptions a
    /// second while the pointer drags along the ruler.
    @Test func scrubbingALongProject() {
        let builder = RenderWorkload.builder()
        let track = RenderWorkload.cursorTrack()
        for count in [1_000, 10_000] {
            let timeline = timeline(zooms: count)
            let times = probes(600)
            let started = Date()
            for at in times { _ = builder.descriptor(for: timeline, at: at, cursor: track) }
            let each = Date().timeIntervalSince(started) / Double(times.count) * 1_000_000
            RenderWorkload.report("scrub frame · \(count) zooms", microseconds: each,
                                  extra: each < 16_667 ? "inside a 60 fps frame" : "OVER a 60 fps frame")
        }
    }
}
