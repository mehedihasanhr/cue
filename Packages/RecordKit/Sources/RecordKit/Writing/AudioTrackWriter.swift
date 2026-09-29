import AVFoundation
import CoreMedia
import Foundation
import os

/// One audio source, into one file of its own.
///
/// The recorder used to put every sound it captured into `screen.mov`: the screen's audio
/// on one track, the microphone on another. That was fine while there were exactly two and
/// nobody needed to tell them apart afterwards — but it cannot answer the question the
/// editor now asks, which is *which* of these is the microphone. A file's audio tracks come
/// back from `loadTracks(withMediaType:)` in an order nothing in AVFoundation promises to
/// keep, so identifying a source by its position in that list is a guess that will be right
/// until the day it is not, and the failure is silent: the level you set on the microphone
/// lands on the system audio instead.
///
/// A file per source removes the question. The manifest names a path, the path holds
/// exactly one audio track, and there is nothing to match up. It also makes the feature
/// literal — a source can be muted, re-levelled, transcribed or handed to another app on
/// its own, because on disk it *is* on its own.
///
/// Time zero comes from the recording's shared `RecordingClock`, exactly as the camera's
/// file does, so every file in a package starts at the same instant. See
/// `SessionWriter.Origin` for why that matters and what the alternative sounds like.
///
/// Every method must be called on `queue`; each one asserts it.
public final class AudioTrackWriter: @unchecked Sendable {
    public let queue: DispatchQueue
    public let url: URL

    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let clock: RecordingClock
    private let gapFiller = AudioGapFiller()

    private var firstTime: CMTime?
    private var writtenThrough: CMTime?

    public private(set) var isPaused = false
    public private(set) var audioGaps = 0
    /// Whether a single sample was ever appended.
    ///
    /// The manifest is written from this rather than from the configuration: a microphone
    /// that was asked for, opened, and then delivered nothing — muted in hardware, taken
    /// over by another app — would otherwise be named in the manifest as a source, and the
    /// editor would show an empty lane for a thing that is not there.
    public private(set) var hasSamples = false

    private static let log = Logger(subsystem: "com.stackrover.klik.studio", category: "audio-writer")

    public init(url: URL, clock: RecordingClock, queue: DispatchQueue) throws(RecordingError) {
        self.queue = queue
        self.clock = clock
        self.url = url

        do {
            writer = try AVAssetWriter(url: url, fileType: .m4a)
        } catch {
            throw .writerFailed(error.localizedDescription)
        }
        // The same protection the picture has. See `CrashSafety`.
        writer.movieFragmentInterval = CrashSafety.fragmentInterval

        input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192_000,
        ])
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw .writerFailed("the audio track was refused") }
        writer.add(input)

        guard writer.startWriting() else {
            throw .writerFailed(writer.error?.localizedDescription ?? "the writer wouldn't start")
        }
    }

    // MARK: - Appending

    public func append(_ buffer: CMSampleBuffer) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard buffer.isValid, writer.status == .writing, !isPaused else { return }
        // Before the recording's first frame is warm-up, not take. Dropping it here is the
        // same bargain `SessionWriter.Origin.sharedClock` makes for the camera, and for the
        // same reason: a sample stamped before the session's start time cannot be appended
        // at all, and keeping it would mean this file began earlier than the picture.
        guard let start = clock.startTime else { return }
        guard let time = presentationTime(of: buffer), time >= start else { return }

        if firstTime == nil {
            firstTime = start
            writer.startSession(atSourceTime: start)
            // The silence between the recording's first frame and this source's first
            // sample. A microphone warms up after the screen does, and without this the
            // whole file would sit that much early against the picture.
            if time > start,
               let silence = SilenceBuffer.make(like: buffer, duration: time - start, at: start),
               input.isReadyForMoreMediaData {
                _ = input.append(silence)
                writtenThrough = time
            }
        }

        guard input.isReadyForMoreMediaData else { return }

        if let silence = gapFiller.silence(writtenThrough: writtenThrough, next: time),
           let filler = SilenceBuffer.make(like: buffer, duration: silence, at: writtenThrough ?? time) {
            audioGaps += 1
            _ = input.append(filler)
        }

        let stamped = time == buffer.presentationTimeStamp
            ? buffer
            : (try? CMSampleBuffer(copying: buffer, withNewTiming: [
                CMSampleTimingInfo(duration: buffer.duration, presentationTimeStamp: time, decodeTimeStamp: .invalid),
              ])) ?? buffer

        if input.append(stamped) {
            writtenThrough = time + buffer.duration
            hasSamples = true
        }
    }

    /// A buffer's timestamp with the paused time taken out, or `nil` when it is unusable
    /// — invalid, or stamped inside a hold. The clock's answer, so this file loses exactly
    /// the stretch the picture and the pointer lose.
    private func presentationTime(of buffer: CMSampleBuffer) -> CMTime? {
        let time = buffer.presentationTimeStamp
        guard time.isValid else { return nil }
        return clock.recordingTime(forHost: time)
    }

    // MARK: - Pausing

    public func setPaused(_ paused: Bool) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard paused != isPaused else { return }
        if !paused {
            // Audio resumes at its own new timestamp; without clearing this the gap filler
            // would helpfully insert the whole pause as silence.
            writtenThrough = nil
        }
        isPaused = paused
    }

    // MARK: - Finishing

    /// Closes the file. `false` means nothing was ever written to it, and the caller
    /// should not name it in the manifest.
    @discardableResult
    public func finish() async throws(RecordingError) -> Bool {
        let wrote: Bool = await withCheckedContinuation { continuation in
            queue.async {
                let wrote = self.hasSamples
                self.input.markAsFinished()
                if let last = self.writtenThrough { self.writer.endSession(atSourceTime: last) }
                self.writer.finishWriting { continuation.resume(returning: wrote) }
            }
        }

        if writer.status == .failed {
            throw .writerFailed(writer.error?.localizedDescription ?? "unknown")
        }
        guard wrote else {
            // A file with no samples in it is worse than no file: the manifest would not
            // name it, so nothing would ever delete it.
            try? FileManager.default.removeItem(at: url)
            Self.log.notice("\(self.url.lastPathComponent, privacy: .public) had no audio; removed")
            return false
        }
        Self.log.notice("Wrote \(self.url.lastPathComponent, privacy: .public), \(self.audioGaps) gaps")
        return true
    }

    public func cancel() {
        queue.async {
            self.writer.cancelWriting()
            try? FileManager.default.removeItem(at: self.url)
        }
    }
}
