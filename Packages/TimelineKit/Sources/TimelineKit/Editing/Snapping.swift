import CoreMedia
import Foundation

/// Making a drag land where the user meant it to.
///
/// Snapping is measured in **screen points**, not seconds: at a wide timeline zoom a
/// tenth of a second is a hair's width, and at a tight one it is half the window. A
/// tolerance in time would mean the same edit feels sticky at one zoom and impossible at
/// another.
public struct Snapping: Sendable {
    /// How close, in points, before a drag gives in.
    public let tolerance: Double
    /// The timeline's zoom: how many points one second occupies.
    public let pointsPerSecond: Double
    /// A ceiling on the tolerance in time.
    ///
    /// Points are the right unit right up until the timeline is zoomed all the way out,
    /// where eight points on a half-hour recording is sixteen seconds and every drag
    /// slams into the nearest cut. The cap costs nothing at any usable zoom and makes
    /// free positioning possible at the extreme one.
    public let maximumSeconds: Double

    /// Snapping turned off, for the modifier-held drag.
    public static let disabled = Snapping(pointsPerSecond: 1, tolerance: 0, maximumSeconds: 0)

    public init(pointsPerSecond: Double, tolerance: Double = 8, maximumSeconds: Double = 0.5) {
        self.pointsPerSecond = max(0.0001, pointsPerSecond)
        self.tolerance = tolerance
        self.maximumSeconds = maximumSeconds
    }

    /// The tolerance actually used, in points.
    var effectiveTolerance: Double {
        min(tolerance, maximumSeconds * pointsPerSecond)
    }

    /// The nearest boundary within tolerance, or the original time.
    public func snap(_ time: CMTime, to boundaries: [CMTime]) -> CMTime {
        let tolerance = effectiveTolerance
        guard tolerance > 0 else { return time }
        var best: CMTime?
        var bestDistance = Double.infinity

        for boundary in boundaries {
            let distance = abs((boundary - time).seconds) * pointsPerSecond
            if distance <= tolerance && distance < bestDistance {
                best = boundary
                bestDistance = distance
            }
        }
        return best ?? time
    }

    /// Snaps a region being dragged, keeping its length.
    ///
    /// Both edges are candidates, and the closer one wins: dragging a five-second zoom by
    /// its middle should still click into place when its *end* meets a cut.
    public func snapRegion(start: CMTime, duration: CMTime, to boundaries: [CMTime]) -> CMTime {
        let snappedStart = snap(start, to: boundaries)
        let snappedEnd = snap(start + duration, to: boundaries) - duration

        let startMoved = abs((snappedStart - start).seconds)
        let endMoved = abs((snappedEnd - start).seconds)
        if startMoved == 0 && endMoved == 0 { return start }
        return startMoved <= endMoved && startMoved > 0 ? snappedStart
            : (endMoved > 0 ? snappedEnd : snappedStart)
    }
}
