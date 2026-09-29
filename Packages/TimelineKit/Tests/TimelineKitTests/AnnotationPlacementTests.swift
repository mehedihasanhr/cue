import CoreGraphics
import CoreMedia
import Foundation
import Testing
@testable import TimelineKit

/// Where a label is allowed to sit.
///
/// Two rules pulling against each other: a label should go anywhere in the frame,
/// including hanging off an edge, and it must never end up somewhere the user cannot get
/// it back from. These pin down the line between them.
struct AnnotationPlacementTests {
    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    private func rect(_ x: Double, _ y: Double, _ w: Double = 0.3, _ h: Double = 0.1) -> CGRect {
        CGRect(x: x, y: y, width: w, height: h)
    }

    private func timeline(_ rect: CGRect) -> (Timeline, UUID) {
        let item = AnnotationItem(start: .zero, duration: time(3), kind: .text("Hi"), rect: rect)
        return (Timeline(sourceDuration: time(10), annotations: [item]), item.id)
    }

    private func placed(_ rect: CGRect) -> CGRect {
        var (edit, id) = timeline(self.rect(0.4, 0.4))
        _ = Commands.SetRegionRect(id: id, rect: rect).apply(to: &edit)
        return edit.annotations[0].rect
    }

    // MARK: - Anywhere

    @Test func aLabelStaysWhereItIsPutInsideTheFrame() {
        #expect(placed(rect(0.1, 0.8)) == rect(0.1, 0.8))
    }

    /// The thing that could not be done before: run a label off the edge of shot.
    @Test func aLabelMayHangOffAnEdge() {
        let left = placed(rect(-0.2, 0.5))
        #expect(left.minX == -0.2, "most of it is out of frame, and that is allowed")

        let top = placed(rect(0.5, -0.05))
        #expect(top.minY == -0.05)
    }

    @Test func aLabelMayHangOffTheFarEdgesToo() {
        let right = placed(rect(0.9, 0.5))
        #expect(right.minX == 0.9)
        #expect(right.maxX > 1, "it reaches past the right-hand edge")
    }

    // MARK: - But never lost

    /// The other half of the promise: something is always left to take hold of.
    ///
    /// Compared with a hair of slack, because the edge case is arrived at by subtracting
    /// the width and adding it back — `0.05 - 0.3 + 0.3` is not exactly `0.05` in binary,
    /// and a test that insists it is would be testing arithmetic rather than the rule.
    private let slack = 1e-9

    @Test func aLabelCannotBePushedRightOutOfTheFrame() {
        let far = placed(rect(-5, 0.5))
        #expect(far.maxX >= Commands.SetRegionRect.minimumVisible - slack)

        let beyond = placed(rect(5, 0.5))
        #expect(beyond.minX <= 1 - Commands.SetRegionRect.minimumVisible + slack)
    }

    @Test func aLabelCannotBePushedOffTheTopOrBottom() {
        #expect(placed(rect(0.5, -9)).maxY >= Commands.SetRegionRect.minimumVisible - slack)
        #expect(placed(rect(0.5, 9)).minY <= 1 - Commands.SetRegionRect.minimumVisible + slack)
    }

    @Test func aLabelIsNeverShrunkToNothing() {
        let tiny = placed(CGRect(x: 0.5, y: 0.5, width: 0, height: 0))
        #expect(tiny.width >= Commands.SetRegionRect.minimumSide)
        #expect(tiny.height >= Commands.SetRegionRect.minimumSide)
    }

    // MARK: - A blur is a different thing

    /// A blur is normalised to the recording, and a blur that is not over the recording
    /// hides nothing — so it keeps the stricter rule.
    @Test func aBlurStaysOverThePicture() {
        let blur = BlurRegion(start: .zero, duration: time(3), rect: rect(0.4, 0.4))
        var edit = Timeline(sourceDuration: time(10), blurs: [blur])
        _ = Commands.SetRegionRect(id: blur.id, rect: rect(-0.4, 0.5)).apply(to: &edit)

        #expect(edit.blurs[0].rect.minX == 0)
        #expect(edit.blurs[0].rect.maxX <= 1)
    }

    /// Moving something to where it already is is not an edit.
    @Test func aMoveThatChangesNothingSaysSo() {
        var (edit, id) = timeline(rect(0.4, 0.4))
        #expect(!Commands.SetRegionRect(id: id, rect: rect(0.4, 0.4)).apply(to: &edit))
        #expect(!Commands.SetRegionRect(id: UUID(), rect: rect(0.1, 0.1)).apply(to: &edit))
    }
}
