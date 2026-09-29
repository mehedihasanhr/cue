import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import RecordKit
import Testing
import TimelineKit
@testable import RenderKit

/// The pointer is drawn where the pointer was.
///
/// Not "near": a pointer is the one thing in a recording the viewer is told to follow, and
/// it is judged against what is under it — the link it is over, the text it is in. Two ways
/// of being near-but-wrong lived here. Every drawn shape was placed by its top-left corner,
/// which is about right for an arrow and half a pointer out for an I-beam; and a pointer
/// that was smeared for speed was placed by the corner of its smear, which moved it by the
/// length of the smear.
///
/// These draw a pointer onto a black frame and measure where the light landed.
struct PointerPlacementTests {
    private let output = CGSize(width: 1_600, height: 1_000)

    /// A frame with no padding, so a position in the recording is a position in the frame.
    private func scene(_ shape: CursorShapeKind,
                       at position: CGPoint,
                       velocity: CGVector = .zero,
                       scale: Double = 2) -> SceneDescriptor {
        SceneDescriptor(outputSize: output,
                        background: .color(.init(r: 0, g: 0, b: 0, a: 1)),
                        videoFrame: CGRect(origin: .zero, size: output),
                        cornerRadius: 0,
                        shadowRadius: 0,
                        shadowOpacity: 0,
                        zoom: 1,
                        zoomCenter: CGPoint(x: 0.5, y: 0.5),
                        cursor: CursorLayer(position: position, shape: shape, scale: scale, velocity: velocity))
    }

    private func black() -> CIImage {
        CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: output))
    }

    /// Where the pointer's white fill is, as a box and as a centre of mass, in pixels from
    /// the top-left.
    private func light(in scene: SceneDescriptor) throws -> (box: CGRect, centre: CGPoint) {
        let image = try #require(SceneRenderer().cgImage(for: scene, source: black()))
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(data: &bytes, width: width, height: height,
                                             bitsPerComponent: 8, bytesPerRow: width * 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
        var sumX = 0.0, sumY = 0.0, total = 0.0
        for y in 0..<height {
            for x in 0..<width {
                // The context's first row is the top of the picture.
                // Low, because a thin shape smeared across its own width is faint: a
                // crosshair's bar at full smear keeps about an eighth of its light.
                let value = Double(bytes[(y * width + x) * 4])
                guard value > 12 else { continue }
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
                sumX += Double(x) * value
                sumY += Double(y) * value
                total += value
            }
        }
        try #require(total > 0, "nothing was drawn")
        return (CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1),
                CGPoint(x: sumX / total, y: sumY / total))
    }

    private var middle: CGPoint { CGPoint(x: 0.5, y: 0.5) }
    private var middlePixel: CGPoint { CGPoint(x: output.width / 2, y: output.height / 2) }

    // MARK: - Where each shape's point is

    /// How big the pointer is drawn at the scale these tests use: 3.5% of the shorter
    /// side, doubled.
    private var drawnSize: Double { min(output.width, output.height) * 0.035 * 2 }

    /// The arrow points with its tip, which is the top-left of its fill — inside its
    /// outline, so the light starts an outline's width in from the point itself.
    @Test func theArrowsTipIsOnThePoint() throws {
        let drawn = try light(in: scene(.arrow, at: middle))
        let outline = drawnSize * 0.08
        #expect(abs(drawn.box.minX - middlePixel.x) <= outline, "tip at \(drawn.box.minX), point at \(middlePixel.x)")
        #expect(abs(drawn.box.minY - middlePixel.y) <= outline, "tip at \(drawn.box.minY), point at \(middlePixel.y)")
    }

    /// And it is the tip that is there, not the corner of the picture the arrow is drawn
    /// in: the rest of the arrow is below and to the right of the point, never above or
    /// to the left of it.
    @Test func theArrowHangsBelowAndRightOfThePoint() throws {
        let drawn = try light(in: scene(.arrow, at: middle))
        #expect(drawn.box.maxX > middlePixel.x + drawnSize * 0.4)
        #expect(drawn.box.maxY > middlePixel.y + drawnSize * 0.8)
    }

    /// A hand points with the tip of its finger, which is at the top of the drawing and
    /// a little left of the middle of it.
    @Test func theHandsFingertipIsOnThePoint() throws {
        let drawn = try light(in: scene(.pointingHand, at: middle))
        #expect(abs(drawn.box.minY - middlePixel.y) <= drawnSize * 0.1, "fingertip at \(drawn.box.minY)")
        // The finger is above the point and the hand hangs below it, on both sides.
        #expect(drawn.box.minX < middlePixel.x)
        #expect(drawn.box.maxX > middlePixel.x)
        #expect(drawn.box.maxY > middlePixel.y + drawnSize * 0.8)
    }

    /// Every shape is one outline. Pieces stroked separately leave the lines where they
    /// cross showing through the fill, which is dark inside something that should be light.
    @Test(arguments: [CursorShapeKind.iBeam, .crosshair, .resizeHorizontal, .resizeVertical])
    func aShapeHasNoLinesThroughItsMiddle(_ shape: CursorShapeKind) throws {
        try expectOneOutline(shape, acrossAt: 0.5, downAt: 0.5)
    }

    /// A hand is not the same shape all the way up — there is a gap between the thumb and
    /// the fingers — so it is cut where it is solid: across the palm, and down the finger
    /// that reaches furthest.
    @Test(arguments: [CursorShapeKind.pointingHand, .openHand])
    func aHandIsOneOutline(_ shape: CursorShapeKind) throws {
        try expectOneOutline(shape, acrossAt: 0.2, downAt: 0.44)
    }

    /// Cuts a drawing across and down, at fractions of its size measured from the bottom
    /// left, and counts the dark edges met on the way.
    private func expectOneOutline(_ shape: CursorShapeKind, acrossAt: Double, downAt: Double) throws {
        CursorArtwork.clearCache()
        let image = try #require(CursorArtwork.image(shape, size: 200))
        let context = CIContext()
        let cg = try #require(context.createCGImage(image, from: image.extent))
        var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let bitmap = try #require(CGContext(data: &bytes, width: cg.width, height: cg.height,
                                            bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))

        // Along the middle row and the middle column: once inside the fill, a dark pixel
        // may only be met on the way out.
        func crossings(_ pixels: [Int]) -> Int {
            var changes = 0
            var previous = false
            for index in pixels {
                let opaque = bytes[index + 3] > 200
                let dark = opaque && bytes[index] < 60
                if dark != previous { changes += 1 }
                previous = dark
            }
            return changes
        }
        // The bitmap's first row is the top of the picture.
        let y = Int(Double(cg.height) * (1 - acrossAt))
        let x = Int(Double(cg.width) * downAt)
        let row = (0..<cg.width).map { (y * cg.width + $0) * 4 }
        let column = (0..<cg.height).map { ($0 * cg.width + x) * 4 }
        // In and out of the outline on the way in, and again on the way out: four edges
        // at most. A line through the middle makes it six or more.
        #expect(crossings(row) <= 4, "\(shape) has \(crossings(row)) dark edges across its middle")
        #expect(crossings(column) <= 4, "\(shape) has \(crossings(column)) dark edges down its middle")
    }

    /// Everything that is not an arrow points with its middle. The I-beam is the one that
    /// matters: it is drawn *in* a line of text, and half a pointer out puts it in the
    /// line below.
    @Test(arguments: [CursorShapeKind.iBeam, .crosshair, .resizeHorizontal, .resizeVertical])
    func aShapeDrawnAboutItsMiddleIsCentredOnThePoint(_ shape: CursorShapeKind) throws {
        let drawn = try light(in: scene(shape, at: middle))
        #expect(abs(drawn.box.midX - middlePixel.x) <= 2.5, "\(shape) is centred at x \(drawn.box.midX)")
        #expect(abs(drawn.box.midY - middlePixel.y) <= 2.5, "\(shape) is centred at y \(drawn.box.midY)")
    }

    @Test func thePointerFollowsThePointAcrossTheFrame() throws {
        for position in [CGPoint(x: 0.2, y: 0.25), CGPoint(x: 0.8, y: 0.7)] {
            let drawn = try light(in: scene(.crosshair, at: position))
            #expect(abs(drawn.box.midX - position.x * output.width) <= 2.5)
            #expect(abs(drawn.box.midY - position.y * output.height) <= 2.5)
        }
    }

    // MARK: - Smearing must not move it

    /// A pointer moving fast is smeared along its travel. The smear is symmetrical, so the
    /// middle of the light stays where the pointer is.
    @Test(arguments: [CGVector(dx: 3_000, dy: 0), CGVector(dx: -3_000, dy: 0),
                      CGVector(dx: 0, dy: 3_000), CGVector(dx: 2_000, dy: -2_000)])
    func aSmearedPointerIsWhereAnUnsmearedOneIs(_ velocity: CGVector) throws {
        let still = try light(in: scene(.crosshair, at: middle))
        let moving = try light(in: scene(.crosshair, at: middle, velocity: velocity))
        #expect(abs(moving.centre.x - still.centre.x) <= 1.5,
                "smearing moved the pointer \(moving.centre.x - still.centre.x) px sideways")
        #expect(abs(moving.centre.y - still.centre.y) <= 1.5,
                "smearing moved the pointer \(moving.centre.y - still.centre.y) px vertically")
        #expect(moving.box.width > still.box.width || moving.box.height > still.box.height,
                "and it was actually smeared")
    }

    /// A pointer that is barely moving is not smeared at all, and so is not moved at all.
    @Test func aSlowPointerIsLeftAlone() throws {
        let still = try light(in: scene(.arrow, at: middle))
        let slow = try light(in: scene(.arrow, at: middle, velocity: CGVector(dx: 200, dy: 100)))
        #expect(still.box == slow.box)
    }
}
