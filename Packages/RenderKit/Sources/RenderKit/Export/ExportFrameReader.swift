import AVFoundation
import CoreImage
import CoreMedia
import Foundation

/// Frames out of the recording, in order, as fast as they decode.
///
/// `FrameSource` seeks exactly and caches, which is right for an editor being scrubbed
/// and wrong for an export: a minute at 60 fps is 3,600 exact seeks, and an exact seek
/// decodes from the previous keyframe every time. This reads the file straight through
/// instead and keeps whichever frame is current, which is what a sequential pass wants.
///
/// An edit is *mostly* sequential, not always — clips can be reordered, and a speed
/// change makes the source run at a different rate than the timeline. So the rule is:
/// walk forwards when the next time is ahead, and start the reader again when it is
/// behind. Reordered clips cost one restart per cut rather than one per frame.
final class ExportFrameReader {
    private let asset: AVAsset
    private let track: AVAssetTrack

    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    /// The frame currently held, and the moment it starts.
    private var current: CIImage?
    private var currentTime: CMTime = .negativeInfinity
    /// When the next frame begins, so we know whether `current` still stands.
    private var nextTime: CMTime = .negativeInfinity
    private var isFinished = false
    /// The track's rotation, applied to every frame so the export is the same way up as
    /// the preview — which gets it free from `AVAssetImageGenerator`.
    private var transform: CGAffineTransform = .identity

    /// How far back a request may reach before the reader is restarted rather than
    /// walked forwards. One frame of slack absorbs the rounding between a timeline time
    /// and a source time; anything more is a real jump.
    private static let rewindTolerance = CMTime(value: 1, timescale: 30)

    init(url: URL) async throws(ExportError) {
        let asset = AVURLAsset(url: url)
        self.asset = asset
        do {
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                throw ExportError.noVideoTrack
            }
            self.track = track
        } catch let error as ExportError {
            throw error
        } catch {
            throw ExportError.unreadableSource(error.localizedDescription)
        }
    }

    /// The recording's size in pixels, rotation applied.
    ///
    /// Also where the rotation itself is picked up, since both come from the same two
    /// loads and the exporter asks for the size before it asks for a frame.
    func naturalSize() async -> CGSize {
        guard let size = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform) else { return .zero }
        self.transform = transform
        return CGRect(origin: .zero, size: size).applying(transform).standardized.size
    }

    /// The frame covering a source time.
    ///
    /// `nil` only when the file has run out, which the exporter treats as "hold the last
    /// picture" rather than as a failure: a recording whose final frame's timestamp is a
    /// few milliseconds short of its stated duration is ordinary, and refusing to export
    /// it over that would be absurd.
    func frame(at time: CMTime) throws(ExportError) -> CIImage? {
        if reader == nil || time < currentTime - Self.rewindTolerance {
            try start(at: time)
        }
        // Walk forwards until the held frame is the one covering `time`.
        while !isFinished, time >= nextTime {
            guard try advance() else { break }
        }
        return current
    }

    private func start(at time: CMTime) throws(ExportError) {
        reader?.cancelReading()
        current = nil
        currentTime = .negativeInfinity
        nextTime = .negativeInfinity
        isFinished = false

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw ExportError.unreadableSource(error.localizedDescription)
        }
        // From the start of the request to the end. The decoder still has to begin at
        // the keyframe before `time`, but it does that once here rather than per frame.
        reader.timeRange = CMTimeRange(start: max(.zero, time), end: .positiveInfinity)

        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw ExportError.unreadableSource("The recording's video track could not be read.") }
        reader.add(output)
        guard reader.startReading() else {
            throw ExportError.unreadableSource(reader.error?.localizedDescription ?? "The recording could not be read.")
        }

        self.reader = reader
        self.output = output
        // Prime the first frame, so a request landing before any sample still has a
        // picture to give back.
        _ = try advance()
    }

    /// Takes the next sample. `false` once the file has run out.
    @discardableResult
    private func advance() throws(ExportError) -> Bool {
        guard let reader, let output else { return false }
        guard let sample = output.copyNextSampleBuffer() else {
            if reader.status == .failed {
                throw ExportError.unreadableSource(reader.error?.localizedDescription ?? "The recording stopped decoding.")
            }
            isFinished = true
            return false
        }
        guard let buffer = CMSampleBufferGetImageBuffer(sample) else { return true }

        let start = CMSampleBufferGetPresentationTimeStamp(sample)
        let duration = CMSampleBufferGetDuration(sample)
        current = rotated(CIImage(cvPixelBuffer: buffer))
        currentTime = start
        nextTime = duration.isNumeric ? start + duration : start
        return true
    }

    /// Puts a frame the way up the preview shows it.
    ///
    /// `AVAssetReaderTrackOutput` hands back the stored picture, transform and all —
    /// unlike `AVAssetImageGenerator`, which the preview uses with
    /// `appliesPreferredTrackTransform`. Without this, a rotated recording would export
    /// on its side, and only on export.
    private func rotated(_ image: CIImage) -> CIImage {
        guard !transform.isIdentity else { return image }
        let turned = image.transformed(by: transform)
        // A rotation moves the picture off the origin; Core Image's origin is where the
        // renderer expects the bottom-left of the frame to be.
        return turned.transformed(by: CGAffineTransform(translationX: -turned.extent.origin.x,
                                                        y: -turned.extent.origin.y))
    }

    func cancel() {
        reader?.cancelReading()
        reader = nil
        output = nil
        current = nil
    }
}
