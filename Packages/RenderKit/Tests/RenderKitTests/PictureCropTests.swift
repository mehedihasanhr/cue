import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import RecordKit
import Testing
import TimelineKit
@testable import RenderKit

/// A window resized while it was recorded: the file kept its size, the picture was scaled
/// to fit, and the rest of the frame is black. The finished frame shows the picture and
/// never the black, and everything recorded in the frame's points follows the picture.
///
/// An 800 × 450 recording at 1×, so a point is a pixel and the arithmetic can be read off
/// the page. The source is red where the picture is and black everywhere else.
struct PictureCropTests {
    private let videoSize = CGSize(width: 800, height: 450)
    /// The window at half its size, in the top-left corner — its shape unchanged.
    private let half = CGRect(x: 0, y: 0, width: 400, height: 225)
    /// The window made taller and shrunk to fit the height: a band down the right.
    private let taller = CGRect(x: 0, y: 0, width: 700, height: 450)

    private func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600) }

    private func builder(_ picture: CGRect? = nil, from start: Double = 0) -> SceneBuilder {
        SceneBuilder(videoSize: videoSize, displayScale: 1,
                     picture: PictureTrack(samples: picture.map { [PictureSample(t: start, rect: $0)] } ?? []))
    }

    /// The picture edge to edge — no padding, corners, shadow or pointer — on a blue
    /// background, so black in the result can only have come from the recording and blue
    /// only from a picture that did not reach its edge.
    private func timeline() -> Timeline {
        var timeline = Timeline(sourceDuration: time(10))
        timeline.style.background = .color(ColorValue(r: 0, g: 0, b: 1))
        timeline.style.padding = 0
        timeline.style.cornerRadius = 0
        timeline.style.shadowOpacity = 0
        timeline.style.shadowRadius = 0
        timeline.cursor.isVisible = false
        return timeline
    }

    /// Red where the picture is, black round it — what ScreenCaptureKit writes. Built in
    /// Core Image's bottom-left space from a rectangle in the frame's top-left one.
    private func source(picture: CGRect) -> CIImage {
        let flipped = CGRect(x: picture.minX, y: videoSize.height - picture.maxY,
                             width: picture.width, height: picture.height)
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: flipped)
        return red.composited(over: CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: videoSize)))
    }

    /// How many of the finished frame's pixels are not the picture's red.
    private func pixelsThatAreNotPicture(_ scene: SceneDescriptor, source: CIImage) throws -> Int {
        let image = try #require(SceneRenderer().cgImage(for: scene, source: source))
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(data: &bytes, width: width, height: height,
                                             bitsPerComponent: 8, bytesPerRow: width * 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var wrong = 0
        for index in stride(from: 0, to: bytes.count, by: 4)
        where !(bytes[index] > 200 && bytes[index + 1] < 60 && bytes[index + 2] < 60) {
            wrong += 1
        }
        return wrong
    }

    // MARK: - No black

    /// The control: left alone, the black band is in the finished frame. Without this the
    /// tests below could pass by measuring nothing.
    @Test func withoutThePictureTrackTheBlackIsThere() throws {
        let scene = builder().descriptor(for: timeline(), at: time(1))
        let wrong = try pixelsThatAreNotPicture(scene, source: source(picture: half))
        #expect(wrong > 800 * 450 / 2)
    }

    @Test func aShrunkPictureFillsTheFrameWithNoBlackEdge() throws {
        let scene = builder(half).descriptor(for: timeline(), at: time(1))
        #expect(scene.outputSize == videoSize, "the finished frame keeps the recording's size")
        #expect(scene.sourceCrop == CGRect(x: 0, y: 0, width: 0.5, height: 0.5))
        #expect(try pixelsThatAreNotPicture(scene, source: source(picture: half)) == 0)
    }

    /// Its shape changed as well: filled evenly, a strip off the top and the bottom, and
    /// still not one pixel of black or of the background round it.
    @Test func aPictureOfAnotherShapeFillsTheFrameWithNoBlackEdge() throws {
        let scene = builder(taller).descriptor(for: timeline(), at: time(1))
        let crop = scene.sourceCrop
        #expect(abs((crop.width * videoSize.width) / (crop.height * videoSize.height)
                    - videoSize.width / videoSize.height) < 0.01, "never stretched")
        #expect(try pixelsThatAreNotPicture(scene, source: source(picture: taller)) == 0)
    }

    /// A picture that ends part-way across a pixel shares it with the black; the crop keeps
    /// to whole pixels of picture, so no dark line is drawn down the edge.
    @Test func aPictureEndingMidPixelLeavesNoDarkLine() throws {
        let ragged = CGRect(x: 0, y: 0, width: 400.4, height: 225.2)
        let scene = builder(ragged).descriptor(for: timeline(), at: time(1))
        #expect(try pixelsThatAreNotPicture(scene, source: source(picture: ragged)) == 0)
    }

    /// Before the window was resized the whole frame is picture, and the frame is built as
    /// it always was.
    @Test func beforeTheChangeTheFrameIsUntouched() {
        let before = builder(half, from: 5).descriptor(for: timeline(), at: time(1))
        #expect(before == builder().descriptor(for: timeline(), at: time(1)))
    }

    @Test func aPictureThatFillsTheFrameIsNoCropAtAll() {
        let whole = builder(CGRect(origin: .zero, size: videoSize)).descriptor(for: timeline(), at: time(1))
        #expect(whole == builder().descriptor(for: timeline(), at: time(1)))
    }

    // MARK: - The pointer follows the picture

    private func pointer(at point: CGPoint, picture: CGRect, crop: CGRect? = nil) throws -> CGPoint {
        var timeline = timeline()
        timeline.cursor.isVisible = true
        timeline.style.crop = crop.map(CropRect.init)
        let track = CursorTrack(samples: [CursorSample(t: 0, x: point.x, y: point.y, shape: .arrow)])
        let scene = builder(picture).descriptor(for: timeline, at: time(1), cursor: track)
        return try #require(scene.cursor).position
    }

    @Test func aPointerAtThePicturesCornerIsAtTheFramesCorner() throws {
        let topLeft = try pointer(at: .zero, picture: half)
        #expect(abs(topLeft.x) < 1e-6 && abs(topLeft.y) < 1e-6)
        let bottomRight = try pointer(at: CGPoint(x: half.maxX, y: half.maxY), picture: half)
        #expect(abs(bottomRight.x - 1) < 1e-6 && abs(bottomRight.y - 1) < 1e-6)
        let middle = try pointer(at: CGPoint(x: half.midX, y: half.midY), picture: half)
        #expect(abs(middle.x - 0.5) < 1e-6 && abs(middle.y - 0.5) < 1e-6)
    }

    /// With the shape changed, the corner of what is shown is the corner of the frame —
    /// the pointer is cropped with the picture, by exactly as much.
    @Test func aPointerAtTheShownCornerOfAReshapedPictureIsAtTheFramesCorner() throws {
        let shown = PictureTrack.filling(taller, frame: videoSize)
        let topLeft = try pointer(at: shown.origin, picture: taller)
        #expect(abs(topLeft.x) < 0.002 && abs(topLeft.y) < 0.002)
        let bottomRight = try pointer(at: CGPoint(x: shown.maxX, y: shown.maxY), picture: taller)
        #expect(abs(bottomRight.x - 1) < 0.002 && abs(bottomRight.y - 1) < 0.002)
    }

    /// A pointer over the black was not over the picture, and is not drawn on it.
    @Test func aPointerInTheBlackIsNotDrawn() throws {
        var timeline = timeline()
        timeline.cursor.isVisible = true
        let track = CursorTrack(samples: [CursorSample(t: 0, x: 600, y: 300, shape: .arrow)])
        #expect(builder(half).descriptor(for: timeline, at: time(1), cursor: track).cursor == nil)
    }

    /// The project's own crop is a crop of the picture as it is shown, so the middle of a
    /// centred half-size crop is still the middle of the picture.
    @Test func theProjectsCropIsTakenOfThePictureNotTheRecording() throws {
        let middle = try pointer(at: CGPoint(x: half.midX, y: half.midY), picture: half,
                                 crop: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        #expect(abs(middle.x - 0.5) < 1e-6 && abs(middle.y - 0.5) < 1e-6)
    }

    /// A still mask is a fraction of the picture, so the blur the renderer is handed moves
    /// and shrinks with the window's content: over the whole frame before the resize, over
    /// the top-left quarter after it. A following mask is left where its path puts it.
    @Test func aStillMasksBlurIsCarriedWithThePicture() throws {
        var timeline = timeline()
        let rect = CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4)
        timeline.blurs = [BlurRegion(start: time(0), duration: time(10), rect: rect, style: .cover)]
        let resized = builder(half, from: 5)
        let before = try #require(resized.descriptor(for: timeline, at: time(2)).blurs.first)
        #expect(before.rect == rect)
        let after = try #require(resized.descriptor(for: timeline, at: time(6)).blurs.first)
        #expect(abs(after.rect.minX - 0.1) < 1e-9 && abs(after.rect.width - 0.2) < 1e-9)
        #expect(abs(after.rect.minY - 0.1) < 1e-9 && abs(after.rect.height - 0.2) < 1e-9)

        timeline.blurs[0].path = MaskPath(keys: [MaskPath.Key(time: 0, offset: .zero),
                                                 MaskPath.Key(time: 10, offset: .zero)])
        #expect(resized.descriptor(for: timeline, at: time(6)).blurs.first?.rect == rect)
    }
}
