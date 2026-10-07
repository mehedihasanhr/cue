import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import Testing
import TimelineKit
@testable import RenderKit

/// What one preview frame costs while a label is dragged across the picture.
///
///     KLIK_BENCH=1 swift test --filter AnnotationDragBenchmarks
///
/// Each step moves the label and renders the frame the way the editor's preview does —
/// `cgImage(for:)`, read back — so the number is the lag between the pointer and the label
/// on screen. Measured at the export's size and at the preview's reduced size, because the
/// drag is only as smooth as the frame it waits for.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["KLIK_BENCH"] != nil,
                "set KLIK_BENCH=1 to measure"),
       .serialized,
       .timeLimit(.minutes(5)))
struct AnnotationDragBenchmarks {
    private let size = RenderWorkload.videoSize

    private func measure(_ name: String, fidelity: Double) throws {
        var timeline = Timeline(sourceDuration: RenderWorkload.time(60))
        timeline.style.padding = 0.06
        timeline.style.cornerRadius = 0.02
        timeline.style.shadowRadius = 0.02
        timeline.style.shadowOpacity = 0.35
        var label = AnnotationItem(start: .zero, duration: RenderWorkload.time(60),
                                   kind: .text("This is a dummy text"),
                                   rect: CGRect(x: 0.1, y: 0.4, width: 0.3, height: 0.2))
        label.fontSize = 0.08
        timeline.annotations = [label]
        let builder = SceneBuilder(videoSize: size)
        let renderer = SceneRenderer()
        let page = CIImage(cgImage: FollowingFootage.page(height: Int(size.height), seed: 3))
            .transformed(by: CGAffineTransform(scaleX: size.width / FollowingFootage.size.width, y: 1))
        let source = CIImage(cgImage: try #require(CIContext().createCGImage(page, from: CGRect(origin: .zero, size: size))))
        let each = RenderWorkload.median(count: 60, warmup: 5) { index in
            // A drag: the same frame, the label a little further along each time.
            timeline.annotations[0].rect.origin.x = 0.1 + Double(index % 60) * 0.008
            let scene = builder.descriptor(for: timeline, at: RenderWorkload.time(2)).scaled(by: fidelity)
            _ = renderer.cgImage(for: scene, source: source)
        }
        RenderWorkload.report("4K drag, \(name)", microseconds: each)
    }

    @Test func costs() throws {
        try measure("full size (still frame)", fidelity: 1)
        try measure("half size", fidelity: 0.5)
        try measure("three-eighths size", fidelity: 0.375)
    }
}
