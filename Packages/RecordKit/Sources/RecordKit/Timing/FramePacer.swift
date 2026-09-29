import CoreMedia
import Foundation

/// Turns "the screen didn't change" into frames.
///
/// ScreenCaptureKit only delivers a frame when something moves. A recording of a still
/// screen therefore has huge gaps, and a file written from those timestamps plays back
/// as a video that freezes and then jumps — the audio, which never stops, drifts away
/// from it. The fix is to re-append the last frame at the times the encoder expected
/// one, which costs nothing (the same pixel buffer, a new presentation time) and keeps
/// the timeline honest.
///
/// Pure arithmetic, so the awkward cases are testable without a screen.
public struct FramePacer: Sendable {
    /// One frame's worth of time at the configured rate.
    public let frameDuration: CMTime
    /// How far behind before filler frames are emitted at all. Below this, the encoder's
    /// own timing is fine and filler would only inflate the file.
    public let tolerance: CMTime
    /// The most filler frames a single gap may produce, so a paused-then-resumed machine
    /// or a clock jump cannot emit thousands of frames at once.
    public let maximumFill: Int

    public init(frameRate: Int, maximumFillSeconds: Double = 2) {
        let rate = max(1, frameRate)
        frameDuration = CMTime(value: 1, timescale: CMTimeScale(rate))
        tolerance = CMTimeMultiplyByFloat64(frameDuration, multiplier: 1.5)
        maximumFill = max(1, Int(Double(rate) * maximumFillSeconds))
    }

    /// The presentation times to repeat the last frame at, given when the next real
    /// frame arrived.
    ///
    /// Empty when the frame arrived on time, or when there is no previous frame to
    /// repeat — a recording never starts with filler.
    public func fillTimes(lastFrame: CMTime?, next: CMTime) -> [CMTime] {
        guard let lastFrame, next > lastFrame else { return [] }
        let gap = next - lastFrame
        guard gap > tolerance else { return [] }

        var times: [CMTime] = []
        var time = lastFrame + frameDuration
        while time < next && times.count < maximumFill {
            times.append(time)
            time = time + frameDuration
        }
        return times
    }

    /// The times to repeat the last frame at when the recording stops on a still screen,
    /// so the file's duration matches the wall clock the user watched.
    public func tailTimes(lastFrame: CMTime?, end: CMTime) -> [CMTime] {
        fillTimes(lastFrame: lastFrame, next: end)
    }
}
