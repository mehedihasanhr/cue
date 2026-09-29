import AVFoundation
import CoreGraphics
import Foundation
import RecordKit

/// When the picture itself was changing.
///
/// The pointer and the keys say when somebody was *doing* something; this says when the
/// screen was — a page arriving, a build scrolling past, a video playing. Without it every
/// one of those reads as nothing happening, and a recording of somebody watching a result
/// come in would be offered at four times speed exactly where it matters.
///
/// Measured on a tiny grey copy of the picture, a few times a second. That is deliberately
/// coarse: a blinking caret or a small spinner is a few pixels, which is waiting, and it
/// should read as still.
public enum ScreenActivity {
    /// The picture is read at this size.
    static let grid = (width: 32, height: 18)
    /// How often the picture is read, in seconds.
    public static let interval = 0.25
    /// A cell counts as changed when its brightness moves by more than this (0–255).
    static let cellThreshold = 6
    /// The picture counts as changing when at least this share of its cells did.
    static let shareThreshold = 0.02
    /// Two changes closer than this are one stretch of change.
    static let gap = 0.6

    /// The stretches of change, from brightness grids read in order.
    public static func changing(_ frames: [(time: Double, luma: [UInt8])]) -> [ClosedRange<Double>] {
        var ranges: [ClosedRange<Double>] = []
        for (before, after) in zip(frames, frames.dropFirst()) {
            guard before.luma.count == after.luma.count, !after.luma.isEmpty else { continue }
            var changed = 0
            for (a, b) in zip(before.luma, after.luma) where abs(Int(a) - Int(b)) > cellThreshold {
                changed += 1
            }
            guard Double(changed) / Double(after.luma.count) >= shareThreshold else { continue }
            if let last = ranges.last, before.time - last.upperBound <= gap {
                ranges[ranges.count - 1] = last.lowerBound...after.time
            } else {
                ranges.append(before.time...after.time)
            }
        }
        return ranges
    }

    /// Reads the recording and returns when its picture was changing, in recording seconds.
    public static func measure(videoURL: URL) async throws -> [ClosedRange<Double>] {
        let asset = AVURLAsset(url: videoURL)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { return [] }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: grid.width * 4, height: grid.height * 4)
        // Near enough is the point: exact frames would mean decoding from a keyframe for
        // every one of them.
        let tolerance = CMTime(seconds: interval / 2, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        let times = stride(from: 0.0, to: duration, by: interval).map { CMTime(seconds: $0, preferredTimescale: 600) }
        var frames: [(time: Double, luma: [UInt8])] = []
        frames.reserveCapacity(times.count)
        for await result in generator.images(for: times) {
            try Task.checkCancellation()
            guard let image = try? result.image, let luma = luma(of: image) else { continue }
            frames.append((result.requestedTime.seconds, luma))
        }
        frames.sort { $0.time < $1.time }
        return changing(frames)
    }

    /// The picture as a small grid of brightness values.
    static func luma(of image: CGImage) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: grid.width * grid.height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: grid.width, height: grid.height,
                                          bitsPerComponent: 8, bytesPerRow: grid.width,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: grid.width, height: grid.height))
            return true
        }
        return drawn ? pixels : nil
    }

    // MARK: - Cache

    private struct Cached: Codable {
        var version = 1
        var size: Int64
        var modified: Double
        var ranges: [[Double]]
    }

    /// The last measurement, if the recording has not changed since.
    public static func cached(in package: RecordingPackage, source url: URL) -> [ClosedRange<Double>]? {
        guard let stamp = stamp(of: url),
              let data = try? Data(contentsOf: cacheURL(in: package)),
              let cached = try? JSONDecoder().decode(Cached.self, from: data),
              cached.version == 1, cached.size == stamp.size, cached.modified == stamp.modified
        else { return nil }
        return cached.ranges.compactMap { $0.count == 2 && $0[0] <= $0[1] ? $0[0]...$0[1] : nil }
    }

    public static func cache(_ ranges: [ClosedRange<Double>], in package: RecordingPackage, source url: URL) {
        guard let stamp = stamp(of: url) else { return }
        let cached = Cached(size: stamp.size, modified: stamp.modified,
                            ranges: ranges.map { [$0.lowerBound, $0.upperBound] })
        try? FileManager.default.createDirectory(at: package.derivedFolder, withIntermediateDirectories: true)
        try? JSONEncoder().encode(cached).write(to: cacheURL(in: package), options: .atomic)
    }

    static func cacheURL(in package: RecordingPackage) -> URL {
        package.derivedFolder.appendingPathComponent("screen-activity.json")
    }

    private static func stamp(of url: URL) -> (size: Int64, modified: Double)? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize, let modified = values.contentModificationDate else { return nil }
        return (Int64(size), modified.timeIntervalSinceReferenceDate)
    }
}
