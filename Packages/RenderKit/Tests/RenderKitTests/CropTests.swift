import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import RecordKit
import Testing
import TimelineKit
@testable import RenderKit

/// Showing part of the recording: the layout it implies, and what it does to everything
/// measured against the frame.
struct CropTests {
    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    private let videoSize = CGSize(width: 1_600, height: 1_000)

    private func builder() -> SceneBuilder {
        SceneBuilder(videoSize: videoSize, displayScale: 2)
    }

    private func timeline(crop: CGRect?) -> Timeline {
        var timeline = Timeline(sourceDuration: time(60))
        timeline.style.crop = crop.map(CropRect.init)
        timeline.cursor.isVisible = false
        return timeline
    }

    // MARK: - The type

    @Test func aCropIsClampedIntoTheFrame() {
        let crop = CropRect(rect: CGRect(x: -0.4, y: 0.8, width: 2, height: 0.5))
        #expect(crop.rect.minX >= 0)
        #expect(crop.rect.maxX <= 1 + 1e-9)
        #expect(crop.rect.maxY <= 1 + 1e-9)
    }

    @Test func aCropCannotBeSmallerThanItsMinimumSide() {
        let crop = CropRect(rect: CGRect(x: 0.5, y: 0.5, width: 0.001, height: 0.001))
        #expect(crop.rect.width == CropRect.minimumSide)
        #expect(crop.rect.height == CropRect.minimumSide)
    }

    @Test func aCroppedSizeIsEvenAndNeverDegenerate() {
        let size = CropRect(rect: CGRect(x: 0, y: 0, width: 0.333, height: 0.333)).pixels(in: videoSize)
        #expect(Int(size.width) % 2 == 0)
        #expect(Int(size.height) % 2 == 0)
        #expect(size.width >= 2 && size.height >= 2)
    }

    @Test func theWholeFrameIsNotACrop() {
        #expect(CropRect.full.isFull)
        #expect(!CropRect(rect: CGRect(x: 0, y: 0, width: 0.9, height: 1)).isFull)
    }

    @Test func settingAFullFrameCropStoresNoCropAtAll() {
        var timeline = timeline(crop: nil)
        let clean = timeline
        #expect(Commands.SetCrop(.full).apply(to: &timeline) == false)
        #expect(timeline == clean, "an untouched project must not become an edited one")
    }

    @Test func aProjectWrittenBeforeCropExistedDecodesWithoutOne() throws {
        var original = Timeline(sourceDuration: time(60))
        original.style.padding = 0.12
        let data = try JSONEncoder().encode(original)
        var fields = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var style = try #require(fields["style"] as? [String: Any])
        style.removeValue(forKey: "crop")
        fields["style"] = style

        let stripped = try JSONSerialization.data(withJSONObject: fields)
        let decoded = try JSONDecoder().decode(Timeline.self, from: stripped)
        #expect(decoded.style.crop == nil)
        #expect(decoded.style.padding == 0.12)
    }

    // MARK: - Layout

    @Test func anIdentityCropDescribesExactlyTheSameFrame() {
        let plain = builder().descriptor(for: timeline(crop: nil), at: .zero)
        let unit = builder().descriptor(for: timeline(crop: CGRect(x: 0, y: 0, width: 1, height: 1)), at: .zero)
        #expect(plain == unit)
    }

    @Test func croppingShrinksTheOutputRatherThanUpscalingTheCrop() {
        let scene = builder().descriptor(for: timeline(crop: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)),
                                         at: .zero)
        #expect(scene.outputSize == CGSize(width: 800, height: 500))
        #expect(Int(scene.outputSize.width) % 2 == 0)
        #expect(Int(scene.outputSize.height) % 2 == 0)
    }

    @Test func theFramedVideoTakesTheCropsShapeNotTheRecordings() {
        var timeline = timeline(crop: CGRect(x: 0, y: 0, width: 0.5, height: 1))
        timeline.style.padding = 0.08
        let scene = builder().descriptor(for: timeline, at: .zero)

        let cropRatio = (videoSize.width * 0.5) / videoSize.height
        #expect(abs(scene.videoFrame.width / scene.videoFrame.height - cropRatio) < 0.01)
        // Still centred, still inset.
        #expect(abs(scene.videoFrame.minX - (scene.outputSize.width - scene.videoFrame.maxX)) < 0.001)
        #expect(scene.videoFrame.minY > 0)
    }

    @Test func anAspectPresetReshapesTheCroppedArea() {
        var timeline = timeline(crop: CGRect(x: 0, y: 0, width: 0.5, height: 0.5))
        timeline.style.aspect = .wide16x9
        let output = builder().descriptor(for: timeline, at: .zero).outputSize

        #expect(abs(output.width / output.height - 16.0 / 9) < 0.01)
        let croppedArea = (videoSize.width * 0.5) * (videoSize.height * 0.5)
        let ratio = (output.width * output.height) / croppedArea
        #expect(ratio > 0.95 && ratio < 1.05, "area is preserved against the crop, not the recording")
    }

    // MARK: - Everything measured against the frame

    private func track(x: Double, y: Double) -> CursorTrack {
        CursorTrack(samples: [CursorSample(t: 0, x: x, y: y, shape: .arrow)])
    }

    @Test func thePointerIsPlacedAgainstTheCropNotTheRecording() throws {
        // displayScale 2, so 400×250 points is 800×500 pixels — the middle of the frame,
        // and therefore the middle of a centred half-size crop.
        var timeline = timeline(crop: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        timeline.cursor.isVisible = true
        let scene = builder().descriptor(for: timeline, at: .zero, cursor: track(x: 400, y: 250))

        let cursor = try #require(scene.cursor)
        #expect(abs(cursor.position.x - 0.5) < 0.001)
        #expect(abs(cursor.position.y - 0.5) < 0.001)
    }

    @Test func aPointerOutsideTheCropIsNotDrawnAtAll() {
        var timeline = timeline(crop: CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5))
        timeline.cursor.isVisible = true
        // Top-left of the recording, nowhere near a bottom-right crop. Clamping this to
        // an edge would draw a pointer sitting on the background.
        let scene = builder().descriptor(for: timeline, at: .zero, cursor: track(x: 10, y: 10))
        #expect(scene.cursor == nil)
    }

    @Test func aFollowingZoomStaysInsideTheCroppedFrame() {
        var timeline = timeline(crop: CGRect(x: 0, y: 0, width: 0.5, height: 0.5))
        timeline.zooms = [ZoomRegion(start: .zero, duration: time(10), scale: 4,
                                     easing: .linear, transition: .zero, followsCursor: true)]
        let scene = builder().descriptor(for: timeline, at: time(5), cursor: track(x: 0, y: 0))

        let margin = 0.5 / scene.zoom
        #expect(scene.zoomCenter.x >= margin - 1e-9)
        #expect(scene.zoomCenter.y >= margin - 1e-9)
        #expect(scene.zoomCenter.x <= 1 - margin + 1e-9)
    }

    // MARK: - Rendering

    /// Left half red, right half blue, in Core Image's bottom-left space.
    private func twoToneSource() -> CIImage {
        let left = CIImage(color: CIColor(red: 1, green: 0, blue: 0))
            .cropped(to: CGRect(x: 0, y: 0, width: videoSize.width / 2, height: videoSize.height))
        let right = CIImage(color: CIColor(red: 0, green: 0, blue: 1))
            .cropped(to: CGRect(x: videoSize.width / 2, y: 0, width: videoSize.width / 2, height: videoSize.height))
        return left.composited(over: right)
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int)? {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return nil }
        let offset = y * image.bytesPerRow + x * (image.bitsPerPixel / 8)
        return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
    }

    @Test func croppingToTheLeftHalfShowsTheLeftHalf() throws {
        var timeline = timeline(crop: CGRect(x: 0, y: 0, width: 0.5, height: 1))
        timeline.style.padding = 0
        timeline.style.cornerRadius = 0
        timeline.style.shadowOpacity = 0

        let scene = builder().descriptor(for: timeline, at: .zero)
        let image = try #require(SceneRenderer().cgImage(for: scene, source: twoToneSource()))
        let middle = try #require(pixel(image, x: image.width / 2, y: image.height / 2))

        #expect(middle.r > 200 && middle.b < 60, "the whole frame is the red half")
    }

    @Test func thePointerIsNeverDrawnOutsideThePicture() throws {
        // Zoomed in, the pointer is placed against a frame larger than the one the video
        // shows through — so a pointer at the edge of the recording used to be composited
        // onto the padding beside it.
        var timeline = timeline(crop: nil)
        timeline.style.padding = 0.2
        timeline.style.cornerRadius = 0
        timeline.style.shadowOpacity = 0
        timeline.style.background = .color(ColorValue(r: 0, g: 0, b: 1))
        timeline.cursor.isVisible = true
        timeline.cursor.smoothing = 0
        timeline.cursor.scale = 3
        timeline.zooms = [ZoomRegion(start: .zero, duration: time(10), scale: 4,
                                     center: CGPoint(x: 0.5, y: 0.5),
                                     easing: .linear, transition: .zero, followsCursor: false)]

        // Bottom-right corner of the recording, in points.
        let corner = CursorTrack(samples: [CursorSample(t: 0, x: videoSize.width / 2, y: videoSize.height / 2, shape: .arrow)])
        let scene = builder().descriptor(for: timeline, at: time(1), cursor: corner)
        let image = try #require(SceneRenderer().cgImage(for: scene,
                                                         source: CIImage(color: CIColor(red: 1, green: 0, blue: 0))
                                                             .cropped(to: CGRect(origin: .zero, size: videoSize))))

        // Anywhere in the padding must still be the background colour.
        let margin = try #require(pixel(image, x: 4, y: image.height / 2))
        #expect(margin.b > 200 && margin.r < 60, "the padding is background, never pointer")
    }

    @Test func aBlurInTheCroppedAwayPartDoesNotSurviveTheCrop() throws {
        var timeline = timeline(crop: CGRect(x: 0, y: 0, width: 0.5, height: 1))
        timeline.style.padding = 0
        timeline.style.cornerRadius = 0
        timeline.style.shadowOpacity = 0
        // Over the right-hand, cropped-away half.
        timeline.blurs = [BlurRegion(start: .zero, duration: time(60),
                                     rect: CGRect(x: 0.6, y: 0, width: 0.3, height: 1),
                                     style: .pixelate, radius: 40)]

        let scene = builder().descriptor(for: timeline, at: .zero)
        #expect(scene.blurs.count == 1, "the blur is still described — it is the crop that removes it")

        let image = try #require(SceneRenderer().cgImage(for: scene, source: twoToneSource()))
        let middle = try #require(pixel(image, x: image.width / 2, y: image.height / 2))
        #expect(middle.r > 200 && middle.b < 60)
    }
}
