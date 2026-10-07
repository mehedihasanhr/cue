import CoreMedia
import Foundation
import Observation

/// How much of the edit the timeline is showing, and where.
///
/// Laid out by hand rather than inside a `ScrollView`: playhead-follow has to be able to
/// say "put 12.4 seconds at the left edge", and neither `scrollTo(id:)` nor
/// `scrollPosition(id:)` can express that — both address views, not time. Owning the
/// offset also makes `time(at:)` exact, which the scrubbing, snapping and waveform
/// arithmetic all depend on.
@MainActor
@Observable
final class TimelineViewport {
    /// One second, in points.
    private(set) var pointsPerSecond: Double = 40
    /// The time at the left edge. Allowed slightly negative, so the head trim bubble has
    /// somewhere to sit before zero without a special case in every conversion.
    private(set) var scrollOffset: Double = 0
    /// The visible width, in points.
    private(set) var width: Double = 1
    /// Whether the view chases the playhead. Turned off by a manual scroll, back on when
    /// playback starts.
    var followsPlayhead = true

    /// Whether the whole edit still has to be fitted to the view.
    ///
    /// SwiftUI lays a `GeometryReader` out at zero before it lays it out for real, and
    /// `onAppear` can arrive in that first pass. Fitting to a width of one point pins the
    /// scale at its minimum — the whole recording as a sliver a few points wide — and
    /// nothing afterwards asked for the fit again. So the fit is owed until it happens at
    /// a width worth fitting to.
    private var needsFit = true

    /// Whether the scale is still "the whole edit", as opposed to one somebody zoomed to.
    ///
    /// The fit used to be taken once, at the first width — so hiding the inspector, or
    /// making the window bigger, left the edit filling the half of the strip it was fitted
    /// to and empty lanes after it. While nobody has zoomed, the edit keeps filling the
    /// strip, as wide as it is and as long as the edit is. Zooming takes it off; Fit, and
    /// ⌘0, put it back.
    private(set) var isFitted = true

    static let minimumPointsPerSecond = 1.0
    /// At 600 points a second one frame of 60 fps is ten points wide — enough to put a
    /// cut exactly where you mean to.
    static let maximumPointsPerSecond = 600.0

    // MARK: - Conversions

    func x(for time: CMTime) -> Double { (time.seconds - scrollOffset) * pointsPerSecond }
    func x(forSeconds seconds: Double) -> Double { (seconds - scrollOffset) * pointsPerSecond }

    func time(at x: Double) -> CMTime {
        CMTime(seconds: seconds(at: x), preferredTimescale: 600)
    }

    func seconds(at x: Double) -> Double { scrollOffset + x / pointsPerSecond }

    /// The stretch of time on screen, which is all the drawing code needs to look at.
    var visibleSeconds: ClosedRange<Double> {
        scrollOffset...(scrollOffset + width / pointsPerSecond)
    }

    // MARK: - Changing the view

    func setWidth(_ width: Double, duration: CMTime) {
        let width = max(1, width)
        // A tolerance, not an exact compare: the strip's height is recomputed from the
        // timeline, so adding a row relays it out by a fraction of a point, and clamping
        // on that would nudge the scroll offset for no reason anyone asked for.
        guard abs(width - self.width) > 0.5 || needsFit else { return }
        self.width = width
        if (needsFit || isFitted), width > 1 {
            fit(duration)
        } else {
            clamp(duration: duration)
        }
    }

    /// The whole edit, edge to edge, with a little air at each end.
    func fit(_ duration: CMTime) {
        // A fit at a width nobody can see is not a fit; it is the bug above.
        if width > 1 { needsFit = false }
        isFitted = true
        let seconds = max(0.5, duration.seconds)
        pointsPerSecond = min(Self.maximumPointsPerSecond,
                              max(Self.minimumPointsPerSecond, (width - 24) / seconds))
        scrollOffset = -12 / pointsPerSecond
        followsPlayhead = true
    }

    /// Zooms while keeping `time` under the same point on screen, which is what makes
    /// ⌘-scroll and pinch feel like they are aimed at something.
    func setPointsPerSecond(_ proposed: Double, anchoring time: CMTime, duration: CMTime) {
        let anchorX = x(for: time)
        isFitted = false
        pointsPerSecond = min(Self.maximumPointsPerSecond, max(Self.minimumPointsPerSecond, proposed))
        scrollOffset = time.seconds - anchorX / pointsPerSecond
        clamp(duration: duration)
    }

    func zoom(by factor: Double, anchoring time: CMTime, duration: CMTime) {
        setPointsPerSecond(pointsPerSecond * factor, anchoring: time, duration: duration)
    }

    /// Fits again when the edit got longer or shorter, if it is being shown whole.
    func durationChanged(_ duration: CMTime) {
        if isFitted { fit(duration) } else { clamp(duration: duration) }
    }

    func scroll(by points: Double, duration: CMTime) {
        scrollOffset += points / pointsPerSecond
        followsPlayhead = false
        clamp(duration: duration)
    }

    /// Keeps the playhead on screen during playback.
    ///
    /// A page turn rather than continuous centring: sliding the whole timeline under a
    /// pinned playhead makes it impossible to aim at anything, and reads as the content
    /// moving rather than the view.
    func reveal(_ time: CMTime, duration: CMTime) {
        guard followsPlayhead else { return }
        let visible = width / pointsPerSecond
        guard duration.seconds > visible else { return }   // it all fits; nothing to chase

        let position = x(for: time)
        guard position < width * 0.15 || position > width * 0.85 else { return }
        scrollOffset = time.seconds - visible * 0.25
        clamp(duration: duration)
    }

    private func clamp(duration: CMTime) {
        let visible = width / pointsPerSecond
        let lead = 12 / pointsPerSecond
        let last = max(-lead, duration.seconds - visible + lead)
        scrollOffset = min(last, max(-lead, scrollOffset))
    }
}
