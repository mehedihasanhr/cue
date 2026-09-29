import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import Testing
@testable import RenderKit

/// The frame the preview shows is the frame that belongs to that moment.
///
/// The pointer is drawn for an exact time. The picture under it came out of a cache that
/// filed frames under twenty-millisecond buckets, and at 60 fps a frame lasts less than
/// seventeen — so two neighbours could share a bucket and whichever was decoded first was
/// shown for both. Stepping through a click frame by frame could show the pointer pressing
/// a button over the frame before the button answered.
struct FrameSourceTests {
    private let sixty = (0..<600).map { Double($0) / 60 }

    // MARK: - Which frame a moment belongs to

    @Test func aMomentBelongsToTheLastFrameThatHasBegun() {
        #expect(FrameSource.key(for: 0, frameTimes: sixty) == 0)
        #expect(FrameSource.key(for: 0.010, frameTimes: sixty) == 0)
        #expect(FrameSource.key(for: 1.0 / 60, frameTimes: sixty) == 1)
        #expect(FrameSource.key(for: 0.020, frameTimes: sixty) == 1)
        #expect(FrameSource.key(for: 5.0 / 60 + 0.001, frameTimes: sixty) == 5)
    }

    /// Every frame at 60 fps has a key of its own. This is the assertion the old buckets
    /// failed: frames 0 and 1 were both bucket zero.
    @Test func neighbouringFramesNeverShareAKey() {
        let keys = sixty.map { FrameSource.key(for: $0, frameTimes: sixty) }
        #expect(Set(keys).count == sixty.count)
        #expect(keys == Array(0..<sixty.count))
    }

    /// A time that is a frame's own timestamp to within rounding is that frame, not the
    /// one before: a playhead at 1/60 is stored as 0.016666…, a hair short of it.
    @Test func aTimeAHairShortOfAFrameIsThatFrame() {
        #expect(FrameSource.key(for: 1.0 / 60 - 0.000_01, frameTimes: sixty) == 1)
        #expect(FrameSource.key(for: 2.0 / 60 - 0.000_3, frameTimes: sixty) == 2)
    }

    @Test func outsideTheRecordingIsItsFirstOrLastFrame() {
        #expect(FrameSource.key(for: -3, frameTimes: sixty) == 0)
        #expect(FrameSource.key(for: 99, frameTimes: sixty) == sixty.count - 1)
    }

    /// A window's frames arrive when the window changes, not on a grid.
    @Test func framesThatAreNotEvenlySpacedAreFoundToo() {
        let uneven = [0, 0.0183, 0.0350, 0.0500, 0.0667, 0.0990]
        #expect(FrameSource.key(for: 0.018, frameTimes: uneven) == 1, "within the hair of tolerance")
        #expect(FrameSource.key(for: 0.0172, frameTimes: uneven) == 0)
        #expect(FrameSource.key(for: 0.04, frameTimes: uneven) == 2)
        #expect(FrameSource.key(for: 0.098, frameTimes: uneven) == 4)
    }

    /// Before the recording's timings have been read, frames are filed finely enough that
    /// two of them cannot collide — and under keys that cannot be mistaken for an index.
    @Test func beforeTheTimingsAreKnownNeighboursStillDoNotCollide() {
        let keys = sixty.prefix(120).map { FrameSource.key(for: $0, frameTimes: []) }
        #expect(Set(keys).count == 120)
        #expect(keys.allSatisfy { $0 < 0 })
    }

    // MARK: - Against a real file

    /// The average colour of a frame, which the test video makes different for each one.
    private func red(of image: CIImage) -> Double {
        var pixel = [UInt8](repeating: 0, count: 4)
        CIContext().render(image, toBitmap: &pixel, rowBytes: 4,
                           bounds: CGRect(x: 8, y: 8, width: 1, height: 1),
                           format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return Double(pixel[0]) / 255
    }

    @Test func steppingThroughARecordingShowsEveryFrameOnce() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("frames-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        try await ExportTests.writeSilentVideo(to: url, size: CGSize(width: 64, height: 64),
                                               frames: 30, frameRate: 60)
        let source = try await FrameSource(url: url)

        // Give the pass over the timings a moment; the keys are safe either way, which is
        // the point, but this exercises the exact ones.
        for _ in 0..<100 {
            if await source.knownFrameTimes.count == 30 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await source.knownFrameTimes.count == 30)

        var shades: [Double] = []
        for index in 0..<30 {
            let time = CMTime(value: CMTimeValue(index), timescale: 60)
            let frame = try #require(await source.frame(at: time), "no frame at \(index)")
            shades.append(red(of: frame))
        }
        // Each frame is redder than the last. A cached neighbour served in a frame's
        // place shows up as two in a row the same.
        for (before, after) in zip(shades, shades.dropFirst()) {
            #expect(after > before, "two moments a frame apart were shown the same frame")
        }

        // And again, from the cache this time, in the other direction.
        for index in stride(from: 29, through: 0, by: -1) {
            let time = CMTime(value: CMTimeValue(index), timescale: 60)
            let frame = try #require(await source.frame(at: time))
            #expect(abs(red(of: frame) - shades[index]) < 0.01)
        }
    }
}
