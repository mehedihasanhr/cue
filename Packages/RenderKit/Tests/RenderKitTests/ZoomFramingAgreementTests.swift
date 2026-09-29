import CoreGraphics
import CoreImage
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

    /// What the camera is showing at this moment, as a rectangle of the recording.
    ///
    /// The shipping arithmetic rather than a copy of it: this helper used to write the clamp
    /// out again, which made it a fourth opinion in a file whose whole job is to check that
    /// there is only one.
    private func shown(_ scene: SceneDescriptor) -> CGRect {
        ZoomFraming.honoured(scale: scene.zoom, center: scene.zoomCenter)
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

    // MARK: - Where the framed region lands

    private let videoSize = CGSize(width: 1_600, height: 1_000)

    /// A recording that is one colour inside the given region of itself and another outside
    /// it, so "is the framed region what the frame is showing?" is one pixel's worth of
    /// question. `region` is normalised, top-left, like everything in the model; the crop
    /// below is Core Image's bottom-left space, hence the flip.
    private func marked(_ region: CGRect, marker: CGRect? = nil) -> CIImage {
        let area = marker ?? region
        let inside = CIImage(color: CIColor(red: 0, green: 1, blue: 0))
            .cropped(to: CGRect(x: area.minX * videoSize.width,
                                y: (1 - area.maxY) * videoSize.height,
                                width: area.width * videoSize.width,
                                height: area.height * videoSize.height))
        let outside = CIImage(color: CIColor(red: 0, green: 0, blue: 1))
            .cropped(to: CGRect(origin: .zero, size: videoSize))
        return inside.composited(over: outside)
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int)? {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return nil }
        let offset = y * image.bytesPerRow + x * (image.bitsPerPixel / 8)
        return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
    }

    private func isMarker(_ sample: (r: Int, g: Int, b: Int)) -> Bool {
        sample.g > 150 && sample.b < 100
    }

    /// A plain frame: no padding, no corners, no shadow, no pointer. The picture fills the
    /// output, so what is asserted about the output is asserted about the picture.
    private func plain(scale: Double, center: CGPoint, wholeFrame: Bool = true) -> Timeline {
        var timeline = Timeline(sourceDuration: time(20))
        timeline.style.padding = 0
        timeline.style.cornerRadius = 0
        timeline.style.shadowOpacity = 0
        timeline.cursor.isVisible = false
        timeline.camera.zoomsWholeFrame = wholeFrame
        timeline.zooms = [ZoomRegion(start: .zero, duration: time(10), scale: scale,
                                     center: center, easing: .linear, transition: .zero,
                                     followsCursor: false)]
        return timeline
    }

    /// **The decisive one.** The region the box draws is the region the pixels show.
    ///
    /// Everything else in this file compares one description against another; this compares a
    /// description against the picture that came out, which is the only reading the person
    /// framing the shot cares about. It fails for every off-centre argument against a camera
    /// that scales about its aim rather than bringing its aim to the middle.
    @Test(arguments: [
        CGPoint(x: 0.5, y: 0.5),
        CGPoint(x: 0.125, y: 0.125),
        CGPoint(x: 0.875, y: 0.875),
        CGPoint(x: 0.625, y: 0.75),
    ])
    func theFramedRegionFillsTheMiddleOfTheFrame(center: CGPoint) throws {
        let edit = plain(scale: 4, center: center)
        let region = ZoomFraming.area(of: edit.zooms[0])
        let scene = SceneBuilder(videoSize: videoSize, displayScale: 2).descriptor(for: edit, at: time(5))
        let image = try #require(SceneRenderer().cgImage(for: scene, source: marked(region)))

        // The middle, and a cross reaching most of the way to the edges of the picture —
        // well inside the framed region, which fills the whole of it.
        let dx = Int(scene.videoFrame.width * 0.35)
        let dy = Int(scene.videoFrame.height * 0.35)
        let middle = (x: image.width / 2, y: image.height / 2)
        for point in [middle,
                      (x: middle.x - dx, y: middle.y), (x: middle.x + dx, y: middle.y),
                      (x: middle.x, y: middle.y - dy), (x: middle.x, y: middle.y + dy)] {
            let sample = try #require(pixel(image, x: point.x, y: point.y))
            #expect(isMarker(sample),
                    "aimed at \(center), \(point) shows what is beside the shot: \(sample)")
        }
    }

    /// The same claim as a rectangle, at every scope: the framed region maps onto the picture
    /// exactly. Cheap enough to run over a wider table than a pixel test can.
    @Test(arguments: [
        CGPoint(x: 0.5, y: 0.5),
        CGPoint(x: 0.125, y: 0.125),
        CGPoint(x: 0.875, y: 0.125),
        CGPoint(x: 0.125, y: 0.875),
        CGPoint(x: 0.875, y: 0.875),
        CGPoint(x: 0.3, y: 0.7),
    ])
    func theFramedRegionLandsOnTheVideoFrameExactly(center: CGPoint) {
        for wholeFrame in [true, false] {
            var edit = plain(scale: 4, center: center, wholeFrame: wholeFrame)
            edit.style.padding = 0.15
            let scene = SceneBuilder(videoSize: videoSize, displayScale: 2).descriptor(for: edit, at: time(5))
            let region = ZoomFraming.area(of: edit.zooms[0])
            let frame = scene.transformedVideoFrame

            // The region, in output pixels: its top in the model is its high y in Core Image.
            let landed = CGRect(x: frame.minX + region.minX * frame.width,
                                y: frame.minY + (1 - region.maxY) * frame.height,
                                width: region.width * frame.width,
                                height: region.height * frame.height)
            #expect(isClose(landed, scene.videoFrame, 1e-6),
                    "aimed at \(center), whole frame \(wholeFrame): \(landed) vs \(scene.videoFrame)")
        }
    }

    /// One zoom hands over to the next without the picture jumping.
    ///
    /// Depth and aim both change across the seam, and the interpolation is the only thing
    /// holding the two together — so this walks the frames rather than sampling two of them.
    @Test func twoZoomsInARowMoveTheFrameWithoutAJump() {
        var edit = Timeline(sourceDuration: time(20))
        edit.style.padding = 0.1
        edit.cursor.isVisible = false
        edit.zooms = [
            ZoomRegion(start: time(1), duration: time(4), scale: 2,
                       center: CGPoint(x: 0.2, y: 0.8), easing: .easeInOut,
                       transition: time(0.4), followsCursor: false),
            ZoomRegion(start: time(5), duration: time(4), scale: 5,
                       center: CGPoint(x: 0.8, y: 0.2), easing: .easeInOut,
                       transition: time(0.4), followsCursor: false),
        ]
        let builder = SceneBuilder(videoSize: videoSize, displayScale: 2)

        // Stepped finer than any frame rate, which is what separates the two things that
        // look alike in a table of numbers: a zoom ramping hard covers less ground per step
        // the smaller the step, while a discontinuity is the same size whatever the step is.
        // So the bound is a fraction of the picture, and a ramp to 5x comes nowhere near it.
        let step = 1.0 / 600
        let limit = scene(builder, edit, 0).videoFrame.width * 0.08
        var previous = scene(builder, edit, 0).transformedVideoFrame
        for index in 1...12_000 {
            let at = Double(index) * step
            let now = scene(builder, edit, at).transformedVideoFrame
            #expect(abs(now.minX - previous.minX) < limit, "a jump at \(at)s")
            #expect(abs(now.minY - previous.minY) < limit, "a jump at \(at)s")
            #expect(abs(now.width - previous.width) < limit, "a jump at \(at)s")
            previous = now
        }
    }

    private func scene(_ builder: SceneBuilder, _ edit: Timeline, _ at: Double) -> SceneDescriptor {
        builder.descriptor(for: edit, at: time(at))
    }

    /// The export frames what the preview framed.
    ///
    /// The preview composites at a fraction of the export's pixels, and the exporter scales
    /// the finished frame instead — two mechanisms for the same picture, which is exactly
    /// where a framing can quietly part company with the file. Asserted as a rectangle *and*
    /// in pixels: the marker covers the left half of the framed region, so its edge is a
    /// landmark that has to sit in the same place in both renders.
    @Test func theExportFramesWhatThePreviewFramed() throws {
        let centre = CGPoint(x: 0.75, y: 0.3)
        let edit = plain(scale: 4, center: centre)
        let scene = SceneBuilder(videoSize: videoSize, displayScale: 2).descriptor(for: edit, at: time(5))
        let cheap = scene.scaled(by: 0.4)

        let full = scene.transformedVideoFrame
        let small = cheap.transformedVideoFrame
        #expect(isClose(small, full.applying(CGAffineTransform(scaleX: 0.4, y: 0.4)), 1e-6))

        let region = ZoomFraming.area(of: edit.zooms[0])
        var half = region
        half.size.width /= 2
        let source = marked(region, marker: half)
        let renderer = SceneRenderer()

        for (name, described) in [("export", scene), ("preview", cheap)] {
            let image = try #require(renderer.cgImage(for: described, source: source))
            let row = image.height / 2
            var edge = 0
            for x in 0..<image.width where isMarker(try #require(pixel(image, x: x, y: row))) {
                edge = x
            }
            // The marker is the left half of the shot, so its last pixel is the middle of it.
            #expect(abs(Double(edge) / Double(image.width) - 0.5) < 0.01,
                    "the \(name) put the middle of the shot at \(Double(edge) / Double(image.width))")
        }
    }
}
