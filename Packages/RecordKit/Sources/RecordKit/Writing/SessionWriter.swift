import AVFoundation
import CoreMedia
import Foundation
import os

/// Writes one recording's tracks to disk.
///
/// A `final class` guarded by a queue rather than an actor, deliberately: sample buffers
/// arrive from ScreenCaptureKit and AVFoundation on a queue we choose, and handing them
/// to an actor would mean sending non-`Sendable` buffers across an isolation boundary on
/// every frame. Giving both producers *this* writer's queue means frames go straight from
/// the system into the encoder, with synchronous methods as the transaction boundary.
///
/// Every method must be called on `queue`; each one asserts it.
public final class SessionWriter: @unchecked Sendable {
    /// Where this file's time zero comes from.
    ///
    /// A recording is one moment in time written into more than one file — the screen into
    /// `screen.mov`, the camera into `webcam.mov` — and the two have to agree about when it
    /// began, or a cut three seconds into the edit shows the screen at 3.0s and the face at
    /// 3.2s. They cannot agree by each using its own first frame: the camera's capture
    /// session warms up on its own schedule, so its first frame lands hundreds of
    /// milliseconds away from the screen's.
    ///
    /// So the screen's writer defines the moment and the camera's writer adopts it. There
    /// is already a shared `RecordingClock` for precisely this — every cursor sample is
    /// stamped against it — and `.first` is what starts it. Nothing about the single-file
    /// case changes: `.first` is the default and is what the screen has always done.
    public enum Origin: Sendable {
        /// The first frame written here is time zero, and writing it starts the
        /// recording's clock for everybody else.
        case first
        /// Time zero is wherever the recording's clock was already started, by whoever
        /// holds `.first`. Frames that arrive before that moment are dropped — they belong
        /// to the warm-up, not to the take.
        case sharedClock
    }

    public let queue: DispatchQueue
    public let videoURL: URL

    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let systemAudio: AVAssetWriterInput?
    private let microphone: AVAssetWriterInput?

    private let pacer: FramePacer
    private let gapFiller = AudioGapFiller()
    private let clock: RecordingClock
    private let origin: Origin

    private var lastVideoTime: CMTime?
    private var lastVideoBuffer: CMSampleBuffer?
    private var systemAudioThrough: CMTime?
    private var microphoneThrough: CMTime?
    private var firstTime: CMTime?

    /// What went oddly, for the log and for a bug report. Counted rather than logged per
    /// frame: a log line per dropped frame is its own performance problem.
    public private(set) var repeatedFrames = 0
    public private(set) var droppedFrames = 0
    public private(set) var audioGaps = 0

    private static let log = Logger(subsystem: "com.stackrover.klik.studio", category: "writer")

    public init(url: URL,
                pixelSize: CGSize,
                codec: AVVideoCodecType,
                bitrate: Int,
                frameRate: Int,
                systemAudio hasSystemAudio: Bool,
                microphone hasMicrophone: Bool,
                clock: RecordingClock,
                origin: Origin = .first,
                queue: DispatchQueue) throws(RecordingError) {
        self.queue = queue
        self.clock = clock
        self.origin = origin
        videoURL = url
        pacer = FramePacer(frameRate: frameRate)

        do {
            writer = try AVAssetWriter(url: url, fileType: .mov)
        } catch {
            throw .writerFailed(error.localizedDescription)
        }

        var compression: [String: any Sendable] = [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoExpectedSourceFrameRateKey: frameRate,
            // One keyframe every two seconds: scrubbing in the editor seeks to the
            // nearest one, and a screen recording with a keyframe every ten seconds
            // scrubs like treacle.
            AVVideoMaxKeyFrameIntervalDurationKey: 2,
        ]
        if codec == .hevc {
            compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main_AutoLevel as String
        } else {
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }

        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: Int(pixelSize.width),
            AVVideoHeightKey: Int(pixelSize.height),
            AVVideoCompressionPropertiesKey: compression,
        ])
        // The encoder is fed from a real-time source, so it must never block it.
        video.expectsMediaDataInRealTime = true
        guard writer.canAdd(video) else { throw .writerFailed("the video track was refused") }
        writer.add(video)

        func audioInput() -> AVAssetWriterInput {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000,
            ])
            input.expectsMediaDataInRealTime = true
            return input
        }

        // Two separate tracks, not one mix: the editor has to be able to mute the
        // microphone without losing the system audio, and a mixdown is a decision the
        // recorder has no business making.
        if hasSystemAudio {
            let input = audioInput()
            systemAudio = writer.canAdd(input) ? input : nil
            if let systemAudio { writer.add(systemAudio) }
        } else {
            systemAudio = nil
        }
        if hasMicrophone {
            let input = audioInput()
            microphone = writer.canAdd(input) ? input : nil
            if let microphone { writer.add(microphone) }
        } else {
            microphone = nil
        }

        guard writer.startWriting() else {
            throw .writerFailed(writer.error?.localizedDescription ?? "the writer wouldn't start")
        }
    }

    // MARK: - Appending

    /// A frame from ScreenCaptureKit.
    ///
    /// The first one starts the session and the clock: everything before it — the
    /// countdown, the permission prompt, the stream warming up — is not the recording.
    public func append(video buffer: CMSampleBuffer) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard buffer.isValid, writer.status == .writing, !isPaused else {
            if writer.status == .failed { recordFailure() }
            return
        }
        guard let time = presentationTime(of: buffer) else { return }

        if firstTime == nil {
            switch origin {
            case .first:
                firstTime = time
                writer.startSession(atSourceTime: time)
                clock.start()
            case .sharedClock:
                // Dropped rather than kept: a frame from before the recording's first
                // moment — the clock not started yet, or this camera frame stamped earlier
                // than the screen's first — belongs to the warm-up, and appending it would
                // be a sample before the session's own start time. Waiting means the
                // camera's file begins at the first frame that is genuinely inside the
                // take, which is the only reading under which the two files line up.
                guard let start = clock.startTime, time >= start else { return }
                firstTime = start
                writer.startSession(atSourceTime: start)
            }
        }

        // The screen only produces frames when it changes, so a still screen leaves a
        // hole. Repeat the last frame at the times the encoder expected one.
        for fill in pacer.fillTimes(lastFrame: lastVideoTime, next: time) {
            appendRepeat(at: fill)
        }

        guard video.isReadyForMoreMediaData else {
            droppedFrames += 1
            return
        }
        // Re-stamped rather than appended as it arrived, because a pause takes real time
        // out of the middle of the recording: the buffer's own timestamp still carries it.
        let stamped = pausedTotal == .zero
            ? buffer
            : (try? CMSampleBuffer(copying: buffer, withNewTiming: [
                CMSampleTimingInfo(duration: buffer.duration, presentationTimeStamp: time, decodeTimeStamp: .invalid),
              ])) ?? buffer

        if video.append(stamped) {
            lastVideoTime = time
            lastVideoBuffer = stamped
        } else {
            droppedFrames += 1
            recordFailure()
        }
    }

    // MARK: - Pausing

    /// Whether the recording is on hold.
    public private(set) var isPaused = false
    /// How much of the wall clock has been spent paused, subtracted from every timestamp
    /// after it so the file has no frozen stretch in the middle.
    private var pausedTotal: CMTime = .zero
    private var pausedAt: CMTime?

    public func setPaused(_ paused: Bool) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard paused != isPaused else { return }
        if paused {
            pausedAt = RecordingClock.now
        } else if let pausedAt {
            pausedTotal = pausedTotal + (RecordingClock.now - pausedAt)
            self.pausedAt = nil
            // Audio resumes at its own new timestamp; without clearing these, the gap
            // filler would helpfully insert the whole pause as silence.
            systemAudioThrough = nil
            microphoneThrough = nil
        }
        isPaused = paused
    }

    /// A buffer's timestamp with the paused time taken out, or `nil` when it is unusable.
    private func presentationTime(of buffer: CMSampleBuffer) -> CMTime? {
        let time = buffer.presentationTimeStamp
        guard time.isValid else { return nil }
        return pausedTotal == .zero ? time : time - pausedTotal
    }

    public func append(systemAudio buffer: CMSampleBuffer) {
        append(buffer, to: systemAudio, through: &systemAudioThrough)
    }

    public func append(microphone buffer: CMSampleBuffer) {
        append(buffer, to: microphone, through: &microphoneThrough)
    }

    private func append(_ buffer: CMSampleBuffer, to input: AVAssetWriterInput?, through: inout CMTime?) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let input, buffer.isValid, writer.status == .writing, !isPaused else { return }
        // Audio that arrives before the first frame belongs to the silence before the
        // recording, not to it.
        guard firstTime != nil, input.isReadyForMoreMediaData,
              let start = presentationTime(of: buffer) else { return }

        if let silence = gapFiller.silence(writtenThrough: through, next: start),
           let filler = SilenceBuffer.make(like: buffer, duration: silence, at: through ?? start) {
            audioGaps += 1
            _ = input.append(filler)
        }

        let stamped = pausedTotal == .zero
            ? buffer
            : (try? CMSampleBuffer(copying: buffer, withNewTiming: [
                CMSampleTimingInfo(duration: buffer.duration, presentationTimeStamp: start, decodeTimeStamp: .invalid),
              ])) ?? buffer

        if input.append(stamped) {
            through = start + buffer.duration
        }
    }

    private func appendRepeat(at time: CMTime) {
        guard let source = lastVideoBuffer, video.isReadyForMoreMediaData,
              let copy = try? CMSampleBuffer(copying: source, withNewTiming: [
                  CMSampleTimingInfo(duration: pacer.frameDuration, presentationTimeStamp: time, decodeTimeStamp: .invalid),
              ])
        else { return }
        if video.append(copy) {
            repeatedFrames += 1
            lastVideoTime = time
        }
    }

    // MARK: - Finishing

    /// Closes the file and returns how long the recording is.
    ///
    /// The tail is padded the same way a mid-recording gap is: stopping on a still screen
    /// would otherwise produce a file that ends at the last thing that moved, which is
    /// short of what the user watched — and shorter than the audio.
    public func finish() async throws(RecordingError) -> CMTime {
        let duration: CMTime = await withCheckedContinuation { continuation in
            queue.async {
                let end = RecordingClock.now - self.pausedTotal
                for fill in self.pacer.tailTimes(lastFrame: self.lastVideoTime, end: end) {
                    self.appendRepeat(at: fill)
                }
                self.video.markAsFinished()
                self.systemAudio?.markAsFinished()
                self.microphone?.markAsFinished()

                let start = self.firstTime ?? .zero
                let last = self.lastVideoTime ?? start
                let length = last - start
                if let endTime = self.lastVideoTime { self.writer.endSession(atSourceTime: endTime) }
                self.writer.finishWriting {
                    continuation.resume(returning: length)
                }
            }
        }

        if writer.status == .failed {
            throw .writerFailed(writer.error?.localizedDescription ?? "unknown")
        }
        Self.log.notice("Wrote \(self.videoURL.lastPathComponent, privacy: .public): \(duration.seconds, format: .fixed(precision: 1))s, \(self.repeatedFrames) repeated, \(self.droppedFrames) dropped, \(self.audioGaps) audio gaps")
        return duration
    }

    /// Stops and throws away what has been written. For a cancelled countdown or a
    /// recording the user abandoned.
    public func cancel() {
        queue.async {
            self.writer.cancelWriting()
            try? FileManager.default.removeItem(at: self.videoURL)
        }
    }

    private func recordFailure() {
        guard let error = writer.error else { return }
        Self.log.error("Writer failed: \(error.localizedDescription, privacy: .public)")
    }
}

/// Makes silence that matches a real audio buffer.
///
/// A hole in the audio (a device unplugged, a stream stalled) has to be filled with
/// something, or every later sample sits earlier in the file than the picture it belongs
/// to. The filler has to have the same format as its neighbours, which is why it is
/// built from one.
///
/// Every refusal here returns `nil`. That is not defensiveness for its own sake: this runs
/// on a capture callback, `AVAudioPCMBuffer`'s initialiser reports bad arguments by raising
/// an Objective-C exception, and an exception on a dispatch queue is an abort — there is
/// nothing above it to catch it. Missing silence is a recording that is slightly out of
/// step. A raise is a recording that is gone.
enum SilenceBuffer {
    /// The longest silence worth synthesising in one buffer.
    ///
    /// Thirty seconds at 48 kHz stereo is about eleven megabytes, which is already far more
    /// than any real gap. Beyond this something has gone wrong with the clock rather than
    /// with the audio, and allocating what the arithmetic asks for is how that becomes an
    /// abort instead of a glitch.
    static let maximumDuration = CMTime(seconds: 30, preferredTimescale: 600)

    static func make(like buffer: CMSampleBuffer, duration: CMTime, at time: CMTime) -> CMSampleBuffer? {
        guard duration.isValid, !duration.isIndefinite, duration > .zero, duration <= maximumDuration,
              time.isValid,
              let description = buffer.formatDescription,
              let streamDescription = description.audioStreamBasicDescription
        else { return nil }

        // `AVAudioFormat(streamDescription:)` borrows the pointer it is given, so the
        // pointer has to be valid *while it reads it*. This used to be written as
        // `[streamDescription].withUnsafeBufferPointer { $0.baseAddress! }`, which returns
        // the address of a temporary array and then uses it after the closure — and
        // therefore after the array may be gone. It worked for as long as nothing happened
        // to reuse that memory, and when something did the format came back describing
        // whatever was there instead. A format that is not PCM makes `AVAudioPCMBuffer`
        // raise, which is why this was a crash in the middle of a recording rather than a
        // silence of the wrong length.
        var asbd = streamDescription
        guard let format = withUnsafePointer(to: &asbd, { AVAudioFormat(streamDescription: $0) }),
              // The raise this function exists to avoid. A compressed format has no frames
              // to zero, and there is no silence to make for it.
              format.commonFormat != .otherFormat,
              format.channelCount > 0, format.sampleRate > 0
        else { return nil }

        let requested = (duration.seconds * format.sampleRate).rounded()
        guard requested >= 1, requested.isFinite, requested <= Double(AVAudioFrameCount.max) else { return nil }
        let frames = AVAudioFrameCount(requested)
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        pcm.frameLength = frames   // freshly allocated buffers are zeroed, which is silence

        var sampleBuffer: CMSampleBuffer?
        let status = CMAudioSampleBufferCreateWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: description,
            sampleCount: CMItemCount(frames),
            presentationTimeStamp: time,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer)
        guard status == noErr, let sampleBuffer else { return nil }

        guard CMSampleBufferSetDataBufferFromAudioBufferList(sampleBuffer,
                                                             blockBufferAllocator: kCFAllocatorDefault,
                                                             blockBufferMemoryAllocator: kCFAllocatorDefault,
                                                             flags: 0,
                                                             bufferList: pcm.audioBufferList) == noErr
        else { return nil }
        return sampleBuffer
    }
}
