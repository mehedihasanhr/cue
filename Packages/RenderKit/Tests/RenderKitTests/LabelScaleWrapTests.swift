import CoreGraphics
import CoreImage
import CoreMedia
import Testing
import TimelineKit
@testable import RenderKit

/// A label fitted to its words at the export's size stays on one line at every size it is
/// drawn — the preview draws smaller while something is dragged or played.
///
/// It did not: set type does not scale exactly with its size, and "This is a dummy text",
/// measured to fit a 3024 × 1898 frame, wrapped at half of it. The second line fell below
/// the box and was cut off, so a label being dragged read "This is a".
struct LabelScaleWrapTests {
    private let frame = CGSize(width: 3_024, height: 1_898)

    /// How far across its box the label's ink reaches, as a share of the box's width.
    private func reach(_ item: AnnotationItem, scale: Double) throws -> Double {
        var timeline = Timeline(sourceDuration: CMTime(seconds: 10, preferredTimescale: 600))
        timeline.annotations = [item]
        let scene = SceneBuilder(videoSize: frame)
            .descriptor(for: timeline, at: CMTime(seconds: 1, preferredTimescale: 600))
            .scaled(by: scale)
        let layer = try #require(scene.annotations.first)
        let output = scene.outputSize
        let box = CGRect(x: layer.rect.minX * output.width, y: (1 - layer.rect.maxY) * output.height,
                         width: layer.rect.width * output.width, height: layer.rect.height * output.height)
        let image = try #require(AnnotationArtwork.image(layer, in: box, outputHeight: output.height))
        let extent = image.extent.integral
        let cg = try #require(CIContext().createCGImage(image, from: extent))
        let width = cg.width, height = cg.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        var right = 0
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 64 { right = max(right, x) }
        }
        let inkRight = extent.minX + Double(right)
        return (inkRight - box.minX) / box.width
    }

    private func label() -> AnnotationItem {
        var item = AnnotationItem(start: .zero, duration: CMTime(seconds: 10, preferredTimescale: 600),
                                  kind: .text("This is a dummy text"),
                                  rect: CGRect(x: 0.28, y: 0.06, width: 0.25, height: 0.05))
        item.fontSize = 0.04427699446179939
        item.color = ColorValue(r: 1, g: 1, b: 1)
        item.animation.entrance = .none
        item.animation.exit = .none
        item.rect = AnnotationFit.fitted(item, frame: frame, setByCaller: false)
        return item
    }

    /// Down to a quarter: below that the type is a few pixels tall, hinting moves it by
    /// more than any room a box could be given, and no Retina pane is small enough to ask
    /// for it of a frame this size.
    @Test(arguments: [1.0, 0.75, 0.625, 0.5, 0.375, 0.25])
    func aFittedLabelStaysOnOneLine(scale: Double) throws {
        // On one line the ink runs to the box's far side; with "dummy text" dropped to a
        // second line it stops a little under halfway.
        #expect(try reach(label(), scale: scale) > 0.9)
    }

    @Test func aLabelTooLongForItsBoxStillWraps() throws {
        var item = label()
        item.fixedWidth = true
        item.rect.size.width /= 2
        item.rect.size.height *= 2
        #expect(try reach(item, scale: 1) < 1.1)
    }
}
