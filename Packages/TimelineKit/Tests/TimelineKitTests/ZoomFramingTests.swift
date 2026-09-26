import CoreMedia
import Foundation
import Testing
@testable import TimelineKit

/// Framing a zoom as a rectangle of the recording.
///
/// The editor lets a zoom be drawn as a box on the picture rather than set as a centre and
/// a scale, and the conversion between the two is the part that can be quietly wrong: a box
/// that means one thing to the overlay and another to the renderer puts the shot somewhere
/// nobody asked for. The arithmetic lives here, away from any view.
struct ZoomFramingTests {
    /// What the editor does: a scale and a centre, from a rectangle.
    private func framing(_ rect: CGRect) -> (scale: Double, centre: CGPoint) {
        let scale = min(ZoomRegion.maximumScale, max(1, 1 / rect.width))
        let half = 0.5 / scale
        return (scale, CGPoint(x: min(1 - half, max(half, rect.midX)),
                               y: min(1 - half, max(half, rect.midY))))
    }

    /// And the inverse: the rectangle a zoom currently frames.
    private func area(scale: Double, centre: CGPoint) -> CGRect {
        let side = 1 / max(1, scale)
        return CGRect(x: centre.x - side / 2, y: centre.y - side / 2, width: side, height: side)
    }

    @Test func halfThePictureIsTwiceTheZoom() {
        let framed = framing(CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        #expect(abs(framed.scale - 2) < 0.0001)
        #expect(abs(framed.centre.x - 0.5) < 0.0001)
        #expect(abs(framed.centre.y - 0.5) < 0.0001)
    }

    @Test func thewholePictureIsNoZoomAtAll() {
        #expect(abs(framing(CGRect(x: 0, y: 0, width: 1, height: 1)).scale - 1) < 0.0001)
    }

    /// A box dragged larger than the picture cannot mean "zoom out past the recording".
    @Test func aBoxBiggerThanThePictureIsStillNoZoom() {
        #expect(framing(CGRect(x: -0.2, y: -0.2, width: 1.6, height: 1.6)).scale == 1)
    }

    @Test func aBoxDraggedTinyStopsAtTheDeepestZoom() {
        #expect(framing(CGRect(x: 0.5, y: 0.5, width: 0.001, height: 0.001)).scale
                == ZoomRegion.maximumScale)
    }

    /// The round trip that matters: what is drawn is what is framed, and framing it again
    /// changes nothing.
    @Test(arguments: [0.2, 0.35, 0.5, 0.8])
    func framingARectangleAndReadingItBackGivesTheSameRectangle(side: Double) {
        let asked = CGRect(x: 0.5 - side / 2, y: 0.5 - side / 2, width: side, height: side)
        let framed = framing(asked)
        let read = area(scale: framed.scale, centre: framed.centre)
        #expect(abs(read.width - side) < 0.0001)
        #expect(abs(read.midX - 0.5) < 0.0001)
        #expect(abs(read.midY - 0.5) < 0.0001)

        // And again, from what was read — a second pass must not drift.
        let again = framing(read)
        #expect(abs(again.scale - framed.scale) < 0.0001)
        #expect(abs(again.centre.x - framed.centre.x) < 0.0001)
    }

    /// A box dragged off the edge frames the corner, not a shot half outside the recording.
    @Test func aBoxPushedOffTheEdgeIsPulledBackInside() {
        let framed = framing(CGRect(x: -0.3, y: -0.3, width: 0.25, height: 0.25))
        let half = 0.5 / framed.scale
        #expect(framed.centre.x >= half - 0.0001)
        #expect(framed.centre.y >= half - 0.0001)

        let far = framing(CGRect(x: 0.95, y: 0.95, width: 0.25, height: 0.25))
        #expect(far.centre.x <= 1 - half + 0.0001)
        #expect(far.centre.y <= 1 - half + 0.0001)
    }

    /// The centre is derived from the *clamped* scale, so a box asking for more
    /// magnification than the renderer allows still centres on what was drawn rather than
    /// drifting to the middle.
    @Test func aBoxTighterThanAllowedStillLooksWhereItWasDrawn() {
        let framed = framing(CGRect(x: 0.7, y: 0.2, width: 0.02, height: 0.02))
        #expect(framed.scale == ZoomRegion.maximumScale)
        let half = 0.5 / ZoomRegion.maximumScale
        #expect(abs(framed.centre.x - 0.71) < half)
        #expect(abs(framed.centre.y - 0.21) < half)
    }
}
