import AVFoundation
import CoreGraphics
import CoreImage
import Foundation
import Testing
import TimelineKit
@testable import RenderKit

/// A picture read back as numbers — colour and alpha, top-left origin, 0…1 — for the tests
/// of backgrounds, windows, motion blur and transparent export.
struct DressingPixels {
    let width: Int
    let height: Int
    /// Premultiplied RGBA, 8 bits a channel, rows top first.
    let bytes: [UInt8]

    init(_ image: CGImage) {
        width = image.width
        height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let (w, h) = (width, height)
        bytes.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                      bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                .draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        self.bytes = bytes
    }

    /// A decoded video frame, read the same way.
    init?(_ buffer: CVPixelBuffer) {
        let image = CIImage(cvPixelBuffer: buffer)
        let context = CIContext()
        guard let cg = context.createCGImage(image, from: image.extent, format: .RGBA8,
                                             colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else { return nil }
        self.init(cg)
    }

    private func index(_ x: Int, _ y: Int) -> Int {
        (min(height - 1, max(0, y)) * width + min(width - 1, max(0, x))) * 4
    }

    /// The colour at a pixel, unpremultiplied so a half-transparent pixel reads as the
    /// colour it is rather than as that colour darkened.
    func colour(_ x: Int, _ y: Int) -> ColorValue {
        let i = index(x, y)
        let a = Double(bytes[i + 3]) / 255
        guard a > 0 else { return ColorValue(r: 0, g: 0, b: 0, a: 0) }
        return ColorValue(r: min(1, Double(bytes[i]) / 255 / a),
                          g: min(1, Double(bytes[i + 1]) / 255 / a),
                          b: min(1, Double(bytes[i + 2]) / 255 / a),
                          a: a)
    }

    func alpha(_ x: Int, _ y: Int) -> Double {
        Double(bytes[index(x, y) + 3]) / 255
    }

    /// How far apart two colours are, as the largest difference in any one channel.
    static func distance(_ a: ColorValue, _ b: ColorValue) -> Double {
        max(abs(a.r - b.r), abs(a.g - b.g), abs(a.b - b.b))
    }

    func isClose(_ x: Int, _ y: Int, to colour: ColorValue, within tolerance: Double = 0.04) -> Bool {
        Self.distance(self.colour(x, y), colour) <= tolerance
    }
}

enum DressingFixtures {
    static func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    /// A flat recording of one colour, the size of `size`.
    static func flat(_ colour: ColorValue, size: CGSize) -> CIImage {
        CIImage(color: CIColor(red: colour.r, green: colour.g, blue: colour.b))
            .cropped(to: CGRect(origin: .zero, size: size))
    }

    /// Renders a timeline's frame at `seconds` over `source`.
    static func render(_ timeline: Timeline, at seconds: Double, source: CIImage,
                       videoSize: CGSize) throws -> (scene: SceneDescriptor, pixels: DressingPixels) {
        let scene = SceneBuilder(videoSize: videoSize).descriptor(for: timeline, at: time(seconds))
        let image = try #require(SceneRenderer().cgImage(for: scene, source: source))
        return (scene, DressingPixels(image))
    }

    /// The first video frame at or after `seconds` in a file, decoded to BGRA.
    static func frame(of url: URL, at seconds: Double) async throws -> DressingPixels {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: time(seconds), duration: .positiveInfinity)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        reader.add(output)
        #expect(reader.startReading())
        let sample = try #require(output.copyNextSampleBuffer())
        let buffer = try #require(CMSampleBufferGetImageBuffer(sample))
        reader.cancelReading()
        return try #require(DressingPixels(buffer))
    }
}
