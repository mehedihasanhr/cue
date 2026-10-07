import Testing
@testable import TimelineKit

struct AnnotationAnimationPreviewTests {
    private func animation(_ entrance: AnnotationAnimation.Entrance = .fade,
                           _ exit: AnnotationAnimation.Exit = .fade,
                           in inLength: Double = 0.4, out outLength: Double = 0.4) -> AnnotationAnimation {
        var animation = AnnotationAnimation()
        animation.entrance = entrance
        animation.exit = exit
        animation.entranceDuration = inLength
        animation.exitDuration = outLength
        return animation
    }

    @Test func theEntranceComesInAndThenHolds() throws {
        let preview = AnnotationAnimationPreview(part: .entrance, animation: animation(), duration: 3)
        #expect(preview.offset(at: 0) == 0)
        #expect(preview.offset(at: 0.2) == 0.2)
        #expect(preview.offset(at: 0.6) == 0.4, "held at full strength")
        #expect(preview.offset(at: preview.length) == nil, "and then over")
        // Drawn through the real pose: invisible at the start, whole at the hold.
        let a = animation()
        #expect(a.pose(atOffset: try #require(preview.offset(at: 0)), of: 3).opacity < 0.01)
        #expect(a.pose(atOffset: try #require(preview.offset(at: 0.6)), of: 3).opacity > 0.99)
    }

    @Test func theExitHoldsThenGoesOut() throws {
        let a = animation()
        let preview = AnnotationAnimationPreview(part: .exit, animation: a, duration: 3)
        #expect(a.pose(atOffset: try #require(preview.offset(at: 0.1)), of: 3).opacity > 0.99, "whole first")
        let gone = try #require(preview.offset(at: AnnotationAnimationPreview.hold + 0.4 + 0.1))
        #expect(gone == 3, "at its very end")
        #expect(preview.offset(at: preview.length) == nil)
    }

    @Test func theChainRunsInHoldOut() throws {
        let preview = AnnotationAnimationPreview(part: .chain, animation: animation(), duration: 3)
        var last = -1.0
        var elapsed = 0.0
        while let offset = preview.offset(at: elapsed) {
            #expect(offset >= last - 1e-9, "never goes backwards")
            last = offset
            elapsed += 1.0 / 30
        }
        #expect(last == 3)
        #expect(abs(elapsed - preview.length) < 1.0 / 15)
    }

    @Test func noneHasNothingToPlay() {
        #expect(!AnnotationAnimationPreview(part: .entrance, animation: animation(.none), duration: 3).hasMotion)
        #expect(AnnotationAnimationPreview(part: .entrance, animation: animation(.none), duration: 3).offset(at: 0) == nil)
        #expect(!AnnotationAnimationPreview(part: .chain, animation: animation(.none, .none), duration: 3).hasMotion)
        #expect(AnnotationAnimationPreview(part: .chain, animation: animation(.none, .fade), duration: 3).hasMotion)
    }

    /// On a short annotation each end is held to half of it, as the renderer holds it, and the
    /// hold sits where both meet.
    @Test func aShortAnnotationKeepsItsEndsApart() throws {
        let preview = AnnotationAnimationPreview(part: .chain, animation: animation(in: 2, out: 2), duration: 1)
        #expect(preview.inLength == 0.5 && preview.outLength == 0.5)
        #expect(preview.offset(at: 0.7) == 0.5)
    }
}
