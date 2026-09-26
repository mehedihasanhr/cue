import CoreGraphics
import CoreMedia
import Foundation
import Testing
import TimelineKit
@testable import RenderKit

/// The framing box and the finished frame agree.
///
/// A zoom is edited as a rectangle on the picture and rendered as a centre and a scale. The
/// editor draws the first; the export writes the second. If those two readings can drift
/// apart by so much as a rounding, the result is the bug that is impossible to argue with
/// from a screenshot: the shot was framed here and the video shows there.
///
/// So the box's rectangle is checked against what the *renderer* says it is showing, at the
/// descriptor level — the same descriptor the preview draws and the exporter encodes, since
/// there is only one.
struct ZoomFramingAgreementTests {
    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    private func builder() -> SceneBuilder {
        SceneBuilder(videoSize: CGSize(width: 1_600, height: 1_000), displayScale: 2)
    }

    /// What the camera is showing at this moment, as a rectangle of the recording — the
    /// same arithmetic the framing overlay used to do by hand.
    private func shown(_ scene: SceneDescriptor) -> CGRect {
        let half = 0.5 / max(1, scene.zoom)
        return CGRect(x: scene.zoomCenter.x - half, y: scene.zoomCenter.y - half,
                      width: half * 2, height: half * 2)
    }

    private func timeline(scale: Double, center: CGPoint) -> Timeline {
        var timeline = Timeline(sourceDuration: time(20))
        timeline.style.padding = 0.15
        timeline.zooms = [ZoomRegion(start: .zero, duration: time(10), scale: scale,
                                     center: center, easing: .linear, transition: time(0.5),
                                     followsCursor: false)]
        return timeline
    }

    private func isClose(_ a: CGRect, _ b: CGRect, _ tolerance: Double = 1e-6) -> Bool {
        abs(a.minX - b.minX) < tolerance && abs(a.minY - b.minY) < tolerance
            && abs(a.width - b.width) < tolerance && abs(a.height - b.height) < tolerance
    }

    /// The box the editor draws is the part of the recording the finished frame fills with.
    @Test(arguments: [
        (2.0, CGPoint(x: 0.5, y: 0.5)),
        (3.0, CGPoint(x: 0.3, y: 0.7)),
        (4.5, CGPoint(x: 0.12, y: 0.12)),
        (8.0, CGPoint(x: 0.9, y: 0.4)),
    ])
    func theFramingBoxIsWhatTheRendererShows(scale: Double, center: CGPoint) {
        let edit = timeline(scale: scale, center: center)
        // Fully in: the one place the framing is the whole of what is shown, and where the
        // inspector's number and the box's width both claim to be `scale`.
        let scene = builder().descriptor(for: edit, at: time(5))
        #expect(isClose(shown(scene), ZoomFraming.area(of: edit.zooms[0])),
                "\(scale)× at \(center)")
    }

    /// A zoom aimed off the edge is drawn where the camera will actually go. The renderer
    /// holds the camera inside the picture at the last moment, so a box drawn from the
    /// stored centre would promise a shot the export never gives.
    @Test func aFramingAimedOffTheEdgeMatchesTheClampedCamera() {
        let edit = timeline(scale: 2, center: CGPoint(x: 1.4, y: -0.3))
        let scene = builder().descriptor(for: edit, at: time(5))
        let box = ZoomFraming.area(of: edit.zooms[0])
        #expect(isClose(shown(scene), box))
        #expect(box.maxX <= 1 + 1e-9 && box.minY >= -1e-9)
    }

    /// Halfway up the ramp the camera is somewhere between 1× and the zoom's own scale —
    /// and the box is not. The box stands for the zoom's *target* framing, so it has to be
    /// read off the region rather than off whatever intermediate frame the playhead is
    /// sitting on, or it would breathe as the animation ran.
    @Test func theBoxIsTheTargetFramingRatherThanAnAnimationFrame() {
        let edit = timeline(scale: 4, center: CGPoint(x: 0.4, y: 0.6))
        let midRamp = builder().descriptor(for: edit, at: time(0.25))
        #expect(midRamp.zoom > 1 && midRamp.zoom < 4, "the camera is on its way in")

        let box = ZoomFraming.area(of: edit.zooms[0])
        #expect(abs(ZoomFraming.scale(forSide: box.width) - 4) < 1e-9)
        #expect(!isClose(shown(midRamp), box), "which is exactly why it is not read off the frame")
    }

    /// Scrubbing outside the zoom shows the whole recording, and the box still says what
    /// the zoom will do when the playhead reaches it.
    @Test func aBoxStillMeansSomethingFromOutsideItsOwnZoom() {
        let edit = timeline(scale: 3, center: CGPoint(x: 0.25, y: 0.25))
        let outside = builder().descriptor(for: edit, at: time(15))
        #expect(outside.zoom == 1, "no camera out here")
        #expect(abs(ZoomFraming.area(of: edit.zooms[0]).width - 1.0 / 3) < 1e-9)
    }

    /// A zoom that is switched off contributes nothing to the frame, and the box goes on
    /// describing the framing it is keeping for when it is switched back on.
    @Test func aDisabledZoomKeepsItsFramingAndMovesNoCamera() {
        var edit = timeline(scale: 3, center: CGPoint(x: 0.3, y: 0.3))
        edit.zooms[0].isEnabled = false
        #expect(builder().descriptor(for: edit, at: time(5)).zoom == 1)
        #expect(abs(ZoomFraming.area(of: edit.zooms[0]).midX - 0.3) < 1e-9)
    }

    /// The preview renders at a fraction of the export's pixels while the picture is
    /// moving. That must change how many pixels are drawn and nothing about where the
    /// camera is pointed, or a framing judged in the preview would export somewhere else.
    @Test func drawingThePreviewSmallerDoesNotMoveTheCamera() {
        let edit = timeline(scale: 3.5, center: CGPoint(x: 0.35, y: 0.55))
        let full = builder().descriptor(for: edit, at: time(5))
        let cheap = full.scaled(by: 0.4)

        #expect(cheap.outputSize.width < full.outputSize.width, "fewer pixels")
        #expect(abs(cheap.zoom - full.zoom) < 1e-9)
        #expect(isClose(shown(cheap), shown(full)))
        #expect(isClose(shown(cheap), ZoomFraming.area(of: edit.zooms[0])))
    }

    // MARK: - Why a drag is cheap

    /// The picture under the framing box cannot change while the box moves.
    ///
    /// This is the fact the editor's performance rests on, and it is worth asserting rather
    /// than timing: framing renders the timeline with its zooms taken out, so every frame of
    /// a drag would decode the same source frame and composite the same output. Knowing
    /// that, the model skips the decode for the whole gesture and lets the box draw itself
    /// — which is how a drag stays ahead of the pointer without any caching, throttling or
    /// interactive-quality trickery.
    ///
    /// Stated as: with the zooms removed, the described frame is byte-identical whatever
    /// the zoom being dragged has been changed to.
    @Test func aFramingDragCannotChangeTheFrameUnderTheBox() {
        var edit = timeline(scale: 2, center: CGPoint(x: 0.5, y: 0.5))
        var framing = edit
        framing.zooms = []
        let before = builder().descriptor(for: framing, at: time(5))

        // Sixty frames of a drag, each a different framing.
        for step in 0..<60 {
            edit.zooms[0].scale = 1 + Double(step) * 0.1
            edit.zooms[0].center = CGPoint(x: 0.2 + Double(step) * 0.01, y: 0.4)
            var during = edit
            during.zooms = []
            let now = builder().descriptor(for: during, at: time(5))
            #expect(now.zoom == before.zoom)
            #expect(now.transformedVideoFrame == before.transformedVideoFrame)
            #expect(now.sourceTime == before.sourceTime, "and the same source frame, so no decode")
        }
    }

    /// Describing the same moment twice gives the same answer, which is what lets the
    /// preview and the exporter share one evaluator. A framing judged on screen is the
    /// framing written to the file.
    @Test func oneMomentDescribesOneFrameHoweverOftenItIsAsked() {
        let edit = timeline(scale: 2.75, center: CGPoint(x: 0.44, y: 0.31))
        let first = builder().descriptor(for: edit, at: time(3))
        let second = builder().descriptor(for: edit, at: time(3))
        #expect(first.zoom == second.zoom)
        #expect(first.zoomCenter == second.zoomCenter)
        #expect(first.transformedVideoFrame == second.transformedVideoFrame)
    }
}
