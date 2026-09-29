import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import Testing
import TimelineKit
@testable import RenderKit

/// The three new shapes and the typed one: the output they make, and where everything
/// placed in that output lands — the picture, the camera bubble, the caption, a note.
struct AspectShapeLayoutTests {
    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    private let videoSize = CGSize(width: 1_600, height: 1_000)

    private func builder() -> SceneBuilder {
        SceneBuilder(videoSize: videoSize, displayScale: 2)
    }

    /// One shape to check, with the ratio it must come out at.
    struct Shape: CustomTestStringConvertible, Sendable {
        let aspect: AspectPreset
        let custom: CustomAspect?
        let ratio: Double
        var testDescription: String { custom.map(\.title) ?? aspect.displayName }
    }

    static let shapes: [Shape] = [
        Shape(aspect: .portrait4x5, custom: nil, ratio: 0.8),
        Shape(aspect: .portrait3x4, custom: nil, ratio: 0.75),
        Shape(aspect: .wide16x10, custom: nil, ratio: 1.6),
        Shape(aspect: .custom, custom: CustomAspect(width: 21, height: 9), ratio: 21.0 / 9),
        Shape(aspect: .custom, custom: CustomAspect(width: 2, height: 3), ratio: 2.0 / 3),
    ]

    private func timeline(_ shape: Shape, padding: Double = 0.06) -> Timeline {
        var timeline = Timeline(sourceDuration: time(60))
        timeline.style.aspect = shape.aspect
        if let custom = shape.custom { timeline.style.customAspect = custom }
        timeline.style.padding = padding
        timeline.cursor.isVisible = false
        return timeline
    }

    // MARK: - The output

    @Test(arguments: shapes)
    func theOutputHasTheShapeAndKeepsTheRecordingsPixels(_ shape: Shape) {
        let output = builder().outputSize(for: timeline(shape).style)
        #expect(abs(output.width / output.height - shape.ratio) < 0.01)
        #expect(Int(output.width) % 2 == 0)
        #expect(Int(output.height) % 2 == 0)
        let area = (output.width * output.height) / (videoSize.width * videoSize.height)
        #expect(area > 0.98 && area < 1.02, "the same number of pixels, neither upscaled nor thrown away")
    }

    @Test(arguments: shapes)
    func thePictureIsCentredInsetAndStillTheRecordingsShape(_ shape: Shape) {
        let scene = builder().descriptor(for: timeline(shape, padding: 0.08), at: .zero)
        let output = scene.outputSize
        let frame = scene.videoFrame
        let inset = min(output.width, output.height) * 0.08

        #expect(abs(frame.width / frame.height - 1.6) < 0.001, "the recording is never stretched")
        #expect(abs(frame.midX - output.width / 2) < 0.001)
        #expect(abs(frame.midY - output.height / 2) < 0.001)
        #expect(frame.minX >= inset - 0.001 && frame.maxX <= output.width - inset + 0.001)
        #expect(frame.minY >= inset - 0.001 && frame.maxY <= output.height - inset + 0.001)
        // Fitted: it touches the padding on one pair of sides.
        let touchesSides = abs(frame.minX - inset) < 0.5 || abs(frame.minY - inset) < 0.5
        #expect(touchesSides, "the picture fills what the padding leaves")
    }

    @Test(arguments: shapes)
    func theShapeIsHonouredAgainstACrop(_ shape: Shape) {
        var edit = timeline(shape)
        edit.style.crop = CropRect(rect: CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.6))
        let output = builder().outputSize(for: edit.style)
        #expect(abs(output.width / output.height - shape.ratio) < 0.02)
        let cropped = (videoSize.width * 0.5) * (videoSize.height * 0.6)
        let area = (output.width * output.height) / cropped
        #expect(area > 0.97 && area < 1.03, "area is preserved against the crop, not the recording")
    }

    @Test(arguments: shapes)
    func anExportSizeKeepsTheShapeUnderACap(_ shape: Shape) {
        let output = builder().outputSize(for: timeline(shape).style)
        let capped = ExportSettings(maximumDimension: 1_280).outputSize(fitting: output)
        #expect(max(capped.width, capped.height) <= 1_280)
        #expect(abs(capped.width / capped.height - shape.ratio) < 0.02)
        #expect(Int(capped.width) % 2 == 0 && Int(capped.height) % 2 == 0)
        let uncapped = ExportSettings().outputSize(fitting: output)
        #expect(uncapped == output)
    }

    // MARK: - Everything placed in the finished frame

    @Test(arguments: shapes)
    func theCameraBubbleIsSquareAndParkedInItsCorner(_ shape: Shape) throws {
        var edit = timeline(shape)
        edit.webcam.isEnabled = true
        edit.webcam.corner = .bottomRight
        edit.webcam.size = 0.2
        let scene = builder().descriptor(for: edit, at: .zero)
        let output = scene.outputSize
        let bubble = try #require(scene.webcam)

        let pixels = bubble.pixelRect(in: output)
        #expect(abs(pixels.width - pixels.height) < 0.001, "square in pixels, whatever the frame's shape")
        let shorter = min(output.width, output.height)
        #expect(abs(pixels.width - shorter * 0.2) < 0.001, "a fraction of the shorter side")
        let margin = shorter * 0.035
        #expect(abs((output.width - pixels.maxX) - margin) < 0.001)
        #expect(abs(pixels.minY - margin) < 0.001, "bottom right, in Core Image's bottom-left space")
        #expect(bubble.rect.maxX <= 1 && bubble.rect.maxY <= 1)
    }

    @Test(arguments: shapes)
    func aCaptionSitsCentredAboveTheBottomMargin(_ shape: Shape) throws {
        let output = builder().outputSize(for: timeline(shape).style)
        let layer = CaptionLayer(text: "Open the settings panel", fontSize: 0.05, color: .white,
                                 backgroundOpacity: 0.5, position: .bottom, margin: 0.08)
        let plate = try #require(CaptionArtwork.image(layer, outputSize: output))
        let extent = plate.extent
        #expect(abs(extent.midX - output.width / 2) < 1)
        #expect(abs(extent.minY - output.height * 0.08) < 1)
        #expect(extent.maxX <= output.width && extent.minX >= 0)
        #expect(extent.maxY <= output.height)
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int)? {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data),
              x >= 0, y >= 0, x < image.width, y < image.height else { return nil }
        let offset = y * image.bytesPerRow + x * (image.bitsPerPixel / 8)
        return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
    }

    /// A box drawn on the finished frame is a fraction of *that* frame: its left edge is
    /// a tenth of the way across whatever width the shape produced.
    @Test(arguments: shapes)
    func aNoteIsPlacedAgainstTheFinishedFrame(_ shape: Shape) throws {
        var edit = timeline(shape)
        edit.style.padding = 0
        edit.style.cornerRadius = 0
        edit.style.shadowOpacity = 0
        edit.annotations = [AnnotationItem(start: .zero, duration: time(10), kind: .rectangle,
                                           rect: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8),
                                           color: ColorValue(r: 1, g: 0, b: 0),
                                           animation: AnnotationAnimation(entrance: .none, exit: .none))]
        let scene = builder().descriptor(for: edit, at: time(2))
        let source = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(origin: .zero, size: videoSize))
        let image = try #require(SceneRenderer().cgImage(for: scene, source: source))

        let left = Int(Double(image.width) * 0.1)
        let row = image.height / 2
        let onTheEdge = (left...(left + 8)).compactMap { pixel(image, x: $0, y: row) }
        #expect(onTheEdge.contains { $0.r > 180 && $0.b < 100 }, "the box's left edge is a tenth of the way in")
        let middle = try #require(pixel(image, x: image.width / 2, y: row))
        #expect(middle.b > 180 && middle.r < 100, "and the middle is picture, not box")
    }

    // MARK: - Custom in particular

    @Test func aCustomShapeNobodyTypedIsThreeByTwo() {
        var edit = Timeline(sourceDuration: time(60))
        edit.style.aspect = .custom
        let output = builder().outputSize(for: edit.style)
        #expect(abs(output.width / output.height - 1.5) < 0.01)
    }

    @Test func aPresetIgnoresTheTypedNumbers() {
        var edit = Timeline(sourceDuration: time(60))
        edit.style.customAspect = CustomAspect(width: 21, height: 9)
        edit.style.aspect = .square
        let output = builder().outputSize(for: edit.style)
        #expect(output.width == output.height)
    }

    @Test func theCropToolsFlatPreviewIsTheRecordingsOwnShape() {
        // What the crop tool renders: the whole recording, no shape — whatever the
        // project's shape is.
        var edit = Timeline(sourceDuration: time(60))
        edit.style.aspect = .custom
        edit.style.customAspect = CustomAspect(width: 1, height: 3)
        edit.style.aspect = .source
        #expect(builder().outputSize(for: edit.style) == videoSize)
    }
}
