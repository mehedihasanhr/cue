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

    @Test func anExportDrawsAPaddedRecordingPixelForPixel() {
        var timeline = timeline()
        timeline.style.padding = 0.06
        let builder = builder()
        let project = builder.outputSize(for: timeline.style)
        let sharp = builder.sharpOutputSize(for: timeline.style)

        #expect(sharp.width > project.width, "a margin must not be paid for in the recording's pixels")
        let scene = builder.framingDescriptor(for: timeline, at: time(1)).scaled(by: sharp.width / project.width)
        #expect(abs(scene.videoFrame.width - videoSize.width) <= 2)
        #expect(abs(sharp.width / sharp.height - project.width / project.height) < 0.01)
        #expect(Int(sharp.width) % 2 == 0 && Int(sharp.height) % 2 == 0, "encoders reject odd dimensions")
    }

    @Test func withoutAFrameTheExportIsTheProjectSize() {
        var style = FrameStyle()
        style.padding = 0
        #expect(builder().sharpOutputSize(for: style) == builder().outputSize(for: style))
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
        // And held there *exactly*: a camera clamped at the right-hand edge has the
        // right-hand edge of the picture as the right-hand edge of its shot. Equality rather
        // than containment, because containment is what let a zoom drift towards the middle
        // of the picture for as long as it did — every rectangle that was wrong still
        // contained the one it was supposed to be.
        let transformed = scene.transformedVideoFrame
        #expect(abs(transformed.maxX - scene.videoFrame.maxX) < 1e-6)
        // Aimed at the top, which is Core Image's high y.
        #expect(abs(transformed.maxY - scene.videoFrame.maxY) < 1e-6)
        #expect(transformed.minX < scene.videoFrame.minX, "and the rest hangs off the far side")
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

    /// Following eases after the pointer instead of moving with it frame for frame.
    ///
    /// Moved by the pointer at each instant, the camera went from rest to the hand's full
    /// speed in a single frame when the pointer reached the edge of the dead zone, stopped
    /// as abruptly, and copied every tremor of a hand resting near the edge — the shake
    /// people saw after a zoom landed. Measured as how sharply the picture's movement
    /// changes from one frame to the next, at 60 frames a second, in points on screen.
    @Test func followingThePointerDoesNotShake() {
        var timeline = timeline()
        timeline.cursor.smoothing = 0
        timeline.zooms = [ZoomRegion(start: .zero, duration: time(10), scale: 2.5,
                                     transition: time(0.5), followsCursor: true)]
        let picture = CGSize(width: videoSize.width / 2, height: videoSize.height / 2)

        func worstJolt(_ samples: [CursorSample], from: Double, to: Double) -> Double {
            let track = CursorTrack(samples: samples)
            let builder = builder()
            var shown: [CGPoint] = []
            for frame in Int(from * 60)...Int(to * 60) {
                let scene = builder.descriptor(for: timeline, at: time(Double(frame) / 60), cursor: track)
                shown.append(CGPoint(x: scene.zoomCenter.x * picture.width * scene.zoom,
                                     y: scene.zoomCenter.y * picture.height * scene.zoom))
            }
            var worst = 0.0
            for index in 2..<shown.count {
                let a = shown[index - 2], b = shown[index - 1], c = shown[index]
                worst = max(worst, hypot(c.x - 2 * b.x + a.x, c.y - 2 * b.y + a.y))
            }
            return worst
        }

        // Still, a fast flick most of the way across the shot, still again — the kind that
        // shook the picture on a real take. (A flick across more than the whole shot in a
        // fraction of a second cannot be both followed smoothly and kept in shot; there
        // keeping it in shot wins — see `theZoomNeverLosesThePointer`.)
        var flick: [CursorSample] = []
        for step in 0...400 {
            let t = Double(step) / 40
            let x: Double = switch t {
            case ..<2: 200
            case ..<2.2: 200 + 300 * ((t - 2) / 0.2)
            default: 500
            }
            flick.append(CursorSample(t: t, x: x, y: 250, shape: .arrow))
        }
        let flickJolt = worstJolt(flick, from: 1, to: 4)
        // Moved with the pointer at each instant this was 31 pt; most of what is left is the
        // camera turning from following the flick to settling, at 2.5×.
        #expect(flickJolt < 20, "a flick jolted the picture \(flickJolt) pt in a frame")

        // A hand resting just past the edge of the dead zone, trembling by a few points
        // ten times a second.
        var tremor: [CursorSample] = []
        for step in 0...1_200 {
            let t = Double(step) / 120
            let x = 600 + 3 * sin(2 * Double.pi * 10 * t)
            tremor.append(CursorSample(t: t, x: x, y: 250, shape: .arrow))
        }
        let tremorJolt = worstJolt(tremor, from: 2, to: 6)
        // And this, moved with the pointer at each instant, was 6.9 pt: the shake itself.
        #expect(tremorJolt < 0.5, "a trembling hand shook the picture \(tremorJolt) pt in a frame")
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

    // MARK: - Camera settings

    /// A follow strength of zero is a zoom that holds still.
    ///
    /// Right for pushing in on something that does not move — a menu, a diagram — where
    /// following the pointer is the camera drifting off the subject.
    @Test func aFollowStrengthOfZeroHoldsTheCentreItWasGiven() {
        var timeline = timeline()
        timeline.cursor.smoothing = 0
        timeline.camera.follow = 0
        timeline.zooms = [ZoomRegion(start: .zero, duration: time(10), scale: 2,
                                     center: CGPoint(x: 0.5, y: 0.5),
                                     transition: time(0.2), followsCursor: true)]
        // The pointer sits hard over to one side the whole time.
        let track = CursorTrack(samples: [CursorSample(t: 0, x: 760, y: 250, shape: .arrow),
                                          CursorSample(t: 10, x: 760, y: 250, shape: .arrow)])

        let scene = builder().descriptor(for: timeline, at: time(5), cursor: track)
        #expect(abs(scene.zoomCenter.x - 0.5) < 0.001, "it followed the pointer anyway")
    }

    /// A tighter safe area keeps the pointer further inside the frame.
    ///
    /// This is the dead zone made visible: the same flick, framed two ways, and the only
    /// difference is how far the pointer is allowed to stray before the camera reacts.
    ///
    /// Judged once the hand has stopped. During the flick itself the camera eases after the
    /// pointer rather than moving with it frame for frame — taken at each instant, the dead
    /// zone dragged the picture from rest to the hand's full speed in one frame, which is
    /// the shake people saw — so a pointer that fast is let past the safe area for a moment,
    /// and only the edge of the frame is a hard limit.
    @Test(arguments: [0.4, 0.85]) func theSafeAreaBoundsHowFarThePointerStrays(_ safeArea: Double) {
        var timeline = timeline()
        timeline.cursor.smoothing = 0
        timeline.camera.safeArea = safeArea
        timeline.zooms = [ZoomRegion(start: .zero, duration: time(10), scale: 2.5,
                                     transition: time(0.5), followsCursor: true)]

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
        var worstFree = 0.0
        var worstAnywhere = 0.0
        for step in 0...80 {
            let at = 1 + Double(step) / 20
            let scene = builder.descriptor(for: timeline, at: time(at), cursor: track)
            guard let cursor = scene.cursor else { continue }
            // How far out the pointer got, as a fraction of centre-to-edge.
            let half = 0.5 / scene.zoom
            let reach = abs(cursor.position.x - scene.zoomCenter.x) / half
            worstAnywhere = max(worstAnywhere, reach)

            // Frames where the camera is pinned against the edge of the picture are not
            // evidence either way: there the safe area asks the camera to travel past the
            // picture, the picture wins, and the pointer sits further out than asked as a
            // result. That is the intended order — showing empty canvas would be worse —
            // so the setting is judged only where the camera was free to obey it.
            let pinned = min(abs(scene.zoomCenter.x - half), abs(scene.zoomCenter.x - (1 - half))) < 0.001
            // Settled: the flick is over and the camera's window has moved past it.
            let settled = at >= 2.3 + SceneBuilder.followWindow(steadiness: timeline.camera.steadiness)
            if !pinned { worstFree = max(worstFree, reach) }
            if !pinned, settled { worst = max(worst, reach) }
        }

        // Never past what was asked for where the camera was free once the hand has
        // settled, and actually pushed out to it, so the setting is doing the work rather
        // than the pointer happening to stay near the middle.
        #expect(worst <= safeArea + 0.02, "the pointer reached \(worst) of the way out")
        #expect(worstFree > safeArea - 0.2, "the setting never bound; the test proves nothing")
        // And wherever it was, it stayed in shot.
        #expect(worstAnywhere <= 1.0001, "the pointer left the frame entirely")
    }

    /// Steadiness is how long a stretch of the pointer the camera weighs, so a steadier
    /// camera spreads the same move over longer and arrives later.
    ///
    /// The pointer jumps back from the right to just right of centre at 2 s. A camera
    /// moved by the pointer at each instant would jump with it, which is the shake this
    /// replaced; a camera that weighs a stretch either side of now eases across instead.
    /// The pointer returns to just right of centre rather than all the way across, so the
    /// rule that keeps the drawn pointer in shot never binds.
    @Test func aSteadierCameraSpreadsAMoveOverLonger() {
        func centre(steadiness: Double, at seconds: Double) -> Double {
            var timeline = timeline()
            timeline.cursor.smoothing = 0
            timeline.camera.steadiness = steadiness
            // A close zoom, so the dead zone is narrow and the pointer's moves reach the
            // camera at all.
            timeline.zooms = [ZoomRegion(start: .zero, duration: time(10), scale: 3,
                                         transition: time(0.2), followsCursor: true)]
            var samples: [CursorSample] = []
            for step in 0...400 {
                let t = Double(step) / 40
                samples.append(CursorSample(t: t, x: t < 2 ? 720 : 440, y: 250, shape: .arrow))
            }
            return builder().descriptor(for: timeline,
                                        at: time(seconds),
                                        cursor: CursorTrack(samples: samples)).zoomCenter.x
        }

        #expect(centre(steadiness: 1, at: 2.1) > centre(steadiness: 0.05, at: 2.1) + 0.005,
                "a steadier camera arrives later")
        #expect(abs(centre(steadiness: 0.05, at: 2.3) - 0.5) < 0.01,
                "and a camera that weighs almost nothing either side is already home")
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

    /// The held-frame reading of a zoom, which is `camera.zoomsWholeFrame == false`: the
    /// content magnifies inside the frame the padding left, and the padding stays padding
    /// however far the zoom goes. Pinned rather than defaulted, because the default is now
    /// the other reading — see `ZoomScopeTests`.
    @Test func aZoomedFrameNeverSpillsOverThePadding() throws {
        var timeline = timeline()
        timeline.camera.zoomsWholeFrame = false
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

    // MARK: - The pointer over time

    /// A track that walks steadily to the right, so a change to the drawn pointer is
    /// visible as a difference from where the recorded hand actually was.
    private func walkingTrack() -> CursorTrack {
        CursorTrack(samples: stride(from: 0.0, through: 10.0, by: 0.05).map { t in
            CursorSample(t: t, x: 200 + t * 30, y: 250, shape: .arrow)
        })
    }

    /// The guard on "a project made before cursor regions existed renders as it did".
    ///
    /// Written as the old arithmetic spelled out again rather than as a comparison against
    /// another descriptor: with no region in force the pointer must be the track's own
    /// position and the track's own velocity, and saying so here means any future
    /// short-cut through the new code path fails a test rather than quietly moving a
    /// pointer in everybody's finished video.
    @Test func withNoCursorRegionsThePointerIsDrawnFromTheTrackAlone() throws {
        var timeline = timeline()
        timeline.cursor.smoothing = 0
        timeline.cursor.motionBlur = true
        timeline.cursor.clickEffect = false
        let track = walkingTrack()
        #expect(timeline.cursorRegions.isEmpty)

        for at in stride(from: 0.5, through: 9.5, by: 0.5) {
            let scene = builder().descriptor(for: timeline, at: time(at), cursor: track)
            let cursor = try #require(scene.cursor)
            let point = try #require(track.position(at: at))
            #expect(abs(cursor.position.x - point.x * 2 / videoSize.width) < 1e-9)
            #expect(abs(cursor.position.y - point.y * 2 / videoSize.height) < 1e-9)
            #expect(cursor.opacity == 1)
            let velocity = track.velocity(at: at)
            #expect(abs(cursor.velocity.dx - velocity.dx) < 1e-6)
            #expect(abs(cursor.velocity.dy - velocity.dy) < 1e-6)
        }
    }

    @Test func insideAHidingRegionThePointerIsNotDrawn() {
        var timeline = timeline()
        timeline.cursorRegions = [CursorRegion(start: time(2), duration: time(4))]
        let track = walkingTrack()

        #expect(builder().descriptor(for: timeline, at: time(4), cursor: track).cursor == nil)
        // And nothing changes outside it, which is the whole promise of a region.
        #expect(builder().descriptor(for: timeline, at: time(1), cursor: track).cursor != nil)
        #expect(builder().descriptor(for: timeline, at: time(7), cursor: track).cursor != nil)
    }

    /// The boundary, which is the part that can look like a fault.
    ///
    /// A pointer that disappears between two frames reads as a dropped frame, so the
    /// region fades it over its ramp: at the very edge it is fully drawn, a third of the
    /// way in it is part-way gone, and it never gets brighter on the way in.
    @Test func aHidingRegionFadesThePointerRatherThanBlinkingItOut() throws {
        var timeline = timeline()
        timeline.cursorRegions = [CursorRegion(start: time(2), duration: time(4),
                                               transition: time(1))]
        let track = walkingTrack()

        func opacity(_ at: Double) -> Double {
            builder().descriptor(for: timeline, at: time(at), cursor: track).cursor?.opacity ?? 0
        }

        #expect(abs(opacity(1.99) - 1) < 1e-6, "outside the region the pointer is untouched")
        let ramp = [opacity(2.1), opacity(2.3), opacity(2.5), opacity(2.7)]
        for value in ramp { #expect(value > 0 && value < 1, "a part-faded pointer, not a switch") }
        #expect(ramp == ramp.sorted(by: >), "the fade only ever goes one way on the way in")
        #expect(opacity(4) == 0, "fully hidden in the middle")
        // And symmetrical: the pointer comes back the way it left.
        #expect(abs(opacity(5.7) - opacity(2.3)) < 1e-6)
    }

    /// A held pointer settles where the region began and stays there.
    @Test func aHeldPointerComesToRestWhereTheRegionBegan() throws {
        var timeline = timeline()
        timeline.cursorRegions = [CursorRegion(start: time(2), duration: time(6),
                                               isHidden: false, isHeld: true,
                                               transition: time(0.5))]
        let track = walkingTrack()
        let anchor = try #require(track.position(at: 2))

        let held = try #require(builder().descriptor(for: timeline, at: time(5), cursor: track).cursor)
        #expect(abs(held.position.x - anchor.x * 2 / videoSize.width) < 1e-6,
                "the pointer is where the hand was when the stretch began")
        // Still, so motion blur has nothing to smear even though the hand kept moving.
        #expect(abs(held.velocity.dx) < 1)

        // Part-way through the ramp it is between the two, not at either end.
        let arriving = try #require(builder().descriptor(for: timeline, at: time(2.25), cursor: track).cursor)
        let live = try #require(track.position(at: 2.25))
        let x = arriving.position.x * videoSize.width / 2
        #expect(x > anchor.x && x < live.x, "eased, not frozen on a frame")
    }

    /// Extra calm moves the drawn pointer off the recorded one, towards where it has been.
    @Test func extraCalmDrawsThePointerBehindTheRecordedHand() throws {
        var timeline = timeline()
        let track = walkingTrack()
        let plain = try #require(builder().descriptor(for: timeline, at: time(5), cursor: track).cursor)

        timeline.cursorRegions = [CursorRegion(start: time(2), duration: time(6),
                                               isHidden: false, smoothing: 1,
                                               transition: time(0.5))]
        let calmed = try #require(builder().descriptor(for: timeline, at: time(5), cursor: track).cursor)

        #expect(calmed.position.x < plain.position.x, "averaging lags, which is what takes the snap out")
        #expect(plain.position.x - calmed.position.x < 0.05, "and lags by a little, not by a third of the frame")
    }

    /// A pointer nobody can see has no claim on the framing.
    ///
    /// Following *is* the clamp now — the camera holds the shot it was aimed at and moves
    /// only to keep the pointer inside it — so a pointer nobody can see stops moving it,
    /// and the frame settles back onto what the zoom was aimed at. What `followsCursor`
    /// says is the user's own decision about the zoom and is left alone.
    @Test func aHiddenPointerStopsDraggingTheCamera() throws {
        var timeline = timeline()
        timeline.cursor.smoothing = 0
        timeline.zooms = [ZoomRegion(start: .zero, duration: time(10), scale: 2,
                                     center: CGPoint(x: 0.5, y: 0.5),
                                     transition: time(0.5), followsCursor: true)]
        // Far enough right that at 2× the frame would lose it.
        let track = CursorTrack(samples: [CursorSample(t: 0, x: 780, y: 250, shape: .arrow),
                                          CursorSample(t: 10, x: 780, y: 250, shape: .arrow)])

        let pulled = builder().descriptor(for: timeline, at: time(5), cursor: track).zoomCenter.x
        #expect(pulled > 0.7, "the clamp is dragging the frame over to keep the pointer in shot")

        timeline.cursorRegions = [CursorRegion(start: time(2), duration: time(6), transition: time(0.5))]
        let released = builder().descriptor(for: timeline, at: time(5), cursor: track).zoomCenter.x
        #expect(released < 0.6, "with the pointer gone the frame settles back to where it was aimed")

        // And it lets go over the ramp rather than on one frame: part-way in, part-way back.
        let arriving = builder().descriptor(for: timeline, at: time(2.25), cursor: track).zoomCenter.x
        #expect(arriving > released && arriving < pulled)
    }

    @Test func theCursorIsDrawnAtTheSizeItWasAskedFor() throws {
        let small = try #require(CursorArtwork.image(.arrow, size: 20))
        let large = try #require(CursorArtwork.image(.arrow, size: 60))
        #expect(large.extent.width > small.extent.width)
        // Cached by rounded size, so an animating scale does not redraw every frame.
        #expect(CursorArtwork.image(.arrow, size: 20.4)?.extent == small.extent)
    }
    // MARK: - Which way up a zoom points

    /// The recording, top half red and bottom half blue as the viewer sees it.
    ///
    /// Built in Core Image's bottom-left space, so the red is the high half of the extent.
    private func topRedSource() -> CIImage {
        let top = CIImage(color: CIColor(red: 1, green: 0, blue: 0))
            .cropped(to: CGRect(x: 0, y: videoSize.height / 2,
                                width: videoSize.width, height: videoSize.height / 2))
        let bottom = CIImage(color: CIColor(red: 0, green: 0, blue: 1))
            .cropped(to: CGRect(x: 0, y: 0, width: videoSize.width, height: videoSize.height / 2))
        return top.composited(over: bottom)
    }

    /// A zoom points where the model says it points, and the model measures from the top.
    ///
    /// Pixels rather than rectangles, because the fault this catches was a rectangle that
    /// looked right: `zoomCenter` is normalised from the top of the picture like every other
    /// point in the model — a crop, a blur, an annotation, the pointer — while the frame it
    /// anchors lives in Core Image's bottom-left space, and the conversion was missing. A
    /// zoom aimed at the top of the shot showed the bottom of it.
    @Test(arguments: [(0.0, "red", true), (1.0, "blue", false)])
    func aZoomShowsTheHalfOfThePictureItIsAimedAt(_ centre: Double, _ expected: String, _ isRed: Bool) throws {
        var timeline = timeline()
        timeline.style.padding = 0
        timeline.style.cornerRadius = 0
        timeline.style.shadowOpacity = 0
        timeline.cursor.isVisible = false
        timeline.zooms = [ZoomRegion(start: .zero, duration: time(10), scale: 4,
                                     center: CGPoint(x: 0.5, y: centre), easing: .linear,
                                     transition: .zero, followsCursor: false)]

        let scene = builder().descriptor(for: timeline, at: time(5))
        let image = try #require(SceneRenderer().cgImage(for: scene, source: topRedSource()))
        let middle = try #require(pixel(image, x: image.width / 2, y: image.height / 2))

        #expect((middle.r > 200 && middle.b < 60) == isRed,
                "aimed at \(centre) the frame should be \(expected), got \(middle)")
    }

    // MARK: - A split zoom, as the renderer sees it

    /// The renderer is the only place this matters, and it resolves overlaps by taking the
    /// deepest zoom — so a split that holds up in the model has to be checked here too.
    @Test func splittingAZoomChangesNoFrame() throws {
        var whole = timeline()
        whole.cursor.isVisible = false
        let region = ZoomRegion(start: time(4), duration: time(12), scale: 2.5,
                                center: CGPoint(x: 0.4, y: 0.6), transition: time(0.6),
                                followsCursor: false)
        whole.zooms = [region]

        var cut = whole
        let (first, second) = try #require(ZoomLane.split(region, at: time(10)))
        cut.zooms = [first, second]

        let builder = builder()
        for step in 0...900 {
            let at = time(3 + Double(step) / 50)
            let before = builder.descriptor(for: whole, at: at)
            let after = builder.descriptor(for: cut, at: at)
            #expect(abs(before.zoom - after.zoom) < 1e-9, "the camera moved at \(at.seconds)s")
            #expect(before.zoomCenter == after.zoomCenter)
            #expect(before.transformedVideoFrame == after.transformedVideoFrame)
        }
    }

    @Test func aimingOneHalfOfASplitLeavesTheOtherHalfWhereItWas() throws {
        var timeline = timeline()
        timeline.cursor.isVisible = false
        let region = ZoomRegion(start: time(4), duration: time(12), scale: 2.5,
                                transition: time(0.6), followsCursor: false)
        let halves = try #require(ZoomLane.split(region, at: time(10)))
        let first = halves.0
        var second = halves.1
        second.center = CGPoint(x: 0.8, y: 0.2)
        timeline.zooms = [first, second]

        let builder = builder()
        // Half a second either side of the seam: the aim changes, the depth does not.
        let before = builder.descriptor(for: timeline, at: time(9.5))
        let after = builder.descriptor(for: timeline, at: time(10.5))
        #expect(abs(before.zoom - after.zoom) < 1e-9, "still fully in across the cut")
        #expect(before.zoomCenter != after.zoomCenter, "and now aimed somewhere else")
    }


    // MARK: - Where a zoom actually points

    /// The framed region ends up in the middle of the picture, not somewhere between there
    /// and the middle of the recording.
    ///
    /// The arithmetic statement of the fault this rectangle had: it scaled the picture about
    /// the aimed-at point and left that point where it was, so the source coordinate landing
    /// in the middle of the frame came out as `c + (0.5 - c) / zoom`. Every shot not aimed at
    /// the exact centre was pulled towards the middle, further the harder it zoomed — and
    /// 0.5, 0.5 was the only centre any pixel test used, which is why it went unnoticed.
    ///
    /// Read back out of the rectangle rather than asserted as a rectangle, so the claim is
    /// the one that matters — *this* part of the recording is what fills the frame — rather
    /// than a transcription of whatever the formula currently says.
    @Test(arguments: [
        (2.0, CGPoint(x: 0.5, y: 0.5)),
        (2.0, CGPoint(x: 0.25, y: 0.75)),
        (4.0, CGPoint(x: 0.125, y: 0.125)),
        (4.0, CGPoint(x: 0.875, y: 0.875)),
        (8.0, CGPoint(x: 0.4, y: 0.6)),
    ])
    func anOffCentreZoomDoesNotDriftTowardTheMiddle(scale: Double, centre: CGPoint) {
        var timeline = timeline()
        timeline.style.padding = 0.12
        timeline.zooms = [ZoomRegion(start: .zero, duration: time(10), scale: scale,
                                     center: centre, easing: .linear, transition: .zero,
                                     followsCursor: false)]
        let scene = builder().descriptor(for: timeline, at: time(5))
        let frame = scene.transformedVideoFrame

        // Which point of the recording is drawn at the centre of the picture, back in the
        // model's top-left space.
        let u = (scene.videoFrame.midX - frame.minX) / frame.width
        let v = 1 - (scene.videoFrame.midY - frame.minY) / frame.height

        #expect(abs(u - scene.zoomCenter.x) < 1e-9, "\(scale)x at \(centre) points sideways")
        #expect(abs(v - scene.zoomCenter.y) < 1e-9, "\(scale)x at \(centre) points up or down")
    }
}
