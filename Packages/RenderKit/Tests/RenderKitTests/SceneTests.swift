import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import RecordKit
import Testing
import TimelineKit
@testable import RenderKit

/// What a frame is described as, and what it comes out looking like.
struct SceneTests {
    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    private let videoSize = CGSize(width: 1_600, height: 1_000)

    private func builder() -> SceneBuilder {
        SceneBuilder(videoSize: videoSize, displayScale: 2)
    }

    private func timeline() -> Timeline {
        Timeline(sourceDuration: time(60))
    }

    // MARK: - Layout

    @Test func withoutAnAspectTheOutputIsTheRecording() {
        #expect(builder().outputSize(for: FrameStyle()) == videoSize)
    }

    @Test func anAspectKeepsRoughlyTheSameNumberOfPixels() {
        var style = FrameStyle()
        style.aspect = .vertical9x16
        let output = builder().outputSize(for: style)

        #expect(abs(output.width / output.height - 9.0 / 16) < 0.01)
        let ratio = (output.width * output.height) / (videoSize.width * videoSize.height)
        #expect(ratio > 0.95 && ratio < 1.05, "a reshape must not quietly upscale or throw pixels away")
        #expect(Int(output.width) % 2 == 0, "encoders reject odd dimensions")
        #expect(Int(output.height) % 2 == 0)
    }

    @Test func paddingLeavesRoomOnEverySide() {
        var timeline = timeline()
        timeline.style.padding = 0.1
        let scene = builder().descriptor(for: timeline, at: .zero)

        #expect(scene.videoFrame.minX > 0)
        #expect(scene.videoFrame.maxX < scene.outputSize.width)
        // Centred: the same margin on both sides.
        #expect(abs(scene.videoFrame.minX - (scene.outputSize.width - scene.videoFrame.maxX)) < 0.001)
    }

    @Test func theVideoKeepsItsShapeInsideADifferentAspect() {
        var timeline = timeline()
        timeline.style.aspect = .square
        let scene = builder().descriptor(for: timeline, at: .zero)

        let sourceRatio = videoSize.width / videoSize.height
        let framedRatio = scene.videoFrame.width / scene.videoFrame.height
        #expect(abs(sourceRatio - framedRatio) < 0.001, "letterboxed, never stretched")
    }

    // MARK: - Camera

    @Test func withoutZoomsTheCameraStaysPut() {
        let scene = builder().descriptor(for: timeline(), at: time(5))
        #expect(scene.zoom == 1)
        #expect(scene.transformedVideoFrame == scene.videoFrame)
    }

    @Test func aZoomScalesAboutItsCentre() {
        var timeline = timeline()
        timeline.zooms = [ZoomRegion(start: time(4), duration: time(6), scale: 2,
                                     center: CGPoint(x: 0.5, y: 0.5), transition: time(1),
                                     followsCursor: false)]
        let scene = builder().descriptor(for: timeline, at: time(7))

        #expect(scene.zoom == 2)
        let transformed = scene.transformedVideoFrame
        #expect(abs(transformed.midX - scene.videoFrame.midX) < 0.001, "the anchor does not move")
        #expect(abs(transformed.width - scene.videoFrame.width * 2) < 0.001)
    }

    /// Two zooms over the same moment must not multiply into a telescope.
    @Test func overlappingZoomsDoNotStack() {
        var timeline = timeline()
        timeline.zooms = [
            ZoomRegion(start: .zero, duration: time(10), scale: 2, transition: time(1), followsCursor: false),
            ZoomRegion(start: time(2), duration: time(6), scale: 3, transition: time(1), followsCursor: false),
        ]
        let scene = builder().descriptor(for: timeline, at: time(5))
        #expect(scene.zoom == 3, "the strongest one wins")
    }

    /// Zoomed in, the camera cannot wander so far that the frame shows its own edge.
    @Test func theCameraStaysInsideThePicture() {
        var timeline = timeline()
        timeline.zooms = [ZoomRegion(start: .zero, duration: time(10), scale: 2,
                                     center: CGPoint(x: 0.99, y: 0.01), transition: time(1),
                                     followsCursor: false)]
        let scene = builder().descriptor(for: timeline, at: time(5))

        #expect(scene.zoomCenter.x <= 0.75 + 0.001)
        #expect(scene.zoomCenter.y >= 0.25 - 0.001)
        let transformed = scene.transformedVideoFrame
        #expect(transformed.minX <= scene.videoFrame.minX + 0.001)
        #expect(transformed.maxX >= scene.videoFrame.maxX - 0.001)
    }

    @Test func aZoomThatFollowsTheCursorCentresOnIt() {
        var timeline = timeline()
        timeline.cursor.smoothing = 0
        timeline.zooms = [ZoomRegion(start: .zero, duration: time(10), scale: 2,
                                     transition: time(1), followsCursor: true)]
        // Recorded in points; the frame is 1600×1000 pixels at 2×, so 400,250 points is
        // the middle of the picture.
        let track = CursorTrack(samples: [CursorSample(t: 0, x: 400, y: 250, shape: .arrow),
                                          CursorSample(t: 10, x: 400, y: 250, shape: .arrow)])
        let scene = builder().descriptor(for: timeline, at: time(5), cursor: track)

        #expect(abs(scene.zoomCenter.x - 0.5) < 0.01)
        #expect(abs(scene.zoomCenter.y - 0.5) < 0.01)
    }

    /// The camera must not be welded to the pointer.
    ///
    /// At 2× every twitch of a hand is 2× on screen. A camera that copies the mouse
    /// exactly is the single thing that makes a zoom unwatchable, so it has to move
    /// markedly less than the pointer it is following.
    @Test func theCameraDoesNotCopyEveryTwitchOfThePointer() {
        var timeline = timeline()
        timeline.cursor.smoothing = 0
        timeline.zooms = [ZoomRegion(start: .zero, duration: time(10), scale: 2,
                                     transition: time(1), followsCursor: true)]

        // A hand resting near the middle, jittering either side of it.
        var samples: [CursorSample] = []
        for step in 0...200 {
            let t = Double(step) / 20
            let jitter = step.isMultiple(of: 2) ? 60.0 : -60.0
            samples.append(CursorSample(t: t, x: 400 + jitter, y: 250, shape: .arrow))
        }
        let track = CursorTrack(samples: samples)
        let builder = builder()

        // How far the camera travels across a second in the middle of the zoom.
        var travelled = 0.0
        var previous: Double?
        for step in 0...30 {
            let at = 5 + Double(step) / 30
            let centre = builder.descriptor(for: timeline, at: time(at), cursor: track).zoomCenter.x
            if let previous { travelled += abs(centre - previous) }
            previous = centre
        }

        // The pointer itself swings 120 points — 0.15 of the 800-point-wide frame — on
        // every one of those samples. The camera must be far calmer than that.
        #expect(travelled < 0.15, "the camera rode the jitter: travelled \(travelled)")
    }

    /// Starting a zoom must not snap the camera onto the pointer.
    ///
    /// The centre is blended in as the zoom arrives; cutting to the pointer at the first
    /// frame lurches, and the edge-clamp then drags the centre across the frame as the
    /// margin opens up.
    @Test func theCameraArrivesRatherThanLurching() {
        var timeline = timeline()
        timeline.cursor.smoothing = 0
        timeline.zooms = [ZoomRegion(start: .zero, duration: time(10), scale: 2,
                                     center: CGPoint(x: 0.5, y: 0.5),
                                     transition: time(2), followsCursor: true)]
        // The pointer sits well off to one side the whole time.
        let track = CursorTrack(samples: [CursorSample(t: 0, x: 700, y: 250, shape: .arrow),
                                          CursorSample(t: 10, x: 700, y: 250, shape: .arrow)])
        let builder = builder()

        let early = builder.descriptor(for: timeline, at: time(0.1), cursor: track).zoomCenter.x
        let settled = builder.descriptor(for: timeline, at: time(5), cursor: track).zoomCenter.x

        #expect(abs(early - 0.5) < 0.1, "it starts from the centre it was given, not from the pointer")
        #expect(settled > early, "and travels towards the pointer as the zoom arrives")
    }

    /// The pointer must stay inside the frame the zoom is showing.
    ///
    /// The camera follows an average of where the pointer has been, so it necessarily
    /// lags the pointer itself — and the cursor is drawn where it actually is. At 2× and
    /// above, that gap is magnified until the pointer slides out of the zoomed frame
    /// altogether and the viewer is watching the wrong part of the screen while the
    /// cursor does the work somewhere off-screen.
    ///
    /// Following has to lag. Losing the subject is a different thing.
    @Test func theZoomNeverLosesThePointer() {
        var timeline = timeline()
        timeline.cursor.smoothing = 0
        timeline.zooms = [ZoomRegion(start: .zero, duration: time(10), scale: 2.5,
                                     transition: time(0.5), followsCursor: true)]

        // Still, then a flick, then still again — the shape of almost every real pointer
        // move. 640 points in a third of a second is an unremarkable speed for reaching
        // across to a toolbar; the average the camera follows cannot keep up with it.
        var samples: [CursorSample] = []
        for step in 0...400 {
            let t = Double(step) / 40
            let x: Double = switch t {
            case ..<2: 80
            case ..<2.3: 80 + 640 * ((t - 2) / 0.3)
            default: 720
            }
            samples.append(CursorSample(t: t, x: x, y: 250, shape: .arrow))
        }
        let track = CursorTrack(samples: samples)
        let builder = builder()

        var worst = 0.0
        var worstAt = 0.0
        for step in 0...80 {
            let at = 1 + Double(step) / 20
            let scene = builder.descriptor(for: timeline, at: time(at), cursor: track)
            guard let cursor = scene.cursor else { continue }
            // What the zoomed frame actually shows, in the same unit space the cursor
            // and the camera centre are both expressed in.
            let half = 0.5 / scene.zoom
            let overshoot = max(abs(cursor.position.x - scene.zoomCenter.x) - half,
                                abs(cursor.position.y - scene.zoomCenter.y) - half)
            if overshoot > worst { worst = overshoot; worstAt = at }
        }

        #expect(worst <= 0, "the pointer left the zoomed frame by \(worst) of it at \(worstAt)s")
    }

    /// A pointer in the corner is kept in shot without the frame leaving the picture.
    ///
    /// The two rules pull against each other there: keeping the pointer in frame wants the
    /// camera past the edge, and the picture bound says it cannot go. The picture wins —
    /// otherwise a zoom in the corner shows empty canvas, which is the one thing the
    /// background modes are allowed to decide and the camera is not.
    @Test func aPointerInTheCornerIsHeldWithoutShowingEmptyCanvas() {
        var timeline = timeline()
        timeline.cursor.smoothing = 0
        timeline.zooms = [ZoomRegion(start: .zero, duration: time(10), scale: 2,
                                     transition: time(0.2), followsCursor: true)]
        // Hard into the top-left corner of the 800 × 500 recorded frame.
        let track = CursorTrack(samples: [CursorSample(t: 0, x: 4, y: 3, shape: .arrow),
                                          CursorSample(t: 10, x: 4, y: 3, shape: .arrow)])

        let scene = builder().descriptor(for: timeline, at: time(5), cursor: track)
        let half = 0.5 / scene.zoom

        // The frame stays on the picture...
        #expect(scene.zoomCenter.x >= half - 0.0001)
        #expect(scene.zoomCenter.y >= half - 0.0001)
        #expect(scene.zoomCenter.x <= 1 - half + 0.0001)
        #expect(scene.zoomCenter.y <= 1 - half + 0.0001)

        // ...and the pointer is still inside it.
        let cursor = try? #require(scene.cursor)
        if let cursor {
            #expect(abs(cursor.position.x - scene.zoomCenter.x) <= half)
            #expect(abs(cursor.position.y - scene.zoomCenter.y) <= half)
        }
    }

    // MARK: - Layers

    @Test func onlyWhatIsOnScreenNowIsDescribed() {
        var timeline = timeline()
        timeline.blurs = [BlurRegion(start: time(10), duration: time(5), rect: .init(x: 0, y: 0, width: 0.5, height: 0.5))]
        timeline.annotations = [AnnotationItem(start: time(10), duration: time(5), kind: .rectangle,
                                               rect: .init(x: 0, y: 0, width: 0.4, height: 0.2))]

        #expect(builder().descriptor(for: timeline, at: time(2)).blurs.isEmpty)
        #expect(builder().descriptor(for: timeline, at: time(2)).annotations.isEmpty)
        #expect(builder().descriptor(for: timeline, at: time(12)).blurs.count == 1)
        #expect(builder().descriptor(for: timeline, at: time(12)).annotations.count == 1)
    }

    @Test func anAnnotationFadesInAndOutRatherThanBlinking() {
        var timeline = timeline()
        timeline.annotations = [AnnotationItem(start: time(10), duration: time(4), kind: .rectangle,
                                               rect: .init(x: 0, y: 0, width: 0.4, height: 0.2))]
        let builder = builder()
        let appearing = builder.descriptor(for: timeline, at: time(10.02)).annotations.first?.opacity ?? 1
        let held = builder.descriptor(for: timeline, at: time(12)).annotations.first?.opacity ?? 0
        let leaving = builder.descriptor(for: timeline, at: time(13.98)).annotations.first?.opacity ?? 1

        #expect(appearing < 0.5)
        #expect(held == 1)
        #expect(leaving < 0.5)
    }

    @Test func theCursorIsDescribedWhereItWasRecorded() {
        var timeline = timeline()
        timeline.cursor.smoothing = 0
        let track = CursorTrack(samples: [CursorSample(t: 0, x: 0, y: 0, shape: .iBeam),
                                          CursorSample(t: 10, x: 800, y: 500, shape: .iBeam)])
        let scene = builder().descriptor(for: timeline, at: time(5), cursor: track)

        let cursor = try! #require(scene.cursor)
        #expect(abs(cursor.position.x - 0.5) < 0.01)
        #expect(abs(cursor.position.y - 0.5) < 0.01)
        #expect(cursor.shape == .iBeam)
    }

    @Test func hidingTheCursorLeavesItOutEntirely() {
        var timeline = timeline()
        timeline.cursor.isVisible = false
        let track = CursorTrack(samples: [CursorSample(t: 0, x: 10, y: 10, shape: .arrow)])
        #expect(builder().descriptor(for: timeline, at: .zero, cursor: track).cursor == nil)
    }

    // MARK: - Rendering

    private func solidSource(_ colour: CIColor) -> CIImage {
        CIImage(color: colour).cropped(to: CGRect(origin: .zero, size: videoSize))
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int)? {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return nil }
        let offset = y * image.bytesPerRow + x * (image.bitsPerPixel / 8)
        return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
    }

    /// The whole promise of the renderer: a described frame comes out as the picture it
    /// described — background at the edges, recording in the middle.
    @Test func aRenderedFrameHasTheBackgroundOutsideAndTheVideoInside() throws {
        var timeline = timeline()
        timeline.style.background = .color(ColorValue(r: 0, g: 0, b: 1))
        timeline.style.padding = 0.1
        timeline.style.cornerRadius = 0
        timeline.style.shadowOpacity = 0
        timeline.cursor.isVisible = false

        let scene = builder().descriptor(for: timeline, at: .zero)
        let renderer = SceneRenderer()
        let image = try #require(renderer.cgImage(for: scene, source: solidSource(CIColor(red: 1, green: 0, blue: 0))))

        #expect(image.width == Int(scene.outputSize.width))
        #expect(image.height == Int(scene.outputSize.height))

        let corner = try #require(pixel(image, x: 4, y: 4))
        #expect(corner.b > 200 && corner.r < 60, "the corner is background")

        let middle = try #require(pixel(image, x: image.width / 2, y: image.height / 2))
        #expect(middle.r > 200 && middle.b < 60, "the middle is the recording")
    }

    @Test func withoutASourceTheFrameIsStillTheBackground() throws {
        var timeline = timeline()
        timeline.style.background = .color(ColorValue(r: 0, g: 1, b: 0))
        let scene = builder().descriptor(for: timeline, at: .zero)
        let image = try #require(SceneRenderer().cgImage(for: scene, source: nil))

        let middle = try #require(pixel(image, x: image.width / 2, y: image.height / 2))
        #expect(middle.g > 200)
    }

    /// Preview and export are the same call. This is the test that keeps it that way.
    @Test func thesameSceneRendersIdenticallyTwice() throws {
        let timeline = timeline()
        let scene = builder().descriptor(for: timeline, at: time(3))
        let renderer = SceneRenderer()
        let source = solidSource(CIColor(red: 0.2, green: 0.4, blue: 0.6))

        let first = try #require(renderer.cgImage(for: scene, source: source))
        let second = try #require(renderer.cgImage(for: scene, source: source))

        let a = try #require(pixel(first, x: first.width / 2, y: first.height / 2))
        let b = try #require(pixel(second, x: second.width / 2, y: second.height / 2))
        #expect(a == b)
    }

    @Test func aZoomedFrameNeverSpillsOverThePadding() throws {
        var timeline = timeline()
        timeline.style.background = .color(ColorValue(r: 0, g: 0, b: 1))
        timeline.style.padding = 0.12
        timeline.style.shadowOpacity = 0
        timeline.cursor.isVisible = false
        timeline.zooms = [ZoomRegion(start: .zero, duration: time(10), scale: 3,
                                     transition: time(1), followsCursor: false)]

        let scene = builder().descriptor(for: timeline, at: time(5))
        let image = try #require(SceneRenderer().cgImage(for: scene, source: solidSource(CIColor(red: 1, green: 0, blue: 0))))
        let corner = try #require(pixel(image, x: 3, y: 3))
        #expect(corner.b > 200, "the frame is still there under a 3× zoom")
    }

    @Test func theCursorIsDrawnAtTheSizeItWasAskedFor() throws {
        let small = try #require(CursorArtwork.image(.arrow, size: 20))
        let large = try #require(CursorArtwork.image(.arrow, size: 60))
        #expect(large.extent.width > small.extent.width)
        // Cached by rounded size, so an animating scale does not redraw every frame.
        #expect(CursorArtwork.image(.arrow, size: 20.4)?.extent == small.extent)
    }
}
