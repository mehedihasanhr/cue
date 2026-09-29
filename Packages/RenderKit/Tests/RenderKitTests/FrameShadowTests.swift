import CoreGraphics
import CoreImage
import CoreMedia
import Testing
import TimelineKit
@testable import RenderKit

/// The frame's shadow fades away from it.
///
/// Square corners are the case that matters: with no rounding at all the shadow's shape was
/// a plain block of colour, which Core Image turned into a colour with no edges — the whole
/// background came out black. Before that, the shape was also clamped before it was
/// blurred, which made a solid band three blurs wide with a hard outer edge.
struct FrameShadowTests {
    @Test func theShadowIsSoftWithNoEdgeOfItsOwn() throws {
        var timeline = Timeline(sourceDuration: CMTime(seconds: 10, preferredTimescale: 600))
        timeline.style.background = .color(ColorValue(r: 1, g: 1, b: 1))
        timeline.style.padding = 0.12
        timeline.style.cornerRadius = 0
        timeline.style.shadowOpacity = 1
        timeline.cursor.isVisible = false
        let builder = SceneBuilder(videoSize: CGSize(width: 1_600, height: 1_000), displayScale: 1)
        let scene = builder.descriptor(for: timeline, at: CMTime(seconds: 1, preferredTimescale: 600))
        let blur = scene.shadowRadius
        try #require(blur > 4)
        let source = CIImage(color: CIColor(red: 1, green: 1, blue: 1))
            .cropped(to: CGRect(x: 0, y: 0, width: 1_600, height: 1_000))
        let image = try #require(SceneRenderer().cgImage(for: scene, source: source))
        func shade(_ blurs: Double) throws -> Int {
            try #require(pixel(image, x: Int(scene.videoFrame.maxX + blur * blurs), y: image.height / 2)).r
        }
        let near = try shade(0.3)
        let middle = try shade(1.2)
        let far = try shade(2.8)
        #expect(near < middle && middle < far, "darkest by the frame, lighter further out: \(near), \(middle), \(far)")
        #expect(near < 235, "there is a shadow: \(near)")
        #expect(far > 245, "and it has faded to nothing before it is cropped: \(far)")
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int)? {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data),
              x >= 0, y >= 0, x < image.width, y < image.height else { return nil }
        let offset = y * image.bytesPerRow + x * (image.bitsPerPixel / 8)
        return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
    }
}
