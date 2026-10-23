@preconcurrency import AVFoundation
import CoreGraphics
import Observation

/// Small pictures of the footage, for the clip lane.
///
/// A clip that is a flat orange bar says how long it is and nothing about what is in it,
/// so finding "the part where the menu opens" meant scrubbing for it. With a picture every
/// few seconds the moment can be found by eye.
///
/// Pictures are made in the background, one at a time, most recently asked for first —
/// the ones on screen now, rather than the ones that were on screen before a scroll. Each
/// is filed under its moment rounded to a grid, and the grid doubles as the lane zooms out,
/// so zooming in finds most of its pictures already made.
@MainActor
@Observable
final class ClipThumbnails {
    /// The finest the grid gets. Two pictures a quarter of a second apart are the same
    /// picture on a screen recording.
    static let quantum = 0.25
    /// Enough for a long recording at any zoom, at about 70 KB each.
    static let capacity = 400

    /// Width over height of the footage, which is the shape every thumbnail is drawn at.
    let aspect: Double

    /// Whether there is footage to take pictures of.
    var isAvailable: Bool { generator != nil }

    /// Bumped whenever a picture arrives, so a view can redraw for it without reading the
    /// whole store.
    private(set) var version = 0

    @ObservationIgnored private let generator: AVAssetImageGenerator?
    @ObservationIgnored private var images: [Int: CGImage] = [:]
    @ObservationIgnored private var order: [Int] = []
    @ObservationIgnored private var wanted: [Int] = []
    @ObservationIgnored private var asked: Set<Int> = []
    @ObservationIgnored private var worker: Task<Void, Never>?

    init(videoURL: URL?, size: CGSize) {
        aspect = size.height > 0 ? max(0.3, min(4, size.width / size.height)) : 16.0 / 9
        guard let videoURL else {
            generator = nil
            return
        }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: videoURL))
        generator.appliesPreferredTrackTransform = true
        // Twice the lane's height in pixels, for a Retina screen, and no more: decoding a
        // 3K frame is the cost, and a bigger picture of it buys nothing at 54 points tall.
        generator.maximumSize = CGSize(width: 120 * aspect, height: 120)
        // Near enough is fine. An exact frame means decoding from the last keyframe, and
        // for a thumbnail the keyframe itself is the same picture, several times sooner.
        let slack = CMTime(seconds: Self.quantum / 2, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = slack
        generator.requestedTimeToleranceAfter = slack
        self.generator = generator
    }

    /// The grid a lane showing a picture every `spacing` seconds uses: the quantum,
    /// doubled until it is at least that coarse.
    static func step(forSpacing spacing: Double) -> Double {
        guard spacing.isFinite, spacing > quantum else { return quantum }
        return quantum * pow(2, (log2(spacing / quantum)).rounded(.up))
    }

    /// The picture for a moment, or the nearest one already made while it is being made.
    ///
    /// Asking is what gets it made; nothing is made that no lane has asked for.
    func image(near seconds: Double, every spacing: Double) -> CGImage? {
        guard generator != nil, seconds.isFinite else { return nil }
        let step = Self.step(forSpacing: spacing)
        let units = Int((step / Self.quantum).rounded())
        let key = Int((max(0, seconds) / step).rounded()) * units
        if let image = images[key] { return image }
        want(key)
        // Something close while the right one is on its way, so a zoom does not blank the
        // lane: the nearest picture within half a step either side.
        var best: (distance: Int, image: CGImage)?
        for offset in 1...max(1, units / 2) {
            for candidate in [key - offset, key + offset] {
                if let image = images[candidate], best == nil || offset < best!.distance {
                    best = (offset, image)
                }
            }
            if best != nil { break }
        }
        return best?.image
    }

    private func want(_ key: Int) {
        guard !asked.contains(key) else { return }
        asked.insert(key)
        wanted.append(key)
        // What was asked for longest ago is least likely to still be on screen.
        if wanted.count > 64 {
            let dropped = wanted.removeFirst()
            asked.remove(dropped)
        }
        pump()
    }

    private func pump() {
        guard worker == nil, let generator else { return }
        worker = Task { [weak self] in
            while let self, let key = self.wanted.popLast() {
                let time = CMTime(seconds: Double(key) * Self.quantum, preferredTimescale: 600)
                if let image = try? await generator.image(at: time).image {
                    self.store(image, for: key)
                }
                self.asked.remove(key)
            }
            self?.worker = nil
        }
    }

    private func store(_ image: CGImage, for key: Int) {
        images[key] = image
        order.append(key)
        if order.count > Self.capacity {
            images.removeValue(forKey: order.removeFirst())
        }
        version &+= 1
    }

    /// Stops making pictures. The editor calls this as its window closes.
    func stop() {
        worker?.cancel()
        wanted.removeAll()
        asked.removeAll()
    }
}
