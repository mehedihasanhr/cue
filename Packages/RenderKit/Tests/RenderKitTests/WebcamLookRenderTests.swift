import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import Testing
import TimelineKit
@testable import RenderKit

/// What the camera shows inside its bubble: which part of the picture, with what round it,
/// and what is left of the room behind the person.
@Suite("The camera's crop, border and background")
struct WebcamLookRenderTests {
    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    private let videoSize = CGSize(width: 1_600, height: 1_000)

    private func builder() -> SceneBuilder {
        SceneBuilder(videoSize: videoSize, displayScale: 1)
    }

    /// A square bubble 300 px across in the middle of the frame, over a red screen.
    private func timeline(_ configure: (inout WebcamSettings) -> Void = { _ in }) -> Timeline {
        var timeline = Timeline(sourceDuration: time(20))
        timeline.style.padding = 0
        timeline.style.cornerRadius = 0
        timeline.style.shadowOpacity = 0
        timeline.cursor.isVisible = false
        timeline.webcam.isEnabled = true
        timeline.webcam.corner = .custom
        timeline.webcam.position = CGPoint(x: 0.5, y: 0.5)
        timeline.webcam.size = 0.3
        timeline.webcam.roundness = 0
        timeline.webcam.shadowOpacity = 0
        timeline.webcam.isMirrored = false
        timeline.webcam.reactsToZoom = false
        configure(&timeline.webcam)
        return timeline
    }

    private func render(_ timeline: Timeline, camera: CIImage,
                        renderer: SceneRenderer = SceneRenderer()) throws -> (CGImage, CGRect) {
        let scene = builder().descriptor(for: timeline, at: time(1))
        let rect = try #require(scene.webcam).pixelRect(in: scene.outputSize)
        let image = try #require(renderer.cgImage(for: scene,
                                                  source: solid(CIColor(red: 1, green: 0, blue: 0), size: videoSize),
                                                  webcam: camera))
        return (image, rect)
    }

    /// A sample at a fraction across and down the bubble, in the image's own top-down rows.
    private func sample(_ image: CGImage, in rect: CGRect, _ x: Double, _ y: Double) throws -> (r: Int, g: Int, b: Int) {
        // `rect` is Core Image's, bottom-up; the bitmap's rows run top-down.
        let column = Int(rect.minX + rect.width * x)
        let row = image.height - 1 - Int(rect.minY + rect.height * (1 - y))
        return try #require(pixel(image, x: column, y: row))
    }

    // MARK: - Crop

    /// A square camera in a square bubble fills it exactly, so there is nothing to move
    /// until it is zoomed. At 2× the window is half the picture, and the offset puts it
    /// against one side or the other.
    @Test(arguments: [(-1.0, true), (1.0, false)])
    func zoomedAndSlidTheBubbleShowsOneSide(_ offset: Double, _ expectsLeft: Bool) throws {
        let edit = timeline { $0.crop = WebcamCrop(zoom: 2, offset: CGPoint(x: offset, y: 0)) }
        let (image, rect) = try render(edit, camera: halves(size: CGSize(width: 480, height: 480)))
        for x in [0.1, 0.5, 0.9] {
            let seen = try sample(image, in: rect, x, 0.5)
            // Green is the camera's left half.
            #expect((seen.g > 200) == expectsLeft, "at \(x) with offset \(offset): \(seen)")
        }
    }

    @Test("Unzoomed and centred, a crop is no crop")
    func noCropIsTheOldBubble() throws {
        let camera = halves(size: CGSize(width: 480, height: 480))
        let (plain, _) = try render(timeline(), camera: camera)
        let (cropped, _) = try render(timeline { $0.crop = WebcamCrop(zoom: 1, offset: .zero) }, camera: camera)
        #expect(try bytes(plain) == bytes(cropped))
    }

    /// Down is down: an offset of +1 in y shows the bottom of the picture.
    @Test func theOffsetRunsDownTheWayTheModelDoes() throws {
        let edit = timeline { $0.crop = WebcamCrop(zoom: 2, offset: CGPoint(x: 0, y: 1)) }
        let (image, rect) = try render(edit, camera: topAndBottom(size: CGSize(width: 480, height: 480)))
        let seen = try sample(image, in: rect, 0.5, 0.5)
        #expect(seen.b > 200 && seen.g < 60, "the bottom half, which is blue: \(seen)")
    }

    /// The offset is measured on the picture as shown, so a mirrored bubble slid to the left
    /// shows what is on the left of the *mirror image*.
    @Test func theOffsetIsMeasuredOnThePictureAsShown() throws {
        let edit = timeline {
            $0.isMirrored = true
            $0.crop = WebcamCrop(zoom: 2, offset: CGPoint(x: -1, y: 0))
        }
        let (image, rect) = try render(edit, camera: halves(size: CGSize(width: 480, height: 480)))
        let seen = try sample(image, in: rect, 0.5, 0.5)
        #expect(seen.r > 200 && seen.g < 60, "mirrored, the red half is on the left: \(seen)")
    }

    @Test func zoomingDoesNotMoveOrGrowTheBubble() throws {
        let plain = builder().descriptor(for: timeline(), at: time(1)).webcam?.rect
        let zoomed = builder().descriptor(for: timeline { $0.crop = WebcamCrop(zoom: 3) }, at: time(1)).webcam?.rect
        #expect(plain == zoomed)
    }

    // MARK: - Border

    @Test("The border is drawn inside the bubble's edge, in its colour")
    func border() throws {
        let edit = timeline {
            $0.borderWidth = 0.1
            $0.borderColor = ColorValue(r: 1, g: 1, b: 1)
        }
        let scene = builder().descriptor(for: edit, at: time(1))
        let layer = try #require(scene.webcam)
        #expect(abs((layer.border?.width ?? 0) - 30) < 0.001, "a tenth of a 300 px bubble")
        let (image, rect) = try render(edit, camera: solid(CIColor(red: 0, green: 1, blue: 0),
                                                            size: CGSize(width: 480, height: 480)))
        let rim = try sample(image, in: rect, 0.03, 0.5)
        #expect(rim.r > 230 && rim.g > 230 && rim.b > 230, "the rim is white: \(rim)")
        let inside = try sample(image, in: rect, 0.5, 0.5)
        #expect(inside.g > 200 && inside.r < 40, "the middle is the camera: \(inside)")
        let outside = try #require(pixel(image, x: Int(rect.minX) - 4, y: image.height / 2))
        #expect(outside.r > 200 && outside.g < 40, "and nothing outside it: \(outside)")
    }

    @Test("A border of nothing, or of a clear colour, is no border")
    func noBorder() {
        #expect(builder().descriptor(for: timeline(), at: time(1)).webcam?.border == nil)
        let clear = timeline {
            $0.borderWidth = 0.05
            $0.borderColor = ColorValue(r: 1, g: 1, b: 1, a: 0)
        }
        #expect(builder().descriptor(for: clear, at: time(1)).webcam?.border == nil)
    }

    @Test("The preview's smaller frame keeps the border in proportion")
    func borderScales() throws {
        let edit = timeline { $0.borderWidth = 0.05 }
        let full = builder().descriptor(for: edit, at: time(1))
        let third = full.scaled(by: 1.0 / 3)
        let width = try #require(full.webcam?.border?.width)
        #expect(abs((third.webcam?.border?.width ?? 0) - width / 3) < 0.001)
    }

    // MARK: - Background

    @Test("Removed, the room is gone and the screen shows through it")
    func removed() throws {
        let matte = PersonMatte(segmenter: Self.leftHalfIsThePerson)
        let edit = timeline { $0.background = .remove }
        let (image, rect) = try render(edit,
                                       camera: solid(CIColor(red: 0, green: 1, blue: 0), size: CGSize(width: 480, height: 480)),
                                       renderer: SceneRenderer(personMatte: matte))
        let person = try sample(image, in: rect, 0.2, 0.5)
        let room = try sample(image, in: rect, 0.8, 0.5)
        #expect(person.g > 200 && person.r < 40, "the person is the camera: \(person)")
        #expect(room.r > 200 && room.g < 40, "the room is the screen behind: \(room)")
    }

    @Test("Blurred, the room is softened and the person is not")
    func blurred() throws {
        let matte = PersonMatte(segmenter: Self.leftHalfIsThePerson)
        let edit = timeline {
            $0.background = .blur
            $0.backgroundBlur = 1
        }
        let camera = fineStripes(size: CGSize(width: 480, height: 480))
        let (sharp, _) = try render(timeline(), camera: camera)
        let (soft, rect) = try render(edit, camera: camera, renderer: SceneRenderer(personMatte: matte))

        // On the right, the stripes are averaged into purple; on the left they are not.
        let room = try sample(soft, in: rect, 0.8, 0.5)
        #expect(room.r > 60 && room.b > 60, "blurred into a mix of the two stripes: \(room)")
        let personSoft = try sample(soft, in: rect, 0.2, 0.5)
        let personSharp = try sample(sharp, in: rect, 0.2, 0.5)
        #expect(abs(personSoft.r - personSharp.r) < 8 && abs(personSoft.b - personSharp.b) < 8,
                "the person is as sharp as they were: \(personSoft) against \(personSharp)")
    }

    /// Segmentation that finds nobody leaves the camera as it was filmed, rather than a
    /// bubble that has vanished or gone blurry all over.
    @Test("With nobody found, the camera is left alone")
    func nobodyFound() throws {
        let matte = PersonMatte(segmenter: { _ in nil })
        let camera = halves(size: CGSize(width: 480, height: 480))
        let (plain, _) = try render(timeline(), camera: camera)
        let (removed, _) = try render(timeline { $0.background = .remove }, camera: camera,
                                      renderer: SceneRenderer(personMatte: matte))
        #expect(try bytes(plain) == bytes(removed))
    }

    /// A camera with its room removed casts the person's shadow, not the bubble's: with
    /// nobody in it, there is no shadow at all.
    @Test("An empty cut-out casts no shadow")
    func removedShadow() throws {
        let nobody = PersonMatte(segmenter: { frame in
            CIImage(color: .black).cropped(to: frame.extent)
        })
        let edit = timeline {
            $0.background = .remove
            $0.shadowOpacity = 1
        }
        var off = timeline()
        off.webcam.isEnabled = false
        let camera = solid(CIColor(red: 0, green: 1, blue: 0), size: CGSize(width: 480, height: 480))
        let (removed, _) = try render(edit, camera: camera, renderer: SceneRenderer(personMatte: nobody))
        let bare = try #require(SceneRenderer().cgImage(for: builder().descriptor(for: off, at: time(1)),
                                                        source: solid(CIColor(red: 1, green: 0, blue: 0), size: videoSize)))
        #expect(try bytes(removed) == bytes(bare))
    }

    // MARK: - Shadow

    /// The bubble's shadow fades away from it. It used to be a band of solid dark three
    /// blurs wide with a hard outer edge: the shape was clamped to its extent before being
    /// blurred, which repeats its solid sides out to infinity.
    @Test("The bubble's shadow is soft, with no edge of its own")
    func softShadow() throws {
        let edit = timeline {
            $0.shadowOpacity = 1
        }
        let scene = builder().descriptor(for: edit, at: time(1))
        let rect = try #require(scene.webcam).pixelRect(in: scene.outputSize)
        let blur = min(rect.width, rect.height) * 0.09
        let white = solid(CIColor(red: 1, green: 1, blue: 1), size: videoSize)
        let image = try #require(SceneRenderer().cgImage(for: scene, source: white,
                                                         webcam: solid(CIColor(red: 0, green: 1, blue: 0),
                                                                       size: CGSize(width: 480, height: 480))))
        func shade(_ blurs: Double) throws -> Int {
            try #require(pixel(image, x: Int(rect.maxX + blur * blurs), y: image.height / 2)).r
        }
        let near = try shade(0.3)
        let middle = try shade(1)
        let far = try shade(2.8)
        #expect(near < middle && middle < far, "darkest by the bubble, lighter further out: \(near), \(middle), \(far)")
        #expect(near < 200, "there is a shadow")
        #expect(far > 245, "and it has faded to nothing before it is cropped: \(far)")
    }

    // MARK: - Remembering the person

    @Test("A frame is segmented once however often it is drawn")
    func segmentedOnce() throws {
        let matte = PersonMatte(segmenter: Self.leftHalfIsThePerson)
        let renderer = SceneRenderer(personMatte: matte)
        let camera = solid(CIColor(red: 0, green: 1, blue: 0), size: CGSize(width: 480, height: 480))
        let edit = timeline { $0.background = .remove }
        _ = try render(edit, camera: camera, renderer: renderer)
        _ = try render(edit, camera: camera, renderer: renderer)
        #expect(matte.segmentations == 1)

        let next = solid(CIColor(red: 0, green: 1, blue: 0), size: CGSize(width: 480, height: 480))
        _ = try render(edit, camera: next, renderer: renderer)
        #expect(matte.segmentations == 2, "a different frame is a different frame, however alike")
    }

    @Test("Only the frames it was asked about recently are kept")
    func bounded() {
        let matte = PersonMatte(capacity: 2, segmenter: Self.leftHalfIsThePerson)
        let frames = (0..<3).map { _ in solid(CIColor(red: 0, green: 1, blue: 0), size: CGSize(width: 64, height: 64)) }
        for frame in frames { _ = matte.matte(for: frame) }
        #expect(matte.segmentations == 3)
        _ = matte.matte(for: frames[2])
        #expect(matte.segmentations == 3, "the newest is still remembered")
        _ = matte.matte(for: frames[0])
        #expect(matte.segmentations == 4, "the oldest had to make room")
    }

    @Test("A mask for a frame the settings never ask to change is never made")
    func keepNeverSegments() throws {
        let matte = PersonMatte(segmenter: Self.leftHalfIsThePerson)
        _ = try render(timeline(), camera: solid(CIColor(red: 0, green: 1, blue: 0), size: CGSize(width: 64, height: 64)),
                       renderer: SceneRenderer(personMatte: matte))
        #expect(matte.segmentations == 0)
    }

    /// The real thing, on a picture with nobody in it. What can be checked without a
    /// person to film: that Vision runs here, that its mask comes back covering the frame
    /// exactly, and that the same picture gets the same mask every time — which is what
    /// makes a scrubbed frame and a played one, and the preview and the export, agree.
    @Test("Vision's mask covers the frame, and the same picture gets the same mask")
    func visionIsDeterministic() throws {
        let frame = gradient(size: CGSize(width: 320, height: 240))
        guard let first = PersonMatte.segment(frame) else {
            // Vision is unavailable where the tests are running. Nothing further can be
            // said, and saying nothing is better than failing on the machine.
            return
        }
        #expect(first.extent == frame.extent)
        let second = try #require(PersonMatte.segment(frame))
        let context = CIContext()
        let a = try #require(context.createCGImage(first, from: frame.extent))
        let b = try #require(context.createCGImage(second, from: frame.extent))
        #expect(try bytes(a) == bytes(b))
    }

    // MARK: - Sources and pixels

    /// A matte with the person on the left half of the frame.
    private static let leftHalfIsThePerson: @Sendable (CIImage) -> CIImage? = { frame in
        let extent = frame.extent
        let person = CIImage(color: .white)
            .cropped(to: CGRect(x: extent.minX, y: extent.minY, width: extent.width / 2, height: extent.height))
        return person.composited(over: CIImage(color: .black).cropped(to: extent))
    }

    private func solid(_ colour: CIColor, size: CGSize) -> CIImage {
        CIImage(color: colour).cropped(to: CGRect(origin: .zero, size: size))
    }

    /// Green on the left, red on the right.
    private func halves(size: CGSize) -> CIImage {
        let left = CIImage(color: CIColor(red: 0, green: 1, blue: 0))
            .cropped(to: CGRect(x: 0, y: 0, width: size.width / 2, height: size.height))
        let right = CIImage(color: CIColor(red: 1, green: 0, blue: 0))
            .cropped(to: CGRect(x: size.width / 2, y: 0, width: size.width / 2, height: size.height))
        return left.composited(over: right)
    }

    /// Green on top, blue underneath — in the picture's own terms, so Core Image's upper
    /// half is the green one.
    private func topAndBottom(size: CGSize) -> CIImage {
        let top = CIImage(color: CIColor(red: 0, green: 1, blue: 0))
            .cropped(to: CGRect(x: 0, y: size.height / 2, width: size.width, height: size.height / 2))
        let bottom = CIImage(color: CIColor(red: 0, green: 0, blue: 1))
            .cropped(to: CGRect(x: 0, y: 0, width: size.width, height: size.height / 2))
        return top.composited(over: bottom)
    }

    /// Red and blue columns two pixels wide: sharp, any sample is one or the other; blurred,
    /// every sample is both.
    private func fineStripes(size: CGSize) -> CIImage {
        var image = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(origin: .zero, size: size))
        var x = 0.0
        while x < size.width {
            let stripe = CIImage(color: CIColor(red: 1, green: 0, blue: 0))
                .cropped(to: CGRect(x: x, y: 0, width: 2, height: size.height))
            image = stripe.composited(over: image)
            x += 4
        }
        return image
    }

    private func gradient(size: CGSize) -> CIImage {
        let filter = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0),
            "inputPoint1": CIVector(x: size.width, y: size.height),
            "inputColor0": CIColor(red: 0.9, green: 0.8, blue: 0.7),
            "inputColor1": CIColor(red: 0.1, green: 0.2, blue: 0.4),
        ])
        return (filter?.outputImage ?? CIImage(color: .gray)).cropped(to: CGRect(origin: .zero, size: size))
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int)? {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return nil }
        guard x >= 0, y >= 0, x < image.width, y < image.height else { return nil }
        let offset = y * image.bytesPerRow + x * (image.bitsPerPixel / 8)
        return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
    }

    private func bytes(_ image: CGImage) throws -> Data {
        let data = try #require(image.dataProvider?.data)
        return Data(referencing: data as NSData)
    }
}
