import CoreGraphics
import CoreMedia
import Testing
@testable import RenderKit
import TimelineKit

/// Annotations as the renderer sees them: which are drawn, in what order, and turned and
/// animated the way the model says. The preview and the export are both this path, so
/// these are the checks that the two agree.
struct AnnotationRenderTests {
    private func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600) }

    private let videoSize = CGSize(width: 1920, height: 1080)

    private func timeline(_ annotations: [AnnotationItem]) -> Timeline {
        var timeline = Timeline(sourceDuration: time(20))
        timeline.annotations = annotations
        return timeline
    }

    private func box(start: Double = 2, rotation: Double = 0, hidden: Bool = false,
                     animation: AnnotationAnimation = AnnotationAnimation()) -> AnnotationItem {
        AnnotationItem(start: time(start), duration: time(4), kind: .rectangle,
                       rect: CGRect(x: 0.3, y: 0.4, width: 0.4, height: 0.1),
                       rotation: rotation, animation: animation, isHidden: hidden)
    }

    private var builder: SceneBuilder { SceneBuilder(videoSize: videoSize, displayScale: 2) }

    // MARK: - What is described

    @Test func aHiddenAnnotationIsInNeitherThePreviewNorTheExport() {
        let scene = builder.descriptor(for: timeline([box(hidden: true)]), at: time(4))
        #expect(scene.annotations.isEmpty)
    }

    @Test func theStackIsTheLanesOrder() {
        let under = AnnotationItem(start: time(2), duration: time(4), kind: .text("under"),
                                   rect: CGRect(x: 0.3, y: 0.4, width: 0.4, height: 0.1))
        let over = AnnotationItem(start: time(2), duration: time(4), kind: .text("over"),
                                  rect: CGRect(x: 0.3, y: 0.4, width: 0.4, height: 0.1))
        let scene = builder.descriptor(for: timeline([under, over]), at: time(4))
        #expect(scene.annotations.map(\.kind) == [.text("under"), .text("over")])
    }

    @Test func theTurnReachesTheRenderer() {
        let scene = builder.descriptor(for: timeline([box(rotation: 30)]), at: time(4))
        #expect(scene.annotations.first?.rotation == 30)
    }

    @Test func anEntranceReachesTheRendererAsScaleAndOffset() {
        let popping = box(animation: AnnotationAnimation(entrance: .slideUp, exit: .none, entranceDuration: 1,
                                                         easing: .linear))
        let halfway = builder.descriptor(for: timeline([popping]), at: time(2.5)).annotations.first
        #expect(halfway.map { abs($0.offset.dy - AnnotationAnimation.slideDistance / 2) < 1e-6 } == true)
        let settled = builder.descriptor(for: timeline([popping]), at: time(4)).annotations.first
        #expect(settled?.offset == .zero)
    }

    // MARK: - What is drawn

    /// Where the drawn pixels are, as a box in top-left coordinates.
    private func inkBounds(_ image: CGImage) -> CGRect? {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4] > 100 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    private func render(_ layer: AnnotationLayer) throws -> CGRect {
        let output = CGSize(width: 400, height: 400)
        var scene = SceneDescriptor(outputSize: output,
                                    background: .color(ColorValue(r: 0, g: 0, b: 0)),
                                    videoFrame: CGRect(origin: .zero, size: output))
        scene.annotations = [layer]
        let image = try #require(SceneRenderer().cgImage(for: scene, source: nil))
        return try #require(inkBounds(image))
    }

    private func wideBox(rotation: Double = 0, scale: Double = 1, offset: CGVector = .zero) -> AnnotationLayer {
        AnnotationLayer(kind: .rectangle, rect: CGRect(x: 0.25, y: 0.45, width: 0.5, height: 0.1),
                        color: ColorValue(r: 1, g: 0, b: 0), fontSize: 0.06, opacity: 1,
                        rotation: rotation, scale: scale, offset: offset)
    }

    @Test func aQuarterTurnStandsAWideBoxUpright() throws {
        let flat = try render(wideBox())
        let upright = try render(wideBox(rotation: 90))
        #expect(flat.width > flat.height * 3)
        #expect(upright.height > upright.width * 3)
        // About its own centre: it turns in place rather than swinging round a corner.
        #expect(abs(upright.midX - flat.midX) < 3 && abs(upright.midY - flat.midY) < 3)
    }

    @Test func aSlideDownMovesThePictureDown() throws {
        let home = try render(wideBox())
        let lower = try render(wideBox(offset: CGVector(dx: 0, dy: 0.1)))
        #expect(abs((lower.midY - home.midY) - 40) < 2, "a tenth of a 400-pixel frame, downwards")
    }

    @Test func aScaleGrowsAboutTheCentre() throws {
        let home = try render(wideBox())
        let small = try render(wideBox(scale: 0.5))
        #expect(abs(small.width - home.width / 2) < 3)
        #expect(abs(small.midX - home.midX) < 2)
    }

    /// Clockwise as seen, which is what the canvas's `rotationEffect` means by a positive
    /// angle: turned +30°, the right-hand end of a wide box goes *down* the picture.
    @Test func aPositiveTurnIsClockwiseOnThePicture() throws {
        let output = CGSize(width: 400, height: 400)
        var scene = SceneDescriptor(outputSize: output,
                                    background: .color(ColorValue(r: 0, g: 0, b: 0)),
                                    videoFrame: CGRect(origin: .zero, size: output))
        scene.annotations = [wideBox(rotation: 30)]
        let image = try #require(SceneRenderer().cgImage(for: scene, source: nil))
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                .draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        // Mean row of the ink in the left and right thirds. Rows are counted from the top of
        // the buffer as drawn, which a CGContext stores top row first.
        func meanRow(_ columns: Range<Int>) -> Double {
            var total = 0.0, count = 0.0
            for y in 0..<height { for x in columns where pixels[(y * width + x) * 4] > 100 {
                total += Double(y); count += 1
            } }
            return count > 0 ? total / count : .nan
        }
        let left = meanRow(0..<(width / 3)), right = meanRow((2 * width / 3)..<width)
        #expect(right > left + 20, "the right end should sit lower than the left")
    }
}
