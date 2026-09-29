import CoreMedia
import Foundation
import os

/// The one clock every part of a recording answers to.
///
/// Video frames, audio buffers and cursor samples all arrive from different subsystems
/// with different ideas of time. If each recorded its own, nothing would line up in the
/// editor. They all read this instead: the host clock, zeroed when the recording starts.
public final class RecordingClock: @unchecked Sendable {
    private let origin = OSAllocatedUnfairLock<CMTime?>(initialState: nil)

    public init() {}

    /// The host clock now — what an arriving sample buffer's timestamps are measured in.
    public static var now: CMTime { CMClockGetTime(CMClockGetHostTimeClock()) }

    /// Zeroes the clock. Called once, when the first frame is about to be written, so
    /// the countdown and the permission dialog before it are not part of the recording.
    public func start(at time: CMTime = RecordingClock.now) {
        origin.withLock { $0 = time }
    }

    public var startTime: CMTime? { origin.withLock { $0 } }
    public var hasStarted: Bool { startTime != nil }

    /// Seconds since the start, for telemetry. Zero before the clock starts, so a sample
    /// that races the first frame lands at the beginning rather than in the past.
    public func elapsed(at time: CMTime = RecordingClock.now) -> Double {
        guard let start = startTime else { return 0 }
        return max(0, (time - start).seconds)
    }
}
