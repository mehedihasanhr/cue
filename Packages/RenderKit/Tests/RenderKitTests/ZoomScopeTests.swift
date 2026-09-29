import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import RecordKit
import Testing
import TimelineKit
@testable import RenderKit

/// What a zoom magnifies: the picture inside its frame, or the framed picture as a whole.
///
/// The recording sits in a hole the padding leaves, with a background around it, rounded
/// corners and a shadow. A zoom has always pushed in on the picture *inside* that hole —
/// like zooming a screen — so the background, padding and corners never move and the
/// zoomed content still only occupies the same part of the finished video.
///
/// The other reading is a camera moving towards the scene: the framed picture itself grows
/// and travels, corners and shadow with it, and the padding closes up. That is what most
/// people mean by zooming in, so it is the default; the first stays available for when the
/// frame itself is the design.
struct ZoomScopeTests {
    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    private let videoSize = CGSize(width: 1_600, height: 1_000)

    private func builder() -> SceneBuilder {
        SceneBuilder(videoSize: videoSize, displayScale: 2)
    }

    /// A framed recording with generous padding, zoomed 2× on the middle.
    private func timeline(wholeFrame: Bool) -> Timeline {
        var timeline = Timeline(sourceDuration: time(20))
        timeline.style.padding = 0.2
        timeline.style.cornerRadius = 0.02
        // No shadow: it darkens the background right where these read it, and the question
        // here is "picture or padding?", not "how soft is the shadow?".
        timeline.style.shadowOpacity = 0
        timeline.style.background = .color(ColorValue(r: 0, g: 0, b: 1))
        timeline.cursor.isVisible = false
        timeline.camera.zoomsWholeFrame = wholeFrame
        timeline.zooms = [ZoomRegion(start: .zero, duration: time(10), scale: 2,
                                     center: CGPoint(x: 0.5, y: 0.5),
                                     easing: .linear, transition: time(0.1),
                                     followsCursor: false)]
        return timeline
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int)? {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return nil }
        let offset = y * image.bytesPerRow + x * (image.bitsPerPixel / 8)
        return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
    }

    /// A plain red recording, so "is this the picture or the background?" is one question.
    private func red() -> CIImage {
        CIImage(color: CIColor(red: 1, green: 0, blue: 0))
            .cropped(to: CGRect(origin: .zero, size: videoSize))
    }

    // MARK: -

    /// The default: the frame holds still. A point just outside where the picture sits is
    /// background before the zoom and background during it.
    @Test func zoomingTheContentsLeavesThePaddingAlone() throws {
        let edit = timeline(wholeFrame: false)
        let renderer = SceneRenderer()

        let scene = builder().descriptor(for: edit, at: time(5))
        let image = try #require(renderer.cgImage(for: scene, source: red()))

        // A little outside the picture's own rectangle, in the padding.
        let x = Int(scene.videoFrame.minX) - 12
        let y = Int(scene.outputSize.height / 2)
        let sample = try #require(pixel(image, x: x, y: y))
        #expect(sample.b > 150 && sample.r < 100, "the padding is still background")
    }

    /// Switched on, the same point is picture: the frame grew past it.
    @Test func zoomingTheWholeFrameFillsThePadding() throws {
        let edit = timeline(wholeFrame: true)
        let renderer = SceneRenderer()

        let scene = builder().descriptor(for: edit, at: time(5))
        let image = try #require(renderer.cgImage(for: scene, source: red()))

        let x = Int(scene.videoFrame.minX) - 12
        let y = Int(scene.outputSize.height / 2)
        let sample = try #require(pixel(image, x: x, y: y))
        #expect(sample.r > 150 && sample.b < 100, "the picture has grown over the padding")
    }

    /// And the rectangle the renderer is allowed to draw in says the same thing.
    @Test func theVisibleFrameIsTheHoleOrTheGrownFrame() {
        let held = builder().descriptor(for: timeline(wholeFrame: false), at: time(5))
        #expect(held.visibleVideoFrame == held.videoFrame)

        let grown = builder().descriptor(for: timeline(wholeFrame: true), at: time(5))
        #expect(grown.visibleVideoFrame.width > grown.videoFrame.width)
        #expect(grown.visibleVideoFrame.minX <= grown.videoFrame.minX)
    }

    /// Never off the edge of the video being written, however far the camera pushes in.
    @Test func theGrownFrameIsHeldToTheOutput() {
        var edit = timeline(wholeFrame: true)
        edit.zooms[0].scale = 8
        let scene = builder().descriptor(for: edit, at: time(5))
        let bounds = CGRect(origin: .zero, size: scene.outputSize)
        #expect(bounds.contains(scene.visibleVideoFrame))
    }

    /// A gentle zoom does not swallow the padding, and what padding is left is still
    /// background rather than pointer.
    ///
    /// The clipping the held reading needs (`CropTests.thePointerIsNeverDrawnOutsideThePicture`)
    /// is needed here too, against a rectangle that moves: the pointer is placed against the
    /// grown frame, so at the edge of the recording it lands beside the picture unless it is
    /// held to the same rect the picture is.
    @Test func thePointerStaysInsideTheGrownFrame() throws {
        var edit = timeline(wholeFrame: true)
        edit.style.cornerRadius = 0
        edit.zooms[0].scale = 1.1
        edit.cursor.isVisible = true
        edit.cursor.smoothing = 0
        edit.cursor.scale = 3

        // The middle of the recording's right-hand edge: as far out as the pointer goes.
        let track = CursorTrack(samples: [CursorSample(t: 0, x: videoSize.width, y: videoSize.height / 2, shape: .arrow)])
        let scene = builder().descriptor(for: edit, at: time(5), cursor: track)
        let image = try #require(SceneRenderer().cgImage(for: scene, source: red()))

        #expect(scene.visibleVideoFrame.maxX < scene.outputSize.width - 4, "there is padding left to check")
        let sample = try #require(pixel(image, x: image.width - 3, y: image.height / 2))
        #expect(sample.b > 150 && sample.r < 100, "the padding is background, never pointer")
    }

    /// With no zoom in force the two readings are the same picture, so turning the switch
    /// on cannot change a frame that is not zoomed.
    @Test func withoutAZoomTheSwitchChangesNothing() throws {
        let renderer = SceneRenderer()
        var held = timeline(wholeFrame: false)
        var grown = timeline(wholeFrame: true)
        held.zooms = []
        grown.zooms = []

        let a = try #require(renderer.cgImage(for: builder().descriptor(for: held, at: time(5)), source: red()))
        let b = try #require(renderer.cgImage(for: builder().descriptor(for: grown, at: time(5)), source: red()))
        for x in stride(from: 4, to: a.width, by: 97) {
            #expect(pixel(a, x: x, y: a.height / 2)?.r == pixel(b, x: x, y: b.height / 2)?.r,
                    "differs at \(x)")
        }
    }

    /// The setting travels with the project, including when it is turned off — and adding
    /// it did not disturb the settings it was added beside.
    @Test func theChoiceIsSavedAndTheNeighboursSurvivedIt() throws {
        var edit = timeline(wholeFrame: false)
        edit.camera.steadiness = 0.4
        let read = try JSONDecoder().decode(Timeline.self, from: JSONEncoder().encode(edit))
        #expect(!read.camera.zoomsWholeFrame, "off is a choice and has to come back off")
        #expect(read.camera.steadiness == 0.4, "and the neighbours survived the new key")

        // A project written before the key existed decodes as the whole frame zooming,
        // which is what a project made today does. The point of the lenient decoder is
        // that the *other* three come back as they were saved rather than as defaults.
        let old = #"{"steadiness":0.9,"follow":0.5,"safeArea":0.7}"#
        let camera = try JSONDecoder().decode(CameraStyle.self, from: Data(old.utf8))
        #expect(camera.zoomsWholeFrame)
        #expect(camera.steadiness == 0.9, "the old settings were not reset by the new one")
        #expect(camera.safeArea == 0.7)
    }

    /// The default is the one the picture is expected to do, so a camera nobody has
    /// configured zooms the frame.
    @Test func aCameraNobodyTouchedZoomsTheWholeFrame() {
        #expect(CameraStyle().zoomsWholeFrame)
        #expect(Timeline(sourceDuration: .zero).camera.zoomsWholeFrame)
    }

    // MARK: - Aimed at an edge

    /// A zoom aimed at the edge of the recording exposes no more padding than was already
    /// there, on any side.
    ///
    /// The whole-frame reading lets the picture grow over its padding, so the question this
    /// answers is how far it may *fail* to. The clamp holds the camera's centre at least
    /// `0.5/scale` from every edge, which works out to the grown picture always still
    /// covering the rectangle it occupied at 1x — so the padding a viewer sees is padding
    /// that was in the design, never a gap the camera opened.
    @Test(arguments: [1.1, 2.0, 8.0])
    func aZoomAimedAtAnEdgeExposesNoMorePaddingThanBefore(scale: Double) throws {
        var edit = timeline(wholeFrame: true)
        edit.style.cornerRadius = 0
        edit.zooms[0].scale = scale
        // The far corner, further than the camera may go, so the clamp is what decides.
        edit.zooms[0].center = CGPoint(x: 1, y: 1)
        let scene = builder().descriptor(for: edit, at: time(5))
        let grown = scene.transformedVideoFrame

        #expect(grown.minX <= scene.videoFrame.minX + 1e-6, "\(scale)x left a gap on the left")
        #expect(grown.maxX >= scene.videoFrame.maxX - 1e-6, "\(scale)x left a gap on the right")
        #expect(grown.minY <= scene.videoFrame.minY + 1e-6)
        #expect(grown.maxY >= scene.videoFrame.maxY - 1e-6)

        // And in pixels, at the corner the camera was aimed away from.
        let image = try #require(SceneRenderer().cgImage(for: scene, source: red()))
        let inside = try #require(pixel(image,
                                        x: Int(scene.videoFrame.minX) + 2,
                                        y: Int(scene.videoFrame.minY) + 2))
        #expect(inside.r > 150 && inside.b < 100, "the corner of the picture is picture")
    }

    /// Which part of the recording a zoom shows cannot depend on the scope switch.
    ///
    /// The switch decides whether the *frame* grows over its padding; it has no say in where
    /// the camera is pointed. Read in pixels, off-centre, because that is the pair of claims
    /// that had quietly become one: the framing used to drift towards the middle of the
    /// picture, and the two readings drifted with it by different amounts.
    @Test func theFramedRegionFillsThePictureUnderBothScopes() throws {
        let renderer = SceneRenderer()
        for wholeFrame in [true, false] {
            var edit = timeline(wholeFrame: wholeFrame)
            edit.style.cornerRadius = 0
            edit.zooms[0].scale = 4
            edit.zooms[0].center = CGPoint(x: 0.75, y: 0.3)

            let scene = builder().descriptor(for: edit, at: time(5))
            let region = ZoomFraming.area(of: edit.zooms[0])
            // Green where the shot is aimed, blue everywhere else in the recording.
            let marker = CIImage(color: CIColor(red: 0, green: 1, blue: 0))
                .cropped(to: CGRect(x: region.minX * videoSize.width,
                                    y: (1 - region.maxY) * videoSize.height,
                                    width: region.width * videoSize.width,
                                    height: region.height * videoSize.height))
            let source = marker.composited(over: CIImage(color: CIColor(red: 0, green: 0, blue: 1))
                .cropped(to: CGRect(origin: .zero, size: videoSize)))

            let image = try #require(renderer.cgImage(for: scene, source: source))
            // A cross reaching most of the way across the picture, not just its middle: a
            // camera drifting by a fraction of its own shot still has the right thing in the
            // centre, and gives away the drift at the edges of the frame.
            let dx = Int(scene.videoFrame.width * 0.35)
            let dy = Int(scene.videoFrame.height * 0.35)
            let middle = (x: image.width / 2, y: image.height / 2)
            for point in [middle,
                          (x: middle.x - dx, y: middle.y), (x: middle.x + dx, y: middle.y),
                          (x: middle.x, y: middle.y - dy), (x: middle.x, y: middle.y + dy)] {
                let sample = try #require(pixel(image, x: point.x, y: point.y))
                #expect(sample.g > 150 && sample.b < 100,
                        "whole frame \(wholeFrame), \(point) shows what is beside the shot: \(sample)")
            }
        }
    }
}
