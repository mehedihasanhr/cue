import CoreGraphics
import CoreMedia
import Testing
import TimelineKit
@testable import RenderKit

/// The editor previews an annotation's animation on a paused frame by moving the annotation's
/// start so the playhead lands `offset` into its life. This is that, through the real scene
/// builder: the way in really fades in, and the way out really fades out.
struct AnnotationAnimationPreviewRenderTests {
    private let playhead = CMTime(seconds: 5, preferredTimescale: 600)

    private func opacity(_ preview: AnnotationAnimationPreview, at elapsed: Double) throws -> Double? {
        var timeline = Timeline(sourceDuration: CMTime(seconds: 30, preferredTimescale: 600))
        let offset = try #require(preview.offset(at: elapsed))
        var item = AnnotationItem(start: .zero, duration: CMTime(seconds: preview.duration, preferredTimescale: 600),
                                  kind: .rectangle, rect: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3))
        item.animation = preview.animation
        item.start = playhead - CMTime(seconds: offset, preferredTimescale: 6_000)
        timeline.annotations = [item]
        let scene = SceneBuilder(videoSize: CGSize(width: 1_600, height: 1_000)).descriptor(for: timeline, at: playhead)
        return scene.annotations.first?.opacity
    }

    @Test func theEntranceFadesInOnAStillPlayhead() throws {
        var animation = AnnotationAnimation()
        animation.entrance = .fade
        animation.entranceDuration = 0.4
        let preview = AnnotationAnimationPreview(part: .entrance, animation: animation, duration: 3)
        let start = try opacity(preview, at: 0.001) ?? 0
        let middle = try #require(try opacity(preview, at: 0.2))
        let held = try #require(try opacity(preview, at: 0.7))
        #expect(start < 0.05)
        #expect(middle > 0.2 && middle < 0.8)
        #expect(held > 0.99)
    }

    @Test func theExitFadesOutOnAStillPlayhead() throws {
        var animation = AnnotationAnimation()
        animation.exit = .fade
        animation.exitDuration = 0.4
        let preview = AnnotationAnimationPreview(part: .exit, animation: animation, duration: 3)
        let whole = try #require(try opacity(preview, at: 0.1))
        let leaving = try #require(try opacity(preview, at: AnnotationAnimationPreview.hold + 0.2))
        #expect(whole > 0.99)
        #expect(leaving > 0.2 && leaving < 0.8)
        // Once it has gone it is not drawn at all.
        #expect((try opacity(preview, at: AnnotationAnimationPreview.hold + 0.4 + 0.1)) ?? 0 < 0.05)
    }
}
