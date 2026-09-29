import AVFoundation
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import TimelineKit

/// Backgrounds that move: drawn from the moment they are at, and nothing else.
///
/// Every movement here is a sum of slow sines of the time, so a frame is a function of its
/// moment alone — the preview scrubbed to a frame and the export writing it draw the same
/// picture, and there is no state to fall out of step. The periods are prime-ish and far
/// apart, so the patterns do not visibly repeat within a video anybody would make.
extension SceneRenderer {
    func animatedBackground(_ layer: AnimatedBackgroundLayer, in output: CGRect) -> CIImage {
        let colours = layer.colors.isEmpty ? AnimatedBackground.defaultColors : layer.colors
        let t = layer.time * min(max(layer.speed, 0.05), 10)
        switch layer.kind {
        case .drift: return drift(colours, t: t, in: output)
        case .aurora: return aurora(colours, t: t, in: output)
        case .grain: return grain(colours, t: t, in: output)
        }
    }

    private static func wave(_ t: Double, period: Double, phase: Double = 0) -> Double {
        sin(2 * .pi * (t / period + phase))
    }

    private static func stops(_ colours: [ColorValue], middle: Double = 0.5) -> [GradientStop] {
        guard colours.count > 2 else {
            return colours.enumerated().map { GradientStop(color: $1, location: Double($0) / Double(max(1, colours.count - 1))) }
        }
        return [GradientStop(color: colours[0], location: 0),
                GradientStop(color: colours[1], location: middle),
                GradientStop(color: colours[2], location: 1)]
    }

    private static func ink(_ colour: ColorValue, alpha: Double) -> CIColor {
        CIColor(red: colour.r, green: colour.g, blue: colour.b, alpha: alpha)
    }

    /// The palette's gradient, slowly turning and breathing, with a soft light wandering
    /// across it.
    private func drift(_ colours: [ColorValue], t: Double, in output: CGRect) -> CIImage {
        let angle = 0.125 + t / 80 + 0.04 * Self.wave(t, period: 19)
        let middle = 0.5 + 0.15 * Self.wave(t, period: 13)
        var image = fittedGradient(stops: Self.stops(colours, middle: middle), angle: angle, isRadial: false, in: output)

        let lightest = colours.max { $0.r + $0.g + $0.b < $1.r + $1.g + $1.b } ?? colours[0]
        let glow = CIFilter.radialGradient()
        glow.center = CGPoint(x: output.minX + output.width * (0.5 + 0.3 * Self.wave(t, period: 29, phase: 0.25)),
                              y: output.minY + output.height * (0.5 + 0.25 * Self.wave(t, period: 23)))
        glow.radius0 = 0
        glow.radius1 = Float(max(output.width, output.height) * 0.7)
        glow.color0 = Self.ink(lightest, alpha: 0.35)
        glow.color1 = Self.ink(lightest, alpha: 0)
        if let light = glow.outputImage?.cropped(to: output) {
            image = light.composited(over: image)
        }
        return image.cropped(to: output)
    }

    /// Soft blobs of the palette's colours wandering over a dark ground, lightening where
    /// they meet.
    private func aurora(_ colours: [ColorValue], t: Double, in output: CGRect) -> CIImage {
        let darkest = colours.min { $0.r + $0.g + $0.b < $1.r + $1.g + $1.b } ?? colours[0]
        var image = CIImage(color: CIColor(red: darkest.r * 0.3, green: darkest.g * 0.3, blue: darkest.b * 0.3))
            .cropped(to: output)
        let shorter = min(output.width, output.height)
        let periods: [(x: Double, y: Double)] = [(23, 29), (31, 17), (19, 25), (27, 21)]
        for (index, period) in periods.enumerated() {
            let colour = colours[index % colours.count]
            let phase = Double(index) * 0.37
            let blob = CIFilter.radialGradient()
            blob.center = CGPoint(x: output.minX + output.width * (0.5 + 0.38 * Self.wave(t, period: period.x, phase: phase)),
                                  y: output.minY + output.height * (0.5 + 0.34 * Self.wave(t, period: period.y, phase: phase * 1.3 + 0.25)))
            blob.radius0 = 0
            blob.radius1 = Float(shorter * (0.62 + 0.12 * Self.wave(t, period: 11, phase: phase)))
            blob.color0 = Self.ink(colour, alpha: 0.85)
            blob.color1 = Self.ink(colour, alpha: 0)
            guard let shape = blob.outputImage?.cropped(to: output) else { continue }
            let screen = CIFilter.screenBlendMode()
            screen.inputImage = shape
            screen.backgroundImage = image
            image = screen.outputImage ?? image
        }
        return image.cropped(to: output)
    }

    /// The palette's gradient, barely moving, under a fine grain that changes every frame of
    /// film — twenty-four times a second at the ordinary speed, whatever the export's rate.
    private func grain(_ colours: [ColorValue], t: Double, in output: CGRect) -> CIImage {
        let base = fittedGradient(stops: Self.stops(colours), angle: 0.125 + t / 240, isRadial: false, in: output)

        // Which grain: a hash of the film frame, so the pattern jumps like grain rather than
        // sliding like a texture, and the same moment always gets the same pattern.
        let frame = Int64((t * 24).rounded(.down))
        let dx = Double((frame &* 73_856_093) & 0xFFF)
        let dy = Double((frame &* 19_349_663) & 0xFFF)
        // A grain of the same size at 1080p and at 4K, rather than one that shrinks.
        let size = max(1, min(output.width, output.height) / 1_080)
        let noise = CIFilter.randomGenerator().outputImage?
            .transformed(by: CGAffineTransform(translationX: -dx, y: -dy).concatenating(CGAffineTransform(scaleX: size, y: size)))
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ])
            .cropped(to: output)
        guard let noise else { return base }
        let light = CIFilter.softLightBlendMode()
        light.inputImage = noise
        light.backgroundImage = base
        guard let grained = light.outputImage else { return base }
        // Soft light at full strength is sandpaper; a fifth of it is film.
        let mix = CIFilter.dissolveTransition()
        mix.inputImage = base
        mix.targetImage = grained
        mix.time = 0.2
        return (mix.outputImage ?? base).cropped(to: output)
    }

    /// A frame of a background movie, filling the output, or the missing background when
    /// the movie cannot be read.
    func videoBackground(_ url: URL, time: Double, in output: CGRect) -> CIImage? {
        guard let frame = movies.frame(of: url, at: time) else { return nil }
        let extent = frame.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        // Fill, not fit, as for a picture: a background with bars down its sides is not one.
        let scale = max(output.width / extent.width, output.height / extent.height)
        let filled = frame.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale)))
        return filled
            .transformed(by: CGAffineTransform(translationX: output.midX - filled.extent.midX,
                                               y: output.midY - filled.extent.midY))
            .cropped(to: output)
    }
}

/// The background movies one renderer is reading, each held open between frames.
///
/// One per renderer, like its background cache: the preview and the exporter each read
/// their own, in their own order, and a reader walking forwards for one must not be sent
/// back to the start by the other.
final class BackgroundMovies: @unchecked Sendable {
    private enum Entry {
        case ready(BackgroundMovie)
        /// Not a movie, or not there. Remembered, so a broken file costs one attempt rather
        /// than one per frame.
        case failed
    }

    private let lock = NSLock()
    private var entries: [URL: Entry] = [:]

    func frame(of url: URL, at seconds: Double) -> CIImage? {
        lock.lock()
        defer { lock.unlock() }
        let entry: Entry
        if let known = entries[url] {
            entry = known
        } else {
            entry = BackgroundMovie(url: url).map(Entry.ready) ?? .failed
            // A project has one background; two covers flicking between a pair of them.
            if entries.count >= 2 { entries.removeAll() }
            entries[url] = entry
        }
        guard case .ready(let movie) = entry else { return nil }
        return movie.frame(at: seconds)
    }
}

/// One background movie, played on a loop, through the reader the export reads the
/// recording with.
///
/// A loop is a moment modulo the movie's length. Reading is sequential, as the export's
/// is: playing forwards walks the reader on a frame at a time, and coming round to the
/// start again — or scrubbing backwards — starts it afresh. A jump more than a second
/// forwards starts it afresh too, because walking there would decode every frame between.
final class BackgroundMovie {
    private let asset: AVAsset
    private let track: AVAssetTrack
    private let transform: CGAffineTransform
    let duration: Double
    private var reader: ExportFrameReader
    private var last = -Double.infinity

    init?(url: URL) {
        guard let opened = Self.open(url), opened.duration > 0 else { return nil }
        asset = opened.asset
        track = opened.track
        transform = opened.transform
        duration = opened.duration
        reader = ExportFrameReader(asset: opened.asset, track: opened.track, transform: opened.transform)
    }

    /// The moment in the movie a moment of the video shows.
    static func looped(_ seconds: Double, duration: Double) -> Double {
        guard duration > 0, seconds.isFinite else { return 0 }
        let wrapped = seconds.truncatingRemainder(dividingBy: duration)
        return wrapped < 0 ? wrapped + duration : wrapped
    }

    func frame(at seconds: Double) -> CIImage? {
        let moment = Self.looped(seconds, duration: duration)
        if moment > last + 1 {
            reader.cancel()
            reader = ExportFrameReader(asset: asset, track: track, transform: transform)
        }
        last = moment
        return try? reader.frame(at: CMTime(seconds: moment, preferredTimescale: 60_000))
    }

    /// Opens the movie, waiting for it.
    ///
    /// The renderer draws synchronously and cannot `await`, so the loading is done on the
    /// side and waited for — once, the first time the movie is drawn; every frame after
    /// that is read from the open track.
    private static func open(_ url: URL) -> (asset: AVAsset, track: AVAssetTrack, transform: CGAffineTransform, duration: Double)? {
        let asset = AVURLAsset(url: url)
        let result = OpenedMovie()
        let done = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            defer { done.signal() }
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let transform = try? await track.load(.preferredTransform),
                  let range = try? await track.load(.timeRange) else { return }
            result.store(track: track, transform: transform, duration: range.duration.seconds)
        }
        guard done.wait(timeout: .now() + 10) == .success, let opened = result.value else { return nil }
        return (asset, opened.track, opened.transform, opened.duration)
    }
}

/// What opening a movie found, handed from the loading task to the thread waiting for it.
private final class OpenedMovie: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: (track: AVAssetTrack, transform: CGAffineTransform, duration: Double)?

    func store(track: AVAssetTrack, transform: CGAffineTransform, duration: Double) {
        lock.lock()
        stored = (track, transform, duration)
        lock.unlock()
    }

    var value: (track: AVAssetTrack, transform: CGAffineTransform, duration: Double)? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
