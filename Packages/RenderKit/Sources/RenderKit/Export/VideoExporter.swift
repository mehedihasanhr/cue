import AVFoundation
import CoreImage
import CoreMedia
import Foundation
import os
import TimelineKit

/// Turns an edit into a video file.
///
/// The payoff of the whole design: this walks the timeline a frame at a time, asks
/// `SceneBuilder` for a descriptor and `SceneRenderer` for pixels — the same two the
/// preview uses, with no second code path — and hands the result to an encoder. "Does
/// the export match the preview?" is not a question anyone has to keep answering,
/// because there is only one renderer and one description of a frame.
///
/// An `actor` because it owns an `AVAssetWriter` and a decoder, neither of which is
/// `Sendable` and both of which must be touched in one order from one place.
public actor VideoExporter {
    private let timeline: Timeline
    private let builder: SceneBuilder
    private let cursor: CursorTrack?
    private let videoURL: URL
    /// The camera's own file inside the package, when the take recorded one.
    ///
    /// A second file rather than a second track in the first: everything that reads a
    /// recording asks for its first video track, and slipping another one in beside the
    /// screen would make "the recording" mean whichever AVFoundation happened to list
    /// first. Optional and defaulted, so a project with no webcam — which is every project
    /// made before this — exports down exactly the path it always did.
    private let webcamURL: URL?
    private let packageURL: URL?
    private let settings: ExportSettings

    /// Shared with the GIF path and readable without `await`, so one `cancel()` stops
    /// whichever loop is running. See `ExportCancellation`.
    private let cancellation = ExportCancellation()

    private static let log = Logger(subsystem: "com.stackrover.klik.studio", category: "export")

    public init(timeline: Timeline,
                builder: SceneBuilder,
                cursor: CursorTrack?,
                videoURL: URL,
                webcamURL: URL? = nil,
                packageURL: URL?,
                settings: ExportSettings) {
        self.timeline = timeline
        self.builder = builder
        self.cursor = cursor
        self.videoURL = videoURL
        self.webcamURL = webcamURL
        self.packageURL = packageURL
        self.settings = settings
    }

    /// Stops at the next frame boundary and leaves nothing behind.
    nonisolated public func cancel() { cancellation.cancel() }

    /// Writes the file, reporting progress as it goes.
    ///
    /// `onProgress` is called from this actor at most a few times a second, not per
    /// frame: a UI update per frame at 60 fps is its own reason for an export to be slow.
    public func export(to destination: URL,
                       onProgress: @Sendable @escaping (ExportProgress) -> Void = { _ in }) async throws(ExportError) {
        guard timeline.duration.seconds > 0 else { throw ExportError.emptyTimeline }
        // Not reset here: one exporter writes one file, and a job cancelled while it was
        // still queued must stay cancelled when its turn comes round.

        if settings.format == .gif {
            try await GIFExporter(timeline: timeline,
                                  builder: builder,
                                  cursor: cursor,
                                  videoURL: videoURL,
                                  webcamURL: webcamURL,
                                  settings: settings,
                                  cancellation: cancellation).export(to: destination, onProgress: onProgress)
            return
        }
        try await writeMovie(to: destination, onProgress: onProgress)
    }

    // MARK: - The movie

    private func writeMovie(to destination: URL,
                            onProgress: @Sendable @escaping (ExportProgress) -> Void) async throws(ExportError) {
        let reader = try await ExportFrameReader(url: videoURL)
        // The same sequential reader, pointed at the camera. Built only when the timeline
        // actually draws a bubble: opening a decoder for a file nobody is going to ask a
        // frame of is a second decode queue for nothing, and a webcam file that has gone
        // missing must not fail an export of the screen it was recorded beside — hence
        // `try?` rather than `try`.
        let webcamReader = await openWebcamReader()
        // The source's real size, not the manifest's idea of it: a builder measured
        // against the wrong size puts the picture in the wrong place, and only in the
        // exported file.
        let sourceSize = await reader.naturalSize()
        let builder = sourceSize == .zero ? self.builder : self.builder.resized(to: sourceSize)

        let projectSize = builder.outputSize(for: timeline.style)
        let outputSize = settings.outputSize(fitting: projectSize)
        let scale = settings.scale(from: projectSize, to: outputSize)
        let frameRate = settings.effectiveFrameRate
        let totalFrames = max(1, Int((timeline.duration.seconds * Double(frameRate)).rounded()))

        // A file already there is replaced, but only once we are sure we can write:
        // deleting someone's last export and then failing is the worst of both.
        try prepare(destination)

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(url: destination, fileType: settings.format.fileType ?? .mp4)
        } catch {
            throw ExportError.destinationNotWritable(error.localizedDescription)
        }

        let video = videoInput(size: outputSize, frameRate: frameRate)
        guard writer.canAdd(video) else { throw ExportError.writerFailed("The encoder refused those settings.") }
        writer.add(video)

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: video,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(outputSize.width),
                kCVPixelBufferHeightKey as String: Int(outputSize.height),
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
        )

        // The sound is built before writing starts, so a project whose audio cannot be
        // assembled fails before it has written half a file.
        var audio: AVAssetWriterInput?
        var audioReader: AVAssetReader?
        var audioOutput: AVAssetReaderOutput?
        if settings.writesAudio {
            let mixdown = await AudioMixdown.build(timeline: timeline, videoURL: videoURL, packageURL: packageURL)
            if !mixdown.isEmpty,
               let (input, source, output) = try audioPath(for: mixdown) {
                guard writer.canAdd(input) else { throw ExportError.writerFailed("The encoder refused the audio.") }
                writer.add(input)
                audio = input
                audioReader = source
                audioOutput = output
            }
        }

        guard writer.startWriting() else {
            throw ExportError.writerFailed(writer.error?.localizedDescription ?? "The writer wouldn't start.")
        }
        writer.startSession(atSourceTime: .zero)
        audioReader?.startReading()

        let renderer = SceneRenderer()
        // Smoothed once, not per frame: the filter runs over every sample in the
        // recording, and an export asks for thousands of frames.
        let cursor = cursor?.smoothed(timeline.cursor.smoothing)
        let started = Date.now
        var framesWritten = 0
        var lastReport = Date.distantPast

        do {
            for index in 0..<totalFrames {
                if cancellation.shouldStop { throw ExportError.cancelled }

                let time = CMTime(value: CMTimeValue(index), timescale: CMTimeScale(frameRate))
                let scene = builder.descriptor(for: timeline, at: time, cursor: cursor)
                let sourceTime = timeline.sourceTime(at: time) ?? time
                let source = try reader.frame(at: sourceTime)
                // The same source time, because the two files share a zero: the camera's
                // writer starts its session at the moment the screen's first frame arrived
                // rather than at its own, so "three seconds into the recording" means the
                // same instant in both. A cut or a speed change therefore moves the face
                // and the screen together, with no second mapping to keep in step.
                let camera = try? webcamReader?.frame(at: sourceTime)

                try await append(scene: scene,
                                 source: source,
                                 webcam: camera,
                                 at: time,
                                 scale: scale,
                                 outputSize: outputSize,
                                 renderer: renderer,
                                 adaptor: adaptor,
                                 input: video)
                framesWritten += 1

                // Audio is drained alongside the picture rather than after it, so the
                // writer never holds a whole track's worth of samples in memory.
                if let audio, let audioOutput { drainAudio(into: audio, from: audioOutput) }

                if Date.now.timeIntervalSince(lastReport) > 0.2 {
                    lastReport = .now
                    onProgress(ExportProgress(framesWritten: framesWritten,
                                              totalFrames: totalFrames,
                                              elapsed: Date.now.timeIntervalSince(started)))
                }
            }

            // Whatever sound is left once the pictures have run out.
            if let audio, let audioOutput {
                while audio.isReadyForMoreMediaData, drainAudio(into: audio, from: audioOutput) {}
                audio.markAsFinished()
            }
            video.markAsFinished()
            await writer.finishWriting()

            if writer.status == .failed {
                throw ExportError.writerFailed(writer.error?.localizedDescription ?? "Unknown encoder failure.")
            }
        } catch {
            writer.cancelWriting()
            reader.cancel()
            webcamReader?.cancel()
            audioReader?.cancelReading()
            try? FileManager.default.removeItem(at: destination)
            throw error as? ExportError ?? ExportError.writerFailed(error.localizedDescription)
        }

        reader.cancel()
        webcamReader?.cancel()
        onProgress(ExportProgress(framesWritten: totalFrames,
                                  totalFrames: totalFrames,
                                  elapsed: Date.now.timeIntervalSince(started)))
        Self.log.notice("Exported \(totalFrames) frames to \(destination.lastPathComponent, privacy: .public)")
    }

    /// Renders one frame and hands it to the encoder.
    ///
    /// The wait is what keeps memory flat: without it the loop renders as fast as the
    /// GPU can go and queues every frame the encoder has not got to yet.
    private func append(scene: SceneDescriptor,
                        source: CIImage?,
                        webcam: CIImage?,
                        at time: CMTime,
                        scale: Double,
                        outputSize: CGSize,
                        renderer: SceneRenderer,
                        adaptor: AVAssetWriterInputPixelBufferAdaptor,
                        input: AVAssetWriterInput) async throws(ExportError) {
        while !input.isReadyForMoreMediaData {
            if cancellation.shouldStop { throw ExportError.cancelled }
            try? await Task.sleep(for: .milliseconds(5))
        }
        guard let pool = adaptor.pixelBufferPool else {
            throw ExportError.writerFailed("The encoder gave us nowhere to draw.")
        }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
              let buffer else {
            throw ExportError.writerFailed("Ran out of buffers to draw into.")
        }

        var image = renderer.image(for: scene, source: source, webcam: webcam)
        if scale != 1 {
            // Scaled here rather than by building a smaller scene: the descriptor's
            // geometry is in project pixels, and re-deriving it at export size would be
            // a second layout that could disagree with the preview's.
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        renderer.context.render(image,
                                to: buffer,
                                bounds: CGRect(origin: .zero, size: outputSize),
                                colorSpace: renderer.colorSpace)

        guard adaptor.append(buffer, withPresentationTime: time) else {
            throw ExportError.writerFailed("The encoder refused a frame.")
        }
    }

    /// Moves what audio the encoder will take right now. `false` when there is no more.
    @discardableResult
    private func drainAudio(into input: AVAssetWriterInput, from output: AVAssetReaderOutput) -> Bool {
        while input.isReadyForMoreMediaData {
            guard let sample = output.copyNextSampleBuffer() else { return false }
            guard input.append(sample) else { return false }
        }
        return true
    }

    // MARK: - Setting up

    /// A reader for the camera's file, or `nil` when this export has no use for one.
    ///
    /// Three ways of having no use for one, all of them ordinary: the project has no bubble
    /// turned on, the recording never had a camera, or the file it named has been deleted
    /// out of the package. None of those is a reason to refuse to export the screen, so a
    /// failure here is swallowed and the frames simply come back without a bubble — which
    /// is what the builder already describes when it has nothing to draw one from.
    private func openWebcamReader() async -> ExportFrameReader? {
        guard timeline.webcam.isEnabled, let webcamURL else { return nil }
        guard let reader = try? await ExportFrameReader(url: webcamURL) else { return nil }
        // Asked before the first frame, because this is also where the reader picks up the
        // track's rotation — a camera recorded sideways would otherwise export sideways.
        _ = await reader.naturalSize()
        return reader
    }

    private func prepare(_ destination: URL) throws(ExportError) {
        let folder = destination.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: folder.path(percentEncoded: false)) else {
            throw ExportError.destinationNotWritable("\(folder.lastPathComponent) can't be written to.")
        }
        if FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) {
            do {
                try FileManager.default.removeItem(at: destination)
            } catch {
                throw ExportError.destinationNotWritable(error.localizedDescription)
            }
        }
    }

    private func videoInput(size: CGSize, frameRate: Int) -> AVAssetWriterInput {
        let pixels = Int(size.width * size.height)
        let compression: [String: Any] = [
            AVVideoAverageBitRateKey: settings.quality.bitrate(forPixels: pixels, frameRate: frameRate),
            // A keyframe every two seconds: scrubbing the finished file stays responsive
            // without the size penalty of an all-intra stream.
            AVVideoMaxKeyFrameIntervalDurationKey: 2,
            AVVideoExpectedSourceFrameRateKey: frameRate,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: settings.codec.resolved(for: settings.format),
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: compression,
        ])
        input.expectsMediaDataInRealTime = false
        return input
    }

    /// The encoder input and the reader that feeds it.
    private func audioPath(for mixdown: AudioMixdown.Result) throws(ExportError)
        -> (AVAssetWriterInput, AVAssetReader, AVAssetReaderOutput)? {
        let tracks = mixdown.composition.tracks(withMediaType: .audio)
        guard !tracks.isEmpty else { return nil }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: mixdown.composition)
        } catch {
            throw ExportError.unreadableSource(error.localizedDescription)
        }
        // One mix output over every track, so several sources come out already summed
        // rather than needing a second pass to combine them.
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        output.audioMix = mixdown.audioMix
        guard reader.canAdd(output) else { return nil }
        reader.add(output)

        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192_000,
        ])
        input.expectsMediaDataInRealTime = false
        return (input, reader, output)
    }
}
