import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import ImageIO
import Testing
import TimelineKit
import UniformTypeIdentifiers
@testable import RenderKit

/// A picture laid over the video: found inside the project, and never stretched.
struct PictureAnnotationTests {
    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    /// A project folder with a red picture twice as wide as it is tall at `Images/red.png`.
    private func project() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pictures-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Images"),
                                                withIntermediateDirectories: true)
        let context = try #require(CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        let image = try #require(context.makeImage())
        let url = folder.appendingPathComponent("Images/red.png")
        let writer = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(writer, image, nil)
        #expect(CGImageDestinationFinalize(writer))
        return folder
    }

    /// The frame, as bytes, 100 × 100.
    private func pixels(_ scene: SceneDescriptor) throws -> [UInt8] {
        let black = CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: scene.outputSize))
        let image = try #require(SceneRenderer().cgImage(for: scene, source: black))
        var bytes = [UInt8](repeating: 0, count: 100 * 100 * 4)
        let context = try #require(CGContext(data: &bytes, width: 100, height: 100, bitsPerComponent: 8,
                                             bytesPerRow: 400, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 100, height: 100))
        return bytes
    }

    /// Red at a point, counted from the top left.
    private func isRed(_ bytes: [UInt8], x: Int, y: Int) -> Bool {
        let index = (y * 100 + x) * 4
        return bytes[index] > 200 && bytes[index + 1] < 60 && bytes[index + 2] < 60
    }

    @Test func aPictureNamedInsideTheProjectIsFoundAndDrawnInItsOwnShape() throws {
        let folder = try project()
        defer { try? FileManager.default.removeItem(at: folder) }
        var timeline = Timeline(sourceDuration: time(10))
        timeline.style.padding = 0
        timeline.style.cornerRadius = 0
        timeline.style.shadowOpacity = 0
        timeline.cursor.isVisible = false
        // A square box in the middle of a square frame; the picture is twice as wide as tall.
        timeline.annotations = [AnnotationItem(start: .zero, duration: time(10),
                                               kind: .image(path: "Images/red.png"),
                                               rect: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))]
        let builder = SceneBuilder(videoSize: CGSize(width: 1_000, height: 1_000), displayScale: 1, packageURL: folder)
        let bytes = try pixels(builder.descriptor(for: timeline, at: time(2), cursor: nil))

        #expect(isRed(bytes, x: 50, y: 50), "drawn")
        #expect(isRed(bytes, x: 27, y: 50) && isRed(bytes, x: 72, y: 50), "the full width of the box")
        // Half as tall as it is wide: from 37.5 to 62.5, not from 25 to 75.
        #expect(!isRed(bytes, x: 50, y: 30), "not stretched to the top of the box")
        #expect(!isRed(bytes, x: 50, y: 70), "nor to the bottom")
        #expect(isRed(bytes, x: 50, y: 40) && isRed(bytes, x: 50, y: 60))
    }
}
