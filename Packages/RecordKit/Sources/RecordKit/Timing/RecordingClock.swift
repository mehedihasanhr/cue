import CoreMedia
import Foundation
import os

/// The one clock every part of a recording answers to.
///
/// Video frames, audio buffers and cursor samples all arrive from different subsystems
/// with different ideas of time. If each recorded its own, nothing would line up in the
/// editor. They all read this instead: the host clock, zeroed when the recording starts.
///
/// It also owns every pause. A hold takes real time out of the middle of a recording, and
/// that time has to come out of *everything* — the picture, each sound, the camera, and
/// the pointer's samples. It used to come out of the files only: each writer kept its own
/// total of time spent paused and the telemetry kept none, so after a two-second hold the
/// pointer was drawn two seconds late for the rest of the take, clicking things that had
/// long since happened in the picture. One owner means there is one number, and nothing
/// can be written down against a different one.
public final class RecordingClock: @unchecked Sendable {
    private struct State {
        var origin: CMTime?
        /// Holds that have ended, oldest first, in host time.
        var holds: [(from: CMTime, to: CMTime)] = []
        /// When the hold in force began. `nil` while the recording is running.
        var heldSince: CMTime?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    /// The host clock now — what an arriving sample buffer's timestamps are measured in.
    public static var now: CMTime { CMClockGetTime(CMClockGetHostTimeClock()) }

    /// Zeroes the clock. Called once, with the first frame's own timestamp, so the
    /// countdown and the permission dialog before it are not part of the recording.
    ///
    /// The frame's timestamp rather than the moment it was handed over: the file's time
    /// zero *is* that timestamp, and a frame reaches the writer a few milliseconds either
    /// side of it. Zeroing on arrival put the pointer's clock and the picture's that far
    /// apart, by a different amount in every recording.
    public func start(at time: CMTime = RecordingClock.now) {
        state.withLock { $0.origin = time }
    }

    public var startTime: CMTime? { state.withLock { $0.origin } }
    public var hasStarted: Bool { startTime != nil }

    // MARK: - Holds

    /// Stops the clock. Nothing stamped from here until `release` belongs to the recording.
    public func hold(at time: CMTime = RecordingClock.now) {
        state.withLock { state in
            guard state.heldSince == nil else { return }
            state.heldSince = time
        }
    }

    /// Lets the clock run again, with the held stretch gone from it.
    public func release(at time: CMTime = RecordingClock.now) {
        state.withLock { state in
            guard let since = state.heldSince else { return }
            state.heldSince = nil
            guard time > since else { return }
            state.holds.append((since, time))
        }
    }

    public var isHeld: Bool { state.withLock { $0.heldSince != nil } }

    /// A host timestamp with every hold before it taken out — the time this moment has in
    /// the recording's files. `nil` for a moment inside a hold, which has no place in them.
    ///
    /// Still in the host clock's numbers rather than counted from zero: it is what a
    /// writer hands to `AVAssetWriter`, whose session starts at the first frame's own
    /// timestamp.
    public func recordingTime(forHost time: CMTime) -> CMTime? {
        state.withLock { state in
            if let since = state.heldSince, time >= since { return nil }
            for hold in state.holds where time > hold.from && time < hold.to { return nil }
            return Self.settled(time, in: state)
        }
    }

    /// Seconds since the start with the holds taken out, for telemetry.
    ///
    /// Zero before the clock starts, so a sample that races the first frame lands at the
    /// beginning rather than in the past. Inside a hold it is the moment the hold began:
    /// the recording's clock is standing still there, which is what holding means.
    public func elapsed(at time: CMTime = RecordingClock.now) -> Double {
        state.withLock { state in
            guard let origin = state.origin else { return 0 }
            return max(0, (Self.settled(time, in: state) - origin).seconds)
        }
    }

    /// A host time with the holds before it removed, a moment inside a hold counting as
    /// the moment that hold began.
    private static func settled(_ time: CMTime, in state: State) -> CMTime {
        var removed = CMTime.zero
        for hold in state.holds {
            if time >= hold.to {
                removed = removed + (hold.to - hold.from)
            } else if time > hold.from {
                return hold.from - removed
            }
        }
        if let since = state.heldSince, time > since { return since - removed }
        return time - removed
    }
}
