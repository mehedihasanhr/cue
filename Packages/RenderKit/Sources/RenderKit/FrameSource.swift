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
    /// When each frame of the recording begins, in order. Empty until it has been read.
    ///
    /// What a cached frame is filed under. It used to be filed under twenty-millisecond
    /// buckets of the time that was asked for, and a frame at 60 fps lasts less than
    /// seventeen: two neighbouring frames could share a bucket, and whichever was decoded
    /// first was then shown for both. The pointer is drawn for the exact moment, so the
    /// preview could show it over the frame before or after the one it belonged to — and
    /// the export, which reads frames in order, never did.
    private var frameTimes: [Double] = []
    /// What to file frames under until the recording's own timings are known: fine enough
    /// that two frames cannot share one.
    private static let provisionalGranularity = 4.0

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
    /// Bumped whenever the quality changes. A decode that began at the old quality and
    /// finishes after the switch belongs to neither the cache nor the caller: a soft
    /// preview-size frame finishing just after a scrub let go was being kept, and shown as
    /// the frame the picture came to rest on.
    private var qualityEpoch = 0
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

        // Read beside everything else rather than before it: opening a recording should
        // not wait on a pass over every frame, and until it is done the provisional keys
        // are already exact enough to be safe.
        if let track {
            Task.detached(priority: .utility) { [weak self] in
                let times = await Self.readFrameTimes(of: track, in: asset)
                await self?.adopt(frameTimes: times)
            }
        }
    }

    /// Every frame's timestamp, read without decoding a single one.
    private static func readFrameTimes(of track: AVAssetTrack, in asset: AVAsset) async -> [Double] {
        guard let reader = try? AVAssetReader(asset: asset) else { return [] }
        // No output settings means no decoder: the samples come back as they are stored,
        // and all that is wanted from them is when they are shown.
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        guard reader.startReading() else { return [] }

        var times: [Double] = []
        while let sample = output.copyNextSampleBuffer() {
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            if time.isValid, CMSampleBufferGetNumSamples(sample) > 0 { times.append(time.seconds) }
        }
        // Stored in the order they are decoded, which is not always the order they are
        // shown.
        return times.sorted()
    }

    private func adopt(frameTimes times: [Double]) {
        guard !times.isEmpty else { return }
        frameTimes = times
        // Filed under the old keys, which mean something else now.
        clearCache()
    }

    /// The timestamps this source files its frames under, for a test to read.
    var knownFrameTimes: [Double] { frameTimes }

    /// What the frame shown at a moment is filed under.
    ///
    /// The frame's own index once the timings are known — the last frame that has begun
    /// by then, which is the rule the generator and the exporter both follow.
    private func key(for time: CMTime) -> Int {
        Self.key(for: time.seconds, frameTimes: frameTimes)
    }

    static func key(for seconds: Double, frameTimes: [Double]) -> Int {
        guard let first = frameTimes.first else {
            // Negative, so a provisional key can never be mistaken for a frame's index.
            return -1 - Int((max(0, seconds) * 1_000 / provisionalGranularity).rounded(.down))
        }
        // A hair of tolerance: a time that is a frame's own timestamp to within rounding
        // belongs to that frame, not to the one before it.
        let moment = seconds + 0.000_5
        guard moment >= first else { return 0 }
        var low = 0
        var high = frameTimes.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if frameTimes[middle] <= moment { low = middle } else { high = middle - 1 }
        }
        return low
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
        qualityEpoch += 1
        clearCache()
    }

    /// The frame at a source time, from the cache when it can be.
    public func frame(at time: CMTime) async -> CIImage? {
        let key = key(for: time)
        if let cached = cache[key] { return cached }

        generation += 1
        let request = generation
        let epoch = qualityEpoch
        guard let image = await generate(at: time) else { return nil }
        // Decoded at a quality that has since been given up: neither kept nor shown.
        guard epoch == qualityEpoch else { return nil }
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
            let key = key(for: target)
            let epoch = qualityEpoch
            guard cache[key] == nil, let image = await generate(at: target), epoch == qualityEpoch else { continue }
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
