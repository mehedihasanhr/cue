import CoreGraphics
import CoreMedia
import Foundation
import Testing
import TimelineKit
@testable import RenderKit

/// A moving camera, in the frames the preview and the export both build.
struct CameraMoveRenderTests {
    private func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600) }
    private let output = CGSize(width: 1920, height: 1080)
    private let left = CameraPlacement(centre: CGPoint(x: 0.25, y: 0.25), size: 0.2)
    private let right = CameraPlacement(centre: CGPoint(x: 0.75, y: 0.75), size: 0.4)

    private func builder() -> SceneBuilder {
        SceneBuilder(videoSize: output, displayScale: 1)
    }

    private func moved() -> Timeline {
        var t = Timeline(sourceDuration: time(30))
        t.webcam.isEnabled = true
        t.webcam.reactsToZoom = false
        _ = Commands.PlaceCamera(at: time(5), placement: left).apply(to: &t)
        _ = Commands.PlaceCamera(at: time(15), placement: right).apply(to: &t)
        return t
    }

    private func rect(_ t: Timeline, _ s: Double) throws -> CGRect {
        try #require(builder().descriptor(for: t, at: time(s)).webcam).rect
    }

    @Test func noMovesIsTheFrameItAlwaysWas() throws {
        var t = Timeline(sourceDuration: time(30))
        t.webcam.isEnabled = true
        var marked = t
        marked.cameraLayouts = [CameraLayoutRegion(start: time(2), duration: time(5), layout: .bubble)]
        #expect(builder().descriptor(for: t, at: time(4)) == builder().descriptor(for: marked, at: time(4)))
    }

    @Test func settledItIsWhereItWasPut() throws {
        let r = try rect(moved(), 10)
        #expect(abs(r.midX - 0.25) < 0.001 && abs(r.midY - 0.25) < 0.001)
        #expect(abs(r.height - 0.2) < 0.001, "size is a fraction of the shorter side")
    }

    @Test func resizingGrowsIt() throws {
        let t = moved()
        #expect(try rect(t, 20).height > rect(t, 10).height * 1.9)
    }

    @Test func itTravelsAndGrowsTogetherWithoutAJump() throws {
        let t = moved()
        let glide = Timeline.cameraMoveTransition
        var previous = try rect(t, 15 - glide)
        var biggest = 0.0
        for step in 1...30 {
            let now = try rect(t, 15 - glide + glide * Double(step) / 30)
            #expect(now.midX >= previous.midX - 1e-9, "never backs up")
            #expect(now.height >= previous.height - 1e-9)
            biggest = max(biggest, abs(now.midX - previous.midX))
            previous = now
        }
        #expect(biggest < 0.06, "no frame covers more than a small part of the way")
        #expect(abs(previous.midX - 0.75) < 0.001)
    }

    @Test func theCornersKeepTheShape() throws {
        let t = moved()
        let scene = builder().descriptor(for: t, at: time(15 - Timeline.cameraMoveTransition / 2))
        let bubble = try #require(scene.webcam)
        #expect(abs(bubble.cornerRadius - bubble.rect.height * output.height / 2) < 0.5, "still a circle part way")
    }

    @Test func aBubbleDraggedPastTheEdgeStaysInFrame() throws {
        var t = Timeline(sourceDuration: time(30))
        t.webcam.isEnabled = true
        _ = Commands.PlaceCamera(at: time(5), placement: CameraPlacement(centre: CGPoint(x: 2, y: -1), size: 0.9)).apply(to: &t)
        let r = try rect(t, 10)
        #expect(r.minX >= 0 && r.maxX <= 1.0001 && r.minY >= 0 && r.maxY <= 1.0001)
    }
}
