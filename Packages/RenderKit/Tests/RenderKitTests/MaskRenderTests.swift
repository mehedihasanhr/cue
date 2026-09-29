import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import Testing
import TimelineKit
@testable import RenderKit

/// The cover and the spotlight, as pixels: inside, outside, several at once, and through
/// a crop and a zoom.
struct MaskRenderTests {
    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    /// No padding, no corners, no shadow: the output is the recording, pixel for pixel,
    /// so a mask's rectangle can be read straight off it.
    private let videoSize = CGSize(width: 1_600, height: 1_000)

    private func builder() -> SceneBuilder {
        SceneBuilder(videoSize: videoSize, displayScale: 2)
    }

    private func timeline(_ masks: [BlurRegion]) -> Timeline {
        var timeline = Timeline(sourceDuration: time(60))
        timeline.style.padding = 0
        timeline.style.cornerRadius = 0
        timeline.style.shadowOpacity = 0
        timeline.style.background = .color(ColorValue(r: 0, g: 0, b: 1))
        timeline.cursor.isVisible = false
        timeline.blurs = masks
        return timeline
    }

    private let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0))
        .cropped(to: CGRect(x: 0, y: 0, width: 1_600, height: 1_000))

    /// The middle of the recording, as a fraction of it.
    private let middle = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)

    private func render(_ timeline: Timeline, at seconds: Double = 5) throws -> CGImage {
        let scene = builder().descriptor(for: timeline, at: time(seconds))
        return try #require(SceneRenderer().cgImage(for: scene, source: red))
    }

    /// A pixel by fractions of the picture, top-left origin like a region's rect.
    private func pixel(_ image: CGImage, _ fx: Double, _ fy: Double) -> (r: Int, g: Int, b: Int)? {
        let x = Int((Double(image.width) * fx).rounded(.down)), y = Int((Double(image.height) * fy).rounded(.down))
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data),
              x >= 0, y >= 0, x < image.width, y < image.height else { return nil }
        let offset = y * image.bytesPerRow + x * (image.bitsPerPixel / 8)
        return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
    }

    private func isRed(_ p: (r: Int, g: Int, b: Int)) -> Bool { p.r > 245 && p.g < 10 && p.b < 10 }
    private func isGreen(_ p: (r: Int, g: Int, b: Int)) -> Bool { p.g > 245 && p.r < 10 && p.b < 10 }
    /// Red at 40%: what 0.6 of dimming leaves.
    private func isDimmedRed(_ p: (r: Int, g: Int, b: Int)) -> Bool { abs(p.r - 102) < 8 && p.g < 10 && p.b < 10 }

    // MARK: - Described

    @Test func aMaskCarriesEverythingTheRendererNeeds() throws {
        let mask = BlurRegion(start: time(1), duration: time(5), rect: middle, style: .spotlight,
                              color: ColorValue(r: 0, g: 1, b: 0), dimming: 0.3, softness: 0.05, cornerRadius: 0.2)
        let scene = builder().descriptor(for: timeline([mask]), at: time(2))
        let layer = try #require(scene.blurs.first)
        #expect(layer.style == .spotlight)
        #expect(layer.color == ColorValue(r: 0, g: 1, b: 0))
        #expect(layer.dimming == 0.3)
        #expect(layer.softness == 0.05)
        #expect(layer.cornerRadius == 0.2)
        #expect(builder().descriptor(for: timeline([mask]), at: time(0.5)).blurs.isEmpty, "not before it starts")
    }

    // MARK: - Cover

    @Test func aCoverIsItsColourInsideAndNothingOutside() throws {
        let cover = BlurRegion(start: .zero, duration: time(10), rect: middle, style: .cover,
                               color: ColorValue(r: 0, g: 1, b: 0))
        let image = try render(timeline([cover]))
        #expect(isGreen(try #require(pixel(image, 0.5, 0.5))), "inside: the cover")
        #expect(isGreen(try #require(pixel(image, 0.26, 0.26))), "right up to its corner")
        #expect(isRed(try #require(pixel(image, 0.1, 0.1))), "outside: the picture")
        #expect(isRed(try #require(pixel(image, 0.9, 0.9))))
    }

    @Test func aCoverIsBlackUnlessToldOtherwise() throws {
        let cover = BlurRegion(start: .zero, duration: time(10), rect: middle, style: .cover)
        let p = try #require(pixel(try render(timeline([cover])), 0.5, 0.5))
        #expect(p.r < 10 && p.g < 10 && p.b < 10)
    }

    @Test func aSeeThroughCoverTintsRatherThanHides() throws {
        let cover = BlurRegion(start: .zero, duration: time(10), rect: middle, style: .cover,
                               color: ColorValue(r: 0, g: 1, b: 0, a: 0.5))
        let p = try #require(pixel(try render(timeline([cover])), 0.5, 0.5))
        #expect(abs(p.r - 128) < 12 && abs(p.g - 128) < 12)
    }

    /// A pill-shaped cover: the rectangle's own corner shows picture, its edge midpoints
    /// and its middle are cover.
    @Test func aCoversCornersCanBeRounded() throws {
        let cover = BlurRegion(start: .zero, duration: time(10), rect: middle, style: .cover,
                               color: ColorValue(r: 0, g: 1, b: 0), cornerRadius: 0.5)
        let image = try render(timeline([cover]))
        #expect(isRed(try #require(pixel(image, 0.253, 0.253))), "the corner of the rectangle is outside the pill")
        #expect(isGreen(try #require(pixel(image, 0.5, 0.5))))
        #expect(isGreen(try #require(pixel(image, 0.253, 0.5))), "the middle of a side is on the pill")
        #expect(isGreen(try #require(pixel(image, 0.5, 0.253))))
    }

    /// The same cover, square, fills the corner the rounded one leaves — so the rounding
    /// is the mask and not an accident of where the rectangle lands on a two-tone source.
    @Test func theSameCoverSquareFillsTheCornerARoundedOneLeaves() throws {
        let left = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 800, height: 1_000))
        let right = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(x: 800, y: 0, width: 800, height: 1_000))
        let source = left.composited(over: right)
        let cover = BlurRegion(start: .zero, duration: time(10), rect: middle, style: .cover,
                               color: ColorValue(r: 0, g: 1, b: 0), cornerRadius: 0.5)
        var square = cover
        square.cornerRadius = 0
        let scene = builder().descriptor(for: timeline([cover]), at: time(1))
        let image = try #require(SceneRenderer().cgImage(for: scene, source: source))
        let squareImage = try #require(SceneRenderer().cgImage(for: builder().descriptor(for: timeline([square]), at: time(1)),
                                                               source: source))
        #expect(isRed(try #require(pixel(image, 0.253, 0.253))))
        #expect(isGreen(try #require(pixel(squareImage, 0.253, 0.253))), "square, the same corner is cover")
    }

    /// Masks arrive and leave on a frame, as blurs always have: there is nothing to fade.
    @Test func aCoverIsThereForItsWholeStretchAndNotAMomentBefore() throws {
        let cover = BlurRegion(start: time(2), duration: time(3), rect: middle, style: .cover,
                               color: ColorValue(r: 0, g: 1, b: 0))
        let edit = timeline([cover])
        #expect(isRed(try #require(pixel(try render(edit, at: 1.99), 0.5, 0.5))))
        #expect(isGreen(try #require(pixel(try render(edit, at: 2), 0.5, 0.5))), "fully there on its first frame")
        #expect(isGreen(try #require(pixel(try render(edit, at: 4.99), 0.5, 0.5))))
        #expect(isRed(try #require(pixel(try render(edit, at: 5), 0.5, 0.5))))
    }

    // MARK: - Spotlight

    @Test func aSpotlightLeavesItsAreaAloneAndDimsTheRest() throws {
        let spot = BlurRegion(start: .zero, duration: time(10), rect: middle, style: .spotlight,
                              dimming: 0.6, softness: 0)
        let image = try render(timeline([spot]))
        #expect(isRed(try #require(pixel(image, 0.5, 0.5))), "inside: untouched")
        #expect(isRed(try #require(pixel(image, 0.26, 0.26))), "right up to its corner")
        #expect(isDimmedRed(try #require(pixel(image, 0.1, 0.1))), "outside: dimmed by the amount asked")
        #expect(isDimmedRed(try #require(pixel(image, 0.9, 0.9))))
    }

    @Test func theDimmingIsTheAmountAsked() throws {
        let spot = BlurRegion(start: .zero, duration: time(10), rect: middle, style: .spotlight,
                              dimming: 0.25, softness: 0)
        let p = try #require(pixel(try render(timeline([spot])), 0.1, 0.1))
        #expect(abs(p.r - 191) < 8)
    }

    /// With softness, the area that was drawn is still clear and the shade fades in
    /// beyond its edge rather than across it.
    @Test func aSoftEdgeFallsOutsideTheArea() throws {
        let spot = BlurRegion(start: .zero, duration: time(10), rect: middle, style: .spotlight,
                              dimming: 0.6, softness: 0.02)
        let image = try render(timeline([spot]))
        // 0.02 of the 1000-pixel shorter side is a sigma of 20; the feather reaches about
        // 80 pixels past the edge, which is 0.05 of the width.
        #expect(isRed(try #require(pixel(image, 0.5, 0.5))))
        let atTheEdge = try #require(pixel(image, 0.252, 0.5))
        #expect(atTheEdge.r > 240, "the edge that was drawn is still clear")
        let inTheFeather = try #require(pixel(image, 0.25 - 0.025, 0.5))
        #expect(inTheFeather.r > 110 && inTheFeather.r < 240, "between clear and dimmed")
        #expect(isDimmedRed(try #require(pixel(image, 0.1, 0.5))), "well outside: fully dimmed")
    }

    @Test func twoSpotlightsAreTwoClearAreasInOneDimmedPicture() throws {
        let a = BlurRegion(start: .zero, duration: time(10), rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2),
                           style: .spotlight, dimming: 0.6, softness: 0)
        let b = BlurRegion(start: .zero, duration: time(10), rect: CGRect(x: 0.6, y: 0.6, width: 0.3, height: 0.3),
                           style: .spotlight, dimming: 0.6, softness: 0)
        let image = try render(timeline([a, b]))
        #expect(isRed(try #require(pixel(image, 0.2, 0.2))), "the first is not dimmed by the second")
        #expect(isRed(try #require(pixel(image, 0.75, 0.75))), "nor the second by the first")
        #expect(isDimmedRed(try #require(pixel(image, 0.45, 0.45))), "and between them is dimmed once, not twice")
    }

    @Test func spotlightsThatDisagreeDimByTheStrongest() throws {
        let a = BlurRegion(start: .zero, duration: time(10), rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2),
                           style: .spotlight, dimming: 0.3, softness: 0)
        let b = BlurRegion(start: .zero, duration: time(10), rect: CGRect(x: 0.6, y: 0.6, width: 0.3, height: 0.3),
                           style: .spotlight, dimming: 0.8, softness: 0)
        let p = try #require(pixel(try render(timeline([a, b])), 0.45, 0.45))
        #expect(abs(p.r - 51) < 8)
    }

    @Test func aSpotlightDimsACoverBesideIt() throws {
        let cover = BlurRegion(start: .zero, duration: time(10), rect: CGRect(x: 0.05, y: 0.05, width: 0.1, height: 0.1),
                               style: .cover, color: ColorValue(r: 0, g: 1, b: 0))
        let spot = BlurRegion(start: .zero, duration: time(10), rect: middle, style: .spotlight,
                              dimming: 0.5, softness: 0)
        let p = try #require(pixel(try render(timeline([cover, spot])), 0.1, 0.1))
        #expect(abs(p.g - 128) < 8 && p.r < 10, "the cover is part of everything else")
    }

    @Test func aSpotlightsCornersCanBeRounded() throws {
        let spot = BlurRegion(start: .zero, duration: time(10), rect: middle, style: .spotlight,
                              dimming: 0.6, softness: 0, cornerRadius: 0.5)
        let image = try render(timeline([spot]))
        #expect(isDimmedRed(try #require(pixel(image, 0.253, 0.253))), "the rectangle's corner is outside the pill")
        #expect(isRed(try #require(pixel(image, 0.5, 0.5))))
        #expect(isRed(try #require(pixel(image, 0.253, 0.5))))
    }

    // MARK: - Through the crop and the camera

    /// A spotlight is stored against the whole recording. Cropping to the left half
    /// leaves it on the same thing, which is now twice as far across the output.
    @Test func aSpotlightFollowsTheCrop() throws {
        let spot = BlurRegion(start: .zero, duration: time(10), rect: CGRect(x: 0.1, y: 0.25, width: 0.2, height: 0.5),
                              style: .spotlight, dimming: 0.6, softness: 0)
        var edit = timeline([spot])
        edit.style.crop = CropRect(rect: CGRect(x: 0, y: 0, width: 0.5, height: 1))
        let image = try render(edit)
        #expect(image.width == 800)
        #expect(isRed(try #require(pixel(image, 0.4, 0.5))), "a fifth of the recording is two fifths of the crop")
        #expect(isDimmedRed(try #require(pixel(image, 0.8, 0.5))))
        #expect(isDimmedRed(try #require(pixel(image, 0.1, 0.5))))
    }

    @Test func aCoverFollowsTheCrop() throws {
        let cover = BlurRegion(start: .zero, duration: time(10), rect: CGRect(x: 0.1, y: 0.25, width: 0.2, height: 0.5),
                               style: .cover, color: ColorValue(r: 0, g: 1, b: 0))
        var edit = timeline([cover])
        edit.style.crop = CropRect(rect: CGRect(x: 0, y: 0, width: 0.5, height: 1))
        let image = try render(edit)
        #expect(isGreen(try #require(pixel(image, 0.4, 0.5))))
        #expect(isRed(try #require(pixel(image, 0.8, 0.5))))
    }

    /// Zoomed in twice on the middle, a spotlight in the middle covers twice as much of
    /// the frame — it is on the picture, not on the frame.
    @Test func aSpotlightGrowsWithTheZoom() throws {
        let spot = BlurRegion(start: .zero, duration: time(10), rect: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2),
                              style: .spotlight, dimming: 0.6, softness: 0)
        var edit = timeline([spot])
        edit.camera.zoomsWholeFrame = false
        let still = try render(edit)
        #expect(isDimmedRed(try #require(pixel(still, 0.35, 0.5))), "outside the area at rest")

        edit.zooms = [ZoomRegion(start: .zero, duration: time(10), scale: 2, center: CGPoint(x: 0.5, y: 0.5),
                                 easing: .linear, transition: .zero, followsCursor: false)]
        let zoomed = try render(edit)
        #expect(isRed(try #require(pixel(zoomed, 0.35, 0.5))), "inside it once the picture is twice the size")
        #expect(isDimmedRed(try #require(pixel(zoomed, 0.2, 0.5))))
    }
}
