import CoreGraphics
import Foundation

/// Keeps the pointer's trips to Cue's own camera bubble out of the recording.
///
/// The bubble is left out of the video, but the pointer is sampled wherever it goes, so the
/// finished picture had a pointer wandering to nothing, dragging nothing, and wandering back.
/// While the pointer is set aside the samples say it stayed where it was before it set off.
///
/// **Going there.** Nobody knows the pointer is heading for the bubble until it arrives, by
/// which time the trip has happened. So samples wait here for `rewind` before being written,
/// and arriving rewrites the ones still waiting.
///
/// **Coming back.** It stays put until it has left the bubble's spot and come to rest, or
/// the user clicks: that is them working again. The trip back is what that leaves out.
///
/// A value with no clock, thread or window in it, so all of this can be tested.
struct PointerAside {
    /// How much of the trip towards the bubble can be taken back, in seconds.
    static let rewind = 0.6
    /// How long the pointer must be still to have arrived somewhere, in seconds.
    static let rest = 0.25
    /// How far from the bubble, in points, counts as having left it.
    static let clearance = 40.0

    private enum Phase {
        case free
        /// On the bubble. `anchor` is `nil` only if nothing has been sampled yet.
        case held(anchor: CGPoint?)
        case leaving(anchor: CGPoint, drop: CGPoint?, hasLeft: Bool, still: CGPoint?, stillSince: Double)
    }

    private var phase = Phase.free
    private var waiting: [CursorSample] = []

    /// The pointer has reached the bubble, or (`false`) gone off it.
    mutating func setAside(_ aside: Bool) {
        switch (aside, phase) {
        case (true, .free):
            let anchor = waiting.first.map { CGPoint(x: $0.x, y: $0.y) }
            if let anchor {
                for index in waiting.indices {
                    waiting[index].x = anchor.x
                    waiting[index].y = anchor.y
                }
            }
            phase = .held(anchor: anchor)
        case (true, .leaving(let anchor, _, _, _, _)):
            phase = .held(anchor: anchor)
        case (false, .held(let anchor?)):
            phase = .leaving(anchor: anchor, drop: nil, hasLeft: false, still: nil, stillSince: 0)
        case (false, .held(nil)):
            phase = .free
        default:
            break
        }
    }

    /// A click somewhere else: whatever the pointer was doing, it is working again.
    mutating func clicked() {
        if case .leaving = phase { phase = .free }
    }

    /// Takes a new sample, and returns those now old enough to write.
    mutating func add(_ sample: CursorSample) -> [CursorSample] {
        var sample = sample
        let real = CGPoint(x: sample.x, y: sample.y)

        switch phase {
        case .free:
            break
        case .held(let anchor):
            let anchor = anchor ?? real
            phase = .held(anchor: anchor)
            sample.x = anchor.x
            sample.y = anchor.y
        case .leaving(let anchor, let drop, var hasLeft, var still, var stillSince):
            let drop = drop ?? real
            hasLeft = hasLeft || Self.distance(real, drop) > Self.clearance
            if still == nil || Self.distance(real, still!) > 2 {
                still = real
                stillSince = sample.t
            }
            let cameBack = hasLeft && Self.distance(real, anchor) <= Self.clearance
            if cameBack || (hasLeft && sample.t - stillSince >= Self.rest) {
                phase = .free
            } else {
                phase = .leaving(anchor: anchor, drop: drop, hasLeft: hasLeft, still: still, stillSince: stillSince)
                sample.x = anchor.x
                sample.y = anchor.y
            }
        }

        waiting.append(sample)
        let due = waiting.prefix { sample.t - $0.t >= Self.rewind }
        guard !due.isEmpty else { return [] }
        defer { waiting.removeFirst(due.count) }
        return Array(due)
    }

    /// Everything still waiting, when sampling stops.
    mutating func flush() -> [CursorSample] {
        defer { waiting = [] }
        return waiting
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
        hypot(a.x - b.x, a.y - b.y)
    }
}
