import CoreImage
import CoreMedia
import Foundation
import Testing
@testable import RenderKit

/// Playback reads the recording straight through rather than seeking for every frame; the
/// frames it hands back must be the frames an exact seek would have.
@Suite("Playback reads straight through")
struct FrameSourcePlaybackTests {
    private let size = CGSize(width: 320, height: 180)

    private func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600) }

    /// The mean difference between two frames, 0 to 1.
    private func difference(_ a: CIImage, _ b: CIImage) -> Double {
        let context = CIContext()
        let width = Int(size.width), height = Int(size.height)
        func pixels(_ image: CIImage) -> [UInt8] {
            var data = [UInt8](repeating: 0, count: width * height * 4)
            context.render(image, toBitmap: &data, rowBytes: width * 4,
                           bounds: CGRect(x: 0, y: 0, width: width, height: height),
                           format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            return data
        }
        let x = pixels(a), y = pixels(b)
        var total = 0
        for index in x.indices { total += abs(Int(x[index]) - Int(y[index])) }
        return Double(total) / Double(x.count) / 255
    }

    @Test("Each played frame is the frame an exact seek gives, through a backward jump too")
    func sameFramesAsSeeking() async throws {
        let folder = try ExportTests.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let movie = folder.appendingPathComponent("noise.mov")
        // Noise, so every frame differs from its neighbours and a frame off by one shows.
        try await ExportTargetTests.writeNoise(to: movie, size: size, frames: 60, frameRate: 30)
        let source = try await FrameSource(url: movie)

        var times = stride(from: 0.0, to: 1.2, by: 1.0 / 30).map { $0 + 0.004 }
        times += [0.304, 0.338, 0.371] // back, and on again
        for seconds in times {
            let played = try #require(await source.playbackFrame(at: time(seconds)), "a frame at \(seconds)s")
            let sought = try #require(await source.frame(at: time(seconds)), "a seek at \(seconds)s")
            #expect(difference(played, sought) < 0.01, "the same frame at \(seconds)s")
        }
        await source.endPlayback()
    }
}
