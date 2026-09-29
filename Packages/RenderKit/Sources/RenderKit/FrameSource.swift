import AVFoundation
import CoreImage
import CoreMedia
import Foundation
import TimelineKit

/// Frames out of the recording, by time.
///
/// The editor scrubs, which means asking for a frame at an arbitrary moment and getting
/// it back quickly enough that dragging feels like dragging. `AVAssetImageGenerator`
/// does the seeking; the cache is what makes the second pass over the same stretch free.
public actor FrameSource {
    private let generator: AVAssetImageGenerator
    private var cache: [Int: CIImage] = [:]
    private var order: [Int] = []
    private let capacity: Int
    /// Frames are cached per this many milliseconds. Finer than a frame at 60 fps would
    /// just be a miss every time; coarser and a scrub would visibly step.
    private let granularity: Int32 = 20

    /// The recording's size in pixels, rotation applied.
    ///
    /// `nonisolated` because it never changes after `init`: making callers `await` a
    /// constant would mean the editor could not size itself without a hop.
    public nonisolated let naturalSize: CGSize

    /// How exactly to seek.
    ///
    /// Exactness is what makes the preview the same picture as the export — but only
    /// when the picture is being *looked at*. While it is moving, a zero-tolerance
    /// full-resolution seek decodes an entire group of pictures for a frame that is on
    /// screen for a fraction of a second, and none of that detail is visible anyway.
    public enum Quality: Equatable, Sendable {
        case exact
        case preview(CGSize)
    }

    private var quality: Quality = .exact
    /// Which request is current. A cancelled `Task` cannot stop a decode that is already
    /// inside the generator, so a fast scrub would otherwise queue up a backlog of
    /// frames nobody will ever look at.
    private var generation = 0

    /// How many decoded frames to keep.
    ///
    /// `CIImage(cgImage:)` is lazy, so what is actually retained is the backing
    /// `CGImage` — about 33 MB at 4K. Sixty of those is two gigabytes, which is not a
    /// cache, it is a leak with a bound.
    public init(url: URL, capacity: Int = 24) async throws {
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .video).first
        let size = try await track?.load(.naturalSize) ?? .zero
        // A recording rotated by its transform reports its size unrotated, so the
        // rectangle is transformed rather than the size.
        let transform = try await track?.load(.preferredTransform) ?? .identity
        naturalSize = CGRect(origin: .zero, size: size).applying(transform).standardized.size

        generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        // Full resolution: this feeds the same renderer the export uses, and a preview
        // drawn from a downscaled frame would not be the picture that gets written.
        generator.maximumSize = .zero
        self.capacity = capacity
    }

    /// Trades exactness for speed while the picture is moving.
    public func setQuality(_ quality: Quality) {
        guard quality != self.quality else { return }
        self.quality = quality
        switch quality {
        case .exact:
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            generator.maximumSize = .zero
        case .preview(let size):
            let half = CMTime(value: 1, timescale: 120)
            generator.requestedTimeToleranceBefore = half
            generator.requestedTimeToleranceAfter = half
            generator.maximumSize = size
        }
        // Frames decoded at one quality must not be handed out at the other.
        clearCache()
    }

    /// The frame at a source time, from the cache when it can be.
    public func frame(at time: CMTime) async -> CIImage? {
        let key = Int((time.seconds * 1_000).rounded() / Double(granularity))
        if let cached = cache[key] { return cached }

        generation += 1
        let request = generation
        guard let image = await generate(at: time) else { return nil }
        // A newer request arrived while this one was decoding, so this frame is already
        // out of date: cache it, but do not hand it back as the current one.
        let frame = CIImage(cgImage: image)
        store(frame, for: key)
        guard request == generation else { return nil }
        return frame
    }

    /// Warms the cache around a time, so a scrub that carries on in the same direction
    /// finds its next frames already there.
    ///
    /// Forward only during playback: there is no such thing as scrubbing backwards while
    /// playing, and half the prefetch was being spent on frames that had just been shown.
    public func prefetch(around time: CMTime, spread: Double = 0.5, forward: Bool = false) async {
        let offsets = forward ? [spread, spread * 2] : [-spread, spread]
        for offset in offsets {
            let target = time + CMTime(seconds: offset, preferredTimescale: 600)
            guard target >= .zero else { continue }
            let key = Int((target.seconds * 1_000).rounded() / Double(granularity))
            guard cache[key] == nil, let image = await generate(at: target) else { continue }
            store(CIImage(cgImage: image), for: key)
        }
    }

    /// The callback API rather than `image(at:)`.
    ///
    /// The `async` property accessor would have to *send* the generator out of this
    /// actor, which Swift refuses — rightly, since the generator is not `Sendable`. With
    /// the callback, the generator stays here and only the finished image crosses back.
    private func generate(at time: CMTime) async -> CGImage? {
        await withCheckedContinuation { continuation in
            generator.generateCGImageAsynchronously(for: time) { image, _, _ in
                continuation.resume(returning: image)
            }
        }
    }

    private func store(_ image: CIImage, for key: Int) {
        cache[key] = image
        order.append(key)
        // A frame of 4K is 30-odd megabytes; without a bound, scrubbing a long recording
        // would keep every one of them.
        while order.count > capacity {
            cache.removeValue(forKey: order.removeFirst())
        }
    }

    public func clearCache() {
        cache.removeAll()
        order.removeAll()
    }
}
