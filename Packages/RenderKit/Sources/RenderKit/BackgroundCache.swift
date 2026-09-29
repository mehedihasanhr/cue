import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import os

/// The finished background, kept between frames.
///
/// A background is the one layer in the composite that does not change from frame to
/// frame, and it was being rebuilt for every one of them — for an image background that
/// meant decoding a wallpaper off disk thirty times a second and blurring it again each
/// time. Three entries is enough: the current background, and the one being compared
/// against it while somebody flicks between two swatches.
final class BackgroundCache: @unchecked Sendable {
    private struct Key: Hashable {
        let layer: BackgroundLayer
        let width: Int
        let height: Int
        let blur: Int
    }

    private let lock = NSLock()
    private var entries: [(key: Key, image: CIImage)] = []
    private let capacity = 3

    func image(for layer: BackgroundLayer,
               size: CGSize,
               blurSigma: Double,
               make: () -> CIImage) -> CIImage {
        let key = Key(layer: layer,
                      width: Int(size.width.rounded()),
                      height: Int(size.height.rounded()),
                      // Rounded to a tenth of a pixel: a slider drag would otherwise
                      // miss the cache on every frame, which is when it matters most.
                      blur: Int((blurSigma * 10).rounded()))

        lock.lock()
        if let hit = entries.firstIndex(where: { $0.key == key }) {
            let entry = entries.remove(at: hit)
            entries.append(entry)
            lock.unlock()
            return entry.image
        }
        lock.unlock()

        let image = make()

        lock.lock()
        entries.append((key, image))
        while entries.count > capacity { entries.removeFirst() }
        lock.unlock()
        return image
    }
}

extension BackgroundLayer: Hashable {
    public func hash(into hasher: inout Hasher) {
        switch self {
        case .color(let color):
            hasher.combine(0)
            hasher.combine(color.r); hasher.combine(color.g)
            hasher.combine(color.b); hasher.combine(color.a)
        case .gradient(let stops, let angle):
            hasher.combine(1)
            hasher.combine(angle)
            for stop in stops {
                hasher.combine(stop.location)
                hasher.combine(stop.color.r); hasher.combine(stop.color.g)
                hasher.combine(stop.color.b); hasher.combine(stop.color.a)
            }
        case .image(let url):
            hasher.combine(2)
            hasher.combine(url)
        case .missing:
            hasher.combine(3)
        case .transparent:
            hasher.combine(4)
        case .fittedGradient(let stops, let angle, let isRadial):
            hasher.combine(5)
            hasher.combine(angle)
            hasher.combine(isRadial)
            for stop in stops {
                hasher.combine(stop.location)
                hasher.combine(stop.color.r); hasher.combine(stop.color.g)
                hasher.combine(stop.color.b); hasher.combine(stop.color.a)
            }
        case .animated(let layer):
            hasher.combine(6)
            hasher.combine(layer)
        case .video(let url, let time):
            hasher.combine(7)
            hasher.combine(url)
            hasher.combine(time)
        }
    }
}

/// Decoding a background picture at the size it will actually be drawn.
enum BackgroundImageLoader {
    /// A wallpaper is often 6000 px wide and the frame behind a recording is not. Asking
    /// ImageIO for a thumbnail decodes at the size we need instead of decoding the whole
    /// thing and throwing most of it away.
    static func load(_ url: URL, fitting size: CGSize) -> CIImage? {
        let longest = Int(max(size.width, size.height).rounded())
        guard longest > 0, let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            // Generous, because the background is scaled to *fill*: a portrait wallpaper
            // in a landscape frame is cropped, so the long edge has to cover more than
            // the long edge of the output.
            kCGImageSourceThumbnailMaxPixelSize: Int(Double(longest) * 1.6),
        ]
        guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            log.error("Couldn't decode background \(url.lastPathComponent, privacy: .public)")
            return nil
        }
        return CIImage(cgImage: decoded)
    }

    private static let log = Logger(subsystem: "com.stackrover.klik.studio", category: "render")
}
