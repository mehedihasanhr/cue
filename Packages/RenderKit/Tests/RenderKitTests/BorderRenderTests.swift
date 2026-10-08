import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import Testing
import TimelineKit
@testable import RenderKit

/// The line round the picture: described by the builder, drawn by the renderer, and
/// moving nothing else.
struct BorderRenderTests {
    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    /// 1600 × 1000 at padding 0.1: the frame is 1280 × 800, at (160, 100).
    private let videoSize = CGSize(width: 1_600, height: 1_000)

    private func builder() -> SceneBuilder {
        SceneBuilder(videoSize: videoSize, displayScale: 2)
    }

    private func timeline(border: Double, cornerRadius: Double = 0) -> Timeline {
        var timeline = Timeline(sourceDuration: time(60))
        timeline.style.padding = 0.1
        timeline.style.cornerRadius = cornerRadius
        timeline.style.shadowOpacity = 0
        timeline.style.background = .color(ColorValue(r: 0, g: 0, b: 1))
        timeline.style.borderWidth = border
        timeline.style.borderColor = ColorValue(r: 0, g: 1, b: 0)
        timeline.cursor.isVisible = false
        return timeline
    }

    private let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0))
        .cropped(to: CGRect(x: 0, y: 0, width: 1_600, height: 1_000))

    /// A pixel in Core Image's coordinates — `y` up from the bottom — as the three
    /// colours, so a test can talk about the frame the way the renderer does.
    private func pixel(_ image: CGImage, x: Double, y: Double) -> (r: Int, g: Int, b: Int)? {
        let column = Int(x.rounded(.down)), row = image.height - 1 - Int(y.rounded(.down))
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data),
              column >= 0, row >= 0, column < image.width, row < image.height else { return nil }
        let offset = row * image.bytesPerRow + column * (image.bitsPerPixel / 8)
        return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
    }

    private func isGreen(_ p: (r: Int, g: Int, b: Int)) -> Bool { p.g > 180 && p.r < 80 && p.b < 80 }
    private func isRed(_ p: (r: Int, g: Int, b: Int)) -> Bool { p.r > 180 && p.g < 80 && p.b < 80 }
    private func isBlue(_ p: (r: Int, g: Int, b: Int)) -> Bool { p.b > 180 && p.r < 80 && p.g < 80 }

    // MARK: - Described

    @Test func noBorderDescribesNoLayer() {
        let scene = builder().descriptor(for: timeline(border: 0), at: .zero)
        #expect(scene.border == nil)
    }

    @Test func theBorderIsAFractionOfTheFramesShorterSide() throws {
        let scene = builder().descriptor(for: timeline(border: 0.02), at: .zero)
        let border = try #require(scene.border)
        #expect(abs(border.width - 800 * 0.02) < 1e-9, "the frame is 800 tall, not the output's 1000")
        #expect(border.color == ColorValue(r: 0, g: 1, b: 0))
    }

    @Test func turningTheBorderOnMovesNothingElse() {
        let without = builder().descriptor(for: timeline(border: 0), at: .zero)
        var with = builder().descriptor(for: timeline(border: 0.02), at: .zero)
        #expect(with.videoFrame == without.videoFrame)
        #expect(with.outputSize == without.outputSize)
        #expect(with.cornerRadius == without.cornerRadius)
        with.border = nil
        #expect(with == without, "the border is the only difference")
    }

    @Test func aFileAskingForAMatGetsALine() throws {
        let scene = builder().descriptor(for: timeline(border: 5), at: .zero)
        let border = try #require(scene.border)
        #expect(abs(border.width - 800 * FrameStyle.borderWidthRange.upperBound) < 1e-9)
    }

    @Test func anInvisibleColourIsNoBorder() {
        var edit = timeline(border: 0.02)
        edit.style.borderColor = ColorValue(r: 1, g: 1, b: 1, a: 0)
        #expect(builder().descriptor(for: edit, at: .zero).border == nil)
    }

    @Test func theBorderScalesWithThePreview() throws {
        let scene = builder().descriptor(for: timeline(border: 0.02), at: .zero)
        let small = scene.scaled(by: 0.5)
        #expect(try #require(small.border).width == 8)
        #expect(scene.scaled(by: 1).border?.width == 16)
    }

    // MARK: - Drawn, square corners

    /// The frame's left edge is at x = 160. Sixteen pixels of band outside it, then
    /// background; the picture starts right at the edge.
    @Test func theBandIsOutsideTheEdgeWithThePictureWhole() throws {
        let scene = builder().descriptor(for: timeline(border: 0.02), at: .zero)
        let image = try #require(SceneRenderer().cgImage(for: scene, source: red))
        #expect(image.width == 1_600 && image.height == 1_000)

        #expect(isGreen(try #require(pixel(image, x: 160 - 8, y: 500))), "just outside the edge: the border")
        #expect(isRed(try #require(pixel(image, x: 160 + 2, y: 500))), "just inside: the picture, uncovered")
        #expect(isBlue(try #require(pixel(image, x: 160 - 16 - 6, y: 500))), "past the band: the background")
        // All four sides.
        #expect(isGreen(try #require(pixel(image, x: 1_440 + 8, y: 500))))
        #expect(isGreen(try #require(pixel(image, x: 800, y: 100 - 8))))
        #expect(isGreen(try #require(pixel(image, x: 800, y: 900 + 8))))
        #expect(isRed(try #require(pixel(image, x: 800, y: 900 - 2))), "the picture's own top row is not covered")
        #expect(isRed(try #require(pixel(image, x: 800, y: 500))), "the middle is untouched")
    }

    @Test func thePictureIsWhereItWasWithoutTheBorder() throws {
        let plain = builder().descriptor(for: timeline(border: 0), at: .zero)
        let bare = try #require(SceneRenderer().cgImage(for: plain, source: red))
        let bordered = try #require(SceneRenderer().cgImage(
            for: builder().descriptor(for: timeline(border: 0.02), at: .zero), source: red))
        // The first picture pixel is at the frame's edge with or without a border: nothing
        // was inset or covered to make room.
        #expect(isRed(try #require(pixel(bare, x: 160 + 2, y: 500))))
        #expect(isRed(try #require(pixel(bordered, x: 160 + 2, y: 500))))
        #expect(isBlue(try #require(pixel(bare, x: 160 - 6, y: 500))))
    }

    // MARK: - Drawn, rounded corners

    /// Corner radius 0.1 of an 800-tall frame is 80 pixels: the top-left arc is centred
    /// at (240, 820). Walking the diagonal away from the centre crosses picture, then the
    /// band — concentric, so 16 wide here too — then background.
    @Test func theBandFollowsTheRoundedCornerExactly() throws {
        let scene = builder().descriptor(for: timeline(border: 0.02, cornerRadius: 0.1), at: .zero)
        #expect(scene.cornerRadius == 80)
        let image = try #require(SceneRenderer().cgImage(for: scene, source: red))

        let centre = CGPoint(x: 240, y: 820)
        func along(_ distance: Double) -> CGPoint {
            CGPoint(x: centre.x - distance / 2.0.squareRoot(), y: centre.y + distance / 2.0.squareRoot())
        }
        let outside = along(80 + 16 + 6), band = along(80 + 8), inside = along(80 - 6)
        #expect(isBlue(try #require(pixel(image, x: outside.x, y: outside.y))), "past the outer arc: background")
        #expect(isGreen(try #require(pixel(image, x: band.x, y: band.y))), "between the arcs: the border")
        #expect(isRed(try #require(pixel(image, x: inside.x, y: inside.y))), "inside the arc: picture")
        #expect(isBlue(try #require(pixel(image, x: 150, y: 910))), "the square corner is not filled in")
        // Along a straight side the band is still sixteen wide.
        #expect(isGreen(try #require(pixel(image, x: 160 - 8, y: 500))))
        #expect(isRed(try #require(pixel(image, x: 160 + 2, y: 500))))
    }

    // MARK: - With the camera moving

    /// With the contents zooming inside a held frame, the edge — and so the border —
    /// stays where the padding put it.
    @Test func theBorderStaysOnTheHoleWhileTheContentsZoom() throws {
        var edit = timeline(border: 0.02)
        edit.camera.zoomsWholeFrame = false
        edit.zooms = [ZoomRegion(start: .zero, duration: time(10), scale: 2,
                                 easing: .linear, transition: .zero, followsCursor: false)]
        let scene = builder().descriptor(for: edit, at: time(5))
        #expect(scene.zoom == 2)
        let image = try #require(SceneRenderer().cgImage(for: scene, source: red))
        #expect(isGreen(try #require(pixel(image, x: 160 - 8, y: 500))))
        #expect(isRed(try #require(pixel(image, x: 160 + 2, y: 500))))
        #expect(isBlue(try #require(pixel(image, x: 160 - 22, y: 500))))
    }

    /// When the whole frame zooms the border travels with the edge, and grows with it.
    @Test func theBorderTravelsWithAFrameThatZoomsWhole() throws {
        var edit = timeline(border: 0.02)
        edit.style.padding = 0.3
        edit.camera.zoomsWholeFrame = true
        // 1.25×, so the grown frame is still inside the output: 1600 × 1000 at padding
        // 0.3 gives a 640 × 400 frame at (480, 300); grown, 800 × 500 at (400, 250).
        edit.zooms = [ZoomRegion(start: .zero, duration: time(10), scale: 1.25,
                                 easing: .linear, transition: .zero, followsCursor: false)]
        let scene = builder().descriptor(for: edit, at: time(5))
        let image = try #require(SceneRenderer().cgImage(for: scene, source: red))
        // 0.02 of the 400-tall frame is 8, grown to 10.
        #expect(isGreen(try #require(pixel(image, x: 400 - 5, y: 500))))
        #expect(isRed(try #require(pixel(image, x: 400 + 2, y: 500))))
        #expect(isBlue(try #require(pixel(image, x: 400 - 10 - 5, y: 500))))
        #expect(isRed(try #require(pixel(image, x: 480 + 5, y: 500))), "where the edge was before the zoom is picture now: the frame grew past it")
    }
}
