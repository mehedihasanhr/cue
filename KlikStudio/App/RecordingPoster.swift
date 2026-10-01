import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import os
import RecordKit
import UniformTypeIdentifiers

/// The one frame that says which take this is.
///
/// Thirty rows of "Recording 2026-09-24 at 11.06.07" are thirty rows of the same row. A
/// picture is the only thing in the list that distinguishes a take at a glance, which is
/// why this exists at all.
///
/// Cached inside the package, in `derived/`, following the waveform's precedent exactly:
/// that folder is documented as regenerable, is not part of whether the document is
/// dirty, and is safe to delete. So the expensive half happens once per recording ever,
/// and every later listing is a 12 kB file read.
///
/// `nonisolated`, because decoding a frame is the one thing in this window that is not
/// instant and the app is main-actor by default. Nothing here touches the resulting
/// `CGImage` from another isolation domain — it becomes JPEG bytes inside the same
/// function that decoded it, and only the file it was written to leaves.
nonisolated struct RecordingPoster: Sendable {
    /// How big the cached picture is. The library's cards draw it up to 300 points wide,
    /// and the cache is sized for a Retina card rather than for the recording: a 4K poster
    /// frame would cost more to read back than to decode again.
    private static let maximumSize = CGSize(width: 640, height: 640)
    /// Named for its size, so the smaller pictures cached for the old rows are not read
    /// back into cards twice their size.
    private static let cacheName = "poster-640.jpg"

    private static let log = Logger(subsystem: "com.stackrover.klik.studio", category: "library")

    /// The poster for a recording, read from the cache or made now.
    ///
    /// Returns bytes rather than an `NSImage` on purpose: this runs off the main actor, an
    /// `NSImage` is not `Sendable`, and `Data` crossing back to the window is a copy the
    /// compiler can prove is safe.
    static func jpeg(for packageURL: URL) async -> Data? {
        let package = RecordingPackage(url: packageURL)
        let cache = package.derivedFolder.appendingPathComponent(cacheName)
        if let cached = try? Data(contentsOf: cache), !cached.isEmpty { return cached }

        guard let manifest = try? package.readManifest(),
              let screen = manifest.track(.screen) else { return nil }
        let video = packageURL.appendingPathComponent(screen.path)
        guard FileManager.default.fileExists(atPath: video.path(percentEncoded: false)) else { return nil }

        guard let data = await render(video, duration: manifest.duration) else { return nil }
        // Written best-effort: a library on a read-only volume still gets its pictures,
        // it just pays for them every time. A poster is not worth an error anybody sees.
        do {
            try FileManager.default.createDirectory(at: package.derivedFolder, withIntermediateDirectories: true)
            try data.write(to: cache, options: .atomic)
        } catch {
            log.debug("Couldn't cache a poster frame: \(error.localizedDescription, privacy: .public)")
        }
        return data
    }

    private static func render(_ video: URL, duration: Double) async -> Data? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = maximumSize
        // Loose tolerance, deliberately: any frame near this moment answers "which take is
        // this?", and an exact seek would decode a whole group of pictures to answer it.
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)

        // A second in, or a third of the way through a take shorter than that. The first
        // frame of a screen recording is very often the countdown still on screen, or the
        // moment before the thing being demonstrated starts — a black rectangle tells
        // nobody which recording this is.
        let moment = duration > 3 ? 1.0 : max(0, duration / 3)
        do {
            let (image, _) = try await generator.image(at: CMTime(seconds: moment, preferredTimescale: 600))
            return encode(image)
        } catch {
            log.debug("No poster frame for \(video.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// ImageIO rather than `NSBitmapImageRep`, so nothing here needs AppKit and the whole
    /// path stays off the main actor.
    private static func encode(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.72] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
