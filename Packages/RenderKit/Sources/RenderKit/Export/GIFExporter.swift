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
    /// How long each frame is shown, in seconds.
    ///
    /// A GIF can only say how long a frame lasts in hundredths of a second, and a
    /// thirtieth of a second is not a whole number of them. Written as 0.03 every time,
    /// the whole GIF ran a tenth faster than the video it came from — thirty seconds of
    /// edit played in twenty-seven. So the rounding is spread: each frame ends at the
    /// hundredth nearest to where it should, which at 30 frames a second is 3, 4, 3, 3,
    /// 4, 3 … and exactly a hundred every second.
    static func delays(frames: Int, frameRate: Int) -> [Double] {
        guard frames > 0, frameRate > 0 else { return [] }
        func hundredths(through frame: Int) -> Int {
            Int((Double(frame) * 100 / Double(frameRate)).rounded())
        }
        return (0..<frames).map { index in
            // Never below two hundredths: most players treat anything shorter as "as slow
            // as you like" and show it for a tenth of a second instead.
            Double(max(2, hundredths(through: index + 1) - hundredths(through: index))) / 100
        }
    }

    let timeline: Timeline
    let builder: SceneBuilder
    let cursor: CursorTrack?
    let videoURL: URL
    /// The camera's file, when the take has one and the project draws it. See
    /// `VideoExporter.webcamURL`; a GIF gets the bubble for the same reason it gets the
    /// pointer — it is the same descriptor and the same renderer, so it cannot not.
    var webcamURL: URL?
    /// The project, for the movies brought into it. See `SourceFrames`.
    var packageURL: URL?
    let settings: ExportSettings
    /// The same flag `VideoExporter.cancel()` sets. A GIF used to stop only because the
    /// task around it had been cancelled as well, which made Cancel a coincidence.
    let cancellation: ExportCancellation

    /// A sane ceiling on a format that stores every frame whole. 1,280 across is already
    /// a very large GIF; beyond that it is a video with the wrong extension.
    static let maximumDimension: Double = 1_280

    /// A reader for the camera's file, or `nil` when there is nothing to draw from. The
    /// same three ordinary nothings as `VideoExporter.openWebcamReader()`, swallowed the
    /// same way: a missing camera file is not a reason to refuse to write a GIF.
    private func webcamFrames() async -> ExportFrameReader? {
        guard timeline.webcam.isEnabled, let webcamURL,
              let reader = try? await ExportFrameReader(url: webcamURL) else { return nil }
        _ = await reader.naturalSize()
        return reader
    }

    func export(to destination: URL,
                onProgress: @Sendable @escaping (ExportProgress) -> Void) async throws(ExportError) {
        let reader = try await ExportFrameReader(url: videoURL)
        let webcamReader = await webcamFrames()
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

        let delays = Self.delays(frames: totalFrames, frameRate: frameRate)

        let renderer = SceneRenderer()
        let pictures = SourceFrames(recording: reader, packageURL: packageURL)
        let lentFrames = LentFrames(videoURL: videoURL, webcamURL: webcamReader == nil ? nil : webcamURL,
                                    packageURL: packageURL)
        defer { lentFrames.cancel() }
        // Smoothed once, not per frame, for the reason in `VideoExporter`.
        let cursor = cursor?.smoothed(timeline.cursor.smoothing)
        let started = Date.now
        var lastReport = Date.distantPast

        for index in 0..<totalFrames {
            if cancellation.shouldStop {
                // Nothing half-written left where the user asked for a file. Image I/O
                // only commits on `finalize`, but it has already created the file, and an
                // unfinalised GIF on the desktop is worse than no GIF at all.
                pictures.cancel()
                webcamReader?.cancel()
                try? FileManager.default.removeItem(at: destination)
                throw ExportError.cancelled
            }

            let time = CMTime(value: CMTimeValue(index), timescale: CMTimeScale(frameRate))
            let scene = builder.descriptor(for: timeline, at: time, cursor: cursor)
            let sourceTime = timeline.sourceTime(at: time) ?? time
            let source = try await pictures.frame(for: scene)
            let camera = scene.sourceMedia == nil ? try? webcamReader?.frame(at: sourceTime) : nil
            let lent = try await lentFrames.frames(for: scene)

            var image = renderer.image(for: scene, source: source, webcam: camera,
                                       blending: lent.screen, blendingWebcam: lent.camera)
            // A GIF has one bit of transparency, which would turn the shadow's soft edge
            // into a hard, speckled one. A see-through frame goes onto black here, as it
            // does in every movie format without an alpha channel.
            if scene.background == .transparent {
                image = image.composited(over: CIImage(color: .black))
            }
            if scale != 1 {
                image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            }
            guard let frame = renderer.context.createCGImage(image,
                                                             from: CGRect(origin: .zero, size: outputSize),
                                                             format: .RGBA8,
                                                             colorSpace: renderer.colorSpace) else {
                pictures.cancel()
                webcamReader?.cancel()
                try? FileManager.default.removeItem(at: destination)
                throw ExportError.writerFailed("A frame couldn't be drawn.")
            }
            let frameProperties = [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: delays[index],
                    // The unclamped delay is the one modern viewers honour; the clamped
                    // one above it is what older software reads. Writing both is why a
                    // fast GIF plays at the same speed in a browser and in Finder.
                    kCGImagePropertyGIFUnclampedDelayTime: delays[index],
                ],
            ] as CFDictionary
            CGImageDestinationAddImage(output, frame, frameProperties)

            if Date.now.timeIntervalSince(lastReport) > 0.2 {
                lastReport = .now
                onProgress(ExportProgress(framesWritten: index + 1,
                                          totalFrames: totalFrames,
                                          elapsed: Date.now.timeIntervalSince(started)))
            }
        }

        pictures.cancel()
        webcamReader?.cancel()
        guard CGImageDestinationFinalize(output) else {
            try? FileManager.default.removeItem(at: destination)
            throw ExportError.writerFailed("The GIF couldn't be finished.")
        }
        onProgress(ExportProgress(framesWritten: totalFrames,
                                  totalFrames: totalFrames,
                                  elapsed: Date.now.timeIntervalSince(started)))
    }
}
