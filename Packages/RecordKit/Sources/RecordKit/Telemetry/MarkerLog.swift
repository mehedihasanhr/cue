import CoreMedia
import Foundation
import os

/// A moment the person recording asked to find again.
///
/// Only a time, in seconds of the recording's own clock — the same clock the pointer and
/// every file answer to, so a marker dropped after a pause lands on the frame that was on
/// screen when the button was pressed rather than a pause-length later.
public struct MarkerSample: Codable, Equatable, Sendable {
    /// Seconds since the recording's clock started, with every pause taken out.
    public var t: Double

    public init(t: Double) { self.t = t }
}

/// The markers of one take, written as they are dropped.
///
/// A sidecar in `telemetry/` rather than a list in the manifest, and the reason is the
/// crash: the manifest is written once, when the take stops, and a take that never stops
/// properly has none until recovery rebuilds it. A marker written the moment it is dropped
/// is flushed with the rest of the telemetry, survives the crash with the video, and is cut
/// to the recovered picture by the same rule as every other sidecar — they all carry `t`.
public final class MarkerLog: @unchecked Sendable {
    /// Where the log lives inside a package, as the manifest names it.
    public static let path = "telemetry/markers.jsonl"

    /// Two presses closer than this are one marker. A shortcut held a moment too long, or a
    /// button and its shortcut pressed together, should not leave two ticks on the ruler a
    /// frame apart.
    public static let minimumSpacing = 0.3

    private let writer: JSONLWriter
    private let queue: DispatchQueue
    private let clock: RecordingClock
    private let times = OSAllocatedUnfairLock(initialState: [Double]())

    public init(writer: JSONLWriter, queue: DispatchQueue, clock: RecordingClock) {
        self.writer = writer
        self.queue = queue
        self.clock = clock
    }

    /// Drops a marker at a moment, and says where it landed — or `nil` when it did not,
    /// because the clock has not started or the last marker is too close.
    ///
    /// The time comes from the clock, so a marker dropped during a pause is at the moment
    /// the pause began: that is the frame the recording is standing on.
    @discardableResult
    public func add(at host: CMTime = RecordingClock.now) -> MarkerSample? {
        guard clock.hasStarted else { return nil }
        let t = clock.elapsed(at: host)
        let accepted = times.withLock { times -> Bool in
            if let last = times.last, abs(t - last) < Self.minimumSpacing { return false }
            times.append(t)
            return true
        }
        guard accepted else { return nil }
        let sample = MarkerSample(t: t)
        let writer = writer
        queue.async { writer.append(sample) }
        return sample
    }

    /// Every marker dropped so far, in the order they were dropped.
    public var markers: [MarkerSample] { times.withLock { $0.map(MarkerSample.init(t:)) } }
}
