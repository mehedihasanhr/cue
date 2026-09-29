import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import Testing
import TimelineKit
@testable import RenderKit

/// The picture turned in space, and what is drawn on it staying on it.
///
/// The promise is that the pointer, a click and an annotation are points *on the picture*:
/// turn the picture and they go where the part of the picture under them went. These draw
/// a mark into the recording and the pointer over it, turn the frame, and measure where
/// each one landed.
struct PerspectiveRenderTests {
    private let output = CGSize(width: 1_600, height: 1_000)
    private let tilt = PerspectiveLayer(turn: 22, lean: 14, rotation: 4, depthShadow: 0.5)

    /// A frame with padding, so the turned picture has room, and the given layers on it.
    private func scene(perspective: PerspectiveLayer?,
                       cursor: CursorLayer? = nil,
                       clicks: [ClickLayer] = []) -> SceneDescriptor {
        var scene = SceneDescriptor(outputSize: output,
                                    background: .color(ColorValue(r: 0, g: 0, b: 0)),
                                    videoFrame: CGRect(x: 160, y: 100, width: 1_280, height: 800),
                                    cornerRadius: 0,
                                    shadowRadius: 0,
                                    shadowOpacity: 0,
                                    cursor: cursor,
                                    clicks: clicks)
        scene.perspective = perspective
        return scene
    }

    /// A black recording with one small white square in it, centred on a point given as a
    /// fraction of the picture from its top-left.
    private func marked(at point: CGPoint, side: Double = 10) -> CIImage {
        let size = CGSize(width: 1_280, height: 800)
        let square = CGRect(x: point.x * size.width - side / 2,
                            y: (1 - point.y) * size.height - side / 2,
                            width: side, height: side)
        return CIImage(color: .white).cropped(to: square)
            .composited(over: CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: size)))
    }

    private func black() -> CIImage {
        CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 1_280, height: 800))
    }

    /// The centre of the light in a frame, in Core Image's space (bottom-left origin).
    private func light(_ scene: SceneDescriptor, source: CIImage, above threshold: Double = 0.5) throws -> CGPoint {
        let pixels = DressingPixels(try #require(SceneRenderer().cgImage(for: scene, source: source)))
        var sumX = 0.0, sumY = 0.0, total = 0.0
        for y in 0..<pixels.height {
            for x in 0..<pixels.width {
                let c = pixels.colour(x, y)
                let value = (c.r + c.g + c.b) / 3 * c.a
                guard value > threshold else { continue }
                sumX += (Double(x) + 0.5) * value
                sumY += (Double(y) + 0.5) * value
                total += value
            }
        }
        try #require(total > 0, "nothing was drawn")
        return CGPoint(x: sumX / total, y: Double(pixels.height) - sumY / total)
    }

    /// Where a point of the picture is in the flat frame, in Core Image's space.
    private func flat(_ point: CGPoint, in scene: SceneDescriptor) -> CGPoint {
        let video = scene.transformedVideoFrame
        return CGPoint(x: video.minX + point.x * video.width, y: video.maxY - point.y * video.height)
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(a.x - b.x, a.y - b.y) }

    // MARK: - The picture

    /// What Core Image draws and what the projection says are the same map: a mark in the
    /// recording lands where `projected` puts it, near each corner and in the middle.
    @Test(arguments: [CGPoint(x: 0.12, y: 0.15), CGPoint(x: 0.88, y: 0.2), CGPoint(x: 0.5, y: 0.5),
                      CGPoint(x: 0.2, y: 0.85), CGPoint(x: 0.9, y: 0.9)])
    func aMarkInThePictureLandsWhereTheProjectionSays(_ point: CGPoint) throws {
        let scene = scene(perspective: tilt)
        let drawn = try light(scene, source: marked(at: point))
        let expected = scene.projected(flat(point, in: scene))
        #expect(distance(drawn, expected) <= 2, "drawn at \(drawn), projected to \(expected)")
        // And it has actually moved: a test of a map that does nothing would pass.
        #expect(distance(expected, flat(point, in: scene)) > 10)
    }

    /// Turned to face left, the left edge is further away and so shorter than the right.
    @Test func theFarEdgeIsShorter() throws {
        var scene = scene(perspective: PerspectiveLayer(turn: 20, lean: 0))
        scene.background = .color(ColorValue(r: 0, g: 0, b: 0))
        let white = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 1_280, height: 800))
        let pixels = DressingPixels(try #require(SceneRenderer().cgImage(for: scene, source: white)))
        func height(ofColumn x: Int) -> Int {
            (0..<pixels.height).filter { pixels.colour(x, $0).r > 0.5 }.count
        }
        let corners = try #require(scene.perspectiveProjection).corners
        let left = height(ofColumn: Int(corners.topLeft.x.rounded()) + 6)
        let right = height(ofColumn: Int(corners.topRight.x.rounded()) - 6)
        #expect(left > 0 && right > 0)
        #expect(Double(left) < Double(right) * 0.95, "left \(left), right \(right)")
    }

    /// Turning never pushes the picture into the padding: the turned corners stay inside the
    /// rectangle the flat picture filled.
    @Test(arguments: FramePerspective.Preset.allCases.filter { $0 != .flat })
    func aTurnedPictureStaysInItsRoom(_ preset: FramePerspective.Preset) throws {
        let perspective = FramePerspective().with(preset)
        let scene = scene(perspective: PerspectiveLayer(turn: perspective.turn, lean: perspective.lean,
                                                        rotation: perspective.rotation))
        let projection = try #require(scene.perspectiveProjection)
        let room = scene.shadowCaster.insetBy(dx: -0.5, dy: -0.5)
        let c = projection.corners
        for corner in [c.topLeft, c.topRight, c.bottomLeft, c.bottomRight] {
            #expect(room.contains(corner), "\(preset): \(corner) outside \(room)")
        }
    }

    // MARK: - What is drawn on it

    /// The pointer's point is over the part of the picture it was over. A crosshair, whose
    /// point is its middle, drawn over nothing — and the white mark in the recording at the
    /// same place, drawn with no pointer — land within two pixels of each other.
    @Test(arguments: [CGPoint(x: 0.25, y: 0.3), CGPoint(x: 0.7, y: 0.65), CGPoint(x: 0.85, y: 0.15)])
    func thePointerStaysOnWhatItPointsAt(_ point: CGPoint) throws {
        let pointer = CursorLayer(position: point, shape: .crosshair, scale: 1.2)
        let withPointer = scene(perspective: tilt, cursor: pointer)
        let tip = try light(withPointer, source: black(), above: 0.3)
        let mark = try light(scene(perspective: tilt), source: marked(at: point, side: 6))
        #expect(distance(tip, mark) <= 2, "pointer at \(tip), the thing under it at \(mark)")
        let expected = withPointer.projected(flat(point, in: withPointer))
        #expect(distance(tip, expected) <= 2, "pointer at \(tip), projected to \(expected)")
    }

    /// A click is marked where it happened on the turned picture.
    @Test func aClickIsMarkedWhereItHappened() throws {
        let point = CGPoint(x: 0.3, y: 0.7)
        let click = ClickLayer(position: point, progress: 0.2,
                               color: ColorValue(r: 1, g: 1, b: 1), size: 0.08, isSecondary: false)
        let clicked = scene(perspective: tilt, clicks: [click])
        let ring = try light(clicked, source: black(), above: 0.3)
        let expected = clicked.projected(flat(point, in: clicked))
        #expect(distance(ring, expected) <= 2, "ring at \(ring), projected to \(expected)")
    }

    /// An annotation is a note on the picture, and turns with it: a small white box drawn
    /// over a spot is still over that spot.
    @Test func anAnnotationTurnsWithThePicture() throws {
        var scene = scene(perspective: tilt)
        // In the finished frame's space, over the picture's point (0.6, 0.4).
        let spot = flat(CGPoint(x: 0.6, y: 0.4), in: scene)
        let side = 16.0
        scene.annotations = [AnnotationLayer(kind: .rectangle,
                                             rect: CGRect(x: (spot.x - side / 2) / output.width,
                                                          y: (output.height - spot.y - side / 2) / output.height,
                                                          width: side / output.width, height: side / output.height),
                                             color: ColorValue(r: 1, g: 1, b: 1),
                                             fontSize: 0.04, opacity: 1,
                                             style: AnnotationStyle(fill: .solid))]
        let drawn = try light(scene, source: black(), above: 0.3)
        let expected = scene.projected(spot)
        #expect(distance(drawn, expected) <= 2, "annotation at \(drawn), projected to \(expected)")
    }

    // MARK: - The shadow

    /// A turned picture's shadow is soft, darkest by the picture and gone further out — and,
    /// the pitfall a plain block of colour falls into, it does not blacken the background.
    @Test func theTurnedShadowIsSoftAndLeavesTheBackgroundAlone() throws {
        var scene = scene(perspective: PerspectiveLayer(turn: 0, lean: 20, depthShadow: 1))
        scene.background = .color(ColorValue(r: 1, g: 1, b: 1))
        scene.shadowRadius = 24
        scene.shadowOpacity = 0.8
        let white = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 1_280, height: 800))
        let pixels = DressingPixels(try #require(SceneRenderer().cgImage(for: scene, source: white)))
        let bottom = try #require(scene.perspectiveProjection).corners.bottomLeft.y
        // Below the picture's middle, stepping down from its bottom edge (top-left rows).
        let row = { (below: Double) in Int((Double(pixels.height) - bottom + below).rounded()) }
        let x = pixels.width / 2
        let near = pixels.colour(x, row(8)).r
        let middle = pixels.colour(x, row(50)).r
        let far = pixels.colour(x, row(95)).r
        #expect(near < middle && middle < far, "\(near), \(middle), \(far)")
        #expect(near < 0.85, "there is a shadow: \(near)")
        #expect(pixels.colour(12, 12).r > 0.97, "the corner of the background is untouched")
        #expect(pixels.colour(pixels.width - 12, pixels.height - 12).r > 0.97)
    }

    // MARK: - The description

    @Test func aFlatProjectDescribesNoPerspective() {
        let timeline = Timeline(sourceDuration: CMTime(seconds: 10, preferredTimescale: 600))
        let scene = SceneBuilder(videoSize: CGSize(width: 1_600, height: 1_000))
            .descriptor(for: timeline, at: CMTime(seconds: 1, preferredTimescale: 600))
        #expect(scene.perspective == nil)
        #expect(scene.grade == nil)
    }

    /// Zoomed in, the picture is turned flat when the project asks for that, and left
    /// turned when it does not; on the way in it is part of the way.
    @Test func zoomingInStraightensThePicture() {
        var timeline = Timeline(sourceDuration: CMTime(seconds: 10, preferredTimescale: 600))
        timeline.style.perspective = FramePerspective().with(.tiltLeft)
        timeline.zooms = [ZoomRegion(start: CMTime(seconds: 2, preferredTimescale: 600),
                                     duration: CMTime(seconds: 4, preferredTimescale: 600),
                                     scale: 2, center: CGPoint(x: 0.5, y: 0.5))]
        let builder = SceneBuilder(videoSize: CGSize(width: 1_600, height: 1_000))
        func turn(at seconds: Double) -> Double {
            builder.descriptor(for: timeline, at: CMTime(seconds: seconds, preferredTimescale: 600))
                .perspective?.turn ?? 0
        }
        #expect(turn(at: 1) == 18)
        #expect(turn(at: 4) == 0, "fully in: flat")
        // Through the zoom's ramp the turn falls steadily from all of it to none.
        let ramp = stride(from: 2.0, through: 2.6, by: 0.02).map { turn(at: $0) }
        #expect(ramp.contains { $0 > 0.5 && $0 < 17.5 }, "part of the way somewhere: \(ramp)")
        #expect(zip(ramp, ramp.dropFirst()).allSatisfy { $1 <= $0 + 1e-9 }, "never turning back: \(ramp)")

        timeline.style.perspective.straightensWhenZoomed = false
        #expect(turn(at: 4) == 18, "kept turned when asked to")
    }

    @Test func aTitleIsDrawnFlat() {
        var scene = scene(perspective: tilt)
        #expect(scene.perspectiveProjection != nil)
        scene.title = TitleLayer(TitleCard(), elapsed: 0)
        #expect(scene.perspectiveProjection == nil)
    }

    /// The angles are held to what can be drawn, whatever a file asks for.
    @Test func aFileCannotTurnThePictureEdgeOn() throws {
        let json = #"{ "turn": 89, "lean": -400, "rotation": 3, "straightensWhenZoomed": false }"#
        let perspective = try JSONDecoder().decode(FramePerspective.self, from: Data(json.utf8)).sanitised
        #expect(perspective.turn == FramePerspective.turnRange.upperBound)
        #expect(perspective.lean == FramePerspective.leanRange.lowerBound)
        #expect(perspective.rotation == 3)
        #expect(!perspective.straightensWhenZoomed)
        #expect(perspective.depthShadow == 0.5, "missing, so the default")
    }
}
