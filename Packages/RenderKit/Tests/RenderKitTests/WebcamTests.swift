import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import RecordKit
import Testing
import TimelineKit
@testable import RenderKit

/// Where the camera bubble lands, what shape it is, and what it does to a frame that has
/// no camera in it — which must be nothing at all.
struct WebcamTests {
    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    /// 1600 × 1000, so the shorter side is a round 1000 and every fraction below is a
    /// number that can be read rather than one that has to be trusted.
    private let videoSize = CGSize(width: 1_600, height: 1_000)

    private func builder() -> SceneBuilder {
        SceneBuilder(videoSize: videoSize, displayScale: 2)
    }

    /// A timeline with nothing on it but the bubble, so a failure here is about the bubble.
    private func timeline(_ configure: (inout WebcamSettings) -> Void = { _ in }) -> Timeline {
        var timeline = Timeline(sourceDuration: time(60))
        timeline.style.padding = 0
        timeline.style.cornerRadius = 0
        timeline.style.shadowOpacity = 0
        timeline.cursor.isVisible = false
        timeline.style.background = .color(ColorValue(r: 0, g: 0, b: 1))
        configure(&timeline.webcam)
        return timeline
    }

    // MARK: - A recording with no camera

    /// The guard on "nothing changes for anybody who has not got a webcam".
    ///
    /// The whole absent case rests on the layer being nil rather than on the renderer
    /// remembering to skip a disabled one, so that is what is asserted — a bubble that is
    /// merely invisible would still be a branch, a crop and a mask in the frame's graph.
    @Test func withTheCameraOffNoBubbleIsDescribedAtAll() {
        let scene = builder().descriptor(for: timeline(), at: time(3))
        #expect(scene.webcam == nil)
    }

    /// Off is off even when a camera frame is going spare.
    ///
    /// Bytes rather than fields, because this is the failure that would reach a finished
    /// video: a renderer that drew whatever it was handed regardless of the description
    /// would pass the test above and still put a face in an old project.
    @Test func aCameraFrameCannotReachAFrameThatDidNotAskForOne() throws {
        let scene = builder().descriptor(for: timeline(), at: time(3))
        let renderer = SceneRenderer()
        let screen = solid(CIColor(red: 1, green: 0, blue: 0), size: videoSize)

        let without = try #require(renderer.cgImage(for: scene, source: screen))
        let with = try #require(renderer.cgImage(for: scene, source: screen,
                                                 webcam: solid(CIColor(red: 0, green: 1, blue: 0),
                                                               size: CGSize(width: 640, height: 480))))
        #expect(try bytes(without) == bytes(with))
    }

    /// And a bubble that is asked for but has no footage behind it draws nothing, rather
    /// than a hole. A camera file deleted out of a package has to look like this.
    @Test func aBubbleWithNoFootageLeavesTheFrameAlone() throws {
        let on = timeline { $0.isEnabled = true }
        let scene = builder().descriptor(for: on, at: time(3))
        #expect(scene.webcam != nil)

        let renderer = SceneRenderer()
        let screen = solid(CIColor(red: 1, green: 0, blue: 0), size: videoSize)
        let drawn = try #require(renderer.cgImage(for: scene, source: screen, webcam: nil))
        let bare = try #require(renderer.cgImage(for: builder().descriptor(for: timeline(), at: time(3)),
                                                 source: screen))
        #expect(try bytes(drawn) == bytes(bare))
    }

    // MARK: - Where it lands

    /// Each corner puts the bubble against its own two edges, the same distance in.
    ///
    /// Written as the four cases rather than as one with arithmetic, because the mistake
    /// worth catching here is a transposition — bottom-left drawn top-left — and a test
    /// that computes the expected corner from the corner would make it too.
    @Test(arguments: [
        (WebcamSettings.Corner.topLeft, true, true),
        (WebcamSettings.Corner.topRight, false, true),
        (WebcamSettings.Corner.bottomLeft, true, false),
        (WebcamSettings.Corner.bottomRight, false, false),
    ])
    func aCornerParksTheBubbleAgainstItsOwnTwoEdges(_ corner: WebcamSettings.Corner,
                                                    _ isLeft: Bool,
                                                    _ isTop: Bool) throws {
        let on = timeline {
            $0.isEnabled = true
            $0.corner = corner
            $0.size = 0.2
            $0.reactsToZoom = false
        }
        let scene = builder().descriptor(for: on, at: .zero)
        let rect = try #require(scene.webcam?.rect)

        // 0.2 of the shorter side (1000) is 200px; the margin is 0.035 of it, 35px.
        let inset = CGSize(width: 35 / 1_600.0, height: 35 / 1_000.0)
        let size = CGSize(width: 200 / 1_600.0, height: 200 / 1_000.0)

        #expect(abs(rect.width - size.width) < 0.0001)
        #expect(abs(rect.height - size.height) < 0.0001)
        if isLeft {
            #expect(abs(rect.minX - inset.width) < 0.0001, "left edge")
        } else {
            #expect(abs(1 - rect.maxX - inset.width) < 0.0001, "right edge")
        }
        if isTop {
            #expect(abs(rect.minY - inset.height) < 0.0001, "top edge")
        } else {
            #expect(abs(1 - rect.maxY - inset.height) < 0.0001, "bottom edge")
        }
    }

    /// A square bubble whatever the output's shape. `size` is a fraction of the shorter
    /// side, so the bubble's two sides are the same number of *pixels* and therefore
    /// different fractions of a 16:10 frame — which is the trap in checking this
    /// normalised.
    @Test func theBubbleIsSquareInPixelsRatherThanInFractions() throws {
        let on = timeline {
            $0.isEnabled = true
            $0.size = 0.25
            $0.reactsToZoom = false
        }
        let scene = builder().descriptor(for: on, at: .zero)
        let layer = try #require(scene.webcam)
        let pixels = layer.pixelRect(in: scene.outputSize)

        #expect(abs(pixels.width - 250) < 0.001)
        #expect(abs(pixels.height - 250) < 0.001)
    }

    /// `.custom` is honoured, and `position` is the bubble's centre.
    ///
    /// The centre rather than the corner is the reading a drag hands over and the only one
    /// under which the model's own default — (0.85, 0.85) with `.bottomRight` — means the
    /// same thing twice.
    @Test func aCustomPositionIsTheBubblesCentre() throws {
        let on = timeline {
            $0.isEnabled = true
            $0.corner = .custom
            $0.position = CGPoint(x: 0.3, y: 0.4)
            $0.size = 0.2
            $0.reactsToZoom = false
        }
        let scene = builder().descriptor(for: on, at: .zero)
        let rect = try #require(scene.webcam?.rect)

        #expect(abs(rect.midX - 0.3) < 0.0001)
        #expect(abs(rect.midY - 0.4) < 0.0001)
    }

    /// A position off the edge is pulled back in. A project is a file, and a file can ask
    /// for a bubble halfway off the frame; a render nobody can explain is worse than a
    /// bubble that is not quite where the numbers said.
    @Test(arguments: [CGPoint(x: -3, y: 0.5), CGPoint(x: 0.5, y: 12), CGPoint(x: 1.4, y: -0.2)])
    func aBubbleOffTheEdgeIsBroughtBack(_ position: CGPoint) throws {
        let on = timeline {
            $0.isEnabled = true
            $0.corner = .custom
            $0.position = position
        }
        let rect = try #require(builder().descriptor(for: on, at: .zero).webcam?.rect)

        #expect(rect.minX >= 0 && rect.maxX <= 1)
        #expect(rect.minY >= 0 && rect.maxY <= 1)
    }

    /// An absurd size is clamped rather than obeyed, for the same reason.
    @Test(arguments: [(-4.0, 0.05), (40.0, 0.6)])
    func anAbsurdSizeIsClampedToSomethingDrawable(_ asked: Double, _ expected: Double) throws {
        let on = timeline {
            $0.isEnabled = true
            $0.size = asked
            $0.reactsToZoom = false
        }
        let scene = builder().descriptor(for: on, at: .zero)
        let pixels = try #require(scene.webcam).pixelRect(in: scene.outputSize)
        #expect(abs(pixels.width - 1_000 * expected) < 0.001)
    }

    /// Roundness is the fraction of the way to a circle, and a circle is half the side.
    @Test(arguments: [(0.0, 0.0), (0.5, 55.0), (1.0, 110.0)])
    func roundnessResolvesToARadiusInPixels(_ roundness: Double, _ radius: Double) throws {
        let on = timeline {
            $0.isEnabled = true
            $0.size = 0.22
            $0.roundness = roundness
            $0.reactsToZoom = false
        }
        let layer = try #require(builder().descriptor(for: on, at: .zero).webcam)
        #expect(abs(layer.cornerRadius - radius) < 0.001)
    }

    /// Growing while zoomed is an option, and it is gently capped: a bubble tracking a 4×
    /// zoom one-for-one would end up most of the picture.
    @Test func theBubbleGrowsWhileZoomedOnlyWhenAskedAndOnlyALittle() throws {
        func side(reacting: Bool, scale: Double) throws -> Double {
            var on = timeline {
                $0.isEnabled = true
                $0.size = 0.2
                $0.reactsToZoom = reacting
            }
            on.zooms = [ZoomRegion(start: .zero, duration: time(10), scale: scale,
                                   easing: .linear, transition: .zero, followsCursor: false)]
            let scene = builder().descriptor(for: on, at: time(5))
            return try #require(scene.webcam).pixelRect(in: scene.outputSize).width
        }

        #expect(try side(reacting: false, scale: 3) == 200)
        #expect(try side(reacting: true, scale: 1) == 200)
        let grown = try side(reacting: true, scale: 3)
        #expect(grown > 200, "it grows")
        #expect(grown <= 200 * 1.3 + 0.001, "but never by more than a third")
    }

    // MARK: - What it looks like

    /// The bubble is drawn, where it was told, over the picture and not over the padding.
    @Test func theBubbleIsDrawnWhereItWasPlaced() throws {
        let on = timeline {
            $0.isEnabled = true
            $0.corner = .bottomRight
            $0.size = 0.25
            $0.roundness = 0
            $0.shadowOpacity = 0
            $0.isMirrored = false
            $0.reactsToZoom = false
        }
        let scene = builder().descriptor(for: on, at: .zero)
        let rect = try #require(scene.webcam?.rect)
        let image = try #require(SceneRenderer().cgImage(
            for: scene,
            source: solid(CIColor(red: 1, green: 0, blue: 0), size: videoSize),
            webcam: solid(CIColor(red: 0, green: 1, blue: 0), size: CGSize(width: 640, height: 480))))

        let inside = try #require(pixel(image, x: Int(rect.midX * Double(image.width)),
                                        y: Int(rect.midY * Double(image.height))))
        #expect(inside.g > 200 && inside.r < 60, "the bubble is the camera")

        // The opposite corner of the frame is still the recording, so the bubble has not
        // been drawn over the whole picture.
        let elsewhere = try #require(pixel(image, x: image.width / 8, y: image.height / 8))
        #expect(elsewhere.r > 200 && elsewhere.g < 60, "and the rest is still the screen")
    }

    /// A wide camera in a square bubble shows the middle of its shot.
    ///
    /// The source is three vertical stripes and the bubble is a third of its width once
    /// scaled, so "fill, centred" means the bubble is entirely the middle stripe. Letterbox
    /// or stretch would both put one of the outer stripes on screen.
    @Test func aWideCameraIsCroppedToTheMiddleOfItsShot() throws {
        let on = timeline {
            $0.isEnabled = true
            $0.size = 0.25
            $0.roundness = 0
            $0.shadowOpacity = 0
            $0.isMirrored = false
            $0.reactsToZoom = false
        }
        let scene = builder().descriptor(for: on, at: .zero)
        let rect = try #require(scene.webcam?.rect)
        let image = try #require(SceneRenderer().cgImage(
            for: scene,
            source: solid(CIColor(red: 0, green: 0, blue: 0), size: videoSize),
            webcam: stripes(size: CGSize(width: 1_200, height: 400))))

        // Near both edges of the bubble as well as its middle: a fill that was off-centre
        // would still be green in the middle.
        for fraction in [0.1, 0.5, 0.9] {
            let x = Int((rect.minX + rect.width * fraction) * Double(image.width))
            let y = Int(rect.midY * Double(image.height))
            let sample = try #require(pixel(image, x: x, y: y))
            #expect(sample.g > 200 && sample.r < 60 && sample.b < 60,
                    "at \(fraction) across the bubble the camera's middle stripe should show, got \(sample)")
        }
    }

    /// Mirroring flips the camera and does not move it.
    ///
    /// A negative scale reflects through the origin, so the bug this catches is a bubble
    /// that comes out correctly mirrored and somewhere else entirely — or, worse, off the
    /// frame and therefore not drawn at all.
    @Test(arguments: [false, true])
    func mirroringFlipsTheCameraWithoutMovingTheBubble(_ mirrored: Bool) throws {
        let on = timeline {
            $0.isEnabled = true
            $0.corner = .custom
            $0.position = CGPoint(x: 0.5, y: 0.5)
            $0.size = 0.3
            $0.roundness = 0
            $0.shadowOpacity = 0
            $0.isMirrored = mirrored
            $0.reactsToZoom = false
        }
        let scene = builder().descriptor(for: on, at: .zero)
        let rect = try #require(scene.webcam?.rect)
        // Square, so the fill is an exact scale and the halves stay halves.
        let camera = halves(size: CGSize(width: 480, height: 480))
        let image = try #require(SceneRenderer().cgImage(
            for: scene,
            source: solid(CIColor(red: 0, green: 0, blue: 0), size: videoSize),
            webcam: camera))

        let y = Int(rect.midY * Double(image.height))
        let left = try #require(pixel(image, x: Int((rect.minX + rect.width * 0.2) * Double(image.width)), y: y))
        let right = try #require(pixel(image, x: Int((rect.minX + rect.width * 0.8) * Double(image.width)), y: y))

        // Unmirrored the camera's left half — green — is on the left.
        #expect((left.g > 200) == !mirrored, "left of the bubble, mirrored \(mirrored): \(left)")
        #expect((right.g > 200) == mirrored, "right of the bubble, mirrored \(mirrored): \(right)")
    }

    // MARK: - Sources and pixels

    private func solid(_ colour: CIColor, size: CGSize) -> CIImage {
        CIImage(color: colour).cropped(to: CGRect(origin: .zero, size: size))
    }

    /// Red, green, blue in three vertical stripes of equal width.
    private func stripes(size: CGSize) -> CIImage {
        let third = size.width / 3
        let left = CIImage(color: CIColor(red: 1, green: 0, blue: 0))
            .cropped(to: CGRect(x: 0, y: 0, width: third, height: size.height))
        let middle = CIImage(color: CIColor(red: 0, green: 1, blue: 0))
            .cropped(to: CGRect(x: third, y: 0, width: third, height: size.height))
        let right = CIImage(color: CIColor(red: 0, green: 0, blue: 1))
            .cropped(to: CGRect(x: third * 2, y: 0, width: third, height: size.height))
        return left.composited(over: middle.composited(over: right))
    }

    /// Green on the left, red on the right — so a flip is unmistakable.
    private func halves(size: CGSize) -> CIImage {
        let left = CIImage(color: CIColor(red: 0, green: 1, blue: 0))
            .cropped(to: CGRect(x: 0, y: 0, width: size.width / 2, height: size.height))
        let right = CIImage(color: CIColor(red: 1, green: 0, blue: 0))
            .cropped(to: CGRect(x: size.width / 2, y: 0, width: size.width / 2, height: size.height))
        return left.composited(over: right)
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int)? {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return nil }
        guard x >= 0, y >= 0, x < image.width, y < image.height else { return nil }
        let offset = y * image.bytesPerRow + x * (image.bitsPerPixel / 8)
        return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
    }

    /// Every byte of a rendered frame, for the comparisons that have to be exact.
    private func bytes(_ image: CGImage) throws -> Data {
        let data = try #require(image.dataProvider?.data)
        return Data(referencing: data as NSData)
    }
}
