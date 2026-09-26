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
}
