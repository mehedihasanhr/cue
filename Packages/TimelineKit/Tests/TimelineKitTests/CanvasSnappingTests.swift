import CoreGraphics
import Testing
@testable import TimelineKit

struct CanvasSnappingTests {
    private let stage = CGRect(x: 0, y: 0, width: 800, height: 450)

    @Test func aBoxNearTheMiddleSnapsToIt() {
        let box = CGRect(x: 353, y: 100, width: 100, height: 40)   // centre 403
        let (snapped, guides) = CanvasSnapping.snap(box, to: [], stage: stage)
        #expect(snapped.midX == 400)
        #expect(guides.contains { $0.axis == .vertical && $0.position == 400 })
    }

    @Test func farFromAnythingNothingMoves() {
        let box = CGRect(x: 120, y: 90, width: 100, height: 40)
        let (snapped, guides) = CanvasSnapping.snap(box, to: [], stage: stage)
        #expect(snapped == box && guides.isEmpty)
    }

    @Test func edgesLineUpWithAnotherBox() {
        let other = CGRect(x: 200, y: 300, width: 120, height: 30)
        let box = CGRect(x: 204, y: 120, width: 60, height: 20)
        let (snapped, guides) = CanvasSnapping.snap(box, to: [other], stage: stage)
        #expect(snapped.minX == 200)
        let guide = guides.first { $0.axis == .vertical }
        #expect(guide?.from == 120 && guide?.to == 330, "runs from this box to the one it lines up with")
    }

    @Test func theNearestLineWins() {
        let box = CGRect(x: 2, y: 3, width: 50, height: 50)
        let (snapped, _) = CanvasSnapping.snap(box, to: [CGRect(x: 5, y: 200, width: 10, height: 10)], stage: stage)
        #expect(snapped.minX == 0, "the frame's edge is 2 away, the other box's 3")
        #expect(snapped.minY == 0)
    }

    @Test func bothAxesSnapIndependently() {
        let box = CGRect(x: 697, y: 402, width: 100, height: 50)   // right at 797, bottom at 452
        let (snapped, guides) = CanvasSnapping.snap(box, to: [], stage: stage)
        #expect(snapped.maxX == 800 && snapped.maxY == 450)
        #expect(guides.count == 2)
    }
}
