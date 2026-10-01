import Foundation

/// The few layout rules of the timeline strip that are arithmetic rather than drawing.
///
/// Here rather than beside the views that use them because each one has already been wrong
/// once in a way nobody could see until a particular recording turned up: a label gate
/// that hid every short zoom's "1.8×", a "0s" sitting under the playhead's knob. A rule
/// that lives in a view can only be checked by looking at it; one that lives here can be
/// pinned by a test, and the views are left with nothing to decide.
public enum TimelineLayout {
    // MARK: - Chips

    /// How wide a chip's grip bar is drawn, in points.
    ///
    /// Seven at most, and never more than a quarter of the chip — at that point the two bars
    /// and the label are competing for the same few points, and the label loses.
    public static func gripBar(forChipWidth width: Double) -> Double {
        max(3, min(7, width / 4))
    }

    /// The room a chip's words have once both grips have taken theirs.
    ///
    /// Measured against the *drawn* bars plus a hair of air, not against the wider area the
    /// grips can be grabbed by. The grab area is invisible and reaches inwards over nothing
    /// that needs protecting; reserving it took 28 points from every chip, and on a zoom
    /// at the auto-zoom minimum length that was the difference between "1.8×" and a blank
    /// purple block.
    public static func labelRoom(forChipWidth width: Double) -> Double {
        max(0, width - 2 * (gripBar(forChipWidth: width) + 2))
    }

    // MARK: - The ruler

    /// The least distance between two numbered marks on the ruler, in points.
    ///
    /// Wide enough for the longest label the ruler draws ("12:30" or "1:02.5" at 9.5 points
    /// monospaced is about 34) with a clear gap either side, so neighbours never touch.
    public static let minimumLabelSpacing: Double = 56

    /// The steps the ruler counts in, finest first.
    ///
    /// Every one of them a number the eye can add up: tenths, fifths, halves, then whole
    /// seconds in the usual clock divisions. A quarter of a second used to be among them,
    /// and printed at one decimal it labelled the marks "0.2s", "0.5s", "0.8s" — three
    /// numbers that are not evenly spaced, under marks that were.
    public static let rulerSteps: [Double] = [0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600]

    /// The ruler's step at a scale: the finest that keeps the numbers `minimumLabelSpacing`
    /// apart.
    public static func rulerStep(forPointsPerSecond pointsPerSecond: Double) -> Double {
        rulerSteps.first { $0 * pointsPerSecond >= minimumLabelSpacing } ?? 900
    }

    /// How many unlabelled marks divide one labelled interval.
    ///
    /// One, halfway, when the numbers are close together; more as they spread apart, so that
    /// zoomed in the eye always has a mark within about 25 points to measure against rather
    /// than a long empty run between two numbers. A step of 5 or 15 divides into fifths or
    /// thirds; the rest into halves, quarters or tenths — whatever lands on a round number.
    public static func rulerSubdivisions(step: Double, pointsPerSecond: Double) -> Int {
        let spacing = step * pointsPerSecond
        let candidates: [Int]
        switch step {
        case 5, 0.5: candidates = [5]
        case 15: candidates = [3]
        default: candidates = [2, 4, 10]
        }
        // The finest division that leaves at least 12 points between its marks, and never
        // fewer than the halfway mark the ruler has always had.
        return candidates.last { spacing / Double($0) >= 12 } ?? 2
    }

    /// How opaque a ruler number is, given where the playhead's knob is.
    ///
    /// Zero where the label and the knob overlap, so the number is never drawn under the
    /// knob and read through it; fully opaque `fade` points clear of it; a ramp between, so
    /// the numbers make way as the playhead passes instead of blinking out.
    ///
    /// - Parameters:
    ///   - minX: the label's left edge.
    ///   - maxX: the label's right edge.
    ///   - playheadX: the centre of the knob.
    ///   - knobRadius: half the knob's width, including its ring.
    public static func rulerLabelOpacity(minX: Double, maxX: Double,
                                         playheadX: Double,
                                         knobRadius: Double = 7,
                                         fade: Double = 6) -> Double {
        let gap: Double
        if playheadX < minX {
            gap = minX - playheadX - knobRadius
        } else if playheadX > maxX {
            gap = playheadX - maxX - knobRadius
        } else {
            gap = -1
        }
        guard gap > 0 else { return 0 }
        return min(1, gap / fade)
    }

    // MARK: - Sound

    /// A peak as it is drawn, 0…1, from a sample's level, 0…1.
    ///
    /// Drawn on a square-root curve rather than straight. Speech peaks around a fifth of
    /// full scale, and drawn linearly that is a waveform a fifth of a 38-point lane tall —
    /// a smear along the middle that says "something" without saying where the words are.
    /// The root lifts the quiet half of the range into view while keeping the order of
    /// everything in it, and leaves silence where it was: a recording with nothing on it
    /// still draws as a flat line.
    public static func displayedLevel(_ level: Float) -> Float {
        let magnitude = min(1, abs(level))
        return magnitude.squareRoot()
    }
}
