import AVFoundation
import CoreImage
import CoreMedia
import Foundation
import ImageIO
import UniformTypeIdentifiers
import TimelineKit

/// Writes the edit as an animated GIF.
///
/// Image I/O rather than an encoder: a GIF is a stack of still frames with a delay on
/// each, and `CGImageDestination` writes exactly that with no third-party dependency —
/// which is the rule this whole add-on is built under. Frames are added one at a time
/// and written straight out, so a long GIF costs no more memory than a short one.
///
/// Same builder, same renderer, same descriptor as the movie path. The only differences
/// are the container and the frame rate.
struct GIFExporter {
    let timeline: Timeline
    let builder: SceneBuilder
    let cursor: CursorTrack?
    let videoURL: URL
    let settings: ExportSettings
    /// The same flag `VideoExporter.cancel()` sets. A GIF used to stop only because the
    /// task around it had been cancelled as well, which made Cancel a coincidence.
    let cancellation: ExportCancellation

    /// A sane ceiling on a format that stores every frame whole. 1,280 across is already
    /// a very large GIF; beyond that it is a video with the wrong extension.
    static let maximumDimension: Double = 1_280

    func export(to destination: URL,
                onProgress: @Sendable @escaping (ExportProgress) -> Void) async throws(ExportError) {
        let reader = try await ExportFrameReader(url: videoURL)
        let sourceSize = await reader.naturalSize()
        let builder = sourceSize == .zero ? self.builder : self.builder.resized(to: sourceSize)

        let projectSize = builder.outputSize(for: timeline.style)
        // The user's cap, then the format's own: a GIF nobody can send is not an export.
        var sized = settings
        sized.maximumDimension = min(settings.maximumDimension ?? .greatestFiniteMagnitude, Self.maximumDimension)
        let outputSize = sized.outputSize(fitting: projectSize)
        let scale = sized.scale(from: projectSize, to: outputSize)

        let frameRate = settings.effectiveFrameRate
        let totalFrames = max(1, Int((timeline.duration.seconds * Double(frameRate)).rounded()))

        if FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) {
            try? FileManager.default.removeItem(at: destination)
        }
        guard let output = CGImageDestinationCreateWithURL(destination as CFURL,
                                                           UTType.gif.identifier as CFString,
                                                           totalFrames,
                                                           nil) else {
            throw ExportError.destinationNotWritable("A GIF couldn't be created there.")
        }

        // 0 means forever, which is what a GIF is expected to do. A GIF that stops is
        // asked for by saying so.
        let loopCount = settings.loops ? 0 : 1
        CGImageDestinationSetProperties(output, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: loopCount],
        ] as CFDictionary)

        let frameProperties = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: 1.0 / Double(frameRate),
                // The unclamped delay is the one modern viewers honour; the clamped one
                // above it is what older software reads. Writing both is why a fast GIF
                // plays at the same speed in a browser and in Finder.
                kCGImagePropertyGIFUnclampedDelayTime: 1.0 / Double(frameRate),
            ],
        ] as CFDictionary

        let renderer = SceneRenderer()
        // Smoothed once, not per frame, for the reason in `VideoExporter`.
        let cursor = cursor?.smoothed(timeline.cursor.smoothing)
        let started = Date.now
        var lastReport = Date.distantPast

        for index in 0..<totalFrames {
            if cancellation.shouldStop {
                // Nothing half-written left where the user asked for a file. Image I/O
                // only commits on `finalize`, but it has already created the file, and an
                // unfinalised GIF on the desktop is worse than no GIF at all.
                reader.cancel()
                try? FileManager.default.removeItem(at: destination)
                throw ExportError.cancelled
            }

            let time = CMTime(value: CMTimeValue(index), timescale: CMTimeScale(frameRate))
            let scene = builder.descriptor(for: timeline, at: time, cursor: cursor)
            let source = try reader.frame(at: timeline.sourceTime(at: time) ?? time)

            var image = renderer.image(for: scene, source: source)
            if scale != 1 {
                image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            }
            guard let frame = renderer.context.createCGImage(image,
                                                             from: CGRect(origin: .zero, size: outputSize),
                                                             format: .RGBA8,
                                                             colorSpace: renderer.colorSpace) else {
                reader.cancel()
                try? FileManager.default.removeItem(at: destination)
                throw ExportError.writerFailed("A frame couldn't be drawn.")
            }
            CGImageDestinationAddImage(output, frame, frameProperties)

            if Date.now.timeIntervalSince(lastReport) > 0.2 {
                lastReport = .now
                onProgress(ExportProgress(framesWritten: index + 1,
                                          totalFrames: totalFrames,
                                          elapsed: Date.now.timeIntervalSince(started)))
            }
        }

        reader.cancel()
        guard CGImageDestinationFinalize(output) else {
            try? FileManager.default.removeItem(at: destination)
            throw ExportError.writerFailed("The GIF couldn't be finished.")
        }
        onProgress(ExportProgress(framesWritten: totalFrames,
                                  totalFrames: totalFrames,
                                  elapsed: Date.now.timeIntervalSince(started)))
    }
}
