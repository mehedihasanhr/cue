import CoreGraphics
import CoreMedia
import Foundation
import Testing
@testable import TimelineKit

/// Framing a zoom by dragging a rectangle on the picture.
///
/// A zoom is stored as a centre and a scale, because that is what the camera needs, and
/// edited as a rectangle, because that is what a person means. Everything here is about the
/// one conversion between those two readings staying honest in both directions — a box
/// dragged to a place and a camera that goes somewhere else is the whole class of bug this
/// type exists to make impossible.
struct ZoomFramingTests {
    private func zoom(scale: Double, center: CGPoint = CGPoint(x: 0.5, y: 0.5)) -> ZoomRegion {
        ZoomRegion(start: .zero, duration: CMTime(seconds: 2, preferredTimescale: 600),
                   scale: scale, center: center)
    }

    private func isClose(_ a: Double, _ b: Double, _ tolerance: Double = 1e-9) -> Bool {
        abs(a - b) < tolerance
    }

    // MARK: - The conversion itself
    //
    // These claims predate `ZoomFraming` and used to be checked against a private copy of
    // the arithmetic written out inside this file — which is to say they were testing a
    // reimplementation rather than the code that ships. They now go through the real thing,
    // which is the whole reason the conversion was moved out of the view layer.

    @Test func halfThePictureIsTwiceTheZoom() {
        let framed = ZoomFraming.honoured(CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        #expect(isClose(ZoomFraming.scale(forSide: framed.width), 2, 0.0001))
        #expect(isClose(framed.midX, 0.5, 0.0001))
        #expect(isClose(framed.midY, 0.5, 0.0001))
    }

    @Test func theWholePictureIsNoZoomAtAll() {
        let whole = ZoomFraming.honoured(CGRect(x: 0, y: 0, width: 1, height: 1))
        #expect(isClose(ZoomFraming.scale(forSide: whole.width), 1, 0.0001))
    }

    /// A box dragged larger than the picture cannot mean "zoom out past the recording".
    @Test func aBoxBiggerThanThePictureIsStillNoZoom() {
        let huge = ZoomFraming.honoured(CGRect(x: -0.2, y: -0.2, width: 1.6, height: 1.6))
        #expect(ZoomFraming.scale(forSide: huge.width) == 1)
    }

    @Test func aBoxDraggedTinyStopsAtTheDeepestZoom() {
        let tiny = ZoomFraming.honoured(CGRect(x: 0.5, y: 0.5, width: 0.001, height: 0.001))
        #expect(ZoomFraming.scale(forSide: tiny.width) == ZoomRegion.maximumScale)
    }

    /// The round trip that matters: what is drawn is what is framed, and framing it again
    /// changes nothing.
    @Test(arguments: [0.2, 0.35, 0.5, 0.8])
    func framingARectangleAndReadingItBackGivesTheSameRectangle(side: Double) {
        let asked = CGRect(x: 0.5 - side / 2, y: 0.5 - side / 2, width: side, height: side)
        let framed = ZoomFraming.honoured(asked)
        #expect(isClose(framed.width, side, 0.0001))
        #expect(isClose(framed.midX, 0.5, 0.0001))
        #expect(isClose(framed.midY, 0.5, 0.0001))

        // And again, from what was read — a second pass must not drift.
        let again = ZoomFraming.honoured(framed)
        #expect(isClose(again.width, framed.width, 0.0001))
        #expect(isClose(again.midX, framed.midX, 0.0001))
    }

    /// A box dragged off the edge frames the corner, not a shot half outside the recording.
    @Test func aBoxPushedOffTheEdgeIsPulledBackInside() {
        let near = ZoomFraming.honoured(CGRect(x: -0.3, y: -0.3, width: 0.25, height: 0.25))
        #expect(near.minX >= -0.0001 && near.minY >= -0.0001)

        let far = ZoomFraming.honoured(CGRect(x: 0.95, y: 0.95, width: 0.25, height: 0.25))
        #expect(far.maxX <= 1.0001 && far.maxY <= 1.0001)
    }

    /// The centre is derived from the *clamped* scale, so a box asking for more
    /// magnification than the renderer allows still centres on what was drawn rather than
    /// drifting to the middle.
    @Test func aBoxTighterThanAllowedStillLooksWhereItWasDrawn() {
        let framed = ZoomFraming.honoured(CGRect(x: 0.7, y: 0.2, width: 0.02, height: 0.02))
        #expect(ZoomFraming.scale(forSide: framed.width) == ZoomRegion.maximumScale)
        let half = 0.5 / ZoomRegion.maximumScale
        #expect(abs(framed.midX - 0.71) < half)
        #expect(abs(framed.midY - 0.21) < half)
    }

    // MARK: - Scale and framing agree

    @Test(arguments: [1.0, 1.5, 2.0, 3.7, 8.0])
    func aFramingsWidthIsTheZoomItStandsFor(scale: Double) {
        let area = ZoomFraming.area(of: zoom(scale: scale))
        #expect(isClose(ZoomFraming.scale(forSide: area.width), scale))
        #expect(isClose(area.width, 1 / scale))
    }

    /// The round trip that keeps the inspector and the box from drifting apart: a scale
    /// becomes a rectangle becomes the same scale, for every scale the slider offers.
    @Test func aScaleSurvivesBecomingARectangleAndBack() {
        for step in 0...40 {
            let scale = 1 + Double(step) * 0.175
            let area = ZoomFraming.area(of: zoom(scale: scale))
            let back = ZoomFraming.scale(forSide: ZoomFraming.honoured(area).width)
            #expect(isClose(back, min(scale, ZoomRegion.maximumScale), 1e-9), "at \(scale)")
        }
    }

    @Test func aSmallerBoxIsABiggerZoom() {
        #expect(ZoomFraming.scale(forSide: 0.25) > ZoomFraming.scale(forSide: 0.5))
        #expect(ZoomFraming.scale(forSide: 1) == 1)
    }

    // MARK: - Nothing is ever stretched

    /// A zoom magnifies both axes by one number, so a framing can only ever be square in
    /// normalised space — which is the recording's own aspect in pixels. This is the claim
    /// that means no framing, however drawn, can produce a stretched output.
    @Test(arguments: [
        CGRect(x: 0.1, y: 0.2, width: 0.6, height: 0.2),
        CGRect(x: 0, y: 0, width: 0.2, height: 0.9),
        CGRect(x: -0.4, y: 0.8, width: 1.8, height: 0.05),
    ])
    func aFramingIsAlwaysSquareInTheRecordingsOwnShape(drawn: CGRect) {
        let honoured = ZoomFraming.honoured(drawn)
        #expect(isClose(honoured.width, honoured.height))
    }

    /// And a drag on any handle leaves it that way, whichever way the pointer went.
    @Test(arguments: ZoomFraming.Handle.allCases)
    func everyHandleKeepsTheBoxTheShapeOfThePicture(handle: ZoomFraming.Handle) {
        let start = ZoomFraming.area(of: zoom(scale: 2))
        for delta in [CGSize(width: 0.1, height: 0), CGSize(width: -0.2, height: 0.3),
                      CGSize(width: 0, height: -0.15), CGSize(width: 0.4, height: 0.4)] {
            let resized = ZoomFraming.resized(start, by: delta, handle: handle)
            #expect(isClose(resized.width, resized.height), "\(handle) by \(delta)")
        }
    }

    // MARK: - Moving

    @Test func draggingTheBoxMovesTheShotAndNotTheScale() {
        let start = ZoomFraming.area(of: zoom(scale: 2, center: CGPoint(x: 0.5, y: 0.5)))
        let moved = ZoomFraming.moved(start, by: CGSize(width: 0.1, height: -0.05))
        #expect(isClose(moved.width, start.width), "the magnification is not a move's business")
        #expect(isClose(moved.midX, 0.6))
        #expect(isClose(moved.midY, 0.45))
    }

    /// Dragged at the edge it stops rather than sliding off, and it stops *square*: a box
    /// that clipped one side against the edge would be a stretched shot.
    @Test func aBoxDraggedOffThePictureStopsAtItsEdge() {
        let start = ZoomFraming.area(of: zoom(scale: 2))
        let moved = ZoomFraming.moved(start, by: CGSize(width: 5, height: -5))
        #expect(isClose(moved.maxX, 1))
        #expect(isClose(moved.minY, 0))
        #expect(isClose(moved.width, start.width))
    }

    // MARK: - Handles

    /// The edge a handle is not dragging stays exactly where it was, which is what makes a
    /// resize feel like pulling a sheet rather than moving it.
    @Test func acornerHoldsTheOppositeCornerStill() {
        let start = CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4)
        let pulled = ZoomFraming.resized(start, by: CGSize(width: -0.1, height: -0.1), handle: .topLeft)
        #expect(isClose(pulled.maxX, start.maxX))
        #expect(isClose(pulled.maxY, start.maxY))
        #expect(pulled.width > start.width, "pulling a corner outward takes in more")
    }

    /// An edge handle opens the box evenly on the axis it is not dragging, because that
    /// axis has no near or far side to it.
    @Test func anEdgeHoldsTheOtherAxisCentred() {
        let start = CGRect(x: 0.3, y: 0.3, width: 0.3, height: 0.3)
        let pulled = ZoomFraming.resized(start, by: CGSize(width: -0.1, height: 0), handle: .left)
        #expect(isClose(pulled.maxX, start.maxX))
        #expect(isClose(pulled.midY, start.midY), "the vertical middle does not move")
        #expect(pulled.width > start.width)
    }

    /// Dragging the left edge straight down must do nothing. It used to resize the box,
    /// because the drag was read along the diagonal whatever handle it came from — a handle
    /// doing something nobody asked it for.
    @Test func anEdgeIgnoresTravelAcrossIt() {
        let start = CGRect(x: 0.3, y: 0.3, width: 0.3, height: 0.3)
        for (handle, delta) in [(ZoomFraming.Handle.left, CGSize(width: 0, height: 0.2)),
                                (.top, CGSize(width: 0.2, height: 0))] {
            let held = ZoomFraming.resized(start, by: delta, handle: handle)
            #expect(isClose(held.width, start.width, 1e-12), "\(handle) changed the framing")
            #expect(isClose(held.midX, start.midX, 1e-12))
            #expect(isClose(held.midY, start.midY, 1e-12))
        }
    }

    @Test(arguments: ZoomFraming.Handle.allCases)
    func aHandleSitsOnTheEdgesItMoves(handle: ZoomFraming.Handle) {
        let rect = CGRect(x: 0.2, y: 0.1, width: 0.4, height: 0.4)
        let point = handle.point(in: rect)
        if handle.movesLeft { #expect(isClose(point.x, rect.minX)) }
        if handle.movesRight { #expect(isClose(point.x, rect.maxX)) }
        if handle.movesTop { #expect(isClose(point.y, rect.minY)) }
        if handle.movesBottom { #expect(isClose(point.y, rect.maxY)) }
    }

    // MARK: - Boundaries

    /// However hard a handle is pulled, the framing stays inside the recording and inside
    /// what the camera will actually do.
    @Test(arguments: ZoomFraming.Handle.allCases)
    func noDragCanLeaveThePicture(handle: ZoomFraming.Handle) {
        var rect = ZoomFraming.area(of: zoom(scale: 2))
        for delta in [CGSize(width: 3, height: 3), CGSize(width: -4, height: 2),
                      CGSize(width: -9, height: -9), CGSize(width: 0.2, height: -6)] {
            rect = ZoomFraming.resized(rect, by: delta, handle: handle)
            #expect(rect.minX >= -1e-9 && rect.maxX <= 1 + 1e-9, "\(handle) \(delta) → \(rect)")
            #expect(rect.minY >= -1e-9 && rect.maxY <= 1 + 1e-9, "\(handle) \(delta) → \(rect)")
            let scale = ZoomFraming.scale(forSide: rect.width)
            #expect(scale >= 1 && scale <= ZoomRegion.maximumScale)
        }
    }

    /// A box dragged tighter than the camera will go stops at the deepest zoom rather than
    /// quietly asking for one the renderer would refuse.
    @Test func theTightestFramingIsTheDeepestZoom() {
        let squeezed = ZoomFraming.honoured(CGRect(x: 0.5, y: 0.5, width: 0.0001, height: 0.0001))
        #expect(isClose(ZoomFraming.scale(forSide: squeezed.width), ZoomRegion.maximumScale))
        #expect(isClose(squeezed.width, ZoomFraming.minimumSide))
    }

    /// A stored centre that points off the edge is drawn where the camera will actually go,
    /// not where the file says. The renderer clamps at the last moment, and a box promising
    /// a shot the export does not give is worse than no box.
    @Test func aFramingIsDrawnWhereTheCameraWillActuallyGo() {
        let area = ZoomFraming.area(of: zoom(scale: 2, center: CGPoint(x: 0.95, y: -0.4)))
        #expect(isClose(area.maxX, 1))
        #expect(isClose(area.minY, 0))
    }

    @Test func keyboardResizingStaysWithinTheSameBounds() {
        var rect = ZoomFraming.area(of: zoom(scale: 2))
        for _ in 0..<40 { rect = ZoomFraming.scaled(rect, by: 1 / 1.1) }
        #expect(isClose(ZoomFraming.scale(forSide: rect.width), ZoomRegion.maximumScale))
        for _ in 0..<40 { rect = ZoomFraming.scaled(rect, by: 1.1) }
        #expect(isClose(ZoomFraming.scale(forSide: rect.width), 1))
    }

    /// Scaling by the keyboard holds the middle, so `+` then `-` comes back to where it was.
    @Test func keyboardResizingHoldsTheMiddle() {
        let start = ZoomFraming.area(of: zoom(scale: 2, center: CGPoint(x: 0.3, y: 0.7)))
        let there = ZoomFraming.scaled(start, by: 1 / 1.1)
        let back = ZoomFraming.scaled(there, by: 1.1)
        #expect(isClose(back.midX, start.midX, 1e-6))
        #expect(isClose(back.midY, start.midY, 1e-6))
        #expect(isClose(back.width, start.width, 1e-6))
    }
}

/// Where a point on screen is in the recording, and back.
///
/// Two nested aspect fits, gone through both ways on every frame of every drag. These are
/// the claims that stop a box being dragged an inch while the shot moves half an inch.
struct PictureMappingTests {
    /// A 16:9 frame in a pane, with the recording inset by a tenth of padding all round.
    private let mapping = PictureMapping(
        stage: CGRect(x: 30, y: 12, width: 960, height: 540),
        video: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8))

    private func isClose(_ a: Double, _ b: Double, _ tolerance: Double = 1e-9) -> Bool {
        abs(a - b) < tolerance
    }

    private func isClose(_ a: CGRect, _ b: CGRect, _ tolerance: Double = 1e-9) -> Bool {
        isClose(a.minX, b.minX, tolerance) && isClose(a.minY, b.minY, tolerance)
            && isClose(a.width, b.width, tolerance) && isClose(a.height, b.height, tolerance)
    }

    @Test func aRectangleOfTheRecordingSurvivesTheRoundTrip() {
        for rect in [CGRect(x: 0, y: 0, width: 1, height: 1),
                     CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
                     CGRect(x: 0.9, y: 0.05, width: 0.1, height: 0.2)] {
            #expect(isClose(mapping.recording(view: mapping.view(recording: rect)), rect, 1e-9))
        }
    }

    @Test func theWholeRecordingIsWhereThePaddingLeftIt() {
        let whole = mapping.view(recording: CGRect(x: 0, y: 0, width: 1, height: 1))
        #expect(isClose(whole.minX, 30 + 96))
        #expect(isClose(whole.width, 960 * 0.8))
    }

    /// The same framing on a pane twice the size lands twice as far across it, and reads
    /// back as exactly the same fraction of the recording. This is what "stable movement at
    /// different preview sizes" means, and what resizing the window must not disturb.
    @Test func resizingThePaneMovesNothingInTheRecording() {
        let small = PictureMapping(stage: CGRect(x: 0, y: 0, width: 480, height: 270),
                                   video: mapping.video)
        let large = PictureMapping(stage: CGRect(x: 0, y: 0, width: 960, height: 540),
                                   video: mapping.video)
        let framing = CGRect(x: 0.3, y: 0.4, width: 0.25, height: 0.25)

        #expect(isClose(large.view(recording: framing).minX, small.view(recording: framing).minX * 2))
        #expect(isClose(small.recording(view: small.view(recording: framing)), framing, 1e-9))
        #expect(isClose(large.recording(view: large.view(recording: framing)), framing, 1e-9))
    }

    /// Points, never pixels. A Retina display changes how many pixels a point is drawn with
    /// and nothing else, so two panes of the same size in points must map identically
    /// whatever the backing scale is — there is no scale factor in this arithmetic, and this
    /// is the test that says there must not be one.
    @Test(arguments: [1.0, 2.0, 3.0])
    func theMappingIsInPointsAndIgnoresTheBackingScale(displayScale: Double) {
        // What a pane of this size would be in *pixels* on such a display. A mapping that
        // had let the scale in would answer differently for each of these.
        let inPoints = PictureMapping(stage: CGRect(x: 20, y: 10, width: 800, height: 450),
                                      video: mapping.video)
        let framing = CGRect(x: 0.2, y: 0.6, width: 0.3, height: 0.3)
        let drawn = inPoints.view(recording: framing)

        let inPixels = PictureMapping(
            stage: CGRect(x: 20 * displayScale, y: 10 * displayScale,
                          width: 800 * displayScale, height: 450 * displayScale),
            video: mapping.video)
        let scaled = inPixels.view(recording: framing)

        #expect(isClose(scaled.minX, drawn.minX * displayScale, 1e-9))
        #expect(isClose(inPixels.recording(view: scaled), framing, 1e-9))
    }

    /// A drag's travel, converted once. The pointer moving a tenth of the recording's width
    /// must move the framing by exactly a tenth, or the box lags the hand.
    @Test func aDragsTravelIsTheSameFractionAsThePointerMoved() {
        let recordingWidth = mapping.stage.width * mapping.video.width
        let delta = mapping.delta(view: CGSize(width: recordingWidth / 10, height: 0))
        #expect(isClose(delta.width, 0.1))
        #expect(isClose(delta.height, 0))
    }

    /// Dragging a framing by the pointer's travel puts the box under the pointer — the test
    /// for "no jump on first click", expressed as arithmetic rather than as a feeling.
    @Test func aFramingFollowsThePointerExactly() {
        let start = ZoomFraming.area(of: ZoomRegion(start: .zero, duration: .zero, scale: 2))
        let grabbed = mapping.view(recording: start)
        let travel = CGSize(width: 40, height: -25)

        let moved = ZoomFraming.moved(start, by: mapping.delta(view: travel))
        let drawn = mapping.view(recording: moved)

        #expect(isClose(drawn.minX, grabbed.minX + travel.width, 1e-6))
        #expect(isClose(drawn.minY, grabbed.minY + travel.height, 1e-6))
    }

    @Test func anEmptyStageMapsToNothingRatherThanToInfinity() {
        let none = PictureMapping(stage: .zero, video: .zero)
        #expect(none.recording(view: CGRect(x: 10, y: 10, width: 5, height: 5)) == .zero)
        #expect(none.frame(view: CGRect(x: 10, y: 10, width: 5, height: 5)) == .zero)
    }
}
